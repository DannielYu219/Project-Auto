//
//  SmolvmRuntime.swift
//  Project-Auto
//
//  驱动打包好的 velum-pack（smolvm 自包含 VM）：
//  - start/stop 由 pack stub 管理，不需要用户安装 smolvm CLI
//  - exec 通过 `velum-pack exec -- bash -lc <cmd>`，返回 stdout/stderr/退出码
//  - 工作区以 `-v <host>:/workspace` 挂进 guest
//
//  【开发期】App 以非沙盒方式运行，才能把带 hypervisor entitlement 的
//  pack stub 作为子进程启动；正式分发改用 helper/XPC。
//

import Foundation

struct SmolvmResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var timedOut: Bool = false
}

enum SmolvmError: Error, LocalizedError {
    case packNotFound
    case startFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .packNotFound: return "找不到 velum-pack（可用 VELUM_PACK_PATH 指定）"
        case .startFailed(let detail): return "Linux 沙盒启动失败：\(detail)"
        case .executionFailed(let detail): return "命令执行失败：\(detail)"
        }
    }
}

nonisolated final class SmolvmRuntime: @unchecked Sendable {
    let packURL: URL
    let workspaceURL: URL
    private let lock = NSLock()
    private var mountArguments: [String] = []

    func configureMountArguments(_ arguments: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard arguments != mountArguments else { return }
        // The packed daemon's volumes are fixed at boot. Preserve disk state, refuse changes while commands run in HelperService.
        if status().running {
            let stopped = try runProcess(["stop"], timeout: 30)
            guard stopped.exitCode == 0 else { throw SmolvmError.executionFailed(stopped.stderr) }
        }
        mountArguments = arguments
    }

    init(packURL: URL, workspaceURL: URL) {
        self.packURL = packURL
        self.workspaceURL = workspaceURL
    }

    static func makeDefault() -> SmolvmRuntime? {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [String] = [
            environment["VELUM_PACK_PATH"] ?? "",
            Bundle.main.resourceURL?.appendingPathComponent("velum-pack").path ?? "",
            "/Users/dannielyu/Project-Auto/Runtime/pack/velum-pack"
        ]
        guard let path = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let workspacePath = environment["VELUM_WORKSPACE"] ?? defaultWorkspacePath()
        try? FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)
        return SmolvmRuntime(packURL: URL(fileURLWithPath: path),
                             workspaceURL: URL(fileURLWithPath: workspacePath))
    }

    static func defaultWorkspacePath() -> String {
        // 必须放在 App 容器之外：helper 读不到 App 自己的容器，
        // virtiofs 挂载会失败。沙盒 App 通过 temporary-exception 访问此路径。
        // 共享路径避免把用户名写死；正式分发应换成 App Group 容器。
        let url = URL(fileURLWithPath: "/Users/Shared/Velum/workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: - 生命周期

    func status() -> (running: Bool, output: String) {
        guard let result = try? runProcess(["status"], timeout: 10) else {
            return (false, "")
        }
        let text = result.stdout + result.stderr
        // 注意 "not running" 也包含 "running"；只认 "Status: running"。
        let running = result.exitCode == 0
            && text.range(of: "Status: running", options: .caseInsensitive) != nil
        return (running, text)
    }

    func ensureStarted() throws {
        lock.lock()
        defer { lock.unlock() }
        if status().running { return }
        let result = try runProcess(["start", "-v", "\(workspaceURL.path):/workspace"] + mountArguments,
                                    timeout: 90)
        guard result.exitCode == 0 else {
            throw SmolvmError.startFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func stop() {
        _ = try? runProcess(["stop"], timeout: 30)
    }

    func exec(_ command: String, timeout: TimeInterval = 60) async throws -> SmolvmResult {
        try ensureStarted()
        // -t 分配 PTY：否则 pack exec 会把输出攒到命令结束才一次性返回，
        // UI 就看不到进度。
        let args = ["exec", "-t", "--", "bash", "-lc", command]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runProcess(args, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }


    /// 流式执行：stdout/stderr 一产生就回调，UI 可实时显示。
    func execStreaming(_ command: String,
                       timeout: TimeInterval,
                       onOutput: @escaping @Sendable (String, Bool) -> Void) async throws -> SmolvmResult {
        try ensureStarted()
        // -t 分配 PTY：否则 pack exec 会把输出攒到命令结束才一次性返回，
        // UI 就看不到进度。
        let args = ["exec", "-t", "--", "bash", "-lc", command]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runProcessStreaming(args, timeout: timeout, onOutput: onOutput)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runProcessStreaming(_ arguments: [String],
                                     timeout: TimeInterval,
                                     onOutput: @escaping @Sendable (String, Bool) -> Void) throws -> SmolvmResult {
        let process = Process()
        process.executableURL = packURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let lock = NSLock()
        var outText = ""
        var errText = ""

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = Self.sanitizeStream(String(decoding: data, as: UTF8.self))
            lock.lock()
            outText += text
            lock.unlock()
            onOutput(text, false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = Self.sanitizeStream(String(decoding: data, as: UTF8.self))
            lock.lock()
            errText += text
            lock.unlock()
            onOutput(text, true)
        }

        try process.run()

        let deadline = Date().addingTimeInterval(max(1, timeout))
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        // Drain anything still buffered in the pipes.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            let text = Self.sanitizeStream(String(decoding: rest, as: UTF8.self))
            lock.lock(); outText += text; lock.unlock()
            onOutput(text, false)
        }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            let text = Self.sanitizeStream(String(decoding: rest, as: UTF8.self))
            lock.lock(); errText += text; lock.unlock()
            onOutput(text, true)
        }

        lock.lock()
        let finalOut = outText
        let finalErr = errText
        lock.unlock()
        return SmolvmResult(stdout: finalOut.trimmingCharacters(in: .whitespacesAndNewlines),
                            stderr: finalErr.trimmingCharacters(in: .whitespacesAndNewlines),
                            exitCode: process.terminationStatus,
                            timedOut: timedOut)
    }

    private static func sanitizeStream(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
                                                with: "",
                                                options: .regularExpression)
        return cleaned
    }

    // MARK: - 进程


    private func runProcess(_ arguments: [String], timeout: TimeInterval) throws -> SmolvmResult {
        let process = Process()
        process.executableURL = packURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(max(1, timeout))
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()

        func text(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SmolvmResult(stdout: text(outData),
                            stderr: text(errData),
                            exitCode: process.terminationStatus,
                            timedOut: timedOut)
    }
}

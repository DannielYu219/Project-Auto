//
//  LinuxHelperClient.swift
//  Project-Auto
//
//  主 App 与 XPC helper 的客户端。App 保持沙盒，命令由 helper 进程执行，
//  helper 再拉起嵌入的 velum-pack。
//
//  XPC 只允许一个 reply block，所以长命令采用 start/poll：
//  start 立即返回 token，App 每 100ms 取一次增量输出。
//

import Foundation

@objc protocol LinuxHelperProtocol {
    func startExec(command: String,
                   packPath: String,
                   workspacePath: String,
                   timeout: Double,
                   reply: @escaping (String) -> Void)
    func pollExec(token: String,
                  reply: @escaping (String, Bool, String, String, Int32, Bool) -> Void)
    func configureMounts(packPath: String, workspacePath: String, mounts: Data,
                         reply: @escaping (String?) -> Void)
    func splitEngineRequest(requestJSON: String, reply: @escaping (String?, String?) -> Void)
    func localRuntimeRequest(requestJSON: String, reply: @escaping (String?, String?) -> Void)
    func stop(reply: @escaping () -> Void)
}

protocol LinuxExecuting: Sendable {
    var workspaceURL: URL { get }
    func exec(_ command: String, timeout: TimeInterval) async throws -> SmolvmResult
    func execStreaming(_ command: String,
                       timeout: TimeInterval,
                       onOutput: @escaping @Sendable (String, Bool) -> Void) async throws -> SmolvmResult
    func stop()
}

nonisolated final class LinuxHelperClient: NSObject, LinuxExecuting, @unchecked Sendable {
    static let serviceName = "com.lyrastudio.Project-Auto.LinuxHelper"

    let packPath: String
    let workspacePath: String

    var workspaceURL: URL { URL(fileURLWithPath: workspacePath) }
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(packPath: String, workspacePath: String) {
        self.packPath = packPath
        self.workspacePath = workspacePath
        super.init()
    }

    private static let defaultLock = NSLock()
    nonisolated(unsafe) private static var defaultClient: LinuxHelperClient?

    static func makeDefault() -> LinuxHelperClient? {
        defaultLock.lock()
        defer { defaultLock.unlock() }
        if let defaultClient { return defaultClient }
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle.main.bundleURL
        let helper = bundle.appendingPathComponent("Contents/XPCServices/VelumLinuxHelper.xpc")
        guard FileManager.default.fileExists(atPath: helper.path) else { return nil }

        let pack = environment["VELUM_PACK_PATH"]
            ?? Bundle.main.resourceURL?.appendingPathComponent("velum-pack").path
        guard let pack, FileManager.default.isExecutableFile(atPath: pack) else { return nil }

        let workspace = environment["VELUM_WORKSPACE"] ?? SmolvmRuntime.defaultWorkspacePath()
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let client = LinuxHelperClient(packPath: pack, workspacePath: workspace)
        defaultClient = client
        return client
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let created = NSXPCConnection(serviceName: Self.serviceName)
        created.remoteObjectInterface = NSXPCInterface(with: LinuxHelperProtocol.self)
        created.invalidationHandler = { [weak self] in
            self?.lock.lock()
            self?.connection = nil
            self?.lock.unlock()
        }
        created.resume()
        connection = created
        return created
    }

    func exec(_ command: String, timeout: TimeInterval) async throws -> SmolvmResult {
        try await execStreaming(command, timeout: timeout, onOutput: { _, _ in })
    }

    func execStreaming(_ command: String,
                       timeout: TimeInterval,
                       onOutput: @escaping @Sendable (String, Bool) -> Void) async throws -> SmolvmResult {
        let saved = UserDefaults.standard.data(forKey: "velum.linux.mounts.v1") ?? Data("[]".utf8)
        try await configureMounts(saved)
        let token = try await startExec(command: command, timeout: timeout)
        while true {
            let poll = try await pollExec(token: token)
            if !poll.chunk.isEmpty {
                onOutput(poll.chunk, false)
            }
            if poll.done {
                return SmolvmResult(stdout: poll.stdout,
                                    stderr: poll.stderr,
                                    exitCode: poll.exitCode,
                                    timedOut: poll.timedOut)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func startExec(command: String, timeout: TimeInterval) async throws -> String {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? LinuxHelperProtocol else {
                continuation.resume(throwing: SmolvmError.executionFailed("helper 不可用"))
                return
            }
            proxy.startExec(command: command,
                            packPath: packPath,
                            workspacePath: workspacePath,
                            timeout: timeout) { token in
                continuation.resume(returning: token)
            }
        }
    }

    private func pollExec(token: String) async throws -> (chunk: String, done: Bool, stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? LinuxHelperProtocol else {
                continuation.resume(throwing: SmolvmError.executionFailed("helper 不可用"))
                return
            }
            proxy.pollExec(token: token) { chunk, done, stdout, stderr, exitCode, timedOut in
                continuation.resume(returning: (chunk, done, stdout, stderr, exitCode, timedOut))
            }
        }
    }

    func configureMounts(_ data: Data) async throws {
        let connection = currentConnection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ continuation.resume(throwing: $0) }) as? LinuxHelperProtocol else {
                continuation.resume(throwing: SmolvmError.executionFailed("helper 不可用")); return
            }
            proxy.configureMounts(packPath: packPath, workspacePath: workspacePath, mounts: data) { error in
                if let error { continuation.resume(throwing: SmolvmError.executionFailed(error)) }
                else { continuation.resume() }
            }
        }
    }

    func stop() {
        let connection = currentConnection()
        (connection.remoteObjectProxy as? LinuxHelperProtocol)?.stop {}
    }
}

extension LinuxExecuting {
    func exec(_ command: String) async throws -> SmolvmResult {
        try await exec(command, timeout: 60)
    }

    func execStreaming(_ command: String,
                       timeout: TimeInterval,
                       onOutput: @escaping @Sendable (String, Bool) -> Void) async throws -> SmolvmResult {
        let result = try await exec(command, timeout: timeout)
        if !result.stdout.isEmpty { onOutput(result.stdout, false) }
        if !result.stderr.isEmpty { onOutput(result.stderr, true) }
        return result
    }
}

extension SmolvmRuntime: LinuxExecuting {}

enum LinuxRuntimeFactory {
    static func make() -> (any LinuxExecuting)? {
        if ProcessInfo.processInfo.environment["VELUM_DIRECT_RUNTIME"] == "1" {
            return SmolvmRuntime.makeDefault()
        }
        if let helper = LinuxHelperClient.makeDefault() {
            return helper
        }
        return SmolvmRuntime.makeDefault()
    }
}

//
//  HelperService.swift
//  VelumLinuxHelper
//

import Foundation

final class HelperService: NSObject, LinuxHelperProtocol {
    func splitEngineRequest(requestJSON: String, reply: @escaping (String?, String?) -> Void) {
        Task {
            do { reply(try await SplitEngineService.shared.handle(requestJSON), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func localRuntimeRequest(requestJSON: String, reply: @escaping (String?, String?) -> Void) {
        Task {
            do { reply(try await LocalRuntimeService.shared.handle(requestJSON), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    private final class Run {
        var buffer = ""
        var done = false
        var result: SmolvmResult?
        var error: String?
    }

    private let lock = NSLock()
    private var runtime: SmolvmRuntime?
    private var runtimeKey: String?
    private var runs: [String: Run] = [:]
    private var mountConfiguration = Data()
    private var grantedURLs: [URL] = []

    private struct MountGrant: Decodable {
        var id: String
        var hostPath: String
        var guestPath: String
        var readOnly: Bool
        var bookmark: Data
        var helperBookmark: Data
    }

    func configureMounts(packPath: String, workspacePath: String, mounts: Data,
                         reply: @escaping (String?) -> Void) {
        let runtime = runtime(packPath: packPath, workspacePath: workspacePath)
        lock.lock()
        defer { lock.unlock() }
        if mounts == mountConfiguration { reply(nil); return }
        guard !runs.values.contains(where: { !$0.done }) else {
            reply("命令执行期间不能更改挂载；等待命令完成后再试。"); return
        }
        var accessed: [URL] = []
        do {
            let grants = try JSONDecoder().decode([MountGrant].self, from: mounts)
            var arguments: [String] = []
            for grant in grants {
                guard UUID(uuidString: grant.id) != nil,
                      grant.guestPath == "/mnt/mac/\(grant.id)" else {
                    throw SmolvmError.executionFailed("挂载目标只能位于 /mnt/mac/<grant-id>")
                }
                var stale = false
                // App-scoped security bookmarks belong to the App's sandbox identity.
                // The unsandboxed embedded helper resolves the separately granted portable bookmark.
                let url = try URL(resolvingBookmarkData: grant.helperBookmark, options: [.withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.standardizedFileURL.path == URL(fileURLWithPath: grant.hostPath).standardizedFileURL.path else {
                    throw SmolvmError.executionFailed("目录授权已失效，请重新选择目录")
                }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                    throw SmolvmError.executionFailed("授权目录不存在")
                }
                _ = url.startAccessingSecurityScopedResource()
                accessed.append(url)
                guard !url.path.contains(":"), !url.path.contains("\n") else {
                    throw SmolvmError.executionFailed("此目录路径暂不支持挂载")
                }
                arguments += ["-v", "\(url.path):\(grant.guestPath):\(grant.readOnly ? "ro" : "rw")"]
            }
            try runtime.configureMountArguments(arguments)
            for url in grantedURLs { url.stopAccessingSecurityScopedResource() }
            grantedURLs = accessed
            mountConfiguration = mounts
            reply(nil)
        } catch {
            for url in accessed { url.stopAccessingSecurityScopedResource() }
            reply(error.localizedDescription)
        }
    }

    private func runtime(packPath: String, workspacePath: String) -> SmolvmRuntime {
        lock.lock()
        defer { lock.unlock() }
        let key = packPath + "|" + workspacePath
        if let runtime, runtimeKey == key {
            return runtime
        }
        let created = SmolvmRuntime(packURL: URL(fileURLWithPath: packPath),
                                    workspaceURL: URL(fileURLWithPath: workspacePath))
        runtime = created
        runtimeKey = key
        return created
    }

    func startExec(command: String,
                   packPath: String,
                   workspacePath: String,
                   timeout: Double,
                   reply: @escaping (String) -> Void) {
        let runtime = runtime(packPath: packPath, workspacePath: workspacePath)
        let token = UUID().uuidString
        let run = Run()
        lock.lock()
        runs[token] = run
        lock.unlock()

        Task { [weak self] in
            do {
                let result = try await runtime.execStreaming(command, timeout: timeout) { text, _ in
                    guard let self else { return }
                    self.lock.lock()
                    if let run = self.runs[token] {
                        run.buffer += text
                        if run.buffer.count > 1_000_000 {
                            run.buffer = String(run.buffer.suffix(500_000))
                        }
                    }
                    self.lock.unlock()
                }
                self?.lock.lock()
                run.result = result
                run.done = true
                self?.lock.unlock()
            } catch {
                self?.lock.lock()
                run.error = error.localizedDescription
                run.done = true
                self?.lock.unlock()
            }
        }
        reply(token)
    }

    func pollExec(token: String,
                  reply: @escaping (String, Bool, String, String, Int32, Bool) -> Void) {
        lock.lock()
        guard let run = runs[token] else {
            lock.unlock()
            reply("", true, "", "run not found", 1, false)
            return
        }
        let chunk = run.buffer
        run.buffer = ""
        if run.done {
            runs.removeValue(forKey: token)
            let result = run.result
            let error = run.error
            lock.unlock()
            reply(chunk,
                  true,
                  result?.stdout ?? "",
                  result?.stderr ?? error ?? "",
                  result?.exitCode ?? 1,
                  result?.timedOut ?? false)
        } else {
            lock.unlock()
            reply(chunk, false, "", "", 0, false)
        }
    }

    func stop(reply: @escaping () -> Void) {
        lock.lock()
        let runtime = self.runtime
        runs.removeAll()
        lock.unlock()
        runtime?.stop()
        reply()
    }
}

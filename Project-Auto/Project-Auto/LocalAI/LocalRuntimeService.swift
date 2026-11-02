import Foundation
import Security
import Darwin

nonisolated private struct LocalRuntimeRegistry: Codable, Sendable {
    var schemaVersion = 1
    var installations: [LocalRuntimeInstallation] = []
}

nonisolated private struct LocalRuntimePreferences: Codable, Sendable {
    var schemaVersion = 1
    var proxyURL: String? = nil
}

nonisolated private final class LocalRuntimeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()
    func append(_ data: Data, stderr: Bool) {
        lock.lock(); defer { lock.unlock() }
        if stderr {
            errorOutput.append(data)
            if errorOutput.count > 16_384 { errorOutput.removeFirst(errorOutput.count - 16_384) }
        } else if output.count < 65_536 {
            output.append(data.prefix(65_536 - output.count))
        }
    }
    func firstLine() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let index = output.firstIndex(of: 10) else { return nil }
        return Data(output[..<index])
    }
}

// Only this actor owns Process. The app talks to handle() through XPC, never an
// arbitrary command runner. The default root is outside the application bundle.
actor LocalRuntimeService {
    static let defaultRoot = URL(fileURLWithPath: "/Users/Shared/Velum/ai", isDirectory: true)
    static let shared = LocalRuntimeService()
    let root: URL
    private let checkSignatures: Bool
    private var status: LocalRuntimeStatus = .notInstalled
    private var lastError: String?
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var endpoint: LocalRuntimeConnection?
    private var busy = false
    private var sessionID = UUID()
    private let session: URLSession

    init(root: URL = LocalRuntimeService.defaultRoot) {
        self.root = root.standardizedFileURL
        self.checkSignatures = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration, delegate: LocalRuntimeHTTPPolicy.shared, delegateQueue: nil)
    }

    #if LOCAL_RUNTIME_SELF_TEST
    init(root: URL, checkSignatures: Bool) {
        self.root = root.standardizedFileURL
        self.checkSignatures = checkSignatures
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: configuration, delegate: LocalRuntimeHTTPPolicy.shared, delegateQueue: nil)
    }
    #endif

    func handle(_ requestJSON: String) async throws -> String {
        guard let data = requestJSON.data(using: .utf8), data.count <= 1_048_576 else { throw LocalRuntimeError.unavailable("运行时请求过大或编码无效。") }
        let request = try JSONDecoder().decode(LocalRuntimeRequest.self, from: data)
        switch request.op {
        case "status": break
        case "setProxy":
            try beginOperation(); defer { busy = false }
            guard process?.isRunning != true else {
                throw LocalRuntimeError.unavailable("请先停止本地 AI 运行时，再修改下载代理；当前任务不会被中断。")
            }
            try savePreferences(LocalRuntimePreferences(proxyURL: try validatedProxy(request.proxyURL)))
            lastError = nil
        case "install":
            try beginOperation(); defer { busy = false }
            guard process?.isRunning != true else {
                throw LocalRuntimeError.unavailable("请先停止本地 AI 运行时，再安装或更新版本；当前任务不会被中断。")
            }
            let priorStatus = status
            status = .installing; lastError = nil
            do { try install(request); status = process?.isRunning == true ? .ready : .installed }
            catch {
                status = process?.isRunning == true ? .ready : priorStatus
                lastError = sanitized(error)
                throw error
            }
        case "start":
            if process?.isRunning == true, endpoint != nil { break }
            try beginOperation(); defer { busy = false }
            status = .starting; lastError = nil
            do { try await launchActive() }
            catch {
                await stopOwnedProcess()
                status = .crashed; lastError = sanitized(error)
                // Failed updated runtimes never strand the active registry. Restore
                // the retained previous version; let the next start retry it.
                try? restorePrevious()
                throw error
            }
        case "stop":
            try beginOperation(); defer { busy = false }
            await stopOwnedProcess(); status = .stopped; lastError = nil
        case "rollback":
            try beginOperation(); defer { busy = false }
            let wasRunning = process?.isRunning == true
            await stopOwnedProcess()
            do {
                try restorePrevious(); status = .installed; lastError = nil
                if wasRunning { try await launchActive() }
            } catch { status = .crashed; lastError = sanitized(error); throw error }
        default: throw LocalRuntimeError.unavailable("未知运行时操作。")
        }
        return try encodedSnapshot()
    }

    private func beginOperation() throws {
        guard !busy else { throw LocalRuntimeError.unavailable("另一个运行时操作正在进行。") }
        busy = true
    }

    private func prepareStorage() throws {
        try LocalRuntimeValidation.ensureDirectory(root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw LocalRuntimeError.unavailable("运行时根目录不属于当前用户。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for name in ["runtimes", "registry", "staging", "Models"] {
            try LocalRuntimeValidation.ensureDirectory(root.appendingPathComponent(name, isDirectory: true))
        }
    }

    private var registryURL: URL { root.appendingPathComponent("registry/runtimes.json") }
    private var preferencesURL: URL { root.appendingPathComponent("registry/preferences.json") }

    private func validatedProxy(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count <= 512, let url = URL(string: value),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host, ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
              let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw LocalRuntimeError.unavailable("下载代理必须为 HTTP(S) 本机回环地址和有效端口，例如 http://127.0.0.1:7890。")
        }
        return url.absoluteString
    }

    private func preferences() throws -> LocalRuntimePreferences {
        try prepareStorage()
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return LocalRuntimePreferences(proxyURL: try validatedProxy(ProcessInfo.processInfo.environment["VELUM_DOWNLOAD_PROXY"]))
        }
        try LocalRuntimeValidation.rejectSymbolicAncestors(preferencesURL)
        let data = try Data(contentsOf: preferencesURL)
        guard data.count <= 4096 else { throw LocalRuntimeError.unavailable("运行时偏好设置过大。") }
        let saved = try JSONDecoder().decode(LocalRuntimePreferences.self, from: data)
        guard saved.schemaVersion == 1 else { throw LocalRuntimeError.unavailable("运行时偏好设置版本无效。") }
        return LocalRuntimePreferences(proxyURL: try validatedProxy(saved.proxyURL))
    }

    private func savePreferences(_ preferences: LocalRuntimePreferences) throws {
        try prepareStorage()
        try LocalRuntimeValidation.rejectSymbolicAncestors(preferencesURL)
        try JSONEncoder().encode(preferences).write(to: preferencesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
    }

    private func registry() throws -> LocalRuntimeRegistry {
        try prepareStorage()
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return LocalRuntimeRegistry() }
        try LocalRuntimeValidation.rejectSymbolicAncestors(registryURL)
        let data = try Data(contentsOf: registryURL)
        guard data.count <= 16 * 1024 * 1024 else { throw LocalRuntimeError.invalidBundle("运行时注册表过大。") }
        let registry = try JSONDecoder().decode(LocalRuntimeRegistry.self, from: data)
        guard registry.schemaVersion == 1, registry.installations.filter(\.isActive).count <= 1,
              registry.installations.filter(\.isPrevious).count <= 1,
              Set(registry.installations.map(\.id)).count == registry.installations.count else { throw LocalRuntimeError.invalidBundle("运行时注册表无效。") }
        for installation in registry.installations {
            guard installation.runtimeID == LocalRuntimeValidation.runtimeID,
                  LocalRuntimeValidation.identifier(installation.version),
                  ["arm64", "x86_64"].contains(installation.architecture) else { throw LocalRuntimeError.invalidBundle("运行时注册表含非法路径。") }
        }
        return registry
    }

    private func save(_ registry: LocalRuntimeRegistry) throws {
        try LocalRuntimeValidation.rejectSymbolicAncestors(registryURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: registryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
    }

    private func location(_ installation: LocalRuntimeInstallation) -> URL {
        root.appendingPathComponent("runtimes/\(installation.runtimeID)/\(installation.version)-\(installation.architecture)", isDirectory: true)
    }

    private func sourceURL(_ request: LocalRuntimeRequest) throws -> URL {
        if let bookmark = request.bookmark {
            var stale = false
            // App creates a portable, minimal bookmark while its panel grant is
            // active. The non-sandboxed broker resolves it; no executable URL is
            // trusted merely because a bookmark resolved successfully.
            let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, resolved.isFileURL else { throw LocalRuntimeError.invalidBundle("安装来源书签已失效，请重新选择。") }
            return resolved.standardizedFileURL
        }
        guard let path = request.sourcePath, path.hasPrefix("/"), !path.contains("\0") else {
            throw LocalRuntimeError.invalidBundle("缺少本地安装来源。")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func install(_ request: LocalRuntimeRequest) throws {
        let fm = FileManager.default
        var current = try registry()
        let source = try sourceURL(request)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFDIR || (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw LocalRuntimeError.invalidBundle("请选择运行时目录或本地归档文件。")
        }
        // Staging is a new private directory on the final filesystem. Copy first,
        // validate the immutable staged contents, then atomic-rename into place.
        let staging = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try LocalRuntimeValidation.ensureDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        let unpacked = staging.appendingPathComponent("payload", isDirectory: true)
        if (sourceInfo.st_mode & S_IFMT) == S_IFDIR {
            guard !root.path.hasPrefix(source.path + "/"), source.path != root.path else { throw LocalRuntimeError.invalidBundle("安装来源不能包含受管理目录。") }
            try fm.copyItem(at: source, to: unpacked)
        } else {
            try LocalRuntimeArchive.extract(source, to: unpacked)
        }
        let bundleRoot: URL
        if fm.fileExists(atPath: unpacked.appendingPathComponent("runtime.json").path) {
            bundleRoot = unpacked
        } else {
            let children = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            guard children.count == 1 else { throw LocalRuntimeError.invalidBundle("归档必须只包含一个运行时目录。") }
            bundleRoot = children[0]
        }
        let manifest = try LocalRuntimeValidation.validate(at: bundleRoot, allowDevelopment: request.allowDevelopmentAdHoc == true, checkSignatures: checkSignatures)
        let installation = LocalRuntimeInstallation(manifest: manifest, installedAt: Date(), isActive: true, isPrevious: false)
        if let existing = current.installations.first(where: { $0.id == installation.id }) {
            guard existing.manifest == manifest else { throw LocalRuntimeError.invalidBundle("同版本已有不同内容，禁止覆盖不可变运行时。") }
            // Even an already installed version is verified before reactivation.
            _ = try LocalRuntimeValidation.validate(at: location(existing), allowDevelopment: existing.isDevelopment, checkSignatures: checkSignatures)
        } else {
            let target = location(installation)
            try LocalRuntimeValidation.ensureDirectory(target.deletingLastPathComponent())
            guard !fm.fileExists(atPath: target.path) else { throw LocalRuntimeError.invalidBundle("目标版本目录已存在但未登记。") }
            try fm.moveItem(at: bundleRoot, to: target)
        }
        let oldActive = current.installations.first(where: \.isActive)?.id
        for index in current.installations.indices {
            current.installations[index].isActive = current.installations[index].id == installation.id
            if oldActive != installation.id {
                current.installations[index].isPrevious = current.installations[index].id == oldActive
            }
        }
        if !current.installations.contains(where: { $0.id == installation.id }) { current.installations.append(installation) }
        // Installation only occurs while stopped. No installed version is edited
        // in place, and active registry always names the next process to launch.
        try save(current)
    }

    private func restorePrevious() throws {
        var current = try registry()
        guard let previous = current.installations.first(where: \.isPrevious) else { throw LocalRuntimeError.unavailable("没有可回滚的上一个版本。") }
        _ = try LocalRuntimeValidation.validate(at: location(previous), allowDevelopment: previous.isDevelopment, checkSignatures: checkSignatures)
        let active = current.installations.first(where: \.isActive)?.id
        for index in current.installations.indices {
            current.installations[index].isActive = current.installations[index].id == previous.id
            current.installations[index].isPrevious = current.installations[index].id == active
        }
        try save(current)
    }

    private func launchActive() async throws {
        guard let active = try registry().installations.first(where: \.isActive) else { throw LocalRuntimeError.unavailable("尚未安装本地 AI 运行时。") }
        let directory = location(active)
        let manifest = try LocalRuntimeValidation.validate(at: directory, allowDevelopment: active.isDevelopment, checkSignatures: checkSignatures)
        guard manifest == active.manifest else { throw LocalRuntimeError.invalidBundle("已安装的 manifest 已被修改。") }
        let token = try randomToken()
        let models = root.appendingPathComponent("Models", isDirectory: true)
        let child = Process()
        // Ignore manifest-selected entry points: these constants are the entire
        // launch allowlist. -I isolates sys.path/environment; -B preserves hashes.
        child.executableURL = directory.appendingPathComponent(LocalRuntimeValidation.interpreter)
        child.arguments = ["-I", "-B", directory.appendingPathComponent(LocalRuntimeValidation.server).path, "--port", "0"]
        child.currentDirectoryURL = directory
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
            "VELUM_RUNTIME_TOKEN": token, "VELUM_MODELS_DIR": models.path,
            "VELUM_RUNTIME_PARENT_PID": String(getpid()),
            "HF_HOME": models.appendingPathComponent(".hub").path,
            "HF_HUB_DISABLE_XET": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
            "TOKENIZERS_PARALLELISM": "false", "PYTHONDONTWRITEBYTECODE": "1",
            "NO_PROXY": "127.0.0.1,localhost,::1"
        ]
        if let proxyURL = try preferences().proxyURL {
            environment["VELUM_DOWNLOAD_PROXY"] = proxyURL
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { environment[key] = proxyURL }
        }
        // Do not inherit PYTHONPATH, DYLD_*, user startup hooks, or a shell.
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = temporary }
        child.environment = environment
        let stdout = Pipe(), stderr = Pipe(), output = LocalRuntimeOutput()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data, stderr: false) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data, stderr: true) }
        }
        child.standardOutput = stdout; child.standardError = stderr; child.standardInput = FileHandle.nullDevice
        let identifier = UUID(); sessionID = identifier
        child.terminationHandler = { [weak self] child in
            let code = child.terminationStatus
            Task { await self?.childExited(identifier: identifier, exitCode: code) }
        }
        process = child; outputPipe = stdout; errorPipe = stderr
        do { try child.run() } catch { throw LocalRuntimeError.launchFailed("运行时启动失败：\(error.localizedDescription)") }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            guard child.isRunning else { throw LocalRuntimeError.launchFailed("运行时在就绪前退出（\(child.terminationStatus)）。") }
            if let line = output.firstLine() {
                guard let ready = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      ready["event"] as? String == "ready", ready["protocol"] as? String == LocalRuntimeValidation.protocolName,
                      ready["host"] as? String == "127.0.0.1", let port = ready["port"] as? Int,
                      (1...65535).contains(port), ready["pid"] as? Int == Int(child.processIdentifier),
                      ready["runtime_id"] as? String == manifest.id, ready["version"] as? String == manifest.version,
                      let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                    throw LocalRuntimeError.launchFailed("运行时就绪握手无效。")
                }
                let connection = LocalRuntimeConnection(baseURL: baseURL, token: token)
                var request = URLRequest(url: baseURL.appendingPathComponent("health"))
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (health, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (try? JSONSerialization.jsonObject(with: health)) is [String: Any], child.isRunning else {
                    throw LocalRuntimeError.launchFailed("运行时健康检查未通过。")
                }
                endpoint = connection; status = .ready; lastError = nil
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LocalRuntimeError.launchFailed("等待运行时就绪超时。")
    }

    private func childExited(identifier: UUID, exitCode: Int32) {
        guard sessionID == identifier else { return }
        endpoint = nil
        if status == .ready || status == .starting {
            status = .crashed
            lastError = "运行时已退出（\(exitCode)）；可重新启动或回滚。"
        }
    }

    private func stopOwnedProcess() async {
        guard let child = process else { endpoint = nil; return }
        sessionID = UUID() // An expected shutdown must not publish a crash.
        if child.isRunning, let endpoint {
            var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("control/shutdown"))
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = 1.5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)
        }
        var deadline = ContinuousClock.now + .seconds(2)
        while child.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if child.isRunning { child.terminate() }
        deadline = ContinuousClock.now + .seconds(2)
        while child.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        // Escalate only for the Process object owned by this actor, never an
        // externally supplied PID or process name.
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        deadline = ContinuousClock.now + .seconds(2)
        while child.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? outputPipe?.fileHandleForReading.close(); try? errorPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close(); try? errorPipe?.fileHandleForWriting.close()
        child.terminationHandler = nil
        process = nil; outputPipe = nil; errorPipe = nil; endpoint = nil
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LocalRuntimeError.unavailable("无法生成安全的运行时令牌。") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sanitized(_ error: Error) -> String {
        var text = error.localizedDescription
        if let token = endpoint?.token { text = text.replacingOccurrences(of: token, with: "[redacted]") }
        return String(text.prefix(1_000))
    }

    private func encodedSnapshot() throws -> String {
        let registry = try registry()
        if process?.isRunning == false && status == .ready { endpoint = nil; status = .crashed }
        if status == .notInstalled && !registry.installations.isEmpty { status = .installed }
        let snapshot = LocalRuntimeSnapshot(status: status, installedRuntimes: registry.installations,
                                            lastError: lastError, baseURL: endpoint?.baseURL.absoluteString, token: endpoint?.token,
                                            proxyURL: try preferences().proxyURL)
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else { throw LocalRuntimeError.unavailable("运行时状态编码失败。") }
        return json
    }
}
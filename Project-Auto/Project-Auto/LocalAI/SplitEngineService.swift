import Foundation
import Security
import Darwin

nonisolated private struct SplitEngineRegistry: Codable, Sendable {
    var schema_version = 2
    var installations: [SplitEngineInstallation] = []
}
nonisolated private final class SplitEngineOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.contains(10) { return }
        guard bytes.count + data.count <= 65536 else { overflow = true; return }
        bytes.append(data)
    }
    func firstLine() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw SplitEngineError.invalid("Engine handshake exceeds size limit.") }
        guard let end = bytes.firstIndex(of: 10) else { return nil }
        return Data(bytes[..<end])
    }
}

// App and XPC share this exact implementation. Only this actor owns the child;
// all state mutations are guarded across await boundaries. One loaded model and
// one active engine are allowed until a measured memory scheduler is introduced.
actor SplitEngineService {
    static let defaultRoot = URL(fileURLWithPath: "/Users/Shared/Velum/ai/engines", isDirectory: true)
    static let shared = SplitEngineService()
    let root: URL
    private let trustedKeys: [String: Data]
    private let session: URLSession
    private var busy = false
    private var state = "notInstalled"
    private var engineID: String?
    private var lastError: String?
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var connection: SplitEngineConnection?
    private var generation = UUID()

    init(root: URL = SplitEngineService.defaultRoot, trustedKeys: [String: Data]? = nil) {
        self.root = root.standardizedFileURL
        // Keys are app-authored trust anchors, never accepted over broker JSON.
        let configured = Bundle.main.object(forInfoDictionaryKey: "SplitEngineTrustedKeys") as? [String: String] ?? [:]
        self.trustedKeys = trustedKeys ?? configured.compactMapValues { Data(base64Encoded: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration, delegate: SplitHTTPPolicy.shared, delegateQueue: nil)
    }

    func handle(_ json: String) async throws -> String {
        guard let data = json.data(using: .utf8), data.count <= 1024 * 1024 else { throw SplitEngineError.invalid("Invalid or oversized engine request.") }
        let request = try JSONDecoder().decode(SplitEngineRequest.self, from: data)
        if let id = request.engine_id, !SplitEngineValidation.identifier(id) { throw SplitEngineError.invalid("Invalid engine identifier.") }
        if request.op == "status" { return try snapshot() }
        guard ["install", "start", "stop", "rollback"].contains(request.op) else { throw SplitEngineError.invalid("Unknown engine operation.") }
        guard !busy else { throw SplitEngineError.unavailable("Another engine operation is in progress.") }
        busy = true
        defer { busy = false }
        let previousState = state
        lastError = nil
        do {
            switch request.op {
            case "install":
                guard process?.isRunning != true else { throw SplitEngineError.unavailable("Stop the active engine before importing an update.") }
                state = "installing"
                try install(request)
                state = "installed"
            case "start":
                guard let id = request.engine_id else { throw SplitEngineError.invalid("Starting an engine requires engine_id.") }
                if process?.isRunning == true {
                    guard engineID == id, connection?.model_id == request.model_id, connection != nil else {
                        throw SplitEngineError.unavailable("A different engine or model is active. Stop it before switching.")
                    }
                } else {
                    await stopOwnedProcess()
                    state = "starting"; engineID = id
                    do { try await launch(request) }
                    catch { await stopOwnedProcess(); state = "crashed"; throw error }
                }
            case "stop":
                if let id = request.engine_id, let engineID, id != engineID { throw SplitEngineError.unavailable("This engine does not own the active process.") }
                await stopOwnedProcess(); state = "stopped"
            case "rollback":
                guard let id = request.engine_id else { throw SplitEngineError.invalid("Rollback requires engine_id.") }
                guard process?.isRunning != true else { throw SplitEngineError.unavailable("Stop the active engine before rollback.") }
                try rollback(id); state = "installed"
            default: break
            }
        } catch {
            if state == "installing" { state = previousState }
            lastError = String(error.localizedDescription.prefix(1000))
            throw error
        }
        return try snapshot()
    }

    private func storage() throws {
        try SplitEngineValidation.ensureDirectory(root)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw SplitEngineError.unavailable("Engine storage must belong to the current user.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for directory in ["packages", "staging", "Models"] { try SplitEngineValidation.ensureDirectory(root.appendingPathComponent(directory, isDirectory: true)) }
    }
    private var registryURL: URL { root.appendingPathComponent("registry.json") }
    private func registry() throws -> SplitEngineRegistry {
        try storage()
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return SplitEngineRegistry() }
        let saved = try JSONDecoder().decode(SplitEngineRegistry.self, from: SplitEngineValidation.regularData(registryURL, maximum: 32 * 1024 * 1024))
        guard saved.schema_version == 2, Set(saved.installations.map(\.id)).count == saved.installations.count else { throw SplitEngineError.invalid("Invalid engine registry.") }
        let groups = Dictionary(grouping: saved.installations, by: { $0.manifest.id })
        for (id, versions) in groups {
            guard SplitEngineValidation.identifier(id), versions.filter(\.active).count <= 1, versions.filter(\.previous).count <= 1 else { throw SplitEngineError.invalid("Invalid engine registry state.") }
            for version in versions {
                guard SplitEngineValidation.identifier(version.manifest.version), ["arm64", "x86_64"].contains(version.manifest.architecture), !(version.active && version.previous) else { throw SplitEngineError.invalid("Invalid engine registry path.") }
            }
        }
        return saved
    }
    private func save(_ registry: SplitEngineRegistry) throws {
        try SplitEngineValidation.rejectSymbolicAncestors(registryURL)
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
    }
    private func location(_ installation: SplitEngineInstallation) -> URL { root.appendingPathComponent("packages/\(installation.id)", isDirectory: true) }
    private func source(_ request: SplitEngineRequest) throws -> URL {
        if let bookmark = request.bookmark {
            var stale = false
            let value = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, value.isFileURL else { throw SplitEngineError.invalid("The engine import bookmark is stale.") }
            return value.standardizedFileURL
        }
        guard let path = request.source, path.hasPrefix("/"), !path.contains("\0") else { throw SplitEngineError.invalid("A local import source is required.") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    private func install(_ request: SplitEngineRequest) throws {
        var saved = try registry()
        let source = try source(request), fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try SplitEngineValidation.rejectSymbolicAncestors(source)
        guard source.path != root.path, !root.path.hasPrefix(source.path + "/") else { throw SplitEngineError.invalid("Import source cannot contain managed engine storage.") }
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw SplitEngineError.invalid("Import source is missing.") }
        let staging = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try SplitEngineValidation.ensureDirectory(staging)
        // staging is a freshly created, verified child of our private root.
        defer { try? fm.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        switch info.st_mode & S_IFMT {
        case S_IFDIR: try fm.copyItem(at: source, to: payload)
        case S_IFREG: try SplitEngineArchive.extract(source, to: payload)
        default: throw SplitEngineError.invalid("Import source must be a directory or archive.")
        }
        let package: URL
        if fm.fileExists(atPath: payload.appendingPathComponent("runtime.json").path) { package = payload }
        else {
            let children = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            guard children.count == 1 else { throw SplitEngineError.invalid("Archive must contain one engine package.") }
            package = children[0]
        }
        let manifest = try SplitEngineValidation.validate(at: package, allowDevelopment: request.allow_development_ad_hoc == true, trustedKeys: trustedKeys)
        guard request.engine_id == nil || request.engine_id == manifest.id else { throw SplitEngineError.invalid("Imported engine identity does not match the request.") }
        let item = SplitEngineInstallation(manifest: manifest, installed_at: Date(), development_authorized: manifest.signing.policy == "development-adhoc", active: true, previous: false)
        if let existing = saved.installations.first(where: { $0.id == item.id }) {
            guard existing.manifest == manifest else { throw SplitEngineError.invalid("An immutable version with different contents is already installed.") }
            _ = try checked(existing)
        } else {
            let target = location(item)
            try SplitEngineValidation.ensureDirectory(target.deletingLastPathComponent())
            guard !fm.fileExists(atPath: target.path) else { throw SplitEngineError.invalid("Unregistered package destination already exists.") }
            // Only move verified staging content to a verified fresh destination.
            try fm.moveItem(at: package, to: target)
        }
        let prior = saved.installations.first(where: { $0.manifest.id == manifest.id && $0.active })?.id
        for index in saved.installations.indices where saved.installations[index].manifest.id == manifest.id {
            saved.installations[index].active = saved.installations[index].id == item.id
            if prior != item.id { saved.installations[index].previous = saved.installations[index].id == prior }
        }
        if !saved.installations.contains(where: { $0.id == item.id }) { saved.installations.append(item) }
        try save(saved)
    }
    private func checked(_ item: SplitEngineInstallation) throws -> SplitEngineManifest {
        let manifest = try SplitEngineValidation.validate(at: location(item), allowDevelopment: item.development_authorized, trustedKeys: trustedKeys)
        guard manifest == item.manifest else { throw SplitEngineError.invalid("Installed engine metadata changed.") }
        return manifest
    }
    private func rollback(_ id: String) throws {
        var saved = try registry()
        guard let previous = saved.installations.first(where: { $0.manifest.id == id && $0.previous }) else { throw SplitEngineError.unavailable("No previous engine version is available.") }
        _ = try checked(previous)
        let active = saved.installations.first(where: { $0.manifest.id == id && $0.active })?.id
        for index in saved.installations.indices where saved.installations[index].manifest.id == id {
            saved.installations[index].active = saved.installations[index].id == previous.id
            saved.installations[index].previous = saved.installations[index].id == active
        }
        try save(saved)
    }
    private func launch(_ request: SplitEngineRequest) async throws {
        guard let item = try registry().installations.first(where: { $0.manifest.id == request.engine_id && $0.active }) else { throw SplitEngineError.unavailable("This engine has not been installed.") }
        let manifest = try checked(item), directory = location(item)
        if let model = request.model_id {
            guard !model.isEmpty, model.utf8.count <= 512, !model.contains("\0"), !model.contains("\n"), !model.hasPrefix("/"), !model.split(separator: "/").contains("..") else { throw SplitEngineError.invalid("Invalid model identifier.") }
        }
        let child = Process()
        if manifest.kind == "python" {
            guard let basePath = request.python_base_path else { throw SplitEngineError.invalid("The app must supply its bundled Python base path.") }
            let base = try SplitEngineValidation.appPythonBase(basePath, allowDevelopment: item.development_authorized, trustedKeys: trustedKeys)
            child.executableURL = base.appendingPathComponent(SplitEngineValidation.pythonExecutable)
            child.arguments = ["-I", "-B", directory.appendingPathComponent(SplitEngineValidation.pythonEntry).path, "--port", "0"]
        } else {
            child.executableURL = directory.appendingPathComponent(SplitEngineValidation.nativeEntry)
            child.arguments = ["--port", "0"]
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SplitEngineError.unavailable("Cannot generate engine authentication token.") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let models = root.appendingPathComponent("Models", isDirectory: true)
        var env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                   "VELUM_RUNTIME_TOKEN": token, "VELUM_MODELS_DIR": models.path, "VELUM_RUNTIME_PARENT_PID": String(getpid()),
                   "VELUM_ENGINE_ID": manifest.id, "VELUM_ENGINE_VERSION": manifest.version,
                   "HF_HOME": models.appendingPathComponent(".hub").path, "HF_HUB_DISABLE_XET": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                   "TOKENIZERS_PARALLELISM": "false", "PYTHONDONTWRITEBYTECODE": "1", "NO_PROXY": "127.0.0.1,localhost,::1"]
        if let model = request.model_id { env["VELUM_MODEL_ID"] = model }
        if let proxy = try proxy(request.proxy_url) {
            env["VELUM_DOWNLOAD_PROXY"] = proxy
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { env[name] = proxy }
        }
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = temporary }
        child.environment = env; child.currentDirectoryURL = directory
        let output = SplitEngineOutput(), stdout = Pipe(), stderr = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { handle in let data = handle.availableData; if !data.isEmpty { output.append(data) } }
        // Drain stderr without retaining package-controlled text or secrets.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.standardOutput = stdout; child.standardError = stderr; child.standardInput = FileHandle.nullDevice
        let generation = UUID(); self.generation = generation
        child.terminationHandler = { [weak self] process in let code = process.terminationStatus; Task { await self?.exited(generation, code: code) } }
        self.process = child; self.stdout = stdout; self.stderr = stderr
        try child.run()
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard child.isRunning else { throw SplitEngineError.unavailable("Engine exited before becoming ready (\(child.terminationStatus)).") }
            if let line = try output.firstLine() {
                guard let ready = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      ready["event"] as? String == "ready", ready["protocol"] as? String == SplitEngineValidation.protocolName,
                      ready["host"] as? String == "127.0.0.1", let port = ready["port"] as? Int, (1...65535).contains(port),
                      ready["pid"] as? Int == Int(child.processIdentifier), ready["runtime_id"] as? String == manifest.id,
                      ready["version"] as? String == manifest.version else { throw SplitEngineError.invalid("Engine readiness handshake is invalid.") }
                let baseURL = URL(string: "http://127.0.0.1:\(port)")!
                let connection = SplitEngineConnection(protocol: SplitEngineValidation.protocolName, base_url: baseURL.absoluteString, token: token, model_id: request.model_id)
                let health = try await authenticated(baseURL.appendingPathComponent("health"), token: token)
                guard let object = try JSONSerialization.jsonObject(with: health) as? [String: Any], object["status"] as? String == "ok",
                      object["protocol"] as? String == SplitEngineValidation.protocolName,
                      object["runtime_id"] as? String == manifest.id, object["version"] as? String == manifest.version,
                      object["pid"] as? Int == Int(child.processIdentifier) else { throw SplitEngineError.invalid("Engine health response is invalid.") }
                if let model = request.model_id {
                    var load = URLRequest(url: baseURL.appendingPathComponent("control/load"))
                    load.httpMethod = "POST"; load.timeoutInterval = 300
                    load.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    load.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    load.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "capability": "chat"])
                    let (_, response) = try await session.data(for: load)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, child.isRunning else { throw SplitEngineError.unavailable("The requested model could not be loaded.") }
                }
                let models = try await authenticated(baseURL.appendingPathComponent("v1/models"), token: token)
                guard let listing = try JSONSerialization.jsonObject(with: models) as? [String: Any], let descriptors = listing["data"] as? [[String: Any]], child.isRunning else { throw SplitEngineError.invalid("Engine does not implement the required models protocol.") }
                if let model = request.model_id {
                    guard descriptors.contains(where: { $0["id"] as? String == model }) else { throw SplitEngineError.invalid("The engine did not register the requested model.") }
                }
                self.connection = connection; state = "ready"
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SplitEngineError.unavailable("Engine readiness timed out.")
    }
    private func authenticated(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw SplitEngineError.invalid("Engine protocol health check failed.") }
        return data
    }
    private func proxy(_ string: String?) throws -> String? {
        guard let string, !string.isEmpty else { return nil }
        guard string.utf8.count <= 512, let url = URL(string: string), ["http", "https"].contains(url.scheme),
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host), let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else { throw SplitEngineError.invalid("Download proxy must be a loopback HTTP(S) endpoint.") }
        return url.absoluteString
    }
    private func exited(_ generation: UUID, code: Int32) {
        guard self.generation == generation else { return }
        connection = nil
        if state == "ready" || state == "starting" { state = "crashed"; lastError = "Engine exited (\(code))." }
    }
    private func stopOwnedProcess() async {
        generation = UUID(); connection = nil
        guard let process else { return }
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        // Only the actor-owned Process is targeted, never an external PID/name.
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let killedDeadline = ContinuousClock.now + .seconds(2)
        while process.isRunning && ContinuousClock.now < killedDeadline { try? await Task.sleep(for: .milliseconds(25)) }
        stdout?.fileHandleForReading.readabilityHandler = nil; stderr?.fileHandleForReading.readabilityHandler = nil
        try? stdout?.fileHandleForReading.close(); try? stdout?.fileHandleForWriting.close()
        try? stderr?.fileHandleForReading.close(); try? stderr?.fileHandleForWriting.close()
        process.terminationHandler = nil
        self.process = nil; stdout = nil; stderr = nil
    }
    private func snapshot() throws -> String {
        let saved = try registry()
        if process?.isRunning == false && state == "ready" { state = "crashed"; connection = nil }
        if state == "notInstalled" && !saved.installations.isEmpty { state = "installed" }
        let snapshot = SplitEngineSnapshot(ok: true, state: state, engine_id: engineID, installations: saved.installations,
                                           connection: state == "ready" ? connection : nil, last_error: lastError)
        return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    }
}

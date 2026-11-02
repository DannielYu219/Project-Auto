import AppKit
import Combine
import Foundation

@MainActor
final class LocalRuntimeManager: ObservableObject {
    static let shared = LocalRuntimeManager()
    @Published private(set) var installedRuntimes: [LocalRuntimeInstallation] = []
    @Published private(set) var status: LocalRuntimeStatus = .notInstalled
    @Published private(set) var lastError: String?
    @Published private(set) var health: LocalRuntimeHealth?
    @Published private(set) var proxyURL: String?
    // Installed by the app's XPC bridge. No direct Process fallback: a sandboxed
    // child would inherit the app sandbox and cannot serve as a runtime broker.
    var requestBroker: (@Sendable (String) async throws -> String)?
    private var currentConnection: LocalRuntimeConnection?
    private let session: URLSession
    private var operationInFlight = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration, delegate: LocalRuntimeHTTPPolicy.shared, delegateQueue: nil)
    }

    func refresh() async {
        do { try await request(LocalRuntimeRequest(op: "status")) }
        catch { report(error) }
    }

    func configureProxy(_ proxyURL: String?) async throws {
        guard !operationInFlight else { throw LocalRuntimeError.unavailable("另一个运行时操作正在进行。") }
        operationInFlight = true
        defer { operationInFlight = false }
        do { try await request(LocalRuntimeRequest(op: "setProxy", proxyURL: proxyURL)) }
        catch { report(error); throw error }
    }

    func install(from url: URL, allowDevelopmentAdHoc: Bool = false) async throws {
        guard !operationInFlight else { throw LocalRuntimeError.unavailable("另一个运行时操作正在进行。") }
        operationInFlight = true
        defer { operationInFlight = false }
        let previousStatus = status
        status = .installing; lastError = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            // Minimal bookmarks are portable across the app/helper boundary.
            // Resolving does not authorize code: the broker still stages, hashes,
            // validates signatures, and allows only fixed Python/server paths.
            let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            try await request(LocalRuntimeRequest(op: "install", sourcePath: url.path, bookmark: bookmark,
                                                  allowDevelopmentAdHoc: allowDevelopmentAdHoc))
        } catch { status = previousStatus; report(error); throw error }
    }

    func chooseAndInstall(allowDevelopmentAdHoc: Bool = false) async {
        let panel = NSOpenPanel()
        panel.title = allowDevelopmentAdHoc ? "选择开发用本地 AI 运行时（临时签名）" : "选择本地 AI 运行时"
        panel.prompt = "安装运行时"
        panel.message = allowDevelopmentAdHoc
            ? "仅安装您信任的开发包。临时签名不代表通过发行签名或 Apple 公证。"
            : "选择完整运行时目录或归档；无需系统 Python，也不会运行 pip。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        do { try await install(from: url, allowDevelopmentAdHoc: allowDevelopmentAdHoc) }
        catch { /* Published lastError is the UI's single error surface. */ }
    }

    func start() async throws {
        guard !operationInFlight else { throw LocalRuntimeError.unavailable("另一个运行时操作正在进行。") }
        operationInFlight = true
        defer { operationInFlight = false }
        status = .starting; lastError = nil
        do {
            try await request(LocalRuntimeRequest(op: "start"))
            guard currentConnection != nil, status == .ready else { throw LocalRuntimeError.launchFailed("运行时未报告就绪。") }
            try await refreshHealth()
        } catch {
            currentConnection = nil
            status = .crashed
            report(error)
            await refresh()
            throw error
        }
    }

    func stop() async {
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        do {
            try await request(LocalRuntimeRequest(op: "stop"))
            currentConnection = nil; health = nil
        } catch { report(error) }
    }

    func rollback() async throws {
        guard !operationInFlight else { throw LocalRuntimeError.unavailable("另一个运行时操作正在进行。") }
        operationInFlight = true
        defer { operationInFlight = false }
        do {
            try await request(LocalRuntimeRequest(op: "rollback"))
            if status == .ready { try await refreshHealth() } else { health = nil }
        } catch { report(error); throw error }
    }

    // Module-internal on purpose. Providers consume this; settings never expose
    // a URL field or token. Getting a connection lazily starts the selected runtime.
    func connection() async throws -> LocalRuntimeConnection {
        if let currentConnection, status == .ready { return currentConnection }
        try await start()
        guard let currentConnection else { throw LocalRuntimeError.unavailable("本地运行时未就绪。") }
        return currentConnection
    }

    func refreshHealth() async throws {
        let data = try await authorizedRequest(path: "/health")
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw LocalRuntimeError.launchFailed("本地运行时健康响应无效。")
        }
        health = LocalRuntimeHealth(data: data)
    }

    func authorizedRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let allowedGet = path == "/health" || path == "/v1/models" || isJobPath(path)
        let allowedPost = ["/control/download", "/control/load", "/control/unload", "/control/shutdown", "/v1/embeddings", "/v1/chat/completions"].contains(path)
        guard (method == "GET" && allowedGet) || (method == "POST" && allowedPost),
              !path.contains("?"), !path.contains("#"), !path.contains("%"), !path.contains("\\") else {
            throw LocalRuntimeError.unavailable("不允许的本地运行时 API 路径。")
        }
        let connection = try await connection()
        guard let url = URL(string: path, relativeTo: connection.baseURL)?.absoluteURL,
              url.host == "127.0.0.1", url.port == connection.baseURL.port, url.scheme == "http" else {
            throw LocalRuntimeError.unavailable("本地运行时地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalRuntimeError.unavailable("本地运行时响应无效。") }
        guard (200...299).contains(http.statusCode) else {
            // Error responses are bounded and tokens removed before publication.
            let message = String(decoding: data.prefix(2_000), as: UTF8.self).replacingOccurrences(of: connection.token, with: "[redacted]")
            throw LocalRuntimeError.http(http.statusCode, message)
        }
        if path == "/control/shutdown" { currentConnection = nil; status = .stopped; health = nil }
        return data
    }

    private func isJobPath(_ path: String) -> Bool {
        let prefix = "/control/jobs/"
        guard path.hasPrefix(prefix) else { return false }
        return LocalRuntimeValidation.identifier(String(path.dropFirst(prefix.count)))
    }

    private func request(_ command: LocalRuntimeRequest) async throws {
        guard let requestBroker else { throw LocalRuntimeError.unavailable("运行时 XPC broker 尚未连接。") }
        let data = try JSONEncoder().encode(command)
        let reply = try await requestBroker(String(decoding: data, as: UTF8.self))
        guard reply.utf8.count <= 32 * 1024 * 1024 else { throw LocalRuntimeError.unavailable("运行时状态响应过大。") }
        let snapshot = try JSONDecoder().decode(LocalRuntimeSnapshot.self, from: Data(reply.utf8))
        installedRuntimes = snapshot.installedRuntimes
        status = snapshot.status
        lastError = snapshot.lastError
        proxyURL = snapshot.proxyURL
        if let base = snapshot.baseURL, let token = snapshot.token, let url = URL(string: base),
           url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port),
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           (url.path.isEmpty || url.path == "/"), token.count == 64,
           token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            currentConnection = LocalRuntimeConnection(baseURL: url, token: token)
        } else {
            currentConnection = nil
        }
        if currentConnection == nil { health = nil }
    }

    private func report(_ error: Error) {
        var message = error.localizedDescription
        if let token = currentConnection?.token { message = message.replacingOccurrences(of: token, with: "[redacted]") }
        lastError = String(message.prefix(2_000))
    }
}
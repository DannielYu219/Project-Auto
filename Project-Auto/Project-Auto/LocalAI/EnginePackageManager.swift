import AppKit
import Combine
import Foundation

/// Python belongs to the App; separately versioned engine code belongs to external package storage.
@MainActor
final class EnginePackageManager: ObservableObject {
    static let shared = EnginePackageManager()
    @Published private(set) var installations: [SplitEngineInstallation] = []
    @Published private(set) var state = "notInstalled"
    @Published private(set) var activeEngineID: String?
    @Published private(set) var errorMessage: String?
    @Published var selectedEngineID: String = "mlx"
    private var endpoint: LocalRuntimeConnection?
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        session = URLSession(configuration: config, delegate: SplitHTTPPolicy.shared, delegateQueue: nil)
    }

    var isRunning: Bool { state == "ready" }
    var pythonBaseURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("python-base", isDirectory: true).resolvingSymlinksInPath() }

    func refresh() async {
        do { try await request(SplitEngineRequest(op: "status")) }
        catch { errorMessage = error.localizedDescription }
    }

    func install(from source: URL, allowDevelopment: Bool) async throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let bookmark = try source.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await request(SplitEngineRequest(op: "install", source: source.path, bookmark: bookmark,
                                            allow_development_ad_hoc: allowDevelopment))
    }

    func chooseAndInstall(allowDevelopment: Bool) async {
        let panel = NSOpenPanel()
        panel.title = "导入独立引擎包"
        panel.prompt = "导入"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        do {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try await install(from: url, allowDevelopment: allowDevelopment)
        } catch { errorMessage = error.localizedDescription }
    }

    func start(engineID: String) async throws {
        guard let base = pythonBaseURL else { throw SplitEngineError.unavailable("App 缺少 Python 基座") }
        try await request(SplitEngineRequest(op: "start", engine_id: engineID, python_base_path: base.path,
                                            proxy_url: downloadProxy))
        selectedEngineID = engineID
    }

    func stop() async {
        do { try await request(SplitEngineRequest(op: "stop")) }
        catch { errorMessage = error.localizedDescription }
    }

    func rollback(engineID: String) async throws {
        try await request(SplitEngineRequest(op: "rollback", engine_id: engineID))
    }

    var downloadProxy: String? {
        get { UserDefaults.standard.string(forKey: "velum.engines.downloadProxy") }
        set { UserDefaults.standard.set(newValue, forKey: "velum.engines.downloadProxy") }
    }

    func connection(engineID: String) async throws -> LocalRuntimeConnection {
        if isRunning, activeEngineID != engineID {
            throw SplitEngineError.unavailable("请先停止当前引擎，再切换到 \(engineID)。")
        }
        if endpoint == nil || !isRunning { try await start(engineID: engineID) }
        guard let endpoint else { throw SplitEngineError.unavailable("引擎没有报告就绪") }
        return endpoint
    }

    func authorizedRequest(engineID: String, path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let allowed = ["/health", "/v1/models", "/v1/embeddings", "/control/load", "/control/unload", "/control/download", "/control/cancel", "/control/import"]
        guard allowed.contains(path) || (path.hasPrefix("/control/jobs/") && !path.contains("..")),
              !path.contains("?"), !path.contains("#"), !path.contains("%"), !path.contains("\\") else {
            throw SplitEngineError.invalid("无效引擎服务路径")
        }
        let info = try await connection(engineID: engineID)
        guard let url = URL(string: path, relativeTo: info.baseURL), url.host == "127.0.0.1", url.port == info.baseURL.port else {
            throw SplitEngineError.invalid("无效引擎地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.httpBody = body
        req.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SplitEngineError.unavailable(String(decoding: data.prefix(2000), as: UTF8.self).replacingOccurrences(of: info.token, with: "[redacted]"))
        }
        return data
    }

    private func request(_ value: SplitEngineRequest) async throws {
        do {
            let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            let response = try await LocalAIConnectionBridge.shared.splitRequest(json)
            let snapshot = try JSONDecoder().decode(SplitEngineSnapshot.self, from: Data(response.utf8))
            installations = snapshot.installations; state = snapshot.state; activeEngineID = snapshot.engine_id
            errorMessage = snapshot.last_error
            if let conn = snapshot.connection, let base = URL(string: conn.base_url), base.host == "127.0.0.1",
               base.scheme == "http", base.port != nil, conn.token.count >= 24 {
                endpoint = LocalRuntimeConnection(baseURL: base, token: conn.token)
            } else { endpoint = nil }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}

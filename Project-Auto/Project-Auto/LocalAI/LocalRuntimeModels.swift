import Foundation

// Shared by the sandboxed app and the narrowly scoped, unsandboxed XPC broker.
// These models must not acquire the app target's default MainActor isolation.
nonisolated struct LocalRuntimeManifest: Codable, Sendable, Equatable {
    struct Python: Codable, Sendable, Equatable { let version: String; let executable: String }
    struct Adapter: Codable, Sendable, Equatable {
        let `protocol`: String
        let host: String
        let port: Int
        let auth_env: String
        let models_env: String
    }
    struct Signing: Codable, Sendable, Equatable { let policy: String; let team_id: String? }
    let schema_version: Int
    let id: String
    let version: String
    let platform: String
    let architecture: String
    let python: Python
    let launcher: String
    let adapter: Adapter
    let capabilities: [String]
    let files: [String: String]
    let symlinks: [String: String]?
    let signing: Signing
    let minimum_macos: String?
}

nonisolated enum LocalRuntimeStatus: String, Codable, Sendable {
    case notInstalled, installing, installed, starting, ready, stopped, crashed, incompatible
    var isBusy: Bool { self == .installing || self == .starting }
    var isRunning: Bool { self == .ready }
    var displayName: String {
        switch self {
        case .notInstalled: return "未安装"
        case .installing: return "正在安装"
        case .installed: return "已安装"
        case .starting: return "正在启动"
        case .ready: return "运行中"
        case .stopped: return "已停止"
        case .crashed: return "运行时已退出"
        case .incompatible: return "不兼容"
        }
    }
}

nonisolated struct LocalRuntimeInstallation: Codable, Identifiable, Sendable, Equatable {
    let manifest: LocalRuntimeManifest
    let installedAt: Date
    var isActive: Bool
    var isPrevious: Bool
    var id: String { "\(manifest.id)/\(manifest.version)-\(manifest.architecture)" }
    var runtimeID: String { manifest.id }
    var version: String { manifest.version }
    var architecture: String { manifest.architecture }
    var isDevelopment: Bool { manifest.signing.policy == "development-adhoc" }
}

nonisolated struct LocalRuntimeSnapshot: Codable, Sendable {
    let status: LocalRuntimeStatus
    let installedRuntimes: [LocalRuntimeInstallation]
    let lastError: String?
    // Kept on the wire for the trusted broker only; the manager never publishes these.
    let baseURL: String?
    let token: String?
    let proxyURL: String?
}

nonisolated struct LocalRuntimeConnection: Sendable {
    let baseURL: URL
    let token: String
}

nonisolated struct LocalRuntimeHealth: Codable, Sendable {
    let data: Data
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
}

nonisolated struct LocalRuntimeRequest: Codable, Sendable {
    let op: String
    var sourcePath: String? = nil
    var bookmark: Data? = nil
    var allowDevelopmentAdHoc: Bool? = nil
    var proxyURL: String? = nil
}

nonisolated final class LocalRuntimeHTTPPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LocalRuntimeHTTPPolicy()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The ephemeral bearer token belongs to one loopback server only.
        // A runtime response must not redirect an authenticated app request.
        completionHandler(nil)
    }
}

nonisolated enum LocalRuntimeError: LocalizedError, Sendable {
    case unavailable(String)
    case invalidBundle(String)
    case incompatible(String)
    case launchFailed(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidBundle(let message), .incompatible(let message), .launchFailed(let message): return message
        case .http(let code, let message): return "本地运行时 HTTP \(code)：\(message)"
        }
    }
}
import Foundation

// Schema 2 deliberately separates the app's CPython base from external engines.
// These types also compile in the non-sandboxed broker without app UI dependencies.
nonisolated struct SplitEngineManifest: Codable, Sendable, Equatable {
    struct Signing: Codable, Sendable, Equatable {
        let policy: String
        let team_id: String?
        let key_id: String?
    }
    struct Python: Codable, Sendable, Equatable {
        let version: String
        let executable: String
        let abi: String?
    }
    struct Adapter: Codable, Sendable, Equatable {
        let `protocol`: String
        let host: String
        let port: Int
        let auth_env: String
        let models_env: String
    }
    let schema_version: Int
    let id: String
    let version: String
    let kind: String
    let platform: String
    let architecture: String
    let python_abi: String?
    let python: Python?
    let entrypoint: String?
    let adapter: Adapter?
    let capabilities: [String]?
    var declaredCapabilities: [String] { capabilities ?? [] }
    let files: [String: String]
    let symlinks: [String: String]?
    let signing: Signing
    let minimum_macos: String?
}

nonisolated struct SplitEngineRequest: Codable, Sendable {
    let op: String
    var engine_id: String? = nil
    var source: String? = nil
    var bookmark: Data? = nil
    var allow_development_ad_hoc: Bool? = nil
    var python_base_path: String? = nil
    var model_id: String? = nil
    var proxy_url: String? = nil
}

nonisolated struct SplitEngineInstallation: Codable, Sendable, Equatable {
    let manifest: SplitEngineManifest
    let installed_at: Date
    let development_authorized: Bool
    var active: Bool
    var previous: Bool
    var id: String { "\(manifest.id)/\(manifest.version)-\(manifest.architecture)" }
}

nonisolated struct SplitEngineConnection: Codable, Sendable {
    let `protocol`: String
    let base_url: String
    let token: String
    let model_id: String?
}

nonisolated struct SplitEngineSnapshot: Codable, Sendable {
    let ok: Bool
    let state: String
    let engine_id: String?
    let installations: [SplitEngineInstallation]
    let connection: SplitEngineConnection?
    let last_error: String?
}

nonisolated enum SplitEngineError: LocalizedError, Sendable {
    case invalid(String), unavailable(String), incompatible(String)
    var errorDescription: String? {
        switch self { case .invalid(let text), .unavailable(let text), .incompatible(let text): return text }
    }
}

nonisolated final class SplitHTTPPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SplitHTTPPolicy()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

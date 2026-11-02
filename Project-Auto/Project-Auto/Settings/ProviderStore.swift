import Combine
import Foundation

nonisolated struct ModelProviderProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kindRaw: String
    var endpoint: String
    /// The provider's fetched catalogue. `models` is the user-checked subset.
    var models: [String]
    var availableModels: [String]?

    init(id: UUID = UUID(), name: String, kind: AgentProviderKind,
         endpoint: String, models: [String], availableModels: [String]? = nil) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.endpoint = endpoint
        self.models = models
        self.availableModels = availableModels
    }

    var kind: AgentProviderKind {
        get { AgentProviderKind(rawValue: kindRaw) ?? .openAIChat }
        set { kindRaw = newValue.rawValue }
    }
}

nonisolated struct ProviderModelOption: Identifiable, Sendable {
    var providerID: UUID
    var providerName: String
    var modelID: String
    var kind: AgentProviderKind
    var id: String { "\(providerID.uuidString)::\(modelID)" }
}

/// The provider app's source of truth. API keys live in Keychain per profile.
@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()
    private let profilesKey = "velum.providers.v1"
    private let selectedProviderKey = "velum.providers.selected"
    private let selectedModelKey = "velum.providers.selectedModel"

    @Published private(set) var profiles: [ModelProviderProfile] = []
    @Published private(set) var selectedProviderID: UUID?
    @Published private(set) var selectedModel: String = ""

    private init() {
        load()
        if profiles.isEmpty { migrateLegacy() }
        if let selectedProviderID, profiles.contains(where: { $0.id == selectedProviderID }) == false {
            self.selectedProviderID = profiles.first?.id
        }
        if selectedProviderID == nil { selectedProviderID = profiles.first?.id }
        if selectedModel.isEmpty {
            selectedModel = selectedProfile?.models.first ?? ""
        }
        if let profile = selectedProfile, !profile.models.contains(selectedModel) {
            selectedModel = profile.models.first ?? ""
        }
        persistSelection()
    }

    var selectedProfile: ModelProviderProfile? {
        profiles.first(where: { $0.id == selectedProviderID })
    }

    var options: [ProviderModelOption] {
        profiles.flatMap { profile in
            profile.models.map {
                ProviderModelOption(providerID: profile.id, providerName: profile.name,
                                    modelID: $0, kind: profile.kind)
            }
        }
    }

    func select(providerID: UUID, model: String) {
        guard let profile = profiles.first(where: { $0.id == providerID }) else { return }
        LocalModelSelection.shared.useRemoteProvider()
        selectedProviderID = providerID
        selectedModel = model.isEmpty ? (profile.models.first ?? "") : model
        persistSelection()
    }

    func select(model option: ProviderModelOption) {
        select(providerID: option.providerID, model: option.modelID)
    }

    @discardableResult
    func addProfile() -> UUID {
        let profile = ModelProviderProfile(name: "新供应商", kind: .openAIChat,
                                           endpoint: "https://api.openai.com/v1",
                                           models: [])
        profiles.append(profile)
        selectedProviderID = profile.id
        selectedModel = ""
        persist()
        return profile.id
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        AgentKeychain.delete(account: keyAccount(id))
        if selectedProviderID == id {
            selectedProviderID = profiles.first?.id
            selectedModel = selectedProfile?.models.first ?? ""
        }
        persist()
        persistSelection()
    }

    func update(_ profile: ModelProviderProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        if selectedProviderID == nil { selectedProviderID = profile.id }
        if selectedProviderID == profile.id && !profile.models.contains(selectedModel) {
            selectedModel = profile.models.first ?? ""
        }
        persist()
        persistSelection()
    }

    /// Fetch the provider's catalogue only. It never auto-selects a model.
    func fetchModels(for profile: ModelProviderProfile) async throws -> [String] {
        let key = apiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderFetchError.missingKey }
        guard var base = URL(string: profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProviderFetchError.invalidEndpoint
        }
        if base.scheme == nil { base = URL(string: "https://" + base.absoluteString) ?? base }
        guard let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme), base.host != nil else {
            throw ProviderFetchError.invalidEndpoint
        }
        var url: URL
        switch profile.kind {
        case .anthropicMessages:
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var path = components?.path ?? ""
            while path.hasSuffix("/") { path.removeLast() }
            components?.path = path.hasSuffix("/v1") ? path + "/models" : path + "/v1/models"
            guard let value = components?.url else { throw ProviderFetchError.invalidEndpoint }
            url = value
        case .openAIChat, .openAIResponses:
            guard let normalized = PiProviderFactory.normalizedBaseURL(kind: profile.kind, endpoint: profile.endpoint) else {
                throw ProviderFetchError.invalidEndpoint
            }
            url = normalized.appendingPathComponent("models")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if profile.kind == .anthropicMessages {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: ProviderNoRedirect.shared, delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFetchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw ProviderFetchError.http(http.statusCode, body)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.invalidResponse
        }
        let rows = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        let ids = rows.compactMap { row -> String? in
            let id = (row["id"] as? String) ?? (row["name"] as? String)
            let value = id?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        }
        guard !ids.isEmpty else { throw ProviderFetchError.emptyCatalogue }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func apiKey(for profile: ModelProviderProfile) -> String {
        let stored = AgentKeychain.get(account: keyAccount(profile.id)) ?? ""
        if !stored.isEmpty { return stored }
        // The migrated first profile inherits the old single-provider key.
        if profiles.first?.id == profile.id { return AgentKeychain.get(account: "agent_api_key") ?? "" }
        return ""
    }

    func setAPIKey(_ key: String, for profile: ModelProviderProfile) {
        if key.isEmpty { AgentKeychain.delete(account: keyAccount(profile.id)) }
        else { try? AgentKeychain.set(key, account: keyAccount(profile.id)) }
    }

    private func keyAccount(_ id: UUID) -> String { "provider_api_key_\(id.uuidString.lowercased())" }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([ModelProviderProfile].self, from: data) {
            profiles = saved
        }
        if let raw = UserDefaults.standard.string(forKey: selectedProviderKey) {
            selectedProviderID = UUID(uuidString: raw)
        }
        selectedModel = UserDefaults.standard.string(forKey: selectedModelKey) ?? ""
    }

    private func migrateLegacy() {
        let defaults = UserDefaults.standard
        let endpoint = defaults.string(forKey: "agent.endpoint") ?? "https://openrouter.ai/api/v1"
        var model = defaults.string(forKey: "agent.model") ?? "xiaomi/mimo-v2.5"
        if model.hasPrefix("local::") { model = "xiaomi/mimo-v2.5" }
        let rawKind = defaults.string(forKey: "agent.providerKind") ?? AgentProviderKind.openAIChat.rawValue
        let kind = AgentProviderKind(rawValue: rawKind) ?? .openAIChat
        let profile = ModelProviderProfile(name: "默认供应商", kind: kind,
                                           endpoint: endpoint, models: [model])
        profiles = [profile]
        selectedProviderID = profile.id
        selectedModel = model
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedProviderID?.uuidString, forKey: selectedProviderKey)
        UserDefaults.standard.set(selectedModel, forKey: selectedModelKey)
    }
}


nonisolated enum ProviderFetchError: LocalizedError {
    case missingKey, invalidEndpoint, invalidResponse, emptyCatalogue
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先保存该供应商的 API Key"
        case .invalidEndpoint: "Endpoint 不是有效的 HTTP(S) 地址"
        case .invalidResponse: "供应商返回了无法解析的模型列表"
        case .emptyCatalogue: "供应商没有返回任何模型"
        case .http(let code, let body): "获取模型失败（HTTP \(code)）\(body.isEmpty ? "" : "：\(body)")"
        }
    }
}

private nonisolated final class ProviderNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ProviderNoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

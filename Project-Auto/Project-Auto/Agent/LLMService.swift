//
//  LLMService.swift
//  Project-Auto
//
//  [macOS 移植] 移植自 Velum（iOS）Agent 数据层，只改平台相关依赖：
//  Logger subsystem → com.lyrastudio.Project-Auto；Keychain 使用默认访问（kSecClassGenericPassword，无 access group）。
//  网络协议 / JSON 编解码 / SSE 流式解析 / Keychain 存取语义保持不变。
//
//  照抄 Visor 架构：Message DTO + StreamDelta + ToolCall + ModelProvider 协议 + OpenAI 兼容 Client + Keychain + Config
//

import Foundation
import Security
import os.log
import Combine

// MARK: - JSONValue（JSON Schema 表达）

nonisolated enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - ToolCall（OpenAI 格式）

nonisolated struct ToolCall: Codable, Sendable, Hashable {
    let id: String
    let type: String
    let function: FunctionCall

    enum CodingKeys: String, CodingKey { case id, type, function }

    struct FunctionCall: Codable, Sendable, Hashable {
        let name: String
        let arguments: String
    }
}

nonisolated struct ToolDefinition: Codable, Sendable, Hashable {
    let type: String
    let function: FunctionSpec

    enum CodingKeys: String, CodingKey { case type, function }

    struct FunctionSpec: Codable, Sendable, Hashable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    static func function(name: String, description: String, parameters: JSONValue) -> ToolDefinition {
        ToolDefinition(type: "function", function: FunctionSpec(name: name, description: description, parameters: parameters))
    }
}

// MARK: - Message DTO（OpenAI Chat Completions 格式）

nonisolated struct Message: Codable, Sendable, Hashable {
    let role: String
    let content: MessageContent?
    let toolCalls: [ToolCall]?
    let toolCallId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case name
    }

    init(role: String, content: MessageContent? = nil, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    static func system(_ s: String) -> Message { Message(role: "system", content: .text(s)) }
    static func user(_ s: String) -> Message { Message(role: "user", content: .text(s)) }
    static func assistant(_ content: String?, toolCalls: [ToolCall]? = nil) -> Message {
        Message(role: "assistant", content: content.map { .text($0) }, toolCalls: toolCalls)
    }
    static func tool(callId: String, content: String, name: String? = nil) -> Message {
        Message(role: "tool", content: .text(content), toolCallId: callId, name: name)
    }
}

nonisolated enum MessageContent: Codable, Sendable, Hashable {
    case text(String)
    case parts([ContentPart])

    struct ContentPart: Codable, Sendable, Hashable {
        let type: String
        let text: String?
        let image_url: ImageURL?

        struct ImageURL: Codable, Sendable, Hashable { let url: String }
        enum CodingKeys: String, CodingKey { case type, text, image_url }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let arr = try? c.decode([ContentPart].self) { self = .parts(arr); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid content")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .parts(let arr): try c.encode(arr)
        }
    }

    var textValue: String? {
        switch self {
        case .text(let s): return s
        case .parts(let arr): return arr.compactMap { $0.text }.isEmpty ? nil : arr.compactMap { $0.text }.joined(separator: "\n")
        }
    }
}

// MARK: - StreamDelta

nonisolated struct StreamDelta: Sendable {
    var contentDelta: String?
    var reasoningDelta: String?
    var toolCallDeltas: [ToolCallFragment]?
    var finishReason: String?
    var usage: Usage?

    struct ToolCallFragment: Sendable {
        var index: Int
        var id: String?
        var type: String?
        var functionName: String?
        var argumentsDelta: String?
    }

    struct Usage: Sendable, Codable {
        var promptTokens: Int
        var completionTokens: Int
        var totalTokens: Int
    }
}

// MARK: - ModelProvider 协议

nonisolated protocol ModelProvider: Sendable {
    var providerName: String { get }
    func stream(messages: [Message], tools: [ToolDefinition], modelId: String) -> AsyncThrowingStream<StreamDelta, Error>
    func cancel()
}

// MARK: - ProviderError

nonisolated enum ProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidResponse
    case serverError(code: Int, message: String)
    case cancelled
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidAPIKey: return "API Key 无效或已失效，请重新配置"
        case .invalidResponse: return "服务器响应格式无效"
        case .serverError(let code, let message): return "服务器错误（\(code)）：\(message)"
        case .cancelled: return "请求已取消"
        case .transport(let e): return "网络错误：\(e.localizedDescription)"
        }
    }
}

// MARK: - KeychainStore（金融级存储，照抄 Visor）

nonisolated enum AgentKeychain {
    /// [macOS] 沙盒下使用默认 Keychain 访问：kSecClassGenericPassword，不指定 access group。
    /// service 名跟随新工程统一为 com.lyrastudio.Project-Auto.*（iOS 侧历史数据无需迁移）。
    private static let service = "com.lyrastudio.Project-Auto.agent"

    static func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess: return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        default: break
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AgentConfig（配置管理）
//
// [FIX 持久化] 配置存 Keychain（App 卸载/重装后仍保留），
// 首次启动时从 UserDefaults 迁移旧值，保证升级不丢。

@MainActor
final class AgentConfig: ObservableObject {
    static let shared = AgentConfig()

    @Published var endpoint: String {
        didSet { Self.persist(endpoint, account: "agent_endpoint", defaultsKey: "agent.endpoint") }
    }
    @Published var model: String {
        didSet { Self.persist(model, account: "agent_model", defaultsKey: "agent.model") }
    }
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                AgentKeychain.delete(account: "agent_api_key")
            } else {
                try? AgentKeychain.set(apiKey, account: "agent_api_key")
            }
        }
    }
    @Published var systemPrompt: String {
        didSet { Self.persist(systemPrompt, account: "agent_systemPrompt", defaultsKey: "agent.systemPrompt") }
    }
    /// 三种协议显式选择，不再按模型名猜。
    @Published var providerKind: AgentProviderKind {
        didSet { UserDefaults.standard.set(providerKind.rawValue, forKey: "agent.providerKind") }
    }
    @Published var reasoningEffort: AgentReasoningEffort {
        didSet { UserDefaults.standard.set(reasoningEffort.rawValue, forKey: "agent.reasoningEffort") }
    }

    private var providerObserver: AnyCancellable?
    private var localModelObserver: AnyCancellable?

    /// Keychain 优先读取；无则回退 UserDefaults（旧版数据）并迁移。
    private static func load(account: String, defaultsKey: String, fallback: String) -> String {
        if let v = AgentKeychain.get(account: account), !v.isEmpty { return v }
        let legacy = UserDefaults.standard.string(forKey: defaultsKey) ?? fallback
        if legacy != fallback { try? AgentKeychain.set(legacy, account: account) }
        return legacy
    }

    private static func persist(_ value: String, account: String, defaultsKey: String) {
        try? AgentKeychain.set(value, account: account)
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    private init() {
        self.endpoint = Self.load(account: "agent_endpoint",
                                  defaultsKey: "agent.endpoint",
                                  fallback: "https://openrouter.ai/api/v1")
        // 本地 MLX 模型功能已移除：如果残留 local:: 命名空间的 model id，重置为默认
        var storedModel = Self.load(account: "agent_model",
                                    defaultsKey: "agent.model",
                                    fallback: "xiaomi/mimo-v2.5")
        if storedModel.hasPrefix("local::") { storedModel = "xiaomi/mimo-v2.5" }
        self.model = storedModel
        self.apiKey = AgentKeychain.get(account: "agent_api_key") ?? ""
        self.systemPrompt = Self.load(account: "agent_systemPrompt",
                                      defaultsKey: "agent.systemPrompt",
                                      fallback: "")
        self.providerKind = AgentProviderKind(rawValue: UserDefaults.standard.string(forKey: "agent.providerKind") ?? "") ?? .openAIChat
        self.reasoningEffort = AgentReasoningEffort(rawValue: UserDefaults.standard.string(forKey: "agent.reasoningEffort") ?? "") ?? .medium
        providerObserver = ProviderStore.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        localModelObserver = LocalModelSelection.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - 测试/环境覆盖（不写入 Keychain）
    //
    // 只用于本地验收（sedtltest / 真实网关），未设置时行为与产品配置一致。

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static func arg(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private var activeProfile: ModelProviderProfile? { ProviderStore.shared.selectedProfile }

    var effectiveEndpoint: String {
        Self.arg("--test-base-url") ?? Self.env["VELUM_TEST_BASE_URL"]
            ?? activeProfile?.endpoint ?? endpoint
    }
    var selectedLocalModel: ManagedLocalModel? {
        guard Self.arg("--test-model") == nil, Self.env["VELUM_TEST_MODEL"] == nil else { return nil }
        return LocalModelSelection.shared.selected
    }

    func makeAgentProvider() -> (any PiProvider)? {
        if let selectedLocalModel {
            return ManagedLocalAIProvider(model: selectedLocalModel, thinkingEnabled: reasoningEffort != .off,
                                          reasoningEffort: reasoningEffort.rawValue)
        }
        return PiProviderFactory.make(kind: effectiveProviderKind, endpoint: effectiveEndpoint, apiKey: effectiveAPIKey)
    }

    var effectiveModel: String {
        if let override = Self.arg("--test-model") ?? Self.env["VELUM_TEST_MODEL"], !override.isEmpty { return override }
        if let selectedLocalModel { return selectedLocalModel.id }
        if activeProfile != nil { return ProviderStore.shared.selectedModel }
        return model
    }
    var effectiveAPIKey: String {
        if let override = Self.arg("--test-api-key") ?? Self.env["VELUM_TEST_API_KEY"], !override.isEmpty {
            return override
        }
        if let activeProfile { return ProviderStore.shared.apiKey(for: activeProfile) }
        return apiKey
    }
    var effectiveProviderKind: AgentProviderKind {
        if let raw = Self.arg("--test-provider") ?? Self.env["VELUM_TEST_PROVIDER"],
           let kind = AgentProviderKind(rawValue: raw) {
            return kind
        }
        return activeProfile?.kind ?? providerKind
    }

    /// 开发验收：把启动参数里的 --test-* 写进 Keychain/UserDefaults，
    /// 之后不带参数启动也能直接使用。显式传 --persist-config 才生效。
    @MainActor
    static func persistTestOverridesIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--persist-config") else { return }
        let config = shared
        if let raw = arg("--test-provider"), let kind = AgentProviderKind(rawValue: raw) {
            config.providerKind = kind
        }
        if let value = arg("--test-base-url") { config.endpoint = value }
        if let value = arg("--test-model") { config.model = value }
        if let value = arg("--test-api-key") { config.apiKey = value }
    }

    func makeProvider() -> ModelProvider? {
        // [TASK #7] DeepSeek Responses API 优先
        if model.lowercased().contains("deepseek") && (model.hasPrefix("deepseek/") || model.contains("r1")) {
            guard !apiKey.isEmpty else { return nil }
            // [修复] Responses API 只在 DeepSeek 官方端点存在。
            // 若用户配置的是 OpenRouter 等其他端点, 必须强制切回官方端点, 否则
            // /api/v1/responses 会 404。
            let effective = endpoint.lowercased().contains("deepseek.com")
                ? endpoint
                : "https://api.deepseek.com/v1"
            let baseURL = URL(string: effective) ?? URL(string: "https://api.deepseek.com/v1")!
            return DeepSeekResponsesClient(baseURL: baseURL, apiKey: apiKey)
        }
        
        // 自定义服务商（custom:: 命名空间）
        if CustomProviderRegistry.shared.isCustomModel(model) {
            return CustomProviderRegistry.shared.resolve(model)?.provider
        }
        // 默认 OpenRouter / OpenAI 兼容
        guard !apiKey.isEmpty, !endpoint.isEmpty, !model.isEmpty else { return nil }
        return OpenAICompatibleClient(baseURL: endpoint, apiKey: apiKey)
    }
    
    /// 实际发给 provider 的 modelId（自定义模型去掉命名空间前缀）
    var effectiveModelId: String {
        if CustomProviderRegistry.shared.isCustomModel(model) {
            return CustomProviderRegistry.shared.resolve(model)?.modelId ?? model
        }
        return model
    }

    /// 当前模型显示名（用于 UI）
    var effectiveModelDisplayName: String {
        let id = effectiveModel
        if id.isEmpty { return "未配置模型" }
        return ModelCatalog.find(id)?.displayName ?? id
    }

    var modelDisplayName: String {
        let id = effectiveModel
        if CustomProviderRegistry.shared.isCustomModel(id) {
            return CustomProviderRegistry.shared.displayName(for: id) ?? id
        }
        return ModelCatalog.find(id)?.displayName ?? id
    }
}

// MARK: - OpenAICompatibleClient（照抄 Visor SSE 解析）

nonisolated final class OpenAICompatibleClient: ModelProvider, @unchecked Sendable {
    nonisolated let providerName = "OpenAI Compatible"
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private var currentTask: Task<Void, Never>?

    init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.baseURL = URL(string: trimmed) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.session = session
    }

    nonisolated func stream(messages: [Message], tools: [ToolDefinition], modelId: String) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let req = self.buildRequest(messages: messages, tools: tools, modelId: modelId)
            let task = Task {
                do {
                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.invalidResponse); return
                    }
                    if http.statusCode == 401 {
                        continuation.finish(throwing: ProviderError.invalidAPIKey); return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyLines: [String] = []
                        do { for try await line in bytes.lines.prefix(5) { bodyLines.append(line) } } catch {}
                        let raw = bodyLines.joined(separator: "\n")
                        var msg = "HTTP \(http.statusCode)"
                        if let data = raw.data(using: .utf8),
                           let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
                           let err = payload.error {
                            msg = "[\(err.code ?? http.statusCode)] \(err.message ?? "未知错误")"
                        } else if !raw.isEmpty {
                            msg += ": \(String(raw.prefix(200)))"
                        }
                        continuation.finish(throwing: ProviderError.serverError(code: http.statusCode, message: msg)); return
                    }
                    try await self.parseSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let e as ProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ProviderError.transport(error))
                }
            }
            self.currentTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    nonisolated func cancel() { currentTask?.cancel(); currentTask = nil }

    // MARK: - Request

    nonisolated private func buildRequest(messages: [Message], tools: [ToolDefinition], modelId: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 0
        let body = RequestBody(model: modelId, messages: messages, stream: true,
                               tools: tools.isEmpty ? nil : tools,
                               tool_choice: tools.isEmpty ? nil : "auto")
        req.httpBody = try? JSONEncoder().encode(body)
        return req
    }

    nonisolated private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let tools: [ToolDefinition]?
        let tool_choice: String?
    }

    // MARK: - SSE Parsing

    nonisolated private func parseSSE(bytes: URLSession.AsyncBytes, continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation) async throws {
        for try await line in bytes.lines {
            if Task.isCancelled { throw ProviderError.cancelled }
            if line.isEmpty { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8) else { continue }

            if let errPayload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
               let err = errPayload.error {
                continuation.finish(throwing: ProviderError.serverError(code: err.code ?? 0, message: err.message ?? "服务器错误")); return
            }
            do {
                let chunk = try JSONDecoder().decode(SSEChunk.self, from: data)
                continuation.yield(chunk.toStreamDelta())
            } catch { continue }
        }
    }

    // MARK: - Wire Format

    nonisolated private struct ErrorPayload: Decodable {
        struct Err: Decodable { let code: Int?; let message: String? }
        let error: Err?
    }

    nonisolated private struct SSEChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let role: String?
                let content: String?
                let reasoning: String?
                let reasoning_content: String?
                let tool_calls: [ToolCallWire]?
            }
            let delta: Delta
            let finish_reason: String?
        }
        struct ToolCallWire: Decodable {
            let index: Int; let id: String?; let type: String?; let function: FunctionWire?
        }
        struct FunctionWire: Decodable { let name: String?; let arguments: String? }
        struct UsageWire: Decodable {
            let prompt_tokens: Int?; let completion_tokens: Int?; let total_tokens: Int?
        }
        let choices: [Choice]
        let usage: UsageWire?

        func toStreamDelta() -> StreamDelta {
            var d = StreamDelta()
            if let first = choices.first {
                d.contentDelta = first.delta.content
                d.reasoningDelta = first.delta.reasoning ?? first.delta.reasoning_content
                d.finishReason = first.finish_reason
                if let tcs = first.delta.tool_calls, !tcs.isEmpty {
                    d.toolCallDeltas = tcs.map { tc in
                        StreamDelta.ToolCallFragment(index: tc.index, id: tc.id, type: tc.type,
                                                     functionName: tc.function?.name,
                                                     argumentsDelta: tc.function?.arguments)
                    }
                }
            }
            if let u = usage {
                let p = u.prompt_tokens ?? 0, c = u.completion_tokens ?? 0
                d.usage = StreamDelta.Usage(promptTokens: p, completionTokens: c, totalTokens: u.total_tokens ?? (p + c))
            }
            return d
        }
    }
}

// MARK: - DeepSeek Responses API（官方 Responses API 支持）

/// [TASK #7] DeepSeek Responses API 专用 Provider
/// 参考：https://api-docs.deepseek.com/zh-cn/guides/responses_api
nonisolated final class DeepSeekResponsesClient: ModelProvider, @unchecked Sendable {
    
    nonisolated let providerName = "DeepSeek Responses"
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    
    // [TASK #7] 思考深度控制 (1 ~ 10)
    var thinkingBudget: Int = 2048
    var enableThinking: Bool = true
    
    init(baseURL: URL = URL(string: "https://api.deepseek.com/v1")!, 
         apiKey: String, 
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }
    
    nonisolated func stream(messages: [Message], tools: [ToolDefinition], modelId: String) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let req = self.buildRequest(messages: messages, tools: tools, modelId: modelId)
            let task = Task {
                do {
                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.invalidResponse); return
                    }
                    
                    if http.statusCode == 401 {
                        continuation.finish(throwing: ProviderError.invalidAPIKey); return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyLines: [String] = []
                        do { for try await line in bytes.lines.prefix(5) { bodyLines.append(line) } } catch {}
                        let raw = bodyLines.joined(separator: "\n")
                        continuation.finish(throwing: ProviderError.serverError(code: http.statusCode, message: String(raw.prefix(200)))); return
                    }
                    
                    try await self.parseResponsesSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let e as ProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ProviderError.transport(error))
                }
            }
            self.currentTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    
    nonisolated func cancel() { currentTask?.cancel(); currentTask = nil }
    
    private var currentTask: Task<Void, Never>?
    
    // MARK: - DeepSeek Requests
    
    /// [TASK #7] 构建 DeepSeek Responses API 请求
    nonisolated private func buildRequest(messages: [Message], tools: [ToolDefinition], modelId: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("responses"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 0
        
        let body = DeepSeekRequestBody(
            model: modelId,
            input: messages.map { $0.toDeepSeekInput() },
            tools: tools.isEmpty ? nil : tools.map { $0.toDeepSeekTool() },
            temperature: 0.7,
            max_output_tokens: 8192,
            reasoning: enableThinking ? ["effort": "medium"] : [:], // [TASK #7] 开启思考过程
            parallel_tool_calls: true
        )
        
        req.httpBody = try? JSONEncoder().encode(body)
        return req
    }
    
    // MARK: - DeepSeek Response Parsing
    
    /// [TASK #7] 解析 DeepSeek Responses SSE
    nonisolated private func parseResponsesSSE(bytes: URLSession.AsyncBytes, continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation) async throws {
        var accumulatedText: String = ""
        var accumulatedReasoning: String = ""
        
        for try await line in bytes.lines {
            if Task.isCancelled { throw ProviderError.cancelled }
            if line.isEmpty { continue }
            guard line.hasPrefix("data:") else { continue }
            
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            
            guard let data = payload.data(using: .utf8) else { continue }
            
            // 错误处理
            if let errPayload = try? JSONDecoder().decode(DeepSeekError.self, from: data),
               let err = errPayload.error {
                continuation.finish(throwing: ProviderError.serverError(code: err.code ?? 0, message: err.message ?? "服务器错误")); return
            }
            
            do {
                let chunk = try JSONDecoder().decode(DeepSeekEvent.self, from: data)
                
                switch chunk.type {
                case .output_text_delta:
                    accumulatedText += chunk.text ?? ""
                    continuation.yield(StreamDelta(contentDelta: chunk.text ?? "", reasoningDelta: accumulatedReasoning))
                    
                case .reasoning_summary_text_delta:
                    accumulatedReasoning += chunk.text ?? ""
                    continuation.yield(StreamDelta(contentDelta: accumulatedText, reasoningDelta: chunk.text ?? ""))
                    
                case .output_text_done:
                    // 文本完成，继续输出
                    break
                    
                case .completed:
                    // 对话完成
                    if let usage = chunk.usage {
                        let event = StreamDelta()
                        // 手动设置 usage
                        var delta = StreamDelta()
                        delta.usage = StreamDelta.Usage(promptTokens: usage.input_tokens ?? 0, 
                                                        completionTokens: usage.output_tokens ?? 0, 
                                                        totalTokens: (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0))
                        continuation.yield(delta)
                    }
                    continuation.finish()
                    
                default:
                    break
                }
            } catch {
                continue
            }
        }
    }
}

// MARK: - Message Extensions for DeepSeek

// [macOS] 显式 nonisolated：工程默认 actor isolation 为 MainActor，
// 扩展成员不会继承类型的 nonisolated，必须单独标注才能保持在非隔离上下文可调用。
nonisolated extension Message {
    /// 转换为 DeepSeek 输入格式
    func toDeepSeekInput() -> DeepSeekMessageInput {
        switch role {
        case "system":
            return .init(role: .system, content: [.type_text(text: content?.textValue ?? "")], callId: nil)
        case "user":
            return .init(role: .user, content: [.type_text(text: content?.textValue ?? "")], callId: nil)
        case "assistant":
            var contents: [DeepSeekContentPart] = []
            if let text = content?.textValue, !text.isEmpty {
                contents.append(.type_text(text: text))
            }
            if let toolCalls = toolCalls, !toolCalls.isEmpty {
                // [修复] 并行工具调用全部携带, 不再只取 first。
                for tc in toolCalls {
                    contents.append(.type_function_call(
                        name: tc.function.name,
                        arguments: tc.function.arguments
                    ))
                }
            }
            return .init(role: .assistant, content: contents, callId: nil)
        case "tool":
            return .init(role: .tool, content: [.type_text(text: content?.textValue ?? "")], callId: toolCallId)
        default:
            return .init(role: .user, content: [.type_text(text: "")], callId: nil)
        }
    }
}

nonisolated extension ToolDefinition {
    /// 转换为 DeepSeek 工具格式（完整 JSON Schema，不再传空字典）。
    func toDeepSeekTool() -> DeepSeekFunctionTool {
        return .init(type: "function", function: .init(
            name: function.name,
            description: function.description,
            parameters: function.parameters
        ))
    }
}

// MARK: - DeepSeek Data Models

nonisolated struct DeepSeekRequestBody: Encodable {
    let model: String
    let input: [DeepSeekMessageInput]
    let tools: [DeepSeekFunctionTool]?
    let temperature: Double
    let max_output_tokens: Int
    let reasoning: [String: String]
    let parallel_tool_calls: Bool
    
    enum CodingKeys: String, CodingKey {
        case model, input, tools, temperature
        case max_output_tokens = "max_output_tokens"
        case reasoning
        case parallel_tool_calls = "parallel_tool_calls"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(input, forKey: .input)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(max_output_tokens, forKey: .max_output_tokens)
        // reasoning 是字典，但可能为空
        if !reasoning.isEmpty {
            try container.encode(reasoning, forKey: .reasoning)
        }
        try container.encode(parallel_tool_calls, forKey: .parallel_tool_calls)
    }
}

nonisolated enum DeepSeekEventType: String {
    case output_text_delta = "output_text.delta"
    case output_text_done = "output_text.done"
    case reasoning_summary_text_delta = "reasoning_summary_text.delta"
    case completed = "completed"
    case error = "error"
}

nonisolated struct DeepSeekEvent: Decodable {
    let type: DeepSeekEventType
    let text: String?
    let usage: DeepSeekUsage?
    
    enum CodingKeys: String, CodingKey {
        case type = "type"
        case text = "text"
        case usage = "usage"
    }
    
    // DeepSeek API 返回格式可能是多种类型
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 尝试解码 type，如果是字符串则转换为 enum
        if let typeString = try? container.decode(String.self, forKey: .type) {
            switch typeString {
            case "output_text.delta": self.type = .output_text_delta
            case "output_text.done": self.type = .output_text_done
            case "reasoning_summary_text.delta": self.type = .reasoning_summary_text_delta
            case "completed": self.type = .completed
            case "error": self.type = .error
            default: self.type = .output_text_delta
            }
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid event type")
        }
        self.text = try? container.decode(String.self, forKey: .text)
        self.usage = try? container.decode(DeepSeekUsage.self, forKey: .usage)
    }
}

nonisolated struct DeepSeekUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case input_tokens = "input_tokens"
        case output_tokens = "output_tokens"
    }
}

nonisolated struct DeepSeekError: Decodable {
    let error: DeepSeekErrorDetail?
    
    enum CodingKeys: String, CodingKey {
        case error = "error"
    }
}

nonisolated struct DeepSeekErrorDetail: Decodable {
    let code: Int?
    let message: String?
}

// MARK: - DeepSeek Data Models (补充)

nonisolated struct DeepSeekMessageInput: Encodable {
    let role: DeepSeekRole
    let content: [DeepSeekContentPart]
    let callId: String?
    
    enum CodingKeys: String, CodingKey {
        case role, content
        case callId = "call_id"
    }
}

nonisolated enum DeepSeekRole: String, Encodable {
    case system = "system"
    case user = "user"
    case assistant = "assistant"
    case tool = "tool"
}

nonisolated struct DeepSeekContentPart: Encodable {
    let type: String
    let text: String?
    let name: String?
    let arguments: String?
    
    enum CodingKeys: String, CodingKey {
        case type = "type"
        case text
        case name
        case arguments
    }
}

nonisolated extension DeepSeekContentPart {
    static func type_text(text: String) -> DeepSeekContentPart {
        .init(type: "input_text", text: text, name: nil, arguments: nil)
    }
    
    static func type_function_call(name: String, arguments: String) -> DeepSeekContentPart {
        .init(type: "input_function_call", text: nil, name: name, arguments: arguments)
    }
}

nonisolated struct DeepSeekFunctionTool: Encodable {
    let type: String
    let function: DeepSeekFunction
    
    enum CodingKeys: String, CodingKey {
        case type = "type"
        case function
    }
}

nonisolated struct DeepSeekFunction: Encodable {
    let name: String
    let description: String
    /// 完整 JSON Schema（任意嵌套）。旧版 [String: String] 无法表达对象/数组属性。
    let parameters: JSONValue
}

// MARK: - LocalModelCleanup（一次性清理已废弃的本地 MLX 模型文件）
// MLX 本地模型功能已移除（中国大陆网络环境下 SPM 缓存无法建立），
// 这里负责清理用户设备上残留的下载文件，释放存储空间。

nonisolated enum LocalModelCleanup {
    /// [macOS] 统一日志通道（原 os_log(OSLog.default) 无 subsystem，移植后走项目 Logger）。
    private static let logger = Logger(subsystem: "com.lyrastudio.Project-Auto", category: "LocalModelCleanup")

    /// 已废弃的本地模型存储根目录：Application Support/models/
    private static var deprecatedModelsRoot: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("models", isDirectory: true)
    }

    /// 清理所有已下载的本地 MLX 模型文件。
    /// 安全可重入：目录不存在时直接返回。
    static func cleanUp() {
        guard let root = deprecatedModelsRoot else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }

        // 计算清理前的总大小（用于日志）
        var totalBytes: Int64 = 0
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    totalBytes += Int64(size)
                }
            }
        }

        do {
            try fm.removeItem(at: root)
            let mb = Double(totalBytes) / 1024.0 / 1024.0
            let msg = String(format: "[LocalModelCleanup] 已清理废弃的本地模型目录，释放 %.2f MB", mb)
            Self.logger.info("\(msg, privacy: .public)")
        } catch {
            Self.logger.error("[LocalModelCleanup] 清理本地模型目录失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}

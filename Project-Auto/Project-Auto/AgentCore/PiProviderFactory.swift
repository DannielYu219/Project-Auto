//
//  PiProviderFactory.swift
//  Project-Auto
//
//  三种协议的统一入口：Chat Completions / Responses / Anthropic Messages。
//  端点语义：
//  - OpenAI 两种：baseURL 指向含 /v1 的前缀（如 http://127.0.0.1:3000/v1）
//  - Anthropic：baseURL 指向主机根（如 http://127.0.0.1:3000），适配器自己拼 /v1/messages
//

import Foundation

nonisolated enum AgentProviderKind: String, CaseIterable, Sendable, Identifiable {
    case openAIChat
    case openAIResponses
    case anthropicMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAIChat: "Chat"
        case .openAIResponses: "Responses"
        case .anthropicMessages: "Anthropic"
        }
    }

    var fullTitle: String {
        switch self {
        case .openAIChat: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

nonisolated enum PiProviderFactory {
    static func make(kind: AgentProviderKind, endpoint: String, apiKey: String) -> (any PiProvider)? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let baseURL = normalizedBaseURL(kind: kind, endpoint: endpoint) else {
            return nil
        }
        switch kind {
        case .openAIChat:
            return OpenAIChatCompletionsClient(baseURL: baseURL, apiKey: apiKey)
        case .openAIResponses:
            return OpenAIResponsesClient(baseURL: baseURL, apiKey: apiKey)
        case .anthropicMessages:
            return AnthropicMessagesClient(baseURL: baseURL, apiKey: apiKey)
        }
    }

    static func normalizedBaseURL(kind: AgentProviderKind, endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text) else { return nil }

        switch kind {
        case .anthropicMessages:
            // Anthropic 适配器会追加 /v1/messages；避免出现 /v1/v1/messages。
            if components.path.hasSuffix("/v1") {
                components.path = String(components.path.dropLast(3))
            }
        case .openAIChat, .openAIResponses:
            // OpenAI 兼容端点通常以 /v1 结尾；没有路径时补上 /v1。
            let path = components.path
            if path.isEmpty || path == "/" {
                components.path = "/v1"
            }
        }
        return components.url
    }
}

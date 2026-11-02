//
//  PiTypes.swift
//  Project-Auto
//
//  参照 pi-ai（@earendil-works/pi-ai, MIT）的规范化模型：
//  统一消息 / 工具调用 / usage / stop reason / 流式事件。
//  各 Provider 适配器只负责「规范化 ⇄ 原生线格式」的转换。
//
//  与 pi 的差异：本工程不产出 partial AssistantMessage 快照，
//  由 AgentLoop 自行累积；这样可以避免每个 delta 复制整条消息。
//

import Foundation

nonisolated enum PiStopReason: String, Sendable, Equatable {
    case pending
    case stop
    case length
    case toolUse
    case error
    case aborted
    case deferred
}

nonisolated enum PiCacheRetention: String, Sendable {
    case none
    case short
    case long
}

nonisolated struct PiUsage: Sendable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0

    var totalTokens: Int { input + output + cacheRead + cacheWrite }

    /// 缓存命中率：命中读取 / 全部输入（三家归一化后 input 不含 cache）。
    var cacheHitRate: Double {
        let total = input + cacheRead + cacheWrite
        guard total > 0 else { return 0 }
        return Double(cacheRead) / Double(total)
    }

    static func + (lhs: PiUsage, rhs: PiUsage) -> PiUsage {
        PiUsage(input: lhs.input + rhs.input,
                output: lhs.output + rhs.output,
                cacheRead: lhs.cacheRead + rhs.cacheRead,
                cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                reasoning: lhs.reasoning + rhs.reasoning)
    }
}

nonisolated struct PiToolCall: Sendable, Equatable {
    var id: String
    var name: String
    /// 解析后的参数对象；解析失败时为 `.object([:])`，原因见 argumentsError。
    var arguments: JSONValue
    var argumentsError: String?
}

nonisolated enum PiContentPart: Sendable, Equatable {
    case text(String)
    case thinking(String, signature: String?)
    case toolCall(PiToolCall)
}

nonisolated struct PiAssistantMessage: Sendable, Equatable {
    var content: [PiContentPart] = []
    var model: String = ""
    var usage = PiUsage()
    var stopReason: PiStopReason = .pending
    var errorMessage: String?
    var timestamp = Date()

    var text: String {
        content.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }.joined()
    }

    var thinking: String {
        content.compactMap { part -> String? in
            if case .thinking(let value, _) = part { return value }
            return nil
        }.joined()
    }

    var toolCalls: [PiToolCall] {
        content.compactMap { part -> PiToolCall? in
            if case .toolCall(let call) = part { return call }
            return nil
        }
    }
}

nonisolated struct PiToolImage: Sendable, Equatable {
    var base64: String
    var mimeType: String = "image/png"
}

nonisolated struct PiToolResult: Sendable, Equatable {
    var toolCallId: String
    var toolName: String
    var content: String
    var isError = false
    var images: [PiToolImage] = []
}

nonisolated enum PiMessage: Sendable, Equatable {
    case system(String)
    case user(String)
    case assistant(PiAssistantMessage)
    case toolResult(PiToolResult)
}

nonisolated struct PiToolSpec: Sendable, Equatable {
    var name: String
    var description: String
    var parameters: JSONValue
}

nonisolated enum PiToolChoice: Sendable, Equatable {
    case auto
    case none
    case required
    case tool(String)
}

nonisolated struct PiRequest: Sendable {
    var model: String
    var messages: [PiMessage]
    var tools: [PiToolSpec] = []
    var toolChoice: PiToolChoice = .auto
    var maxTokens = 4096
    var temperature: Double?
    var systemExtra: String? = nil
    var cacheRetention: PiCacheRetention = .short
    /// OpenAI 的 prompt_cache_key；用会话 id 保持跨轮稳定。Anthropic 忽略。
    var promptCacheKey: String? = nil
}

/// 统一的流式事件。Provider 只发增量，循环负责累积成 PiAssistantMessage。
nonisolated enum PiStreamEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStart(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, delta: String)
    case toolCallEnd(index: Int, call: PiToolCall)
    case usage(PiUsage)
    case stop(PiStopReason, raw: String?)
}

nonisolated enum PiProviderError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case unauthorized(String)
    case invalidRequest(String)
    case rateLimited(retryAfter: String?)
    case server(status: Int, message: String)
    case invalidResponse(String)
    case transport(String)
    case cancelled
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .unauthorized(let detail): return detail.isEmpty ? "API Key 无效或已失效" : "鉴权失败：\(detail)"
        case .invalidRequest(let detail): return "请求被拒绝：\(detail)"
        case .rateLimited(let retry): return retry.map { "触发限流，建议 \($0) 秒后重试" } ?? "触发限流，请稍后重试"
        case .server(let status, let message): return "服务器错误（\(status)）：\(message)"
        case .invalidResponse(let detail): return "响应格式无效：\(detail)"
        case .transport(let detail): return "网络错误：\(detail)"
        case .cancelled: return "请求已取消"
        case .streamError(let detail): return "流式错误：\(detail)"
        }
    }
}

nonisolated protocol PiProvider: Sendable {
    var providerName: String { get }
    func stream(_ request: PiRequest) -> AsyncThrowingStream<PiStreamEvent, Error>
    func cancel()
}

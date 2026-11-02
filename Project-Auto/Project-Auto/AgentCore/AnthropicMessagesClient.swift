//
//  AnthropicMessagesClient.swift
//  Project-Auto
//
//  Anthropic Messages API（/v1/messages）流式 + 工具调用适配器。
//  规格对齐 pi-ai 的 anthropic-messages 实现（MIT），只保留产品需要的部分：
//  - 自己解析 SSE（不依赖 SDK）
//  - 工具调用按 content block index 累积 partial_json，结束后严格解析
//  - 连续 toolResult 合并成一条 user 消息；tool_use / tool_result 成对出现
//
//  【与 pi 的差异】pi 用 SDK 处理鉴权与 beta 头；这里直接写 x-api-key / anthropic-version。
//  pi 的 thinking 回放需要额外签名与 beta，本适配器暂不回放 thinking 块。
//

import Foundation

nonisolated final class AnthropicMessagesClient: PiProvider, @unchecked Sendable {
    nonisolated let providerName = "Anthropic Messages"

    private static let anthropicVersion = "2023-06-01"

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let lock = NSLock()
    private var currentTask: Task<Void, Never>?

    init(baseURL: URL = URL(string: "https://api.anthropic.com")!,
         apiKey: String,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    nonisolated func stream(_ request: PiRequest) -> AsyncThrowingStream<PiStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !apiKey.isEmpty else {
                continuation.finish(throwing: PiProviderError.missingAPIKey)
                return
            }
            let task = Task {
                do {
                    let urlRequest = try Self.buildRequest(baseURL: baseURL, apiKey: apiKey, request: request)
                    if ProcessInfo.processInfo.environment["VELUM_DEBUG_REQUESTS"] == "1",
                       let body = urlRequest.httpBody {
                        print("REQUEST", urlRequest.url?.absoluteString ?? "", String(data: body, encoding: .utf8) ?? "")
                    }
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw PiProviderError.invalidResponse("没有 HTTP 响应")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let body = try await Self.readBody(bytes: bytes, limit: 8192)
                        throw Self.mapHTTPError(status: http.statusCode,
                                                body: body,
                                                retryAfter: http.value(forHTTPHeaderField: "retry-after"))
                    }
                    try await Self.parseStream(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: PiProviderError.cancelled)
                } catch let error as PiProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: PiProviderError.transport(error.localizedDescription))
                }
            }
            lock.lock()
            currentTask = task
            lock.unlock()
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    nonisolated func cancel() {
        lock.lock()
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: - 请求

    private static func buildRequest(baseURL: URL, apiKey: String, request: PiRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/messages")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.timeoutInterval = 0

        let cacheControl = cacheControl(for: request.cacheRetention)
        var messages = convertMessages(request.messages)
        if let cacheControl {
            attachCacheControl(toLastMessageOf: &messages, cacheControl)
        }
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": messages
        ]
        let system = systemText(request.messages, extra: request.systemExtra)
        if !system.isEmpty {
            var block: [String: Any] = ["type": "text", "text": system]
            if let cacheControl { block["cache_control"] = cacheControl }
            body["system"] = [block]
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.enumerated().map { index, tool -> [String: Any] in
                var dict: [String: Any] = ["name": tool.name,
                                           "description": tool.description,
                                           "input_schema": prunedSchema(tool.parameters)]
                // pi 的做法：只打在最后一个工具上，作为工具前缀的缓存断点。
                if index == request.tools.count - 1, let cacheControl {
                    dict["cache_control"] = cacheControl
                }
                return dict
            }
            switch request.toolChoice {
            case .auto: body["tool_choice"] = ["type": "auto"]
            case .none: body["tool_choice"] = ["type": "none"]
            case .required: body["tool_choice"] = ["type": "any"]
            case .tool(let name): body["tool_choice"] = ["type": "tool", "name": name]
            }
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// Anthropic 需要显式 cache_control 断点。短缓存默认 5 分钟，长缓存用 1h（写入更贵）。
    private static func cacheControl(for retention: PiCacheRetention) -> [String: Any]? {
        switch retention {
        case .none: return nil
        case .short: return ["type": "ephemeral"]
        case .long: return ["type": "ephemeral", "ttl": "1h"]
        }
    }

    /// 把断点打在最后一条消息的最后一个 block 上：之前的前缀（system + tools + 历史）命中缓存。
    private static func attachCacheControl(toLastMessageOf messages: inout [[String: Any]],
                                           _ cacheControl: [String: Any]) {
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            if var blocks = messages[index]["content"] as? [[String: Any]], !blocks.isEmpty {
                var last = blocks[blocks.count - 1]
                last["cache_control"] = cacheControl
                blocks[blocks.count - 1] = last
                messages[index]["content"] = blocks
                return
            }
            if let text = messages[index]["content"] as? String, !text.isEmpty {
                messages[index]["content"] = [["type": "text",
                                              "text": text,
                                              "cache_control": cacheControl]]
                return
            }
        }
    }

    private static func systemText(_ messages: [PiMessage], extra: String?) -> String {
        var parts: [String] = []
        for message in messages {
            if case .system(let text) = message {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            }
        }
        if let extra {
            let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Anthropic 只接受 name/description/input_schema，schema 只保留 type/properties/required。
    private static func prunedSchema(_ parameters: JSONValue) -> [String: Any] {
        guard case .object(let object) = parameters else {
            return ["type": "object", "properties": [:], "required": []]
        }
        var schema: [String: Any] = ["type": "object"]
        if let properties = object["properties"] {
            schema["properties"] = anyValue(properties)
        } else {
            schema["properties"] = [:]
        }
        if let required = object["required"] {
            schema["required"] = anyValue(required)
        } else {
            schema["required"] = []
        }
        return schema
    }

    private static func convertMessages(_ messages: [PiMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            result.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }

        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let text):
                flushToolResults()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result.append(["role": "user", "content": [["type": "text", "text": text]]])
            case .assistant(let assistant):
                flushToolResults()
                var blocks: [[String: Any]] = []
                for part in assistant.content {
                    switch part {
                    case .text(let text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        blocks.append(["type": "text", "text": text])
                    case .thinking:
                        // 不回放 thinking：需要签名与 beta 头，暂不参与上下文。
                        continue
                    case .toolCall(let call):
                        blocks.append(["type": "tool_use",
                                       "id": call.id,
                                       "name": call.name,
                                       "input": anyValue(call.arguments)])
                    }
                }
                guard !blocks.isEmpty else { continue }
                result.append(["role": "assistant", "content": blocks])
            case .toolResult(let toolResult):
                var resultBlocks: [[String: Any]] = [["type": "text", "text": toolResult.content]]
                for image in toolResult.images {
                    resultBlocks.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": image.base64]])
                }
                pendingToolResults.append(["type": "tool_result",
                                           "tool_use_id": toolResult.toolCallId,
                                           "content": resultBlocks,
                                           "is_error": toolResult.isError])
            }
        }
        flushToolResults()
        return result
    }

    // MARK: - 流解析

    private static func parseStream(bytes: URLSession.AsyncBytes,
                                    continuation: AsyncThrowingStream<PiStreamEvent, Error>.Continuation) async throws {
        let parser = SSEParser()
        let state = AnthropicStreamState()
        for try await rawLine in bytes.lines {
            if Task.isCancelled { throw PiProviderError.cancelled }
            for message in parser.consume(line: rawLine) {
                try state.consume(message, continuation: continuation)
                if state.sawMessageStop { break }
            }
            if state.sawMessageStop { break }
        }
        if !state.sawMessageStop {
            while let tail = parser.flush() {
                try state.consume(tail, continuation: continuation)
                if state.sawMessageStop { break }
            }
        }
        try state.finish(continuation: continuation)
    }

    // MARK: - HTTP 错误

    private static func readBody(bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func mapHTTPError(status: Int, body: String, retryAfter: String?) -> PiProviderError {
        let message = errorMessage(from: body)
        switch status {
        case 401, 403:
            return .unauthorized(message)
        case 400, 404, 422:
            return .invalidRequest(message.isEmpty ? "HTTP \(status)" : message)
        case 408, 409, 429:
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(status: status, message: message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    private static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String { return message }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON 辅助

    static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .int(let int): return int
        case .double(let double): return double
        case .string(let string): return string
        case .array(let array): return array.map(anyValue)
        case .object(let object): return object.mapValues(anyValue)
        }
    }

    static func jsonValue(_ any: Any) -> JSONValue {
        PiJSON.jsonValue(any)
    }
}

// MARK: - Anthropic 流状态机

nonisolated private final class AnthropicStreamState {
    private struct Block {
        enum Kind { case text, thinking, toolUse, other }
        var kind: Kind
        var partialJSON = ""
        var toolID: String?
        var toolName: String?
    }

    private var blocks: [Int: Block] = [:]
    private(set) var sawMessageStop = false
    private var stopReason: PiStopReason = .pending
    private var rawStopReason: String?
    private var usage = PiUsage()

    func consume(_ message: SSEMessage,
                 continuation: AsyncThrowingStream<PiStreamEvent, Error>.Continuation) throws {
        guard let data = message.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let type = message.event ?? (object["type"] as? String) ?? ""
        switch type {
        case "message_start":
            if let payload = object["message"] as? [String: Any],
               let usageObject = payload["usage"] as? [String: Any] {
                mergeUsage(usageObject)
            }
        case "content_block_start":
            let index = intValue(object["index"]) ?? 0
            guard let block = object["content_block"] as? [String: Any] else { return }
            switch block["type"] as? String {
            case "text":
                blocks[index] = Block(kind: .text)
            case "thinking":
                blocks[index] = Block(kind: .thinking)
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                blocks[index] = Block(kind: .toolUse, toolID: id, toolName: name)
                continuation.yield(.toolCallStart(index: index, id: id, name: name))
            default:
                blocks[index] = Block(kind: .other)
            }
        case "content_block_delta":
            let index = intValue(object["index"]) ?? 0
            guard var block = blocks[index],
                  let delta = object["delta"] as? [String: Any] else { return }
            let deltaType = delta["type"] as? String ?? ""
            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
            case "thinking_delta":
                if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                    continuation.yield(.thinkingDelta(thinking))
                }
            case "signature_delta":
                break
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String, !partial.isEmpty {
                    block.partialJSON += partial
                    blocks[index] = block
                    continuation.yield(.toolCallArgumentsDelta(index: index, delta: partial))
                }
            default:
                break
            }
        case "content_block_stop":
            let index = intValue(object["index"]) ?? 0
            guard let block = blocks[index] else { return }
            if block.kind == .toolUse {
                let call = makeToolCall(block)
                continuation.yield(.toolCallEnd(index: index, call: call))
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                rawStopReason = reason
                stopReason = Self.mapStopReason(reason)
            }
            if let usageObject = object["usage"] as? [String: Any] {
                mergeUsage(usageObject)
            }
        case "message_stop":
            sawMessageStop = true
            continuation.yield(.usage(usage))
            continuation.yield(.stop(stopReason, raw: rawStopReason))
        case "error":
            let errorObject = object["error"] as? [String: Any]
            let detail = errorObject?["message"] as? String ?? message.data
            throw PiProviderError.streamError(detail)
        default:
            // ping 与未知事件按 pi 的做法忽略
            break
        }
    }

    func finish(continuation: AsyncThrowingStream<PiStreamEvent, Error>.Continuation) throws {
        guard sawMessageStop else {
            throw PiProviderError.invalidResponse("流在 message_stop 之前结束")
        }
        guard stopReason != .pending else {
            throw PiProviderError.invalidResponse("缺少 stop_reason")
        }
    }

    private func makeToolCall(_ block: Block) -> PiToolCall {
        let argumentsText = block.partialJSON
        var arguments: JSONValue = .object([:])
        var error: String?
        if !argumentsText.isEmpty {
            if let data = argumentsText.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                arguments = AnthropicMessagesClient.jsonValue(parsed)
                if case .object = arguments {} else {
                    arguments = .object([:])
                    error = "工具参数不是 JSON 对象"
                }
            } else {
                error = "工具参数不是合法 JSON"
            }
        }
        return PiToolCall(id: block.toolID ?? "",
                          name: block.toolName ?? "",
                          arguments: arguments,
                          argumentsError: error)
    }

    private func mergeUsage(_ object: [String: Any]) {
        if let value = intValue(object["input_tokens"]) { usage.input = value }
        if let value = intValue(object["output_tokens"]) { usage.output = value }
        if let value = intValue(object["cache_read_input_tokens"]) { usage.cacheRead = value }
        if let value = intValue(object["cache_creation_input_tokens"]) { usage.cacheWrite = value }
        if let details = object["output_tokens_details"] as? [String: Any],
           let thinking = intValue(details["thinking_tokens"]) {
            usage.reasoning = thinking
        }
    }

    private static func mapStopReason(_ raw: String) -> PiStopReason {
        switch raw {
        case "end_turn", "stop_sequence", "pause_turn": return .stop
        case "max_tokens": return .length
        case "tool_use": return .toolUse
        case "refusal", "sensitive": return .error
        default: return .error
        }
    }
}

private func intValue(_ any: Any?) -> Int? {
    if let int = any as? Int { return int }
    if let number = any as? NSNumber { return number.intValue }
    if let double = any as? Double { return Int(double) }
    return nil
}

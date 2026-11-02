//
//  OpenAIChatCompletionsClient.swift
//  Project-Auto
//
//  OpenAI Chat Completions（/v1/chat/completions）流式 + 工具调用适配器。
//  语义对齐 pi-ai 的 openai-completions：
//  - tools 是 {type:"function", function:{...}} 包装
//  - assistant 的 content 用纯字符串；无 content 且无 tool_calls 的消息跳过
//  - 并行 tool_calls 按 index 累积；参数是字符串 JSON，结束后严格解析
//  - stream_options.include_usage 让最后一个 chunk 带 usage
//  - finish_reason 映射；缺省时按是否出现工具调用推断
//

import Foundation

nonisolated final class OpenAIChatCompletionsClient: PiProvider, @unchecked Sendable {
    nonisolated let providerName = "OpenAI Chat Completions"

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let localThinkingEnabled: Bool?
    private let localReasoningEffort: String?
    private let lock = NSLock()
    private var currentTask: Task<Void, Never>?

    init(baseURL: URL = URL(string: "https://api.openai.com/v1")!,
         apiKey: String,
         session: URLSession = .shared,
         localThinkingEnabled: Bool? = nil,
         localReasoningEffort: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.localThinkingEnabled = localThinkingEnabled
        self.localReasoningEffort = localReasoningEffort
    }

    nonisolated func stream(_ request: PiRequest) -> AsyncThrowingStream<PiStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !apiKey.isEmpty else {
                continuation.finish(throwing: PiProviderError.missingAPIKey)
                return
            }
            let task = Task {
                do {
                    let urlRequest = try Self.buildRequest(baseURL: baseURL, apiKey: apiKey, request: request, localThinkingEnabled: localThinkingEnabled, localReasoningEffort: localReasoningEffort)
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

    private static func buildRequest(baseURL: URL, apiKey: String, request: PiRequest, localThinkingEnabled: Bool?, localReasoningEffort: String?) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.timeoutInterval = 0

        var body: [String: Any] = [
            "model": request.model,
            "messages": convertMessages(request.messages, systemExtra: request.systemExtra),
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": request.maxTokens
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": ["name": tool.name,
                              "description": tool.description,
                              "parameters": PiJSON.anyValue(tool.parameters)]]
            }
            switch request.toolChoice {
            case .auto: body["tool_choice"] = "auto"
            case .none: body["tool_choice"] = "none"
            case .required: body["tool_choice"] = "required"
            case .tool(let name):
                body["tool_choice"] = ["type": "function", "function": ["name": name]]
            }
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if request.cacheRetention != .none, let key = request.promptCacheKey, !key.isEmpty {
            body["prompt_cache_key"] = String(key.prefix(64))
            if request.cacheRetention == .long {
                body["prompt_cache_retention"] = "24h"
            }
        }
        if let localThinkingEnabled {
            body["chat_template_kwargs"] = ["enable_thinking": localThinkingEnabled]
        }
        if let localReasoningEffort { body["reasoning_effort"] = localReasoningEffort }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func convertMessages(_ messages: [PiMessage], systemExtra: String?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var systemParts: [String] = []
        for message in messages {
            if case .system(let text) = message {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { systemParts.append(trimmed) }
            }
        }
        if let systemExtra {
            let trimmed = systemExtra.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { systemParts.append(trimmed) }
        }
        if !systemParts.isEmpty {
            result.append(["role": "system", "content": systemParts.joined(separator: "\n\n")])
        }

        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result.append(["role": "user", "content": text])
            case .assistant(let assistant):
                let text = assistant.text
                var toolCalls: [[String: Any]] = []
                for part in assistant.content {
                    guard case .toolCall(let call) = part else { continue }
                    toolCalls.append(["id": call.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : call.id,
                                      "type": "function",
                                      "function": ["name": call.name,
                                                   "arguments": PiJSON.encodeString(call.arguments)]])
                }
                if text.isEmpty && toolCalls.isEmpty { continue }
                var dict: [String: Any] = ["role": "assistant"]
                dict["content"] = text.isEmpty ? NSNull() : text
                if !toolCalls.isEmpty { dict["tool_calls"] = toolCalls }
                result.append(dict)
            case .toolResult(let toolResult):
                var content = toolResult.content
                if content.isEmpty { content = "(no tool output)" }
                result.append(["role": "tool",
                               "tool_call_id": toolResult.toolCallId,
                               "content": content])
                if !toolResult.images.isEmpty {
                    let images: [[String: Any]] = toolResult.images.map {
                        ["type": "image_url", "image_url": ["url": "data:\($0.mimeType);base64,\($0.base64)"]]
                    }
                    result.append(["role": "user", "content": images])
                }
            }
        }
        return result
    }

    // MARK: - 流解析

    private struct ToolCallAccumulator {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private static func parseStream(bytes: URLSession.AsyncBytes,
                                    continuation: AsyncThrowingStream<PiStreamEvent, Error>.Continuation) async throws {
        var tools: [Int: ToolCallAccumulator] = [:]
        var finishReason: PiStopReason?
        var usage = PiUsage()

        // Chat Completions 的 SSE 没有 event: 行，每个 data: 行就是一条完整 JSON。
        // 这里按行直接解析，不依赖空行分帧（代理经常不保证空行）。
        outer: for try await rawLine in bytes.lines {
            if Task.isCancelled { throw PiProviderError.cancelled }
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard line.hasPrefix("data:") else { continue }
            var payload = String(line.dropFirst("data:".count))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" { break outer }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? payload
                throw PiProviderError.streamError(message)
            }
            if let usageObject = object["usage"] as? [String: Any] {
                mergeUsage(usageObject, into: &usage)
            }
            guard let choices = object["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let delta = choice["delta"] as? [String: Any] {
                if let reasoning = firstString(in: delta, keys: ["reasoning_content", "reasoning", "reasoning_text"]),
                   !reasoning.isEmpty {
                    continuation.yield(.thinkingDelta(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    for callObject in calls {
                        let index = PiJSON.int(callObject["index"]) ?? 0
                        let function = callObject["function"] as? [String: Any]
                        var accumulator = tools[index] ?? ToolCallAccumulator()
                        let startedWithoutName = accumulator.name.isEmpty
                        if let id = callObject["id"] as? String, !id.isEmpty { accumulator.id = id }
                        if let name = function?["name"] as? String { accumulator.name += name }
                        if let arguments = function?["arguments"] as? String, !arguments.isEmpty {
                            accumulator.arguments += arguments
                            continuation.yield(.toolCallArgumentsDelta(index: index, delta: arguments))
                        }
                        tools[index] = accumulator
                        if startedWithoutName && !accumulator.name.isEmpty {
                            continuation.yield(.toolCallStart(index: index,
                                                             id: accumulator.id,
                                                             name: accumulator.name))
                        }
                    }
                }
            }
            if let rawFinish = choice["finish_reason"] as? String, !rawFinish.isEmpty {
                finishReason = mapFinishReason(rawFinish)
            }
        }

        for (index, accumulator) in tools.sorted(by: { $0.key < $1.key }) where !accumulator.name.isEmpty {
            let parsed = PiJSON.parseObject(accumulator.arguments)
            let id = accumulator.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : accumulator.id
            continuation.yield(.toolCallEnd(index: index,
                                            call: PiToolCall(id: id,
                                                             name: accumulator.name,
                                                             arguments: parsed.arguments,
                                                             argumentsError: parsed.error)))
        }
        if usage.totalTokens > 0 {
            continuation.yield(.usage(usage))
        }
        let reason = finishReason ?? (tools.isEmpty ? .stop : .toolUse)
        continuation.yield(.stop(reason, raw: nil))
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func mergeUsage(_ object: [String: Any], into usage: inout PiUsage) {
        let promptTokens = PiJSON.int(object["prompt_tokens"]) ?? 0
        let promptDetails = object["prompt_tokens_details"] as? [String: Any]
        let cached = promptDetails.flatMap { PiJSON.int($0["cached_tokens"]) }
            ?? PiJSON.int(object["prompt_cache_hit_tokens"])
            ?? 0
        let written = promptDetails.flatMap { PiJSON.int($0["cache_write_tokens"]) } ?? 0
        // OpenAI 把缓存读写都算在 prompt_tokens 里；归一化成 pi 的 input/cacheRead/cacheWrite。
        usage.input = max(0, promptTokens - cached - written)
        usage.cacheRead = cached
        usage.cacheWrite = written
        if let value = PiJSON.int(object["completion_tokens"]) { usage.output = value }
        if let details = object["completion_tokens_details"] as? [String: Any],
           let reasoning = PiJSON.int(details["reasoning_tokens"]) {
            usage.reasoning = reasoning
        }
    }

    private static func mapFinishReason(_ raw: String) -> PiStopReason {
        switch raw {
        case "stop", "end", "eos": return .stop
        case "length", "max_tokens": return .length
        case "tool_calls", "function_call": return .toolUse
        default: return .error
        }
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
        case 401, 403: return .unauthorized(message)
        case 400, 404, 422: return .invalidRequest(message.isEmpty ? "HTTP \(status)" : message)
        case 408, 409, 429: return .rateLimited(retryAfter: retryAfter)
        default: return .server(status: status, message: message.isEmpty ? "HTTP \(status)" : message)
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
}

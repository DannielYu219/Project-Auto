//
//  OpenAIResponsesClient.swift
//  Project-Auto
//
//  OpenAI Responses API（/v1/responses）流式 + 工具调用适配器。
//  语义对齐 pi-ai 的 openai-responses：
//  - tools 是扁平结构（没有 function 包装层）
//  - 工具结果用 function_call_output（call_id 关联）
//  - 流事件以 response.* 为主，工具参数走 function_call_arguments.delta/done
//  - 没有终止事件要报错；有未收尾的工具调用要报错
//

import Foundation

nonisolated final class OpenAIResponsesClient: PiProvider, @unchecked Sendable {
    nonisolated let providerName = "OpenAI Responses"

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let lock = NSLock()
    private var currentTask: Task<Void, Never>?

    init(baseURL: URL = URL(string: "https://api.openai.com/v1")!,
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
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.timeoutInterval = 0

        var body: [String: Any] = [
            "model": request.model,
            "input": convertInput(request.messages, systemExtra: request.systemExtra),
            "stream": true,
            "store": false,
            // OpenAI Responses 要求 max_output_tokens >= 16
            "max_output_tokens": max(16, request.maxTokens)
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                ["type": "function",
                 "name": tool.name,
                 "description": tool.description,
                 "parameters": PiJSON.anyValue(tool.parameters)]
            }
            switch request.toolChoice {
            case .auto: body["tool_choice"] = "auto"
            case .none: body["tool_choice"] = "none"
            case .required: body["tool_choice"] = "required"
            case .tool(let name): body["tool_choice"] = ["type": "function", "name": name]
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
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func convertInput(_ messages: [PiMessage], systemExtra: String?) -> [[String: Any]] {
        var items: [[String: Any]] = []
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
            items.append(["type": "message",
                          "role": "system",
                          "content": [["type": "input_text",
                                       "text": systemParts.joined(separator: "\n\n")]]])
        }

        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                items.append(["type": "message",
                              "role": "user",
                              "content": [["type": "input_text", "text": text]]])
            case .assistant(let assistant):
                let text = assistant.text
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(["type": "message",
                                  "role": "assistant",
                                  "content": [["type": "output_text",
                                               "text": text,
                                               "annotations": []]]])
                }
                for part in assistant.content {
                    guard case .toolCall(let call) = part else { continue }
                    items.append(["type": "function_call",
                                  "call_id": call.id,
                                  "name": call.name,
                                  "arguments": PiJSON.encodeString(call.arguments)])
                }
            case .toolResult(let toolResult):
                var output = toolResult.content
                if output.isEmpty { output = "(no tool output)" }
                items.append(["type": "function_call_output",
                              "call_id": toolResult.toolCallId,
                              "output": output])
                if !toolResult.images.isEmpty {
                    let images: [[String: Any]] = toolResult.images.map {
                        ["type": "input_image", "image_url": "data:\($0.mimeType);base64,\($0.base64)"]
                    }
                    items.append(["type": "message", "role": "user", "content": images])
                }
            }
        }
        return items
    }

    // MARK: - 流解析

    private struct ToolSlot {
        var callID = ""
        var name = ""
        var arguments = ""
        var closed = false
        var index = 0
    }

    private static func parseStream(bytes: URLSession.AsyncBytes,
                                    continuation: AsyncThrowingStream<PiStreamEvent, Error>.Continuation) async throws {
        var slots: [Int: ToolSlot] = [:]
        var sawTerminal = false
        var status: String?
        var incompleteReason: String?
        var usage = PiUsage()
        var stopReason: PiStopReason?

        for try await rawLine in bytes.lines {
            if Task.isCancelled { throw PiProviderError.cancelled }
            let trimmed = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard trimmed.hasPrefix("data:") else { continue }
            var payload = String(trimmed.dropFirst("data:".count))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = object["type"] as? String ?? ""

            switch type {
            case "response.created":
                break

            case "response.output_item.added":
                guard let item = object["item"] as? [String: Any],
                      (item["type"] as? String) == "function_call" else { break }
                let outputIndex = PiJSON.int(object["output_index"]) ?? 0
                var slot = slots[outputIndex] ?? ToolSlot()
                slot.index = outputIndex
                slot.callID = item["call_id"] as? String ?? item["id"] as? String ?? ""
                slot.name = item["name"] as? String ?? ""
                slots[outputIndex] = slot
                if !slot.name.isEmpty {
                    continuation.yield(.toolCallStart(index: outputIndex,
                                                     id: slot.callID,
                                                     name: slot.name))
                }

            case "response.output_text.delta":
                if let delta = object["delta"] as? String, !delta.isEmpty {
                    continuation.yield(.textDelta(delta))
                }

            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = object["delta"] as? String, !delta.isEmpty {
                    continuation.yield(.thinkingDelta(delta))
                }

            case "response.function_call_arguments.delta":
                let outputIndex = PiJSON.int(object["output_index"]) ?? 0
                guard var slot = slots[outputIndex] else { break }
                if let delta = object["delta"] as? String, !delta.isEmpty {
                    slot.arguments += delta
                    slots[outputIndex] = slot
                    continuation.yield(.toolCallArgumentsDelta(index: outputIndex, delta: delta))
                }

            case "response.function_call_arguments.done":
                let outputIndex = PiJSON.int(object["output_index"]) ?? 0
                guard var slot = slots[outputIndex] else { break }
                if let arguments = object["arguments"] as? String {
                    slot.arguments = arguments
                    slots[outputIndex] = slot
                }

            case "response.output_item.done":
                guard let item = object["item"] as? [String: Any],
                      (item["type"] as? String) == "function_call" else { break }
                let outputIndex = PiJSON.int(object["output_index"]) ?? 0
                var slot = slots[outputIndex] ?? ToolSlot()
                slot.index = outputIndex
                slot.callID = item["call_id"] as? String ?? slot.callID
                slot.name = item["name"] as? String ?? slot.name
                if let arguments = item["arguments"] as? String { slot.arguments = arguments }
                slots[outputIndex] = slot
                if !slot.closed, !slot.name.isEmpty {
                    slot.closed = true
                    slots[outputIndex] = slot
                    continuation.yield(.toolCallEnd(index: outputIndex, call: makeToolCall(slot)))
                }

            case "response.completed", "response.incomplete", "response.failed", "response.cancelled":
                let response = object["response"] as? [String: Any]
                status = response?["status"] as? String ?? type.replacingOccurrences(of: "response.", with: "")
                if let details = response?["incomplete_details"] as? [String: Any] {
                    incompleteReason = details["reason"] as? String
                }
                if let usageObject = response?["usage"] as? [String: Any] {
                    mergeUsage(usageObject, into: &usage)
                }
                if type == "response.failed" {
                    let error = (response?["error"] as? [String: Any])?["message"] as? String
                    throw PiProviderError.streamError(error ?? "response.failed")
                }
                sawTerminal = true
                stopReason = mapStatus(status, incompleteReason: incompleteReason, hasToolCalls: !slots.isEmpty)

            case "error":
                let error = object["error"] as? [String: Any]
                let message = error?["message"] as? String ?? object["message"] as? String ?? "流式错误"
                throw PiProviderError.streamError(message)

            default:
                break
            }
            if sawTerminal { break }
        }

        guard sawTerminal else {
            throw PiProviderError.invalidResponse("流在 response.completed 之前结束")
        }

        // 没有 output_item.done 的槽位：用累积参数收尾
        for (index, slot) in slots.sorted(by: { $0.key < $1.key }) where !slot.closed && !slot.name.isEmpty {
            continuation.yield(.toolCallEnd(index: index, call: makeToolCall(slot)))
        }
        let hasToolCalls = slots.contains { !$0.value.name.isEmpty }
        if let reason = stopReason {
            let finalReason = (hasToolCalls && reason == .stop) ? .toolUse : reason
            continuation.yield(.usage(usage))
            continuation.yield(.stop(finalReason, raw: status))
        } else {
            throw PiProviderError.invalidResponse("缺少 response 状态")
        }
    }

    private static func makeToolCall(_ slot: ToolSlot) -> PiToolCall {
        let parsed = PiJSON.parseObject(slot.arguments)
        let id = slot.callID.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : slot.callID
        return PiToolCall(id: id, name: slot.name,
                          arguments: parsed.arguments, argumentsError: parsed.error)
    }

    private static func mergeUsage(_ object: [String: Any], into usage: inout PiUsage) {
        let inputTokens = PiJSON.int(object["input_tokens"]) ?? 0
        let inputDetails = object["input_tokens_details"] as? [String: Any]
        let cached = inputDetails.flatMap { PiJSON.int($0["cached_tokens"]) } ?? 0
        let written = inputDetails.flatMap { PiJSON.int($0["cache_write_tokens"]) } ?? 0
        // OpenAI 把缓存读写都算在 input_tokens 里；归一化成 pi 的 input/cacheRead/cacheWrite。
        usage.input = max(0, inputTokens - cached - written)
        usage.cacheRead = cached
        usage.cacheWrite = written
        if let value = PiJSON.int(object["output_tokens"]) { usage.output = value }
        if let details = object["output_tokens_details"] as? [String: Any],
           let reasoning = PiJSON.int(details["reasoning_tokens"]) {
            usage.reasoning = reasoning
        }
    }

    private static func mapStatus(_ status: String?, incompleteReason: String?, hasToolCalls: Bool) -> PiStopReason {
        switch status {
        case "completed":
            return hasToolCalls ? .toolUse : .stop
        case "incomplete":
            return incompleteReason == "max_output_tokens" ? .length : .error
        case "failed", "cancelled":
            return .error
        default:
            return .stop
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

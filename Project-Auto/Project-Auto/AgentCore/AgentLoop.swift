//
//  AgentLoop.swift
//  Project-Auto
//
//  工具调用循环：对齐 pi-agent-core 的单步状态机，但补上产品必需的护栏：
//  - maxTurns（pi 没有轮数上限）
//  - 单工具超时（pi 只传 signal）
//  - 审批闸门（pi 的 beforeToolCall 位置）
//  - 发请求前修复孤儿 tool_use（pi 在 provider 层做，这里显式做）
//  - length 截断时不执行工具，回填错误让模型重发
//

import Foundation

nonisolated final class AgentLoop: @unchecked Sendable {
    struct Configuration: Sendable {
        var model: String
        var systemPrompt: String
        var maxTurns = 12
        var maxTokens = 4096
        var toolTimeout: TimeInterval = 120
        var temperature: Double? = nil
        /// 用会话 id 保持跨轮稳定；换会话才换 key。
        var cacheKey: String? = nil
        var cacheRetention: PiCacheRetention = .short
    }

    enum Event: Sendable {
        case turnStarted(Int)
        case textDelta(String)
        case thinkingDelta(String)
        case toolCall(PiToolCall)
        case toolResult(PiToolResult)
        case assistantFinished(PiAssistantMessage)
        case usage(PiUsage)
        case failed(String)
    }

    private struct ToolTimeout: Error {}

    private let provider: PiProvider
    private let tools: [any AgentTool]
    private let gate: any ApprovalGate
    private let configuration: Configuration

    init(provider: PiProvider,
         tools: [any AgentTool],
         gate: any ApprovalGate,
         configuration: Configuration) {
        self.provider = provider
        self.tools = tools
        self.gate = gate
        self.configuration = configuration
    }

    func run(prompt: String, history: [PiMessage] = []) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.loop(prompt: prompt, history: history, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed("已取消"))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                self.provider.cancel()
            }
        }
    }

    // MARK: - 主循环

    private func loop(prompt: String,
                      history: [PiMessage],
                      continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        // 缓存友好的请求形状：system + tools + history 是稳定前缀，只追加。
        // 任何随请求变化的上下文（时间、运行状态）都必须放在最后一条 user 消息里，
        // 不能写进 system，否则每一轮都会改写前缀。
        var messages: [PiMessage] = [.system(configuration.systemPrompt)] + history
        messages.append(.user(prompt))
        // 工具声明按名字排序：前缀里的 tools 顺序必须字节稳定，
        // 否则不同注册顺序会让缓存从 tools 段开始整段失效（DSH 同做法）。
        let specs = tools.map(\.spec).sorted { $0.name < $1.name }

        for turn in 1...max(1, configuration.maxTurns) {
            try Task.checkCancellation()
            continuation.yield(.turnStarted(turn))

            let request = PiRequest(model: configuration.model,
                                    messages: repairToolPairing(messages),
                                    tools: specs,
                                    toolChoice: .auto,
                                    maxTokens: configuration.maxTokens,
                                    temperature: configuration.temperature,
                                    cacheRetention: configuration.cacheRetention,
                                    promptCacheKey: configuration.cacheKey)
            let assistant = try await streamAssistant(request, continuation: continuation)
            messages.append(.assistant(assistant))
            continuation.yield(.assistantFinished(assistant))
            continuation.yield(.usage(assistant.usage))

            if assistant.stopReason == .error || assistant.stopReason == .aborted {
                continuation.yield(.failed(assistant.errorMessage ?? "模型返回错误"))
                return
            }

            let calls = assistant.toolCalls
            guard !calls.isEmpty else { return }

            if assistant.stopReason == .length {
                // 参数可能被截断：一律不执行，回填错误让模型重发。
                for call in calls {
                    let result = PiToolResult(toolCallId: call.id,
                                              toolName: call.name,
                                              content: "上一条回复被长度截断，工具参数可能不完整，请重新发送。",
                                              isError: true)
                    messages.append(.toolResult(result))
                    continuation.yield(.toolResult(result))
                }
                continue
            }

            for call in calls {
                try Task.checkCancellation()
                continuation.yield(.toolCall(call))
                let result = await execute(call)
                messages.append(.toolResult(result))
                continuation.yield(.toolResult(result))
            }
        }

        continuation.yield(.failed("达到最大轮数 \(configuration.maxTurns)，已停止。"))
    }

    // MARK: - 单次流式

    private func streamAssistant(_ request: PiRequest,
                                 continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws -> PiAssistantMessage {
        var text = ""
        var thinking = ""
        var calls: [Int: PiToolCall] = [:]
        var order: [Int] = []
        var usage = PiUsage()
        var stop: PiStopReason = .pending
        var rawStop: String?

        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                text += delta
                continuation.yield(.textDelta(delta))
            case .thinkingDelta(let delta):
                thinking += delta
                continuation.yield(.thinkingDelta(delta))
            case .toolCallStart:
                break
            case .toolCallArgumentsDelta:
                break
            case .toolCallEnd(let index, let call):
                calls[index] = call
                if !order.contains(index) { order.append(index) }
            case .usage(let value):
                usage = value
            case .stop(let reason, let raw):
                stop = reason
                rawStop = raw
            }
        }

        guard stop != .pending else {
            throw PiProviderError.invalidResponse("流没有 stop 事件")
        }

        var content: [PiContentPart] = []
        if !thinking.isEmpty { content.append(.thinking(thinking, signature: nil)) }
        if !text.isEmpty { content.append(.text(text)) }
        for index in order.sorted() {
            if let call = calls[index] { content.append(.toolCall(call)) }
        }
        var message = PiAssistantMessage(content: content,
                                         model: request.model,
                                         usage: usage,
                                         stopReason: stop)
        if stop == .error {
            message.errorMessage = "模型返回错误（raw: \(rawStop ?? "unknown")）"
        }
        return message
    }

    // MARK: - 工具执行

    private func execute(_ call: PiToolCall) async -> PiToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return PiToolResult(toolCallId: call.id,
                                toolName: call.name,
                                content: "Tool \(call.name) not found",
                                isError: true)
        }
        if let argumentsError = call.argumentsError {
            return PiToolResult(toolCallId: call.id,
                                toolName: call.name,
                                content: "工具参数无效：\(argumentsError)",
                                isError: true)
        }

        let decision = await gate.decide(toolName: tool.name,
                                         risk: tool.risk,
                                         arguments: call.arguments)
        if case .deny(let reason) = decision {
            return PiToolResult(toolCallId: call.id,
                                toolName: call.name,
                                content: "操作被拒绝：\(reason)",
                                isError: true)
        }

        do {
            let result = try await runWithTimeout(seconds: configuration.toolTimeout) {
                try await tool.execute(call.arguments)
            }
            return PiToolResult(toolCallId: call.id,
                                toolName: call.name,
                                content: result.content,
                                isError: result.isError,
                                images: result.images)
        } catch is ToolTimeout {
            return PiToolResult(toolCallId: call.id,
                                toolName: call.name,
                                content: "工具执行超时（\(Int(configuration.toolTimeout)) 秒）",
                                isError: true)
        } catch {
            return PiToolResult(toolCallId: call.id,
                                toolName: call.name,
                                content: "工具执行失败：\(error.localizedDescription)",
                                isError: true)
        }
    }

    private func runWithTimeout<T: Sendable>(seconds: TimeInterval,
                                             _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw ToolTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ToolTimeout() }
            return first
        }
    }

    // MARK: - 孤儿 tool_use 修复（发请求前）

    private func repairToolPairing(_ messages: [PiMessage]) -> [PiMessage] {
        var result: [PiMessage] = []
        var pendingCalls: [PiToolCall] = []
        var answered = Set<String>()

        func closePending() {
            for call in pendingCalls where !answered.contains(call.id) {
                result.append(.toolResult(PiToolResult(toolCallId: call.id,
                                                       toolName: call.name,
                                                       content: "No result provided",
                                                       isError: true)))
            }
            pendingCalls = []
            answered = []
        }

        for message in messages {
            switch message {
            case .assistant(let assistant):
                closePending()
                if assistant.stopReason == .error || assistant.stopReason == .aborted { continue }
                pendingCalls = assistant.toolCalls
                result.append(message)
            case .toolResult(let toolResult):
                answered.insert(toolResult.toolCallId)
                result.append(message)
            case .system, .user:
                closePending()
                result.append(message)
            }
        }
        closePending()
        return result
    }
}

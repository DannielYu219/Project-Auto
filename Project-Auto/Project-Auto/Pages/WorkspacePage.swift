//
//  WorkspacePage.swift
//  Project-Auto
//
//  Agent 工作区：真实的会话消息、流式返回、失败原因与会话状态。
//  当前不执行工具：不跑命令、不读文件、不操作其它应用。
//

import SwiftUI

struct WorkspacePage: View {
    @ObservedObject var chat: AgentChatModel
    @ObservedObject var approvals: ApprovalCenter
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 0) {
            if chat.isHistoryVisible {
                SessionHistoryRail(chat: chat)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = chat.errorMessage {
                        errorBanner(error)
                    }
                    if chat.messages.isEmpty && chat.phase == .idle && approvals.pending == nil {
                        emptyState
                    } else {
                        ForEach(displayItems) { item in
                            chatItem(item)
                        }
                    }
                    if chat.approvalCenter.pending != nil
                        || chat.phase == .waiting
                        || chat.phase == .thinking
                        || chat.phase == .streaming
                        || chat.phase == .failed {
                        RunStatusView(chat: chat)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .onChange(of: chat.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.phase) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.thinkingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.currentTool?.output) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            }
        }
        if let pending = approvals.pending {
            approvalCard(pending)
                .padding(.horizontal, 28)
                .padding(.bottom, 10)
        }
        }
        .animation(.snappy(duration: 0.22), value: chat.isHistoryVisible)
        .task {
            await chat.loadIfNeeded()
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane").foregroundStyle(VelumPalette.blue)
                Text("Agent").fontWeight(.semibold)
                Text("· \(chat.providerLabel)").foregroundStyle(VelumPalette.muted)
            }.font(.system(size: 12))
            Text(chat.isConfigured ? "已接入 \(chat.providerLabel)。" : "还没有配置 Provider。")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(VelumPalette.ink)
            Text(chat.isConfigured
                 ? "可以在 Debian 13 沙盒里执行命令，工作区在 /workspace；命令和写操作会先请求你的批准。"
                 : "到设置里填写 Endpoint、模型与 API Key 后即可开始对话。")
                .font(.system(size: 13))
                .foregroundStyle(VelumPalette.muted)
                .lineSpacing(3)
            HStack(spacing: 10) {
                if !chat.isConfigured {
                    Button("打开设置") { onOpenSettings() }
                        .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                }
                Button("新建会话") { Task { await chat.newConversation() } }
                    .buttonStyle(VelumCapsuleButtonStyle())
            }
            if chat.isConfigured {
                Text("会话内容保存在本机 Documents/agent-sessions。")
                    .font(.system(size: 10))
                    .foregroundStyle(VelumPalette.muted)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, 24)
    }

    // MARK: - 消息分组

    private enum ChatDisplay: Identifiable {
        case user(VelumChatMessage)
        case process(id: String, messages: [VelumChatMessage], running: Bool)
        case assistant(VelumChatMessage)

        var id: String {
            switch self {
            case .user(let message), .assistant(let message): return message.id.uuidString
            case .process(let id, _, _): return "process-" + id
            }
        }
    }

    private var displayItems: [ChatDisplay] {
        var items: [ChatDisplay] = []
        var index = 0
        while index < chat.messages.count {
            let message = chat.messages[index]
            if case .user = message.kind {
                items.append(.user(message))
                index += 1
                continue
            }
            var run: [VelumChatMessage] = []
            while index < chat.messages.count {
                if case .user = chat.messages[index].kind { break }
                run.append(chat.messages[index])
                index += 1
            }
            guard !run.isEmpty else { continue }
            let last = run.count - 1
            let lastIsFinalAssistant: Bool = {
                guard case .assistant = run[last].kind else { return false }
                return !run[last].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || run[last].isStreaming
            }()
            if lastIsFinalAssistant {
                let process = Array(run[..<last])
                if !process.isEmpty {
                    items.append(.process(id: process[0].id.uuidString,
                                          messages: process,
                                          running: process.contains(where: \.isStreaming)))
                }
                items.append(.assistant(run[last]))
            } else {
                items.append(.process(id: run[0].id.uuidString,
                                      messages: run,
                                      running: run.contains(where: \.isStreaming)))
            }
        }
        return items
    }

    @ViewBuilder
    private func chatItem(_ item: ChatDisplay) -> some View {
        switch item {
        case .user(let message), .assistant(let message):
            messageView(message)
        case .process(_, let messages, let running):
            AgentProcessGroup(messages: messages, running: running,
                              liveThinking: running ? chat.thinkingText : "")
        }
    }

    // MARK: - 消息

    @ViewBuilder
    private func messageView(_ message: VelumChatMessage) -> some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                CopyableMessage(text: message.content) {
                    VelumMessage(text: message.content)
                }
            }
        case .assistant:
            CopyableMessage(text: message.content) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane").foregroundStyle(VelumPalette.blue)
                    Text("Agent").fontWeight(.semibold)
                    Text("· \(chat.providerLabel)").foregroundStyle(VelumPalette.muted)
                }.font(.system(size: 12))
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在生成…")
                            .font(.system(size: 12))
                            .foregroundStyle(VelumPalette.muted)
                    }
                } else if !message.content.isEmpty {
                    MarkdownMessage(text: message.content)
                }
                if let error = message.errorText {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(VelumPalette.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .toolCall(_, let name, let arguments):
            ToolActivityRow(name: name, arguments: arguments, message: message)
        }
    }

    private func approvalCard(_ request: ApprovalCenter.Request) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(VelumPalette.blue)
                Text("Agent 请求\(request.riskLabel)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(request.toolName)
                    .font(.system(size: 10))
                    .foregroundStyle(VelumPalette.muted)
            }
            Text(request.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VelumPalette.muted)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("允许") { approvals.resolve(true) }
                    .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                Button("拒绝") { approvals.resolve(false) }
                    .buttonStyle(VelumCapsuleButtonStyle())
                Button("本次会话总是允许") { approvals.allowAlways() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(VelumPalette.muted)
            }
        }
        .padding(14)
        .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(VelumPalette.danger)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(VelumPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - 运行状态

private struct RunStatusView: View {
    @ObservedObject var chat: AgentChatModel
    @State private var expanded = false

    private var title: String {
        if chat.approvalCenter.pending != nil { return "等待你的批准…" }
        switch chat.phase {
        case .waiting: return "正在等待响应…"
        case .thinking: return "正在思考…"
        case .streaming: return "正在生成…"
        case .toolRunning: return "正在执行 \(chat.currentTool?.name ?? "命令")…"
        case .toolDone: return "\(chat.currentTool?.name ?? "命令") 已完成"
        case .failed: return "执行失败"
        case .idle: return ""
        }
    }

    private var tint: Color {
        switch chat.phase {
        case .failed: return VelumPalette.danger
        case .toolDone: return VelumPalette.blue
        default: return VelumPalette.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                    if let start = chat.statusStartedAt, chat.phase != .toolDone {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(VelumPalette.muted)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(VelumPalette.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .velumSurface(.soft, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                detail
                    .padding(12)
                    .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch chat.phase {
        case .waiting, .thinking, .toolRunning, .streaming:
            ProgressView().controlSize(.small)
        case .toolDone:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(VelumPalette.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VelumPalette.danger)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch chat.phase {
            case .waiting:
                Text("已发送给 \(chat.providerLabel)（\(chat.protocolLabel)），等待模型返回第一个事件。")
                    .font(.system(size: 11))
                    .foregroundStyle(VelumPalette.muted)
            case .thinking:
                if chat.thinkingText.isEmpty {
                    Text("模型还没有返回可显示的思考内容；这里不会伪造推理过程。")
                        .font(.system(size: 11))
                        .foregroundStyle(VelumPalette.muted)
                } else {
                    Text(chat.thinkingText)
                        .font(.system(size: 11))
                        .foregroundStyle(VelumPalette.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .streaming:
                Text("正在接收模型输出…")
                    .font(.system(size: 11))
                    .foregroundStyle(VelumPalette.muted)
            case .toolRunning:
                commandBlock(chat.currentTool?.arguments ?? "{}")
                Text("命令结束后会显示完整输出。")
                    .font(.system(size: 10))
                    .foregroundStyle(VelumPalette.muted)
            case .toolDone:
                commandBlock(chat.currentTool?.arguments ?? "{}")
                if let output = chat.currentTool?.output, !output.isEmpty {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(chat.currentTool?.isError == true ? VelumPalette.danger : VelumPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("（无输出）")
                        .font(.system(size: 11))
                        .foregroundStyle(VelumPalette.muted)
                }
            case .failed:
                Text(chat.errorMessage ?? "未知错误")
                    .font(.system(size: 11))
                    .foregroundStyle(VelumPalette.danger)
                    .textSelection(.enabled)
            case .idle:
                EmptyView()
            }
        }
    }

    private func commandBlock(_ json: String) -> some View {
        Text(Self.command(from: json))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(VelumPalette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VelumPalette.ink.opacity(0.04))
            )
    }

    private static func command(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            return json
        }
        return command
    }
}

// MARK: - 工具执行行

private struct ToolActivityRow: View {
    let name: String
    let arguments: String
    let message: VelumChatMessage

    @State private var expanded: Bool

    init(name: String, arguments: String, message: VelumChatMessage) {
        self.name = name
        self.arguments = arguments
        self.message = message
        // 运行中默认展开，能直接看到流式输出；用户可以随时折叠。
        _expanded = State(initialValue: message.isStreaming)
    }

    private var running: Bool { message.isStreaming }
    private var isBrowserTool: Bool { name.hasPrefix("browser_") }
    private var failed: Bool { message.errorText != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? VelumPalette.danger : VelumPalette.blue)
                    }
                    Text(name).fontWeight(.medium)
                    Text(command)
                        .foregroundStyle(VelumPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(running ? "执行中" : failed ? "失败" : "完成")
                        .font(.system(size: 10))
                        .foregroundStyle(failed ? VelumPalette.danger : VelumPalette.muted)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(VelumPalette.muted)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .velumSurface(.soft, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isBrowserTool ? "参数" : "命令")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(VelumPalette.muted)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VelumPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Rectangle()
                        .fill(VelumPalette.ink.opacity(0.06))
                        .frame(height: 1)

                    HStack(spacing: 6) {
                        Text(isBrowserTool ? "结果" : "输出")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VelumPalette.muted)
                        if running { ProgressView().controlSize(.mini) }
                    }
                    if message.content.isEmpty {
                        Text(running ? (isBrowserTool ? "等待浏览器返回…" : "等待第一行输出…") : "（无输出）")
                            .font(.system(size: 11))
                            .foregroundStyle(VelumPalette.muted)
                    } else {
                        Text(message.content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(failed ? VelumPalette.danger : VelumPalette.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .onChange(of: message.isStreaming) { _, running in
            // 运行中展开看进度；结束后自动收起，保持列表整洁。
            if !running {
                withAnimation(.easeInOut(duration: 0.16)) { expanded = false }
            }
        }
    }

    private var command: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            return arguments
        }
        return command
    }
}


/// A whole Agent run's intermediate text and tool calls, collapsed as one block.
private struct AgentProcessGroup: View {
    let messages: [VelumChatMessage]
    let running: Bool
    let liveThinking: String
    @State private var expanded: Bool
    @State private var showThinking = false

    init(messages: [VelumChatMessage], running: Bool, liveThinking: String) {
        self.messages = messages
        self.running = running
        self.liveThinking = liveThinking
        _expanded = State(initialValue: running)
    }

    private var tools: [VelumChatMessage] {
        messages.filter { if case .toolCall = $0.kind { return true }; return false }
    }

    private var thinking: String {
        let stored = messages.compactMap(\.thinking).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let live = liveThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty { return live }
        if live.isEmpty { return stored }
        return stored + "\n\n" + live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(VelumPalette.blue)
                    }
                    Text("操作过程").font(.system(size: 11, weight: .medium))
                    Text("\(tools.count) 步")
                        .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                    if !thinking.isEmpty {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VelumPalette.muted)
                    }
                    Spacer(minLength: 8)
                    Text(running ? "执行中" : "完成")
                        .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(VelumPalette.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .velumSurface(.soft, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !thinking.isEmpty { thinkingView }
                    ForEach(messages) { message in
                        if case .toolCall(_, let name, let arguments) = message.kind {
                            toolRow(name: name, arguments: arguments, message: message)
                        } else if case .assistant = message.kind,
                                  !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownMessage(text: message.content)
                                .font(.system(size: 12))
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 12)
            }
        }
        .onChange(of: running) { _, value in
            if !value {
                withAnimation(.snappy(duration: 0.2)) { expanded = false; showThinking = false }
            }
        }
    }

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showThinking.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                    Text("思考过程").font(.system(size: 10, weight: .medium))
                    Image(systemName: showThinking ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(VelumPalette.muted)
            }
            .buttonStyle(.plain)
            if showThinking {
                Text(thinking)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VelumPalette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    private func toolRow(name: String, arguments: String, message: VelumChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: name.hasPrefix("browser_") ? "globe" : "terminal")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(VelumPalette.blue)
                Text(name).font(.system(size: 10, weight: .medium))
                Spacer()
                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                } else if message.errorText != nil {
                    Text("失败").font(.system(size: 9)).foregroundStyle(VelumPalette.danger)
                }
            }
            if !arguments.isEmpty && arguments != "{}" {
                Text(arguments)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(VelumPalette.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(message.errorText == nil ? VelumPalette.ink : VelumPalette.danger)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

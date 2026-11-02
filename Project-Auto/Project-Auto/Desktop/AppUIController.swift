//
//  AppUIController.swift
//  Project-Auto
//
//  把 App 内 UI 暴露给 Agent：窗口、可交互元素、只读信息。
//  Agent 通过 ui_snapshot / ui_click / ui_type / ui_open_app / ui_clipboard
//  读取并操作。所有方法都在主线程执行。
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let velumOpenPage = Notification.Name("VelumOpenPage")
    static let velumActivateWindow = Notification.Name("VelumActivateWindow")
    static let velumCloseWindow = Notification.Name("VelumCloseWindow")
    static let velumMinimizeWindow = Notification.Name("VelumMinimizeWindow")
    static let velumMaximizeWindow = Notification.Name("VelumMaximizeWindow")
}

nonisolated struct UICanvasWindow: Sendable {
    var id: UUID
    var page: String
    var frame: CGRect
    var active: Bool
    var minimized: Bool
    var fullscreen: Bool
    var maximized: Bool
}

@MainActor
final class AppUIController: ObservableObject {
    static let shared = AppUIController()

    private final class Registration {
        weak var chat: AgentChatModel?
        weak var model: VelumWindowModel?
        init(chat: AgentChatModel, model: VelumWindowModel) {
            self.chat = chat
            self.model = model
        }
    }

    private var windows: [UICanvasWindow] = []
    private var activeID: UUID?
    private var registrations: [UUID: Registration] = [:]

    private init() {}

    // MARK: - 状态注入

    func update(windows: [DesktopWindowItem], activeID: UUID?) {
        self.windows = windows.map {
            UICanvasWindow(id: $0.id,
                           page: $0.page,
                           frame: $0.frame,
                           active: $0.id == activeID,
                           minimized: $0.minimized,
                           fullscreen: $0.fullscreen,
                           maximized: $0.maximized)
        }
        self.activeID = activeID
        registrations = registrations.filter { id, _ in
            windows.contains(where: { $0.id == id })
        }
        for registration in registrations.values {
            if let chat = registration.chat { chat.refreshServerAttachment() }
        }
    }

    func register(windowID: UUID, chat: AgentChatModel, model: VelumWindowModel) {
        registrations[windowID] = Registration(chat: chat, model: model)
    }

    func unregister(windowID: UUID) {
        registrations.removeValue(forKey: windowID)
    }

    // MARK: - Snapshot

    func snapshotJSON() -> String {
        let appInteractive = VelumTab.allCases.map { tab -> [String: Any] in
            ["id": "app.open.\(tab.rawValue)", "role": "button", "label": "打开\(tab.rawValue)", "enabled": true]
        }
        let app: [String: Any] = [
            "name": "Velum",
            "active": NSApp?.isActive ?? false,
            "active_window_id": activeID?.uuidString ?? "",
            "window_count": windows.count,
            "interactive": appInteractive
        ]
        let windowJSON = windows.map(windowJSON(_:))
        let root: [String: Any] = ["app": app, "windows": windowJSON,
                                   "mounts": HostMountCenter.shared.snapshotJSON(),
                                   "browser": ["tab_count": BrowserController.shared.tabs.count,
                                               "selected_tab_id": BrowserController.shared.selectedTabID?.uuidString ?? "",
                                               "url": BrowserController.shared.selectedTab?.url ?? ""]]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"snapshot unavailable\"}"
        }
        return text
    }

    private func windowJSON(_ window: UICanvasWindow) -> [String: Any] {
        let registration = registrations[window.id]
        let chat = registration?.chat
        let model = registration?.model

        var interactive: [[String: Any]] = []
        var readable: [[String: Any]] = []
        let prefix = "window.\(window.id.uuidString)"

        // 只读信息
        var status: [String: Any] = [
            "id": "\(prefix).status",
            "role": "status",
            "phase": phaseName(chat?.phase ?? .idle)
        ]
        if let chat {
            status["provider"] = chat.providerLabel
            status["protocol"] = chat.protocolLabel
            status["streaming"] = chat.isStreaming
            status["prompt_tokens"] = chat.promptTokens
            status["completion_tokens"] = chat.completionTokens
            status["cache_read_tokens"] = chat.cacheReadTokens
            if let tool = chat.currentTool {
                status["tool"] = [
                    "name": tool.name,
                    "command": command(from: tool.arguments),
                    "running": tool.finishedAt == nil,
                    "output": tool.output ?? ""
                ]
            }
        }
        readable.append(status)

        if let model {
            readable.append([
                "id": "\(prefix).page",
                "role": "page",
                "selected_tab": model.selectedTab.rawValue,
                "details_visible": model.detailsVisible,
                "search": model.searchText
            ])
        }

        if let chat {
            interactive.append([
                "id": "\(prefix).history-toggle",
                "role": "button",
                "label": "会话历史",
                "visible": chat.isHistoryVisible,
                "enabled": true
            ])
            let sessionItems = chat.sessions.map { session -> [String: Any] in
                [
                    "id": "\(prefix).session.\(session.id)",
                    "role": "session",
                    "label": session.title,
                    "selected": session.id == chat.currentSessionID,
                    "message_count": session.messageCount
                ]
            }
            readable.append([
                "id": "\(prefix).sessions",
                "role": "sessions",
                "items": sessionItems
            ])
            for session in chat.sessions {
                interactive.append([
                    "id": "\(prefix).session.\(session.id)",
                    "role": "session",
                    "label": session.title,
                    "selected": session.id == chat.currentSessionID,
                    "enabled": true
                ])
            }
            for (index, message) in chat.messages.enumerated() {
                switch message.kind {
                case .user:
                    readable.append([
                        "id": "\(prefix).message.\(index)",
                        "role": "user",
                        "text": message.content
                    ])
                case .assistant:
                    readable.append([
                        "id": "\(prefix).message.\(index)",
                        "role": "assistant",
                        "text": message.content,
                        "streaming": message.isStreaming
                    ])
                case .toolCall(_, let name, let arguments):
                    readable.append([
                        "id": "\(prefix).message.\(index)",
                        "role": "tool",
                        "name": name,
                        "command": command(from: arguments),
                        "state": message.isStreaming ? "running" : (message.errorText == nil ? "done" : "failed"),
                        "output": message.content,
                        "error": message.errorText ?? ""
                    ])
                }
            }
            if let error = chat.errorMessage, !error.isEmpty {
                readable.append(["id": "\(prefix).error", "role": "error", "text": error])
            }
            if model?.selectedTab == .settings {
                let config = AgentConfig.shared
                readable.append([
                    "id": "\(prefix).settings",
                    "role": "settings",
                    "provider": config.effectiveProviderKind.rawValue,
                    "model": config.effectiveModel,
                    "endpoint": config.effectiveEndpoint,
                    "api_key_present": !config.effectiveAPIKey.isEmpty,
                    "system_prompt": config.systemPrompt
                ])
            }
            if let pending = chat.approvalCenter.pending {
                readable.append([
                    "id": "\(prefix).approval",
                    "role": "approval",
                    "tool": pending.toolName,
                    "risk": pending.riskLabel,
                    "summary": pending.summary
                ])
                interactive.append(["id": "\(prefix).approval.allow", "role": "button", "label": "允许", "enabled": true])
                interactive.append(["id": "\(prefix).approval.deny", "role": "button", "label": "拒绝", "enabled": true])
                interactive.append(["id": "\(prefix).approval.always", "role": "button", "label": "本次会话总是允许", "enabled": true])
            }
        }

        // 可交互元素：标签页
        for tab in VelumTab.allCases {
            interactive.append([
                "id": "\(prefix).tab.\(tab.rawValue)",
                "role": "tab",
                "label": tab.rawValue,
                "selected": model?.selectedTab == tab,
                "enabled": true
            ])
        }

        // 输入框与发送/停止
        let draft = chat?.draft ?? ""
        interactive.append([
            "id": "\(prefix).composer",
            "role": "textfield",
            "label": "任务内容",
            "value": draft,
            "enabled": true
        ])
        if chat?.isStreaming == true {
            interactive.append(["id": "\(prefix).stop", "role": "button", "label": "停止生成", "enabled": true])
        } else {
            interactive.append([
                "id": "\(prefix).send",
                "role": "button",
                "label": "发送",
                "enabled": !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ])
        }
        interactive.append(["id": "\(prefix).new-conversation", "role": "button", "label": "新建会话", "enabled": true])
        interactive.append(["id": "\(prefix).close", "role": "button", "label": "关闭窗口", "enabled": true])
        interactive.append(["id": "\(prefix).minimize", "role": "button", "label": "最小化窗口", "enabled": true])
        interactive.append(["id": "\(prefix).maximize", "role": "button", "label": "缩放窗口", "enabled": true])

        // Only expose controls that actually exist in this app window.
        let workspaceActions = ["history-toggle", "composer", "send", "stop", "new-conversation", "approval.allow", "approval.deny", "approval.always"]
        interactive.removeAll { element in
            guard let id = element["id"] as? String else { return false }
            if id.hasPrefix("\(prefix).tab.") { return true }
            if model?.selectedTab != .workspace {
                return workspaceActions.contains { id == "\(prefix).\($0)" } || id.hasPrefix("\(prefix).session.")
            }
            return false
        }

        var json: [String: Any] = [
            "id": window.id.uuidString,
            "page": window.page,
            "title": window.page,
            "active": window.active,
            "minimized": window.minimized,
            "fullscreen": window.fullscreen,
            "maximized": window.maximized,
            "frame": [
                "x": Double(window.frame.origin.x),
                "y": Double(window.frame.origin.y),
                "width": Double(window.frame.width),
                "height": Double(window.frame.height)
            ],
            "interactive": interactive,
            "readable": readable
        ]
        json["root_element_id"] = prefix
        return json
    }

    // MARK: - 动作

    func click(_ elementID: String) -> String {
        if elementID.hasPrefix("app.open.") {
            let page = String(elementID.dropFirst("app.open.".count))
            return openApp(page)
        }
        guard let parsed = parseWindowElement(elementID) else {
            return "ERROR: 未知元素 \(elementID)"
        }
        let registration = registrations[parsed.id]
        let chat = registration?.chat
        let model = registration?.model

        switch parsed.action {
        case "send":
            guard let chat else { return "ERROR: 窗口没有会话" }
            guard !chat.isStreaming else { return "ERROR: 当前正在生成，先停止" }
            chat.send()
            return "OK: 已发送"
        case "stop":
            guard let chat else { return "ERROR: 窗口没有会话" }
            if chat.isStreaming {
                return "ERROR: 这会中断当前 Agent 会话，请让用户手动操作"
            }
            chat.stop()
            return "OK: 已停止"
        case "new-conversation":
            guard let chat else { return "ERROR: 窗口没有会话" }
            if chat.isStreaming {
                return "ERROR: 这会中断当前 Agent 会话，请让用户手动操作"
            }
            Task { await chat.newConversation() }
            return "OK: 已新建会话"
        case "history-toggle":
            chat?.isHistoryVisible.toggle()
            return "OK: 已切换会话历史"
        case "approval.allow":
            chat?.approvalCenter.resolve(true)
            return "OK: 已允许"
        case "approval.deny":
            chat?.approvalCenter.resolve(false)
            return "OK: 已拒绝"
        case "approval.always":
            chat?.approvalCenter.allowAlways()
            return "OK: 本次会话总是允许"
        case "close":
            NotificationCenter.default.post(name: .velumCloseWindow, object: nil, userInfo: ["id": parsed.id.uuidString])
            return "OK: 已请求关闭窗口"
        case "minimize":
            NotificationCenter.default.post(name: .velumMinimizeWindow, object: nil, userInfo: ["id": parsed.id.uuidString])
            return "OK: 已请求最小化"
        case "maximize":
            NotificationCenter.default.post(name: .velumMaximizeWindow, object: nil, userInfo: ["id": parsed.id.uuidString])
            return "OK: 已请求缩放窗口"
        default:
            if parsed.action.hasPrefix("session.") {
                let sessionID = String(parsed.action.dropFirst("session.".count))
                guard let chat else { return "ERROR: 窗口没有会话" }
                if chat.isStreaming { return "ERROR: 当前正在生成，请先停止" }
                Task { await chat.selectSession(sessionID) }
                return "OK: 已切换会话"
            }
            if parsed.action.hasPrefix("tab.") {
                let page = String(parsed.action.dropFirst("tab.".count))
                guard VelumTab(rawValue: page) != nil else {
                    return "ERROR: 未知应用 \(page)"
                }
                return openApp(page)
            }
            return "ERROR: 不支持的操作 \(parsed.action)"
        }
    }

    func type(_ elementID: String, text: String, submit: Bool) -> String {
        guard let parsed = parseWindowElement(elementID),
              let chat = registrations[parsed.id]?.chat else {
            return "ERROR: 找不到输入框 \(elementID)"
        }
        guard parsed.action == "composer" else {
            return "ERROR: \(elementID) 不是可输入元素"
        }
        chat.draft = text
        if submit {
            guard !chat.isStreaming else { return "ERROR: 当前正在生成，稍后再发送" }
            chat.send()
            return "OK: 已输入并发送"
        }
        return "OK: 已写入草稿"
    }

    func openApp(_ name: String) -> String {
        guard VelumTab(rawValue: name) != nil else {
            return "ERROR: 未知应用 \(name)，可用：\(VelumTab.allCases.map(\.rawValue).joined(separator: "、"))"
        }
        NotificationCenter.default.post(name: .velumOpenPage, object: nil, userInfo: ["page": name])
        return "OK: 已请求打开 \(name)"
    }

    func clipboard(action: String, text: String?, elementID: String?, submit: Bool) -> String {
        let pasteboard = NSPasteboard.general
        switch action {
        case "copy":
            guard let text else { return "ERROR: copy 需要 text" }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return "OK: 已复制 \(text.count) 个字符"
        case "paste":
            guard let string = pasteboard.string(forType: .string) else {
                return "ERROR: 剪贴板没有文本"
            }
            if let elementID {
                return type(elementID, text: string, submit: submit)
            }
            return string
        default:
            return "ERROR: action 只支持 copy / paste"
        }
    }

    // MARK: - Helpers

    private struct ParsedElement {
        var id: UUID
        var action: String
    }

    private func parseWindowElement(_ elementID: String) -> ParsedElement? {
        let parts = elementID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "window", let id = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        return ParsedElement(id: id, action: parts.dropFirst(2).joined(separator: "."))
    }

    private func phaseName(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .thinking: return "thinking"
        case .streaming: return "streaming"
        case .toolRunning: return "tool_running"
        case .toolDone: return "tool_done"
        case .failed: return "failed"
        }
    }

    private func command(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            return json
        }
        return command
    }
}

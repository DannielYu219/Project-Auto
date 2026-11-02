//
//  UITools.swift
//  Project-Auto
//
//  Agent 读取/操作 App 内 UI 的工具。元素 ID 来自 ui_snapshot 的 JSON。
//

import Foundation

nonisolated struct UISnapshotTool: AgentTool {
    let name = "ui_snapshot"
    let description = "读取当前 App 的完整 UI 状态 JSON：窗口、可交互元素（按钮/输入框/标签页/审批）、只读信息（消息、工具输出、状态）。执行操作前先调用它。"
    var risk: ToolRisk { .readOnly }
    var parameters: JSONValue {
        .object(["type": .string("object"), "properties": .object([:]), "required": .array([])])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        let json = await MainActor.run { AppUIController.shared.snapshotJSON() }
        return AgentToolResult(content: json, isError: false)
    }
}

nonisolated struct UIClickTool: AgentTool {
    let name = "ui_click"
    let description = "按 element_id 点击 App 内元素（发送、停止、标签页、审批、最小化/关闭窗口等）。element_id 必须来自 ui_snapshot。"
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "element_id": .object(["type": .string("string"), "description": .string("元素 ID，例如 window.<uuid>.send")])
            ]),
            "required": .array([.string("element_id")])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let id = arguments["element_id"]?.stringValue, !id.isEmpty else {
            throw HostToolError.invalidPath("缺少 element_id")
        }
        let result = await MainActor.run { AppUIController.shared.click(id) }
        return AgentToolResult(content: result, isError: result.hasPrefix("ERROR"))
    }
}

nonisolated struct UITypeTool: AgentTool {
    let name = "ui_type"
    let description = "把文本写进 App 内输入框（当前是 window.<uuid>.composer）。submit=true 时写完直接发送。"
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "element_id": .object(["type": .string("string"), "description": .string("输入框元素 ID")]),
                "text": .object(["type": .string("string"), "description": .string("要写入的文本")]),
                "submit": .object(["type": .string("boolean"), "description": .string("是否输入后立即发送")])
            ]),
            "required": .array([.string("element_id"), .string("text")])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let id = arguments["element_id"]?.stringValue, !id.isEmpty else {
            throw HostToolError.invalidPath("缺少 element_id")
        }
        let text = arguments["text"]?.stringValue ?? ""
        let submit = arguments["submit"]?.boolValue ?? false
        let result = await MainActor.run { AppUIController.shared.type(id, text: text, submit: submit) }
        return AgentToolResult(content: result, isError: result.hasPrefix("ERROR"))
    }
}

nonisolated struct UIOpenAppTool: AgentTool {
    let name = "ui_open_app"
    let description = "打开/激活 App 内的一个应用：工作区、文件、组件、设置、浏览器、供应商、ServerBox、本地 AI。"
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "app": .object(["type": .string("string"), "description": .string("应用名：工作区/文件/组件/设置/浏览器/供应商/ServerBox/本地 AI")])
            ]),
            "required": .array([.string("app")])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let app = arguments["app"]?.stringValue, !app.isEmpty else {
            throw HostToolError.invalidPath("缺少 app")
        }
        let result = await MainActor.run { AppUIController.shared.openApp(app) }
        return AgentToolResult(content: result, isError: result.hasPrefix("ERROR"))
    }
}

nonisolated struct UIClipboardTool: AgentTool {
    let name = "ui_clipboard"
    let description = "复制文本到系统剪贴板，或把剪贴板文本粘贴到输入框（可再发送）。"
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "description": .string("copy 或 paste")]),
                "text": .object(["type": .string("string"), "description": .string("copy 时的文本")]),
                "element_id": .object(["type": .string("string"), "description": .string("paste 目标输入框")]),
                "submit": .object(["type": .string("boolean"), "description": .string("paste 后是否发送")])
            ]),
            "required": .array([.string("action")])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        let action = arguments["action"]?.stringValue ?? ""
        let text = arguments["text"]?.stringValue
        let elementID = arguments["element_id"]?.stringValue
        let submit = arguments["submit"]?.boolValue ?? false
        let result = await MainActor.run {
            AppUIController.shared.clipboard(action: action, text: text, elementID: elementID, submit: submit)
        }
        return AgentToolResult(content: result, isError: result.hasPrefix("ERROR"))
    }
}

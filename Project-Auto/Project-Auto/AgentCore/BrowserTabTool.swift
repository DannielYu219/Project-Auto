import Foundation

/// Explicit tab management. Page actions remain in browser_action.
nonisolated struct BrowserTabTool: AgentTool {
    let name = "browser_tab"
    let description = "Manage embedded browser tabs. new creates an Agent-controlled hidden tab by default (activate=false) and can load a URL directly; pass its tab_id to browser_action/browser_state to control it without stealing the user's tab. activate:true shows it immediately; the user can also select it from the tab strip. select/close use tab_id; list reports controlled/background state."
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue { .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"), "enum": .array([
                "new", "select", "close", "list"
            ].map(JSONValue.string))]),
            "url": .object(["type": .string("string")]),
            "tab_id": .object(["type": .string("string")]),
            "activate": .object(["type": .string("boolean")])
        ]),
        "required": .array([.string("action")]),
        "additionalProperties": .bool(false)
    ]) }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let action = arguments["action"]?.stringValue else {
            throw HostToolError.invalidPath("action required")
        }
        return await MainActor.run {
            switch action {
            case "new":
                let id = BrowserController.shared.createAgentTab(
                    urlString: arguments["url"]?.stringValue,
                    activate: arguments["activate"]?.boolValue ?? false
                )
                let suffix = arguments["url"]?.stringValue.map { " url=\($0)" } ?? ""
                return AgentToolResult(content: "Created Agent tab \(id.uuidString)\(suffix)", isError: false)
            case "select":
                guard let raw = arguments["tab_id"]?.stringValue, let id = UUID(uuidString: raw),
                      BrowserController.shared.tabs.contains(where: { $0.id == id }) else {
                    return AgentToolResult(content: "Unknown tab_id", isError: true)
                }
                BrowserController.shared.selectTab(id)
                return AgentToolResult(content: "Selected tab \(id.uuidString)", isError: false)
            case "close":
                guard let raw = arguments["tab_id"]?.stringValue, let id = UUID(uuidString: raw) else {
                    return AgentToolResult(content: "tab_id required", isError: true)
                }
                BrowserController.shared.closeTab(id)
                return AgentToolResult(content: "Closed tab \(id.uuidString)", isError: false)
            case "list":
                let tabs = BrowserController.shared.tabs
                let selected = BrowserController.shared.selectedTabID?.uuidString ?? ""
                let text = tabs.map { tab in
                    "\(tab.id.uuidString)\t\(tab.id.uuidString == selected ? "selected" : "idle")\t\(tab.isAgentControlled ? "agent" : "user")\t\(tab.isBackground ? "background" : "visible")\t\(tab.url)\t\(tab.title)"
                }.joined(separator: "\n")
                return AgentToolResult(content: text.isEmpty ? "No tabs" : text, isError: false)
            default:
                return AgentToolResult(content: "Unknown action \(action)", isError: true)
            }
        }
    }
}

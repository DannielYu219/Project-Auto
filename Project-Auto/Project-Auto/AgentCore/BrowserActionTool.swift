import Foundation

/// Direct control is the default. Needle remains optional; both paths share the same executor.
nonisolated struct BrowserActionTool: AgentTool {
    let name = "browser_action"
    let description = "Directly control the embedded browser. Use browser_state(screenshot:true) to inspect the viewport, then issue one JSON action. Coordinates x/y are CSS pixels from the viewport top-left. scroll delta_x/delta_y default to zero if omitted. type inserts at the focused field; use key Control+a to select existing text first. Navigation is asynchronous; inspect state again before clicking. Does not require Needle."
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue { .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"), "enum": .array([
                "navigate", "click", "scroll", "type", "key", "back", "forward", "reload"
            ].map(JSONValue.string))]),
            "url": .object(["type": .string("string")]),
            "x": .object(["type": .string("number")]),
            "y": .object(["type": .string("number")]),
            "delta_x": .object(["type": .string("number")]),
            "delta_y": .object(["type": .string("number")]),
            "text": .object(["type": .string("string")]),
            "key": .object(["type": .string("string")])
        ]),
        "required": .array([.string("action")]),
        "additionalProperties": .bool(false)
    ]) }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        let json = PiJSON.encodeString(arguments)
        let result = await BrowserController.shared.execute(json)
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        return AgentToolResult(content: result, isError: object?["ok"] as? Bool != true)
    }
}

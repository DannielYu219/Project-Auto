import Foundation

nonisolated struct LinuxMountTool: AgentTool {
    let name = "linux_mount"
    let description = "List authorized Mac directory mounts, ask the user to choose a directory to mount into Linux, or unmount a prior grant. choose opens the real directory picker; arbitrary host paths cannot be mounted without user selection. Read-only by default. Mount changes require no shell commands to be running."
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue { .object([
        "type": .string("object"), "properties": .object([
            "action": .object(["type": .string("string"), "enum": .array([.string("list"), .string("choose"), .string("remove")])]),
            "mount_id": .object(["type": .string("string")]),
            "read_only": .object(["type": .string("boolean")])
        ]), "required": .array([.string("action")])
    ]) }
    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        switch arguments["action"]?.stringValue {
        case "list": return await AgentToolResult(content: HostMountCenter.shared.snapshotJSON(), isError: false)
        case "choose":
            if let mount = try await HostMountCenter.shared.chooseDirectory(readOnly: arguments["read_only"]?.boolValue ?? true) {
                return AgentToolResult(content: "Mounted at \(mount.guestPath) (\(mount.readOnly ? "ro" : "rw"))", isError: false)
            }
            return AgentToolResult(content: "User cancelled directory selection; nothing mounted.", isError: true)
        case "remove":
            guard let id = arguments["mount_id"]?.stringValue else { throw HostToolError.invalidPath("mount_id required") }
            try await HostMountCenter.shared.remove(id)
            return AgentToolResult(content: "Unmounted", isError: false)
        default: throw HostToolError.invalidPath("action must be list, choose or remove")
        }
    }
}

nonisolated struct BrowserStateTool: AgentTool {
    let name = "browser_state"
    let description = "Read embedded browser tab/URL/loading/viewport state, including agent-controlled background tabs, or capture a screenshot. Pass tab_id for an Agent tab. Screenshot is saved locally and returned as an image. Coordinates are viewport CSS pixels from top-left. Open the 浏览器 app first."
    var risk: ToolRisk { .readOnly }
    var parameters: JSONValue { .object(["type": .string("object"), "properties": .object([
        "screenshot": .object(["type": .string("boolean")]),
        "tab_id": .object(["type": .string("string")])
    ])]) }
    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        let tabID = arguments["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let state = await BrowserController.shared.snapshotJSON(tabID: tabID)
        if arguments["screenshot"]?.boolValue == true {
            let path = try await BrowserController.shared.captureScreenshot(tabID: tabID)
            return AgentToolResult(content: state + "\nScreenshot: \(path.path)", isError: false,
                                   images: [PiToolImage(base64: try Data(contentsOf: path).base64EncodedString())])
        }
        return AgentToolResult(content: state, isError: false)
    }
}

nonisolated struct BrowserCommandTool: AgentTool {
    let name = "browser_command"
    let description = "Control the embedded browser using one precise English instruction. The local Needle3 model translates English into validated browser JSON, then the browser executes it. Supported: navigate URL, click at x/y CSS pixels, scroll direction/pixels, type into focused field, press key, back/forward/reload. One action per instruction improves accuracy. Low-confidence/unsupported commands are refused. Use browser_state before/after."
    var risk: ToolRisk { .controlsUI }
    var parameters: JSONValue { .object(["type": .string("object"), "properties": .object([
        "instruction": .object(["type": .string("string")]),
        "tab_id": .object(["type": .string("string")])
    ]), "required": .array([.string("instruction")])]) }
    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let command = arguments["instruction"]?.stringValue else { throw HostToolError.invalidPath("instruction required") }
        let tabID = arguments["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let translator = try NeedleBrowserTranslator(configuration: .bundled())
        let translated = try await translator.translate(command)
        guard !translated.actions.isEmpty else {
            return AgentToolResult(content: "Needle withheld command; confidence=\(translated.confidence ?? 0). No action executed.", isError: true)
        }
        var results: [String] = []
        for action in translated.actions {
            let json = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
            let result = await BrowserController.shared.execute(json, tabID: tabID)
            results.append(result)
        }
        return AgentToolResult(content: "Needle: \(try translated.json)\nResults:\n" + results.joined(separator: "\n"), isError: results.contains { $0.contains("\"ok\":false") })
    }
}

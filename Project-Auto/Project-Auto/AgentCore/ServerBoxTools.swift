import Foundation

nonisolated struct ServerBoxTool: AgentTool {
    let hostID: UUID
    let hostName: String
    var onOutput: (@Sendable (String, Bool) -> Void)? = nil

    let name = "serverbox"
    let description = "Run one non-interactive SSH command on the remote host attached to this Agent task. This tool cannot choose another host. The host must have a selected key and explicitly trusted host fingerprint. Never request passwords or read identity files."
    var risk: ToolRisk { .executesProcess }
    var parameters: JSONValue { .object([
        "type": .string("object"),
        "properties": .object([
            "command": .object(["type": .string("string"), "description": .string("One non-interactive shell command for the attached host")]),
            "timeout": .object(["type": .string("integer")])
        ]),
        "required": .array([.string("command")]),
        "additionalProperties": .bool(false)
    ]) }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let command = arguments["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostToolError.invalidPath("command required")
        }
        guard let host = await MainActor.run(body: { ServerBoxStore.shared.host(hostID) }) else {
            throw HostToolError.notFound(hostID.uuidString)
        }
        let timeout = min(max(arguments["timeout"]?.intValue ?? 60, 1), 300)
        let result = try await SSHConnection.shared.exec(host: host, command: command,
                                                         timeout: TimeInterval(timeout), onOutput: onOutput)
        var output = "Host: \(hostName)\n" + result.stdout
        if !result.stderr.isEmpty { output += (output.isEmpty ? "" : "\n") + "[stderr]\n" + result.stderr }
        if result.timedOut { output += "\n[timeout]" }
        output += "\n[exit \(result.exitCode)]"
        if output.count > 20_000 { output = String(output.prefix(20_000) + "\n…(truncated)") }
        return AgentToolResult(content: output, isError: result.exitCode != 0 || result.timedOut)
    }
}

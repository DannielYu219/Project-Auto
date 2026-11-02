//
//  BashTool.swift
//  Project-Auto
//
//  Agent 的 Linux 执行工具：命令在 smolvm 沙盒里运行，工作区通过
//  /workspace 双向挂载。属于高风险工具，必须经过审批闸门。
//

import Foundation

nonisolated struct BashTool: AgentTool {
    let runtime: any LinuxExecuting
    var onOutput: (@Sendable (String, Bool) -> Void)? = nil

    let name = "bash"
    let description = "在 Linux 沙盒（Debian 13）里执行 shell 命令，工作区挂载在 /workspace。适合查看系统、运行构建/脚本、处理文件；不用于交互式命令。"

    var risk: ToolRisk { .executesProcess }

    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("要执行的 shell 命令（非交互）")
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("超时秒数，默认 60，最大 600")
                ])
            ]),
            "required": .array([.string("command")])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let command = arguments["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostToolError.invalidPath("缺少 command")
        }
        let timeout = min(max(arguments["timeout"]?.intValue ?? 60, 1), 600)
        let result = try await runtime.execStreaming(command,
                                                     timeout: TimeInterval(timeout),
                                                     onOutput: onOutput ?? { _, _ in })

        var content = result.stdout
        if !result.stderr.isEmpty {
            content += (content.isEmpty ? "" : "\n") + "[stderr]\n" + result.stderr
        }
        if result.timedOut { content += "\n[已超时，进程被终止]" }
        content += "\n[exit \(result.exitCode)]"
        if content.count > 20_000 {
            content = String(content.prefix(20_000)) + "\n…（输出已截断）"
        }
        return AgentToolResult(content: content, isError: result.exitCode != 0 || result.timedOut)
    }
}

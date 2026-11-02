//
//  AgentTools.swift
//  Project-Auto
//
//  工具注册与宿主工具实现。首批是只读工具（list_dir / read_file），
//  写入与命令执行等能力等权限策略确定后再加；新增工具必须带 risk。
//

import Foundation

nonisolated struct AgentToolResult: Sendable {
    var content: String
    var isError = false
    var images: [PiToolImage] = []
}

nonisolated protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    var risk: ToolRisk { get }
    func execute(_ arguments: JSONValue) async throws -> AgentToolResult
}

extension AgentTool {
    /// 默认只读；写文件/执行命令的工具必须显式覆盖。
    var risk: ToolRisk { .readOnly }

    var spec: PiToolSpec {
        PiToolSpec(name: name, description: description, parameters: parameters)
    }
}

nonisolated enum HostToolError: Error, LocalizedError {
    case invalidPath(String)
    case outsideSandbox(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "无效路径：\(path)"
        case .outsideSandbox(let path): return "路径不在允许的工作区内：\(path)"
        case .notFound(let path): return "文件不存在：\(path)"
        case .notAFile(let path): return "不是文件：\(path)"
        case .notADirectory(let path): return "不是目录：\(path)"
        case .tooLarge(let detail): return detail
        }
    }
}

/// 路径沙盒：工具只能访问给定的根目录（后续接用户选择目录时替换 roots）。
nonisolated struct HostToolSandbox: Sendable {
    var roots: [URL]

    init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL }
    }

    static var defaultWorkspace: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let workspace = docs.appendingPathComponent("agent-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    static var `default`: HostToolSandbox {
        HostToolSandbox(roots: [defaultWorkspace])
    }

    func resolve(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HostToolError.invalidPath("路径为空") }
        let base = roots.first ?? HostToolSandbox.defaultWorkspace
        let candidate = URL(fileURLWithPath: trimmed, relativeTo: base).standardizedFileURL
        let allowed = roots.contains { root in
            candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
        }
        guard allowed else { throw HostToolError.outsideSandbox(candidate.path) }
        return candidate
    }
}

// MARK: - 只读工具

nonisolated struct ListDirectoryTool: AgentTool {
    var sandbox: HostToolSandbox

    let name = "list_dir"
    let description = "列出工作区内指定目录的文件和子目录（相对路径，默认当前目录）。"

    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("相对工作区的目录路径，默认为 .")
                ])
            ])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        let rawPath = arguments["path"]?.stringValue ?? "."
        let directory = try sandbox.resolve(rawPath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw HostToolError.notFound(rawPath)
        }
        guard isDirectory.boolValue else { throw HostToolError.notADirectory(rawPath) }

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let sorted = entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var lines: [String] = []
        for entry in sorted.prefix(500) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                lines.append("\(entry.lastPathComponent)/")
            } else {
                let size = values?.fileSize ?? 0
                lines.append("\(entry.lastPathComponent)  (\(size) bytes)")
            }
        }
        if entries.count > 500 { lines.append("…（已截断，共 \(entries.count) 项）") }
        if lines.isEmpty { lines.append("（空目录）") }
        return AgentToolResult(content: lines.joined(separator: "\n"))
    }
}

nonisolated struct ReadFileTool: AgentTool {
    var sandbox: HostToolSandbox
    private static let maxBytes = 256 * 1024

    let name = "read_file"
    let description = "读取工作区内文本文件的内容；超大文件会截断。"

    var parameters: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("相对工作区的文件路径")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    }

    func execute(_ arguments: JSONValue) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue, !rawPath.isEmpty else {
            throw HostToolError.invalidPath("缺少 path")
        }
        let fileURL = try sandbox.resolve(rawPath)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw HostToolError.notFound(rawPath)
        }
        guard !isDirectory.boolValue else { throw HostToolError.notAFile(rawPath) }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        let truncated = data.count > Self.maxBytes
        let slice = truncated ? data.prefix(Self.maxBytes) : data
        guard !slice.contains(0) else {
            return AgentToolResult(content: "（二进制文件，\(slice.count) bytes，未作为文本读取）")
        }
        var text = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        if truncated { text += "\n…（已截断，只读取前 \(Self.maxBytes) bytes）" }
        return AgentToolResult(content: text)
    }
}

// MARK: - JSONValue 便捷读取

extension JSONValue {
    nonisolated subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    nonisolated var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    nonisolated var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    nonisolated var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }
}

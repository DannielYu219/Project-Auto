//
//  SSE.swift
//  Project-Auto
//
//  极简 SSE 行解析：事件名 + data 行累积，空行触发一次分发。
//  同时兼容 \r\n；末尾残行需要调用 flush()。
//

import Foundation

nonisolated struct SSEMessage: Sendable, Equatable {
    var event: String?
    var data: String
}

nonisolated final class SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    /// 返回本行推进后可以分发的完整事件（通常 0 或 1 个）。
    /// 除了空行，新的 `event:` 行也视为上一条事件的边界——
    /// 有些代理不保证空行分隔，只靠 event 行切开。
    func consume(line rawLine: String) -> [SSEMessage] {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty {
            return flush().map { [$0] } ?? []
        }
        if line.hasPrefix(":") { return [] }
        if line.hasPrefix("event:") {
            var messages: [SSEMessage] = []
            if let previous = flush() { messages.append(previous) }
            event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            return messages
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst("data:".count))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
            return []
        }
        return []
    }

    func flush() -> SSEMessage? {
        guard event != nil || !dataLines.isEmpty else { return nil }
        let message = SSEMessage(event: event, data: dataLines.joined(separator: "\n"))
        event = nil
        dataLines = []
        return message
    }
}

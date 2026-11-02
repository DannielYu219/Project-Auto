//
//  MarkdownMessage.swift
//  Project-Auto
//
//  Agent 回复的 Markdown 渲染：段落、标题、列表、引用、行内代码、围栏代码块。
//  SwiftUI 的 AttributedString(markdown:) 只负责行内语义，代码块和列表在
//  这里按块解析，避免把 ``` 和 ** 原样显示给用户。
//

import AppKit
import SwiftUI

struct MarkdownMessage: View {
    let text: String
    @State private var copiedBlock: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            let blocks = Self.parse(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, index: index)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: Block, index: Int) -> some View {
        switch block {
        case .paragraph(let value):
            inlineText(value)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(VelumPalette.ink)
        case .heading(let level, let value):
            inlineText(value)
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(VelumPalette.ink)
                .padding(.top, level <= 2 ? 4 : 2)
        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(VelumPalette.muted)
                inlineText(value)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(VelumPalette.ink)
            }
        case .ordered(let number, let value):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(VelumPalette.muted)
                inlineText(value)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(VelumPalette.ink)
            }
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(VelumPalette.muted.opacity(0.35))
                    .frame(width: 3)
                inlineText(value)
                    .font(.system(size: 13))
                    .foregroundStyle(VelumPalette.muted)
            }
            .padding(.vertical, 2)
        case .rule:
            Rectangle()
                .fill(VelumPalette.line)
                .frame(height: 1)
                .padding(.vertical, 2)
        case .code(let language, let value):
            codeBlock(language: language, code: value, index: index)
        case .table(let headers, let rows):
            tableBlock(headers: headers, rows: rows)
        }
    }

    private func inlineText(_ source: String) -> Text {
        guard var attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(source)
        }
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attributed[run.range].font = .system(size: 13, design: .monospaced)
            attributed[run.range].foregroundColor = VelumPalette.blue
        }
        return Text(attributed)
    }

    private func codeBlock(language: String?, code: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VelumPalette.muted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copiedBlock = index
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        if copiedBlock == index { copiedBlock = nil }
                    }
                } label: {
                    Image(systemName: copiedBlock == index ? "checkmark" : "square.on.square")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(VelumPalette.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("复制代码")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(VelumPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.bottom, 2)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(VelumPalette.ink.opacity(0.045))
        }
    }

    private func tableBlock(headers: [String], rows: [[String]]) -> some View {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        return VStack(spacing: 0) {
            tableRow(headers, columns: columns, header: true)
            Rectangle().fill(VelumPalette.line).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                tableRow(row, columns: columns, header: false)
                if index < rows.count - 1 {
                    Rectangle().fill(VelumPalette.line.opacity(0.55)).frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VelumPalette.ink.opacity(0.035))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VelumPalette.line, lineWidth: 0.6)
        }
    }

    private func tableRow(_ cells: [String], columns: Int, header: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<columns, id: \.self) { index in
                inlineText(index < cells.count ? cells[index] : "")
                    .font(.system(size: header ? 10 : 11.5,
                                  weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? VelumPalette.muted : VelumPalette.ink)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, header ? 8 : 9)
        .background(header ? VelumPalette.ink.opacity(0.035) : .clear)
    }

    /// GFM pipe table; only accepted when the second line is a matching divider.
    private static func tableMatch(_ lines: [String], index: Int)
        -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = tableCells(lines[index]),
              let divider = tableCells(lines[index + 1]),
              headers.count >= 2,
              divider.count == headers.count,
              divider.allSatisfy(isTableDivider)
        else { return nil }
        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let cells = tableCells(lines[cursor]) else { break }
            var normalized = Array(cells.prefix(headers.count))
            while normalized.count < headers.count { normalized.append("") }
            rows.append(normalized)
            cursor += 1
        }
        return (headers, rows, cursor)
    }

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableDivider(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !core.isEmpty && core.allSatisfy { $0 == "-" }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    // MARK: - Block parser

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case bullet(String)
        case ordered(Int, String)
        case quote(String)
        case code(String?, String)
        case table([String], [[String]])
        case rule
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let value = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(.paragraph(value)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3)
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(marker) { break }
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                var value = code.joined(separator: "\n")
                if value.hasSuffix("\n") { value.removeLast() }
                blocks.append(.code(language.isEmpty ? nil : language, value))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let table = tableMatch(lines, index: index) {
                flushParagraph()
                blocks.append(.table(table.headers, table.rows))
                index = table.nextIndex
                continue
            }

            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(value))
                index += 1
                continue
            }

            if let bullet = bulletMatch(trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                index += 1
                continue
            }

            if let ordered = orderedMatch(trimmed) {
                flushParagraph()
                blocks.append(.ordered(ordered.number, ordered.text))
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletMatch(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedMatch(_ line: String) -> (number: Int, text: String)? {
        var digits = ""
        var rest = line[...]
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}

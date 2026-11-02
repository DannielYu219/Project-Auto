//
//  FileBrowserModel.swift
//  Project-Auto
//
//  真实文件浏览：通过 Linux helper 读取 /workspace（AI 产物）里的目录和文件。
//  不读取宿主任意目录；宿主目录需要显式挂载。
//

import Combine
import Foundation

nonisolated struct BrowserFile: Identifiable, Sendable, Equatable {
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: Int64
    var modified: Date

    var id: String { path }
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var currentPath = "/workspace"
    @Published private(set) var entries: [BrowserFile] = []
    @Published private(set) var selected: BrowserFile?
    @Published private(set) var preview = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""

    private var runtime: (any LinuxExecuting)?

    private func executor() -> (any LinuxExecuting)? {
        if let runtime { return runtime }
        runtime = LinuxRuntimeFactory.make()
        return runtime
    }

    func load(_ path: String? = nil) async {
        let target = ((path ?? currentPath) as NSString).standardizingPath
        guard target == "/workspace" || target.hasPrefix("/workspace/") || target == "/mnt/mac" || target.hasPrefix("/mnt/mac/") else {
            errorMessage = "只能浏览 AI 产物与授权挂载目录"; return
        }
        guard let runtime = executor() else {
            errorMessage = "Linux 运行时不可用"
            return
        }
        isLoading = true
        errorMessage = nil
        selected = nil
        preview = ""
        do {
            let command = """
            cd -- \(Self.quote(target)) && find . -mindepth 1 -maxdepth 1 -printf '%y\\0%s\\0%T@\\0%f\\0'
            """
            let result = try await runtime.exec(command, timeout: 30)
            guard result.exitCode == 0 else {
                throw NSError(domain: "FileBrowser", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "无法读取目录" : result.stderr])
            }
            var parsed: [BrowserFile] = []
            let fields = result.stdout.split(separator: "\0", omittingEmptySubsequences: false)
            for offset in stride(from: 0, through: max(0, fields.count - 4), by: 4) {
                guard fields.count >= offset + 4 else { continue }
                let parts = Array(fields[offset..<(offset + 4)])
                let kind = String(parts[0])
                let size = Int64(parts[1]) ?? 0
                let stamp = TimeInterval(parts[2]) ?? 0
                let name = String(parts[3])
                if name == "." || name == ".." { continue }
                parsed.append(BrowserFile(name: name,
                                          path: target.hasSuffix("/") ? target + name : target + "/" + name,
                                          isDirectory: kind == "d",
                                          isSymlink: kind == "l",
                                          size: size,
                                          modified: Date(timeIntervalSince1970: stamp)))
            }
            entries = parsed.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            currentPath = target
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func open(_ file: BrowserFile) async {
        if file.isDirectory {
            await load(file.path)
            return
        }
        guard let runtime = executor() else { return }
        selected = file
        preview = "读取中…"
        do {
            let escaped = Self.quote(file.path)
            let result = try await runtime.exec("if LC_ALL=C grep -Iq '' -- \(escaped) || [ ! -s \(escaped) ]; then printf 'VELUM_TEXT\\n'; head -c 200000 -- \(escaped); else printf 'VELUM_BINARY\\n'; fi", timeout: 30)
            guard result.exitCode == 0 else { throw NSError(domain: "FileBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
            if result.stdout.hasPrefix("VELUM_TEXT\n") {
                let text = String(result.stdout.dropFirst("VELUM_TEXT\n".count))
                preview = text.isEmpty ? "（空文件）" : text
            } else {
                preview = "二进制文件\n大小 \(Self.sizeText(file.size))"
            }
        } catch {
            preview = "读取失败：\(error.localizedDescription)"
        }
    }

    func clearSelection() {
        selected = nil
        preview = ""
    }

    func goUp() async {
        if currentPath == "/workspace" || currentPath == "/mnt/mac" { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/workspace" : parent)
    }

    var filteredEntries: [BrowserFile] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return entries
        }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    static func sizeText(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = -1
        repeat {
            value /= 1024
            index += 1
        } while value >= 1024 && index < units.count - 1
        return String(format: "%.1f %@", value, units[index])
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

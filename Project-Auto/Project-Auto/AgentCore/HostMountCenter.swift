import AppKit
import Combine
import Foundation

nonisolated struct HostDirectoryMount: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var hostPath: String
    var guestPath: String
    var readOnly: Bool
    var bookmark: Data
    var helperBookmark: Data
}

/// Explicit user grants. A model can request the picker or use a prior grant; it cannot grant itself a path.
@MainActor
final class HostMountCenter: ObservableObject {
    static let shared = HostMountCenter()
    @Published private(set) var mounts: [HostDirectoryMount] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isApplying = false
    private let storageKey = "velum.linux.mounts.v1"
    private var scopedURLs: [URL] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([HostDirectoryMount].self, from: data) {
            mounts = saved
            for mount in saved {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: mount.bookmark,
                                      options: [.withSecurityScope], relativeTo: nil,
                                      bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
                    scopedURLs.append(url)
                }
            }
        }
    }

    func chooseDirectory(readOnly: Bool = true) async throws -> HostDirectoryMount? {
        let panel = NSOpenPanel()
        panel.title = readOnly ? "授权挂载 Mac 目录（只读）" : "授权挂载 Mac 目录（可读写）"
        panel.prompt = "挂载所选目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
            let helperBookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            let id = UUID().uuidString.lowercased()
            let mount = HostDirectoryMount(id: id, name: url.lastPathComponent,
                                           hostPath: url.path, guestPath: "/mnt/mac/\(id)",
                                           readOnly: readOnly, bookmark: bookmark, helperBookmark: helperBookmark)
            let updated = mounts + [mount]
            try await apply(updated)
            mounts = updated
            persist()
            if scoped { scopedURLs.append(url) }
            return mount
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func remove(_ id: String) async throws {
        let updated = mounts.filter { $0.id != id }
        try await apply(updated)
        mounts = updated
        persist()
    }

    func synchronize() async throws { try await apply(mounts) }

    private func apply(_ list: [HostDirectoryMount]) async throws {
        guard let client = LinuxHelperClient.makeDefault() else {
            throw SmolvmError.executionFailed("Linux helper 不可用")
        }
        isApplying = true
        defer { isApplying = false }
        try await client.configureMounts(JSONEncoder().encode(list))
        errorMessage = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(mounts) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    func snapshotJSON() -> String {
        let values = mounts.map { ["id": $0.id, "name": $0.name, "guest_path": $0.guestPath,
                                    "mode": $0.readOnly ? "ro" : "rw"] }
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

import CryptoKit
import Foundation

nonisolated enum LocalModelImportError: LocalizedError, Sendable {
    case invalidFolder(String)
    case invalidFiles(String)
    case unsafePath
    case notEnoughSpace

    var errorDescription: String? {
        switch self {
        case .invalidFolder(let message): message
        case .invalidFiles(let message): message
        case .unsafePath: "模型文件包含逃逸目录的符号链接"
        case .notEnoughSpace: "磁盘空间不足"
        }
    }
}

/// Local imports stay data-only. MLX is registered directly; Splash is staged and
/// handed to the official `prepare_local_model` endpoint.
nonisolated enum LocalModelImporter {
    static let modelsRoot = URL(fileURLWithPath: "/Users/Shared/Velum/ai/engines/Models", isDirectory: true)

    static func importMLX(folder: URL, capability: String) async throws -> String {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let source = folder.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LocalModelImportError.invalidFolder("请选择包含 config.json 的模型文件夹")
            }
            let config = source.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: config.path) else {
                throw LocalModelImportError.invalidFolder("模型文件夹缺少 config.json")
            }
            let files = try inventory(source)
            guard files.contains(where: { $0.pathExtension.lowercased() == "safetensors" }) else {
                throw LocalModelImportError.invalidFolder("模型文件夹缺少 safetensors 权重")
            }
            let identifier = UUID().uuidString.lowercased()
            let revision = identifier.replacingOccurrences(of: "-", with: "") + "00000000"
            let relative = "mlx-local/\(identifier)"
            let destination = modelsRoot.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            var records: [[String: Any]] = []
            for file in files {
                let targetPath = destination.appendingPathComponent(try relativePath(of: file, in: source))
                try fm.createDirectory(at: targetPath.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: targetPath)
                records.append(["path": try relativePath(of: file, in: source),
                                "size": (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0,
                                "sha256": try sha256(file)])
            }
            let display = source.lastPathComponent.isEmpty ? "local-model" : source.lastPathComponent
            let modelID = "local/\(display)@\(revision.prefix(12))"
            let descriptor: [String: Any] = [
                "id": modelID, "repo": "local/\(display)", "revision": revision,
                "capability": capability, "path": relative, "created": Int(Date().timeIntervalSince1970),
                "manifest": "\(relative)/velum-model.json"
            ]
            let manifest: [String: Any] = ["schema_version": 1, "files": records]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("velum-model.json"), options: .atomic)
            try register(descriptor)
            return modelID
        }.value
    }

    struct StagedSplash {
        let target: String
        let draft: String
        let mmproj: String?
        let stagingDirectory: URL
    }

    /// Copies the three user-selected groups into the managed model store so the
    /// unsandboxed engine can read them without inheriting App security scopes.
    static func stageSplash(targets: [URL], draft: URL, mmproj: URL?) async throws -> StagedSplash {
        let targetScopes = targets.map { ($0, $0.startAccessingSecurityScopedResource()) }
        let draftScoped = draft.startAccessingSecurityScopedResource()
        let mmprojScoped = mmproj?.startAccessingSecurityScopedResource() ?? false
        defer {
            for (url, scoped) in targetScopes where scoped { url.stopAccessingSecurityScopedResource() }
            if draftScoped { draft.stopAccessingSecurityScopedResource() }
            if let mmproj, mmprojScoped { mmproj.stopAccessingSecurityScopedResource() }
        }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard !targets.isEmpty else { throw LocalModelImportError.invalidFiles("请选择至少一个 GGUF 模型文件") }
            for target in targets where target.pathExtension.lowercased() != "gguf" {
                throw LocalModelImportError.invalidFiles("模型本体必须是 .gguf 文件：\(target.lastPathComponent)")
            }
            if let mmproj, mmproj.pathExtension.lowercased() != "gguf" {
                throw LocalModelImportError.invalidFiles("mmproj 必须是 .gguf 文件")
            }
            let identifier = UUID().uuidString.lowercased()
            let staging = modelsRoot.appendingPathComponent("splash-local/\(identifier)", isDirectory: true)
            let targetDirectory = staging.appendingPathComponent("target", isDirectory: true)
            let draftDirectory = staging.appendingPathComponent("draft", isDirectory: true)
            try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: draftDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            var targetPaths: [String] = []
            for (target, _) in targetScopes {
                let destination = targetDirectory.appendingPathComponent(target.lastPathComponent)
                if fm.fileExists(atPath: destination.path) {
                    throw LocalModelImportError.invalidFiles("模型文件重名：\(target.lastPathComponent)")
                }
                try fm.copyItem(at: target, to: destination)
                targetPaths.append(destination.path)
            }
            // DFlash2 is normally a directory. Accept a single file too and let the
            // official installer produce the precise format error.
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: draft.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try copyDirectoryContents(draft, to: draftDirectory, fm: fm)
            } else {
                try fm.copyItem(at: draft, to: draftDirectory.appendingPathComponent(draft.lastPathComponent))
            }
            var mmprojPath: String?
            if let mmproj {
                let destination = staging.appendingPathComponent("mmproj.gguf")
                try fm.copyItem(at: mmproj, to: destination)
                mmprojPath = destination.path
            }
            let target = targetPaths.sorted().first!
            return StagedSplash(target: target, draft: draftDirectory.path,
                                mmproj: mmprojPath, stagingDirectory: staging)
        }.value
    }

    static func removeStaging(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    private static func copyDirectoryContents(_ source: URL, to destination: URL, fm: FileManager) throws {
        let files = try inventory(source)
        for file in files {
            let relative = try relativePath(of: file, in: source)
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
    }

    private static func inventory(_ source: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles]) else {
            throw LocalModelImportError.invalidFolder("无法读取模型目录")
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let resolved = file.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                    throw LocalModelImportError.unsafePath
                }
            }
            if values.isRegularFile == true {
                if file.lastPathComponent == "velum-model.json" || file.pathComponents.contains(".cache") { continue }
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL, in root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        let path = file.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath) else { throw LocalModelImportError.unsafePath }
        return String(path.dropFirst(rootPath.count))
    }

    private static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 4 * 1024 * 1024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func register(_ descriptor: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let registry = modelsRoot.appendingPathComponent("models.json")
        var models: [[String: Any]] = []
        if let data = try? Data(contentsOf: registry),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = object["models"] as? [[String: Any]] {
            models = existing
        }
        let id = descriptor["id"] as? String ?? ""
        models.removeAll { ($0["id"] as? String) == id }
        models.append(descriptor)
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "models": models],
                                              options: [.prettyPrinted, .sortedKeys])
        let temporary = registry.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if fm.fileExists(atPath: registry.path) {
            try fm.replaceItemAt(registry, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: registry)
        }
    }
}

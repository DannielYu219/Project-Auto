import Foundation
import CryptoKit
import Security
import Darwin

nonisolated enum LocalRuntimeValidation {
    static let runtimeID = "velum-mlx-python"
    static let interpreter = "python/bin/python3.12"
    static let server = "service/server.py"
    static let protocolName = "velum.local-ai.v1"

    static func relativePath(_ path: String) throws -> String {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count < 4096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalRuntimeError.invalidBundle("运行时含不安全的相对路径。")
        }
        return path
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        } && value != "." && value != ".."
    }

    static func ensureDirectory(_ url: URL) throws {
        try rejectSymbolicAncestors(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymbolicAncestors(url)
    }

    // An existing symlink in any managed ancestor must never redirect writes.
    static func rejectSymbolicAncestors(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                throw LocalRuntimeError.invalidBundle("受管理目录不能经过符号链接：\(current.lastPathComponent)")
            }
        }
    }

    static func validate(at root: URL, allowDevelopment: Bool, checkSignatures: Bool = true) throws -> LocalRuntimeManifest {
        try rejectSymbolicAncestors(root)
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("runtime.json")
        var manifestStat = stat()
        guard lstat(manifestURL.path, &manifestStat) == 0, (manifestStat.st_mode & S_IFMT) == S_IFREG,
              manifestStat.st_size > 0, manifestStat.st_size <= 16 * 1024 * 1024 else {
            throw LocalRuntimeError.invalidBundle("缺少有效 runtime.json。")
        }
        let manifest = try JSONDecoder().decode(LocalRuntimeManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schema_version == 1, manifest.id == runtimeID,
              identifier(manifest.version), manifest.platform == "macos",
              manifest.python.version.hasPrefix("3.12."), manifest.python.executable == interpreter,
              manifest.launcher == "bin/velum-mlx-runtime",
              manifest.adapter.protocol == protocolName, manifest.adapter.host == "127.0.0.1",
              manifest.adapter.port == 0, manifest.adapter.auth_env == "VELUM_RUNTIME_TOKEN",
              manifest.adapter.models_env == "VELUM_MODELS_DIR",
              Set(manifest.capabilities).isSubset(of: ["chat", "embeddings", "download"]) else {
            throw LocalRuntimeError.invalidBundle("运行时标识、固定入口或协议不匹配。")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard manifest.architecture == architecture else {
            throw LocalRuntimeError.incompatible("运行时架构 \(manifest.architecture) 与本机 \(architecture) 不兼容。")
        }
        if let minimum = manifest.minimum_macos {
            let components = minimum.split(separator: ".").compactMap { Int($0) }
            guard !components.isEmpty, components.count <= 3 else { throw LocalRuntimeError.invalidBundle("最低系统版本无效。") }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = [os.majorVersion, os.minorVersion, os.patchVersion]
            let required = components + Array(repeating: 0, count: 3 - components.count)
            guard !current.lexicographicallyPrecedes(required) else {
                throw LocalRuntimeError.incompatible("此运行时需要 macOS \(minimum) 或更新版本。")
            }
        }
        guard !manifest.files.isEmpty, manifest.files.count <= 200_000 else { throw LocalRuntimeError.invalidBundle("运行时文件清单无效。") }
        let expectedLinks = manifest.symlinks ?? [:]
        for (path, hash) in manifest.files {
            _ = try relativePath(path)
            guard path != "runtime.json", hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw LocalRuntimeError.invalidBundle("SHA256 文件清单无效。")
            }
        }
        for (path, target) in expectedLinks {
            _ = try relativePath(path)
            guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), !target.contains("\0") else { throw LocalRuntimeError.invalidBundle("符号链接目标无效。") }
        }
        guard Set(manifest.files.keys).isDisjoint(with: expectedLinks.keys) else { throw LocalRuntimeError.invalidBundle("文件清单包含重复类型。") }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { throw LocalRuntimeError.invalidBundle("无法遍历运行时。") }
        var files = Set<String>()
        var links = Set<String>()
        var nativeFiles = [URL]()
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(root.path.count + 1))
            _ = try relativePath(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw LocalRuntimeError.invalidBundle("无法读取运行时文件。") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: break
            case S_IFLNK:
                enumerator.skipDescendants()
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                guard expectedLinks[path] == target else { throw LocalRuntimeError.invalidBundle("符号链接清单不匹配：\(path)") }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(root.standardizedFileURL.path + "/"), fm.fileExists(atPath: resolved) else {
                    throw LocalRuntimeError.invalidBundle("符号链接越界或失效：\(path)")
                }
                links.insert(path)
            case S_IFREG:
                guard info.st_nlink == 1 else { throw LocalRuntimeError.invalidBundle("运行时不允许硬链接。") }
                if path == "runtime.json" { continue }
                guard let expected = manifest.files[path] else { throw LocalRuntimeError.invalidBundle("运行时含未登记文件：\(path)") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256()
                var prefix = Data()
                while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
                    if prefix.isEmpty { prefix = Data(block.prefix(4)) }
                    digest.update(data: block)
                }
                let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw LocalRuntimeError.invalidBundle("SHA256 校验失败：\(path)") }
                files.insert(path)
                if isMachO(prefix) { nativeFiles.append(url) }
            default: throw LocalRuntimeError.invalidBundle("运行时含设备、socket 或其他特殊文件。")
            }
        }
        guard files == Set(manifest.files.keys), links == Set(expectedLinks.keys),
              files.contains(server), fm.isExecutableFile(atPath: root.appendingPathComponent(interpreter).path),
              !nativeFiles.isEmpty else { throw LocalRuntimeError.invalidBundle("运行时文件缺失或入口无效。") }
        switch manifest.signing.policy {
        case "development-adhoc":
            guard allowDevelopment else { throw LocalRuntimeError.invalidBundle("这是开发用临时签名运行时；必须明确允许开发包后才能安装。") }
            if checkSignatures { for url in nativeFiles { try verifyCode(url, requiredTeam: nil) } }
        case "developer-id":
            // Hashes alone cannot authenticate Python source or runtime.json. A future
            // signed release envelope must cover them; do not silently accept a Team ID
            // chosen by an untrusted manifest as release authorization.
            throw LocalRuntimeError.invalidBundle("正式发行包的受信签名封装尚未配置；拒绝仅凭文件哈希安装。请使用明确标记的开发包。")
        default: throw LocalRuntimeError.invalidBundle("未知运行时签名策略。")
        }
        return manifest
    }

    private static func isMachO(_ prefix: Data) -> Bool {
        let signatures: [[UInt8]] = [[0xfe,0xed,0xfa,0xce], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xcf,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]]
        return signatures.contains(Array(prefix))
    }

    private static func verifyCode(_ url: URL, requiredTeam: String?) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw LocalRuntimeError.invalidBundle("原生代码签名无效：\(url.lastPathComponent)")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { throw LocalRuntimeError.invalidBundle("无法读取代码签名。") }
        if let requiredTeam, dictionary[kSecCodeInfoTeamIdentifier as String] as? String != requiredTeam {
            throw LocalRuntimeError.invalidBundle("原生代码 Team ID 不匹配。")
        }
    }
}

// libarchive is shipped by macOS. We read entries ourselves, never call a shell or
// extract an archive wholesale: hardlinks, path traversal, special files and
// symlink parents are rejected before any destination is opened.
nonisolated enum LocalRuntimeArchive {
    typealias New = @convention(c) () -> OpaquePointer?
    typealias Support = @convention(c) (OpaquePointer?) -> Int32
    typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias EntryString = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias EntryType = @convention(c) (OpaquePointer?) -> UInt32
    typealias EntrySize = @convention(c) (OpaquePointer?) -> Int64
    typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int

    static func extract(_ source: URL, to destination: URL) throws {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw LocalRuntimeError.invalidBundle("系统 libarchive 不可用。") }
        defer { dlclose(library) }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let value = dlsym(library, name) else { throw LocalRuntimeError.invalidBundle("系统归档接口不可用。") }
            return unsafeBitCast(value, to: T.self)
        }
        let new = try symbol("archive_read_new", New.self)
        let supportFilter = try symbol("archive_read_support_filter_all", Support.self)
        let supportFormat = try symbol("archive_read_support_format_all", Support.self)
        let open = try symbol("archive_read_open_filename", Open.self)
        let next = try symbol("archive_read_next_header", Next.self)
        let read = try symbol("archive_read_data", Read.self)
        let free = try symbol("archive_read_free", Support.self)
        let path = try symbol("archive_entry_pathname", EntryString.self)
        let link = try symbol("archive_entry_symlink", EntryString.self)
        let hardlink = try symbol("archive_entry_hardlink", EntryString.self)
        let type = try symbol("archive_entry_filetype", EntryType.self)
        let size = try symbol("archive_entry_size", EntrySize.self)
        let perm = try symbol("archive_entry_perm", EntryType.self)
        guard let archive = new() else { throw LocalRuntimeError.invalidBundle("无法打开归档。") }
        defer { _ = free(archive) }
        _ = supportFilter(archive); _ = supportFormat(archive)
        guard source.path.withCString({ open(archive, $0, 64 * 1024) }) == 0 else { throw LocalRuntimeError.invalidBundle("无法读取归档。") }
        try LocalRuntimeValidation.ensureDirectory(destination)
        var seen = Set<String>()
        var deferredLinks: [(URL, String)] = []
        var bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            var entry: OpaquePointer?
            let result = next(archive, &entry)
            if result == 1 { break }
            guard result == 0, let entry, let rawPath = path(entry) else { throw LocalRuntimeError.invalidBundle("归档损坏。") }
            var name = String(cString: rawPath)
            while name.hasPrefix("./") { name.removeFirst(2) }
            while name.hasSuffix("/") { name.removeLast() }
            if name.isEmpty { continue }
            _ = try LocalRuntimeValidation.relativePath(name)
            guard seen.insert(name).inserted, seen.count <= 200_000, hardlink(entry) == nil else { throw LocalRuntimeError.invalidBundle("归档含重复文件或硬链接。") }
            let url = destination.appendingPathComponent(name)
            try LocalRuntimeValidation.ensureDirectory(url.deletingLastPathComponent())
            switch type(entry) {
            case UInt32(S_IFDIR): try LocalRuntimeValidation.ensureDirectory(url)
            case UInt32(S_IFLNK):
                guard let target = link(entry) else { throw LocalRuntimeError.invalidBundle("归档符号链接无效。") }
                let targetPath = String(cString: target)
                guard !targetPath.hasPrefix("/"), !targetPath.contains("\\"), !targetPath.isEmpty else { throw LocalRuntimeError.invalidBundle("归档符号链接越界。") }
                let resolved = url.deletingLastPathComponent().appendingPathComponent(targetPath).standardizedFileURL.path
                guard resolved.hasPrefix(destination.path + "/") else { throw LocalRuntimeError.invalidBundle("归档符号链接越界。") }
                deferredLinks.append((url, targetPath))
            case UInt32(S_IFREG):
                guard size(entry) >= 0, size(entry) <= 8 * 1024 * 1024 * 1024 else { throw LocalRuntimeError.invalidBundle("归档文件尺寸无效。") }
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(perm(entry) & 0o777))
                guard descriptor >= 0 else { throw LocalRuntimeError.invalidBundle("无法写入归档文件。") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    var written: Int64 = 0
                    while true {
                        let count = buffer.withUnsafeMutableBytes { read(archive, $0.baseAddress, $0.count) }
                        guard count >= 0 else { throw LocalRuntimeError.invalidBundle("归档内容损坏。") }
                        if count == 0 { break }
                        written += Int64(count); bytes += Int64(count)
                        guard written <= size(entry), bytes <= 24 * 1024 * 1024 * 1024 else { throw LocalRuntimeError.invalidBundle("归档超过安全尺寸上限。") }
                        try handle.write(contentsOf: Data(buffer.prefix(count)))
                    }
                    guard written == size(entry) else { throw LocalRuntimeError.invalidBundle("归档文件被截断。") }
                    try handle.close()
                } catch { try? handle.close(); throw error }
            default: throw LocalRuntimeError.invalidBundle("归档含不支持的特殊文件。")
            }
        }
        // Create links last, so archive order cannot redirect later writes.
        for (url, target) in deferredLinks {
            try LocalRuntimeValidation.rejectSymbolicAncestors(url.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }
}
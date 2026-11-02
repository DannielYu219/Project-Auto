import Foundation
import CryptoKit
import Security
import Darwin

nonisolated enum SplitEngineValidation {
    static let protocolName = "velum.local-ai.v1"
    static let pythonExecutable = "python/bin/python3.12"
    static let pythonEntry = "service/server.py"
    static let nativeEntry = "bin/engine-server"

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 100 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
    @discardableResult static func relativePath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count < 4096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SplitEngineError.invalid("Package contains an unsafe relative path.")
        }
        return path
    }
    static func rejectSymbolicAncestors(_ url: URL) throws {
        var part = URL(fileURLWithPath: "/", isDirectory: true)
        // Foundation standardization can rewrite /private/tmp back to /tmp.
        // Walk the supplied physical path verbatim so system aliases do not
        // reappear after appPythonBase has explicitly canonicalized them.
        for component in url.pathComponents.dropFirst() {
            part.appendPathComponent(component)
            var info = stat()
            if lstat(part.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                throw SplitEngineError.invalid("Managed paths cannot traverse symbolic links: \(part.path)")
            }
        }
    }
    static func ensureDirectory(_ url: URL) throws {
        try rejectSymbolicAncestors(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymbolicAncestors(url)
    }
    static func regularData(_ url: URL, maximum: Int) throws -> Data {
        try rejectSymbolicAncestors(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximum else { throw SplitEngineError.invalid("Invalid package metadata.") }
        return try Data(contentsOf: url)
    }
    static func validate(at root: URL, allowDevelopment: Bool, trustedKeys: [String: Data], base: Bool = false) throws -> SplitEngineManifest {
        try rejectSymbolicAncestors(root)
        let raw = try regularData(root.appendingPathComponent("runtime.json"), maximum: 32 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(SplitEngineManifest.self, from: raw)
        guard manifest.schema_version == 2, identifier(manifest.id), identifier(manifest.version), manifest.platform == "macos" else {
            throw SplitEngineError.invalid("Unsupported schema, platform, or package identifier.")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard manifest.architecture == architecture else { throw SplitEngineError.incompatible("Engine architecture is incompatible with this Mac.") }
        if base {
            guard manifest.id == "velum-python", manifest.kind == "python-base",
                  manifest.python?.executable == pythonExecutable, manifest.python?.abi == "cp312",
                  manifest.python?.version.hasPrefix("3.12.") == true else {
                throw SplitEngineError.invalid("The app Python base has an invalid identity or entry point.")
            }
        } else {
            guard ["python", "executable"].contains(manifest.kind),
                  manifest.entrypoint == (manifest.kind == "python" ? pythonEntry : nativeEntry),
                  manifest.kind != "python" || manifest.python_abi == "cp312",
                  manifest.python == nil,
                  manifest.adapter?.protocol == protocolName, manifest.adapter?.host == "127.0.0.1",
                  manifest.adapter?.port == 0, manifest.adapter?.auth_env == "VELUM_RUNTIME_TOKEN",
                  manifest.adapter?.models_env == "VELUM_MODELS_DIR",
                  !manifest.declaredCapabilities.isEmpty, Set(manifest.declaredCapabilities).count == manifest.declaredCapabilities.count,
                  Set(manifest.declaredCapabilities).isSubset(of: ["chat", "models", "embeddings", "download"]),
                  manifest.declaredCapabilities.contains("chat") else {
                throw SplitEngineError.invalid("Engine entry point, capabilities, or connection protocol is unsupported.")
            }
            if manifest.id == "mlx", manifest.kind != "python" { throw SplitEngineError.invalid("MLX requires a Python engine package.") }
            if manifest.id == "splash" {
                guard !manifest.declaredCapabilities.contains("embeddings") else { throw SplitEngineError.invalid("Splash supports chat and does not provide embeddings.") }
                try minimumOS("26.4")
                try splashHardware()
            }
        }
        if let minimum = manifest.minimum_macos { try minimumOS(minimum) }
        guard !manifest.files.isEmpty, manifest.files.count <= 200_000 else { throw SplitEngineError.invalid("Invalid package file inventory.") }
        let expectedLinks = manifest.symlinks ?? [:]
        guard expectedLinks.count <= 200_000, Set(expectedLinks.keys).isDisjoint(with: manifest.files.keys) else { throw SplitEngineError.invalid("Duplicate package file types.") }
        for (path, hash) in manifest.files {
            try relativePath(path)
            if base {
                let components = path.split(separator: "/")
                guard !components.contains("site-packages"), !components.contains("ensurepip"), !components.contains("pip") else {
                    throw SplitEngineError.invalid("The bundled Python base must contain only the standalone standard library.")
                }
            } else {
                guard !path.hasPrefix("python/"), !path.split(separator: "/").contains(where: { $0.hasPrefix("libpython") }) else {
                    throw SplitEngineError.invalid("External engines must use the app Python base instead of bundling CPython.")
                }
            }
            guard !["runtime.json", "runtime.sig"].contains(path), hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SplitEngineError.invalid("Invalid SHA256 inventory.") }
        }
        for (path, target) in expectedLinks {
            try relativePath(path)
            guard !["runtime.json", "runtime.sig"].contains(path) else { throw SplitEngineError.invalid("Package metadata cannot be a symbolic link.") }
            try safeLink(target, at: root.appendingPathComponent(path), root: root)
        }
        let development: Bool
        switch manifest.signing.policy {
        case "development-adhoc":
            guard allowDevelopment else { throw SplitEngineError.invalid("Development packages require explicit opt-in.") }
            development = true
        case "developer-id", "ed25519":
            guard let keyID = manifest.signing.key_id, let key = trustedKeys[keyID],
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
                  publicKey.isValidSignature(try regularData(root.appendingPathComponent("runtime.sig"), maximum: 64), for: raw),
                  let team = manifest.signing.team_id, !team.isEmpty else {
                throw SplitEngineError.invalid("Package manifest has no trusted release signature.")
            }
            development = false
        default: throw SplitEngineError.invalid("Unsupported signature policy.")
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw SplitEngineError.invalid("Cannot enumerate package.") }
        var files = Set<String>(), links = Set<String>()
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(root.path.count + 1))
            try relativePath(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw SplitEngineError.invalid("Unreadable package file.") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: break
            case S_IFLNK:
                enumerator.skipDescendants()
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                try safeLink(target, at: url, root: root)
                guard expectedLinks[path] == target, let resolved = realpath(url.path, nil) else { throw SplitEngineError.invalid("Package symbolic link inventory mismatch.") }
                let resolvedPath = String(cString: resolved); free(resolved)
                guard resolvedPath.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw SplitEngineError.invalid("Package symbolic link inventory mismatch.") }
                links.insert(path)
            case S_IFREG:
                guard info.st_nlink == 1 else { throw SplitEngineError.invalid("Hard links are not permitted.") }
                if path == "runtime.json" || path == "runtime.sig" { continue }
                guard let expected = manifest.files[path], info.st_size >= 0, info.st_size <= 8 * 1024 * 1024 * 1024 else { throw SplitEngineError.invalid("Unregistered or oversized package file.") }
                total += info.st_size
                guard total <= 24 * 1024 * 1024 * 1024 else { throw SplitEngineError.invalid("Package exceeds size limit.") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256(), prefix = Data()
                while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
                    if prefix.isEmpty { prefix = Data(block.prefix(4)) }; digest.update(data: block)
                }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw SplitEngineError.invalid("Package SHA256 mismatch: \(path)") }
                if isMachO(prefix) { try verifyCode(url, requiredTeam: development ? nil : manifest.signing.team_id) }
                files.insert(path)
            default: throw SplitEngineError.invalid("Package contains a special file.")
            }
        }
        guard files == Set(manifest.files.keys), links == Set(expectedLinks.keys) else { throw SplitEngineError.invalid("Package file inventory is incomplete.") }
        let entry = base ? pythonExecutable : (manifest.kind == "python" ? pythonEntry : nativeEntry)
        guard files.contains(entry) || (base && links.contains(entry)),
              manifest.kind == "python" || FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(entry).path) else { throw SplitEngineError.invalid("Package entry is missing or not executable.") }
        if base || manifest.kind == "executable" {
            let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(entry)); defer { try? handle.close() }
            guard isMachO(try handle.read(upToCount: 4) ?? Data()) else { throw SplitEngineError.invalid("Native engine entry must be a signed Mach-O executable.") }
        }
        return manifest
    }
    static func safeLink(_ target: String, at url: URL, root: URL) throws {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), !target.contains("\0") else { throw SplitEngineError.invalid("Package symbolic link escapes its root.") }
        // Lexical normalization must preserve /private; Foundation may rewrite
        // it to its /tmp alias and break otherwise valid containment checks.
        var components = url.deletingLastPathComponent().pathComponents
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            if component == ".." { if components.count > 1 { components.removeLast() } }
            else { components.append(String(component)) }
        }
        let resolved = "/" + components.dropFirst().joined(separator: "/")
        guard resolved.hasPrefix(root.path + "/") else { throw SplitEngineError.invalid("Package symbolic link escapes its root.") }
    }
    static func minimumOS(_ string: String) throws {
        let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              pieces.allSatisfy({ Int($0) != nil }) else { throw SplitEngineError.invalid("Invalid minimum macOS version.") }
        let required = pieces.map { Int($0)! } + Array(repeating: 0, count: 3 - pieces.count)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard ![os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(required) else { throw SplitEngineError.incompatible("Engine requires macOS \(string) or newer.") }
    }
    static func splashHardware() throws {
        var count = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &count, nil, 0) == 0, count > 0 else { throw SplitEngineError.incompatible("Cannot verify Splash hardware requirements.") }
        var chars = [CChar](repeating: 0, count: count)
        guard sysctlbyname("machdep.cpu.brand_string", &chars, &count, nil, 0) == 0 else { throw SplitEngineError.incompatible("Cannot verify Splash hardware requirements.") }
        let name = String(decoding: chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let range = name.range(of: "Apple M"), let generation = Int(name[range.upperBound...].prefix(while: { $0.isNumber })), generation >= 3 else { throw SplitEngineError.incompatible("Splash requires Apple M3 or newer.") }
    }
    static func isMachO(_ prefix: Data) -> Bool {
        [[UInt8]([0xfe,0xed,0xfa,0xce]), [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xcf,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(Array(prefix))
    }
    static func verifyCode(_ url: URL, requiredTeam: String?) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw SplitEngineError.invalid("Native code signature is invalid.") }
        if let requiredTeam {
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String == requiredTeam else { throw SplitEngineError.invalid("Native code signing team mismatch.") }
        }
    }
    static func appPythonBase(_ path: String, allowDevelopment: Bool, trustedKeys: [String: Data]) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw SplitEngineError.invalid("Missing app-bundled Python base.") }
        // macOS exposes these root-owned aliases; Foundation may preserve them
        // even after resolvingSymlinksInPath. Resolve only these exact aliases,
        // then retain strict rejection for every package/app-internal symlink.
        var physicalPath = path
        for alias in ["/tmp", "/var", "/etc"] where path.hasPrefix(alias + "/") {
            let target = "/private" + alias
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: alias)
            guard link == target || link == String(target.dropFirst()) else {
                throw SplitEngineError.invalid("Unexpected macOS system directory alias.")
            }
            physicalPath = target + path.dropFirst(alias.count)
            break
        }
        let base = URL(fileURLWithPath: physicalPath, isDirectory: true)
        try rejectSymbolicAncestors(base)
        let resources = base.deletingLastPathComponent(), contents = resources.deletingLastPathComponent(), app = contents.deletingLastPathComponent()
        guard base.lastPathComponent == "python-base", resources.lastPathComponent == "Resources", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { throw SplitEngineError.invalid("Python base must be inside the app Resources directory.") }
        // Validate both the base's complete inventory and the containing app seal.
        try verifyCode(app, requiredTeam: nil)
        _ = try validate(at: base, allowDevelopment: allowDevelopment, trustedKeys: trustedKeys, base: true)
        return base
    }
}

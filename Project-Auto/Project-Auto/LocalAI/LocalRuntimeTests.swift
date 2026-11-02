#if LOCAL_RUNTIME_SELF_TEST
import Foundation
import CryptoKit

// Standalone, no GUI:
// swiftc -D LOCAL_RUNTIME_SELF_TEST -parse-as-library LocalRuntimeModels.swift
//   LocalRuntimeValidation.swift LocalRuntimeService.swift LocalRuntimeTests.swift
//   -o /tmp/velum-runtime-tests
// /tmp/velum-runtime-tests [--bundle /absolute/path/to/real/bundle]
@main
nonisolated struct LocalRuntimeSelfTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw Failure(description: description) }
    }

    static func main() async {
        do {
            try await run()
            print("PASS: LocalRuntime standalone lifecycle/security acceptance tests")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func snapshot(_ service: LocalRuntimeService, op: String, source: URL? = nil, allowDev: Bool = false, proxyURL: String? = nil) async throws -> LocalRuntimeSnapshot {
        let request = LocalRuntimeRequest(op: op, sourcePath: source?.path, allowDevelopmentAdHoc: allowDev, proxyURL: proxyURL)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let result = try await service.handle(json)
        return try JSONDecoder().decode(LocalRuntimeSnapshot.self, from: Data(result.utf8))
    }

    static func expectedFailure(_ name: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { print("PASS: rejects \(name)"); return }
        throw Failure(description: "Accepted invalid \(name)")
    }

    static func fixture(_ parent: URL, version: String, extraPath: String? = nil, symlink: String? = nil, signing: String = "development-adhoc") throws -> URL {
        let fm = FileManager.default
        let root = parent.appendingPathComponent(version, isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("python/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("service"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: root.appendingPathComponent("python/bin/python3.12").path)
        try Data("# test fixture, not an executable server\n".utf8).write(to: root.appendingPathComponent("service/server.py"))
        try Data("#!/bin/false\n".utf8).write(to: root.appendingPathComponent("bin/velum-mlx-runtime"))
        var files = [String: String]()
        for path in ["python/bin/python3.12", "service/server.py", "bin/velum-mlx-runtime"] {
            files[path] = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path))).map { String(format: "%02x", $0) }.joined()
        }
        if let extraPath { files[extraPath] = String(repeating: "0", count: 64) }
        var links = [String: String]()
        if let symlink {
            links["service/link"] = symlink
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("service/link").path, withDestinationPath: symlink)
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let manifest: [String: Any] = [
            "schema_version": 1, "id": "velum-mlx-python", "version": version,
            "platform": "macos", "architecture": arch,
            "python": ["version": "3.12.16", "executable": "python/bin/python3.12"],
            "launcher": "bin/velum-mlx-runtime",
            "adapter": ["protocol": "velum.local-ai.v1", "host": "127.0.0.1", "port": 0, "auth_env": "VELUM_RUNTIME_TOKEN", "models_env": "VELUM_MODELS_DIR"],
            "capabilities": ["chat", "embeddings", "download"], "files": files, "symlinks": links,
            "signing": ["policy": signing], "minimum_macos": "13.0"
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("runtime.json"))
        return root
    }

    // Minimal POSIX tar builder used only to exercise hostile extraction inputs.
    static func tar(name: String, data: Data, type: UInt8 = 48, link: String = "") -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ string: String, at offset: Int, length: Int) {
            let bytes = Array(string.utf8.prefix(length))
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        put(name, at: 0, length: 100)
        put("0000755", at: 100, length: 7)
        put("0000000", at: 108, length: 7); put("0000000", at: 116, length: 7)
        put(String(format: "%011o", data.count), at: 124, length: 11)
        put("00000000000", at: 136, length: 11)
        for index in 148..<156 { header[index] = 32 }
        header[156] = type
        put(link, at: 157, length: 100)
        put("ustar", at: 257, length: 5); put("00", at: 263, length: 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum), at: 148, length: 6)
        header[154] = 0; header[155] = 32
        var result = Data(header); result.append(data)
        if data.count % 512 != 0 { result.append(Data(repeating: 0, count: 512 - data.count % 512)) }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }

    static func run() async throws {
        let fm = FileManager.default
        let temporary = URL(fileURLWithPath: "/Users/Shared", isDirectory: true).appendingPathComponent("velum-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        // This exact UUID-owned temporary subtree is the only cleanup target.
        defer { try? fm.removeItem(at: temporary) }
        let service = LocalRuntimeService(root: temporary.appendingPathComponent("managed ai"))
        var state = try await snapshot(service, op: "status")
        try require(state.installedRuntimes.isEmpty && state.status == .notInstalled, "initial state")
        state = try await snapshot(service, op: "setProxy", proxyURL: "http://127.0.0.1:7890")
        try require(state.proxyURL == "http://127.0.0.1:7890", "explicit proxy saved")
        let sameRootService = LocalRuntimeService(root: temporary.appendingPathComponent("managed ai"))
        let persistedProxy = try await snapshot(sameRootService, op: "status")
        try require(persistedProxy.proxyURL == state.proxyURL, "proxy persists across service recreation")
        for invalid in ["http://example.com:7890", "file:///tmp/proxy", "http://127.0.0.1", "http://user:password@127.0.0.1:7890", "http://127.0.0.1:7890/path", "http://127.0.0.1:7890?secret=1"] {
            try await expectedFailure("unsafe proxy URL") { _ = try await snapshot(service, op: "setProxy", proxyURL: invalid) }
        }
        state = try await snapshot(service, op: "setProxy")
        try require(state.proxyURL == nil, "proxy disabled explicitly")
        print("PASS: optional proxy persistence, disable, validation")
        let one = try fixture(temporary, version: "1.0-dev")
        await tryRejectDevelopment(service: service, bundle: one)
        state = try await snapshot(service, op: "install", source: one, allowDev: true)
        try require(state.installedRuntimes.count == 1 && state.installedRuntimes[0].isActive, "first install active")
        let two = try fixture(temporary, version: "2.0-dev")
        state = try await snapshot(service, op: "install", source: two, allowDev: true)
        try require(state.installedRuntimes.first(where: \.isActive)?.version == "2.0-dev", "upgrade active")
        try require(state.installedRuntimes.first(where: \.isPrevious)?.version == "1.0-dev", "upgrade previous")
        state = try await snapshot(service, op: "install", source: two, allowDev: true)
        try require(state.installedRuntimes.first(where: \.isPrevious)?.version == "1.0-dev", "reinstall retains rollback")
        state = try await snapshot(service, op: "rollback")
        try require(state.installedRuntimes.first(where: \.isActive)?.version == "1.0-dev", "atomic rollback")
        print("PASS: install, immutable reinstall, upgrade, registry rollback")
        try await expectedFailure("hash tampering") {
            try Data("tampered".utf8).write(to: one.appendingPathComponent("service/server.py"))
            _ = try await snapshot(service, op: "install", source: one, allowDev: true)
        }
        let pathTraversal = try fixture(temporary, version: "traversal", extraPath: "../outside")
        try await expectedFailure("manifest path traversal") { _ = try await snapshot(service, op: "install", source: pathTraversal, allowDev: true) }
        let badLink = try fixture(temporary, version: "escaping-link", symlink: "../../../outside")
        try await expectedFailure("escaping symlink") { _ = try await snapshot(service, op: "install", source: badLink, allowDev: true) }
        let absoluteLink = try fixture(temporary, version: "absolute-link", symlink: "/usr/bin/true")
        try await expectedFailure("absolute symlink") { _ = try await snapshot(service, op: "install", source: absoluteLink, allowDev: true) }
        let production = try fixture(temporary, version: "release", signing: "developer-id")
        try await expectedFailure("unauthenticated release manifest") { _ = try await snapshot(service, op: "install", source: production, allowDev: true) }
        let undeclared = try fixture(temporary, version: "undeclared")
        try Data("extra".utf8).write(to: undeclared.appendingPathComponent("extra.py"))
        try await expectedFailure("unlisted files") { _ = try await snapshot(service, op: "install", source: undeclared, allowDev: true) }
        let signatureTamper = try fixture(temporary, version: "signature-tamper")
        let binary = signatureTamper.appendingPathComponent("python/bin/python3.12")
        var changedBinary = try Data(contentsOf: binary)
        changedBinary[4096] ^= 1
        try changedBinary.write(to: binary)
        let manifestURL = signatureTamper.appendingPathComponent("runtime.json")
        var changedManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var changedFiles = changedManifest["files"] as! [String: String]
        changedFiles["python/bin/python3.12"] = SHA256.hash(data: changedBinary).map { String(format: "%02x", $0) }.joined()
        changedManifest["files"] = changedFiles
        try JSONSerialization.data(withJSONObject: changedManifest).write(to: manifestURL)
        try await expectedFailure("native signature tamper even with recomputed hash") {
            _ = try await snapshot(service, op: "install", source: signatureTamper, allowDev: true)
        }
        let hostileTar = temporary.appendingPathComponent("hostile.tar")
        try tar(name: "../outside", data: Data("escape".utf8)).write(to: hostileTar)
        try await expectedFailure("archive path traversal") { _ = try await snapshot(service, op: "install", source: hostileTar, allowDev: true) }
        let hardlinkTar = temporary.appendingPathComponent("hardlink.tar")
        try tar(name: "hardlink", data: Data(), type: 49, link: "outside").write(to: hardlinkTar)
        try await expectedFailure("archive hardlink") { _ = try await snapshot(service, op: "install", source: hardlinkTar, allowDev: true) }
        let deviceTar = temporary.appendingPathComponent("device.tar")
        try tar(name: "device", data: Data(), type: 51).write(to: deviceTar)
        try await expectedFailure("archive special file") { _ = try await snapshot(service, op: "install", source: deviceTar, allowDev: true) }
        try require(!fm.fileExists(atPath: temporary.appendingPathComponent("outside").path), "archive did not write outside staging")
        // The fixture interpreter exits immediately. Verify failed readiness never
        // exposes a token and automatically returns the previous active version.
        try await expectedFailure("failed startup") { _ = try await snapshot(service, op: "start") }
        state = try await snapshot(service, op: "status")
        try require(state.baseURL == nil && state.token == nil && state.status == .crashed, "failed process secret cleanup")
        try require(state.installedRuntimes.first(where: \.isActive)?.version == "2.0-dev", "failed startup rollback")
        _ = try await snapshot(service, op: "stop")
        try await expectedFailure("arbitrary broker command") { _ = try await snapshot(service, op: "exec") }
        if let index = CommandLine.arguments.firstIndex(of: "--bundle"), CommandLine.arguments.count > index + 1 {
            let bundle = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let realService = LocalRuntimeService(root: temporary.appendingPathComponent("real runtime relocated"))
            _ = try await snapshot(realService, op: "install", source: bundle, allowDev: true)
            do {
                let ready = try await snapshot(realService, op: "start")
                try require(ready.status == .ready && ready.baseURL != nil && ready.token?.count == 64, "real readiness")
                try await expectedFailure("install while runtime is running") {
                    _ = try await snapshot(realService, op: "install", source: bundle, allowDev: true)
                }
                try await expectedFailure("proxy change while runtime is running") {
                    _ = try await snapshot(realService, op: "setProxy", proxyURL: "http://127.0.0.1:7890")
                }
                let afterRejectedInstall = try await snapshot(realService, op: "status")
                try require(afterRejectedInstall.status == .ready && afterRejectedInstall.token == ready.token &&
                            afterRejectedInstall.baseURL == ready.baseURL &&
                            afterRejectedInstall.installedRuntimes == ready.installedRuntimes,
                            "rejected running install preserves process and active registry")
                let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
                let session = URLSession(configuration: configuration)
                let healthURL = URL(string: ready.baseURL!)!.appendingPathComponent("health")
                let (_, unauthenticated) = try await session.data(from: healthURL)
                try require((unauthenticated as? HTTPURLResponse)?.statusCode == 401, "unauthenticated health rejected")
                var request = URLRequest(url: healthURL)
                request.setValue("Bearer \(ready.token!)", forHTTPHeaderField: "Authorization")
                let (data, authenticated) = try await session.data(for: request)
                try require((authenticated as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty, "authenticated health")
                let stopped = try await snapshot(realService, op: "stop")
                try require(stopped.status == .stopped && stopped.token == nil && stopped.baseURL == nil, "clean shutdown")
                print("PASS: real relocated CPython launch, port0 handshake, HTTP 401/200, shutdown")
            } catch {
                _ = try? await snapshot(realService, op: "stop")
                throw error
            }
        }
    }

    static func tryRejectDevelopment(service: LocalRuntimeService, bundle: URL) async {
        do {
            _ = try await snapshot(service, op: "install", source: bundle)
            fputs("FAIL: development bundle installed without explicit consent\n", stderr)
            exit(1)
        } catch { print("PASS: development signing requires explicit opt-in") }
    }
}
#endif
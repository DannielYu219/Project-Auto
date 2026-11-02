#if SPLIT_ENGINE_SELF_TEST
import Foundation
import CryptoKit

// Standalone: swiftc -swift-version 6 -D SPLIT_ENGINE_SELF_TEST Split*.swift -o /tmp/split-engine-tests
// Run: /tmp/split-engine-tests <python-base> <custom-echo> [mlx-engine]
@main @MainActor struct SplitEngineSelfTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SplitEngineError.invalid("TEST FAILED: \(message)") }
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { print("PASS rejected \(label)"); return }
        throw SplitEngineError.invalid("TEST FAILED: accepted \(label)")
    }
    static func rejectsAsync(_ label: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { print("PASS rejected \(label)"); return }
        throw SplitEngineError.invalid("TEST FAILED: accepted \(label)")
    }
    static func call(_ service: SplitEngineService, _ object: [String: Any]) async throws -> SplitEngineSnapshot {
        let result = try await service.handle(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        return try JSONDecoder().decode(SplitEngineSnapshot.self, from: Data(result.utf8))
    }
    static func shell(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Test preparation command failed: \(executable)")
    }
    static func tarEntry(_ path: String, type: UInt8 = 48, target: String = "", body: Data = Data()) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ string: String, _ offset: Int, _ maximum: Int) { for (index, byte) in string.utf8.prefix(maximum).enumerated() { header[offset + index] = byte } }
        put(path, 0, 100); put("0000755", 100, 8); put("0000000", 108, 8); put("0000000", 116, 8)
        put(String(format: "%011o", body.count), 124, 12); put("00000000000", 136, 12)
        for index in 148..<156 { header[index] = 32 }
        header[156] = type; put(target, 157, 100); put("ustar", 257, 6); put("00", 263, 2)
        put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), 148, 6); header[154] = 0; header[155] = 32
        var data = Data(header); data.append(body)
        data.append(Data(repeating: 0, count: (512 - body.count % 512) % 512)); return data
    }
    static func archiveTests(_ root: URL) throws {
        let cases: [(String, Data)] = [
            ("parent traversal", tarEntry("../escaped")),
            ("absolute path", tarEntry("/tmp/velum-escape")),
            ("hardlink", tarEntry("hard", type: 49, target: "runtime.json")),
            ("symbolic escape", tarEntry("link", type: 50, target: "../outside")),
            ("device node", tarEntry("device", type: 51)),
            ("duplicate", tarEntry("repeat") + tarEntry("repeat")),
            ("link-parent order", tarEntry("parent", type: 50, target: "inside") + tarEntry("parent/file"))
        ]
        for (label, content) in cases {
            let archive = root.appendingPathComponent(UUID().uuidString + ".tar")
            try (content + Data(repeating: 0, count: 1024)).write(to: archive)
            try rejects(label) { try SplitEngineArchive.extract(archive, to: root.appendingPathComponent(UUID().uuidString)) }
        }
        let archive = root.appendingPathComponent("valid.tar")
        try (tarEntry("folder", type: 53) + tarEntry("folder/value", body: Data("valid".utf8)) + Data(repeating: 0, count: 1024)).write(to: archive)
        let result = root.appendingPathComponent("valid-unpack")
        try SplitEngineArchive.extract(archive, to: result)
        let value = try Data(contentsOf: result.appendingPathComponent("folder/value"))
        try require(value == Data("valid".utf8), "Valid archive extracted incorrectly")
        print("PASS valid archive")
    }
    static func signedManifestTests(_ root: URL, sample: URL) throws {
        let package = root.appendingPathComponent("signed-custom")
        try FileManager.default.copyItem(at: sample, to: package)
        let manifestURL = package.appendingPathComponent("runtime.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let privateKey = Curve25519.Signing.PrivateKey()
        manifest["signing"] = ["policy": "ed25519", "key_id": "test", "team_id": "TESTTEAM"]
        let raw = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try raw.write(to: manifestURL)
        try privateKey.signature(for: raw).write(to: package.appendingPathComponent("runtime.sig"))
        let keys = ["test": privateKey.publicKey.rawRepresentation]
        _ = try SplitEngineValidation.validate(at: package, allowDevelopment: false, trustedKeys: keys)
        print("PASS trusted exact-byte manifest signature")
        try rejects("unknown signing key") { _ = try SplitEngineValidation.validate(at: package, allowDevelopment: false, trustedKeys: [:]) }
        try (raw + Data([32])).write(to: manifestURL)
        try rejects("tampered signed manifest") { _ = try SplitEngineValidation.validate(at: package, allowDevelopment: false, trustedKeys: keys) }
        try raw.write(to: manifestURL)
        try Data("tampered".utf8).write(to: package.appendingPathComponent("service/server.py"))
        try rejects("tampered signed source") { _ = try SplitEngineValidation.validate(at: package, allowDevelopment: false, trustedKeys: keys) }
    }
    static func main() async {
        do { try await run() } catch { print("TEST ERROR: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        guard CommandLine.arguments.count >= 3 else { throw SplitEngineError.invalid("Provide python-base and custom-echo package directories.") }
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true).appendingPathComponent("VelumSplitTests-\(UUID().uuidString)", isDirectory: true)
        try SplitEngineValidation.ensureDirectory(scratch)
        // scratch is the exact freshly created private test directory, never user input.
        defer { try? fm.removeItem(at: scratch) }
        try archiveTests(scratch)
        let sample = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        try signedManifestTests(scratch, sample: sample)
        let app = scratch.appendingPathComponent("Signed App.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try SplitEngineValidation.ensureDirectory(resources)
        let base = resources.appendingPathComponent("python-base", isDirectory: true)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: base)
        let executable = app.appendingPathComponent("Contents/MacOS/TestHost")
        try SplitEngineValidation.ensureDirectory(executable.deletingLastPathComponent())
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let plist: [String: Any] = ["CFBundleExecutable": "TestHost", "CFBundleIdentifier": "ai.velum.split-tests", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let service = SplitEngineService(root: scratch.appendingPathComponent("managed engines"))
        try await rejectsAsync("development without opt-in") { _ = try await call(service, ["op": "install", "source": sample.path]) }
        var snapshot = try await call(service, ["op": "install", "source": sample.path, "allow_development_ad_hoc": true])
        try require(snapshot.installations.count == 1 && snapshot.state == "installed", "Install state")
        let baseStart: [String: Any] = ["op": "start", "engine_id": "custom-echo", "python_base_path": base.path, "model_id": "custom-echo"]
        snapshot = try await call(service, baseStart)
        try require(snapshot.state == "ready" && snapshot.connection != nil, "Start readiness")
        let connection = snapshot.connection!
        var chat = URLRequest(url: URL(string: connection.base_url)!.appendingPathComponent("v1/chat/completions"))
        chat.httpMethod = "POST"; chat.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
        chat.httpBody = try JSONSerialization.data(withJSONObject: ["model": "custom-echo", "messages": [["role": "user", "content": "Swift broker"]]])
        let (answer, response) = try await URLSession.shared.data(for: chat)
        try require((response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: answer, as: UTF8.self).contains("Echo: Swift broker"), "Actual model protocol")
        try await rejectsAsync("concurrent second engine") { _ = try await call(service, ["op": "start", "engine_id": "mlx", "python_base_path": base.path]) }
        try await rejectsAsync("concurrent second model") { _ = try await call(service, ["op": "start", "engine_id": "custom-echo", "model_id": "other", "python_base_path": base.path]) }
        snapshot = try await call(service, ["op": "status"])
        try require(snapshot.state == "ready" && snapshot.connection?.token == connection.token, "Status preserves ready connection")
        snapshot = try await call(service, ["op": "stop"])
        try require(snapshot.state == "stopped" && snapshot.connection == nil, "Stop clears connection")
        print("PASS custom package install/start/chat/status/stop and single-active policy")
        let update = scratch.appendingPathComponent("updated custom")
        try fm.copyItem(at: sample, to: update)
        let updateManifest = update.appendingPathComponent("runtime.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: updateManifest)) as! [String: Any]
        object["version"] = "test-update"
        try JSONSerialization.data(withJSONObject: object).write(to: updateManifest)
        _ = try await call(service, ["op": "install", "source": update.path, "allow_development_ad_hoc": true])
        snapshot = try await call(service, ["op": "rollback", "engine_id": "custom-echo"])
        try require(snapshot.installations.first(where: \.active)?.manifest.version == "2026.11.02-split.1", "Rollback restores prior immutable version")
        print("PASS install update and rollback")
        if CommandLine.arguments.count > 3 {
            _ = try await call(service, ["op": "install", "engine_id": "mlx", "source": URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL.path, "allow_development_ad_hoc": true])
            snapshot = try await call(service, ["op": "start", "engine_id": "mlx", "python_base_path": base.path])
            try require(snapshot.state == "ready" && snapshot.engine_id == "mlx", "Real MLX package readiness")
            _ = try await call(service, ["op": "stop", "engine_id": "mlx"])
            print("PASS real MLX separate package install/start/status/stop")
        }
        print("ALL SPLIT ENGINE TESTS PASSED")
    }
}
#endif

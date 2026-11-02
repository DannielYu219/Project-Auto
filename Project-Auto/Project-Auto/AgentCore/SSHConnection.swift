import Foundation

nonisolated struct SSHCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

nonisolated enum SSHConnectionError: LocalizedError, Sendable {
    case invalidHost
    case missingIdentity
    case missingPassword
    case untrustedHostKey
    case keyChanged
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "SSH 主机地址或用户无效"
        case .missingIdentity: "请先在 ServerBox 选择 SSH 私钥"
        case .missingPassword: "请先在 ServerBox 保存 SSH 密码"
        case .untrustedHostKey: "主机公钥尚未确认；请在 ServerBox 核对指纹并信任"
        case .keyChanged: "主机公钥与保存值不一致；已拒绝连接"
        case .timedOut: "SSH 连接或命令超时"
        case .failed(let message): message
        }
    }
}

/// SSH runs on the host, not inside the VM. Key material stays in a user-selected file.
/// No shell interpolation, password prompts, ProxyCommand, agent forwarding, or unknown-host acceptance.
nonisolated final class SSHConnection: @unchecked Sendable {
    static let shared = SSHConnection()
    private init() {}

    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private let relay: (@Sendable (String, Bool) -> Void)?

        init(relay: (@Sendable (String, Bool) -> Void)?) { self.relay = relay }

        func append(_ data: Data, error: Bool) {
            lock.lock()
            if error { stderr.append(data) } else { stdout.append(data) }
            lock.unlock()
            relay?(String(decoding: data, as: UTF8.self), error)
        }

        func result() -> (String, String) {
            lock.lock()
            defer { lock.unlock() }
            return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
        }
    }

    func exec(host: ServerHost, command: String, timeout: TimeInterval = 60,
              onOutput: (@Sendable (String, Bool) -> Void)? = nil) async throws -> SSHCommandResult {
        guard Self.valid(host) else { throw SSHConnectionError.invalidHost }
        guard !host.trustedHostKeys.isEmpty else { throw SSHConnectionError.untrustedHostKey }
        let liveKeys = try await scanHostKeys(host: host)
        let trustedFingerprints = Set(try await trustedKeyFingerprints(host))
        guard !liveKeys.isEmpty, liveKeys.allSatisfy({ trustedFingerprints.contains($0.fingerprint) }) else {
            throw SSHConnectionError.keyChanged
        }
        let directory = try Self.workingDirectory()
        let knownHosts = directory.appendingPathComponent("known_hosts_\(host.id.uuidString)")
        try Data((host.trustedHostKeys.joined(separator: "\n") + "\n").utf8).write(to: knownHosts, options: .atomic)
        var args = [
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ControlMaster=no",
            "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=15"
        ]
        var extraEnvironment: [String: String] = [:]
        switch host.authentication {
        case .key:
            guard let identity = host.identityPath, !identity.isEmpty else { throw SSHConnectionError.missingIdentity }
            let resolved = try Self.resolveIdentity(host)
            defer { if resolved.scoped { resolved.url.stopAccessingSecurityScopedResource() } }
            args += ["-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                     "-i", resolved.url.path]
        case .password:
            let account = ServerBoxStore.passwordAccount(host.id)
            guard !(AgentKeychain.get(account: account) ?? "").isEmpty else { throw SSHConnectionError.missingPassword }
            let askpass = try Self.askpassScript()
            extraEnvironment = [
                "SSH_ASKPASS": askpass.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": ":0",
                "VELUM_SERVERBOX_HOST_ID": host.id.uuidString.lowercased()
            ]
            args += ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1",
                     "-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no"]
        }
        args += ["-p", String(host.port), "--", "\(host.username)@\(host.hostname)", command]
        let result = try await Self.run(url: URL(fileURLWithPath: "/usr/bin/ssh"),
                                        arguments: args, timeout: timeout, onOutput: onOutput,
                                        extraEnvironment: extraEnvironment)
        if result.stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") ||
           result.stderr.contains("Host key verification failed") {
            throw SSHConnectionError.keyChanged
        }
        return result
    }

    struct HostKey: Sendable {
        let line: String
        let fingerprint: String
    }

    func scanHostKeys(host: ServerHost) async throws -> [HostKey] {
        guard Self.valid(host) else { throw SSHConnectionError.invalidHost }
        let result = try await Self.run(url: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
                                        arguments: ["-T", "8", "-p", String(host.port), host.hostname],
                                        timeout: 12)
        guard result.exitCode == 0 || !result.stdout.isEmpty else {
            throw SSHConnectionError.failed(result.stderr.isEmpty ? "无法获取主机公钥" : result.stderr)
        }
        let lines = result.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        var results: [HostKey] = []
        var seen = Set<String>()
        for line in lines where line.split(separator: " ").count >= 3 {
            let fingerprint = try await fingerprint(for: line)
            guard seen.insert(fingerprint).inserted else { continue }
            results.append(HostKey(line: line, fingerprint: fingerprint))
        }
        return results
    }

    func scanHostKey(host: ServerHost) async throws -> String {
        guard let key = try await scanHostKeys(host: host).first else {
            throw SSHConnectionError.failed("主机未返回有效 SSH 公钥")
        }
        return key.line
    }

    private func trustedKeyFingerprints(_ host: ServerHost) async throws -> [String] {
        var results: [String] = []
        for line in host.trustedHostKeys {
            results.append(try await fingerprint(for: line))
        }
        return results
    }

    func fingerprint(for key: String) async throws -> String {
        let directory = try Self.workingDirectory()
        let file = directory.appendingPathComponent("scan-\(UUID().uuidString).pub")
        try Data((key + "\n").utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await Self.run(url: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                                        arguments: ["-lf", file.path, "-E", "sha256"], timeout: 10)
        guard result.exitCode == 0 else { throw SSHConnectionError.failed(result.stderr) }
        return result.stdout
    }

    private static func valid(_ host: ServerHost) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/:\\'\";|&$`<>"))
        return !host.hostname.isEmpty && !host.username.isEmpty &&
               host.hostname.rangeOfCharacter(from: forbidden) == nil &&
               host.username.rangeOfCharacter(from: forbidden) == nil &&
               (1...65535).contains(host.port)
    }

    private static func resolveIdentity(_ host: ServerHost) throws -> (url: URL, scoped: Bool) {
        guard let data = host.identityBookmark else { throw SSHConnectionError.missingIdentity }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.path == host.identityPath else { throw SSHConnectionError.missingIdentity }
        let scoped = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw SSHConnectionError.missingIdentity
        }
        return (url, scoped)
    }

    private static func askpassScript() throws -> URL {
        let directory = try workingDirectory()
        let script = directory.appendingPathComponent("askpass.sh")
        let body = "#!/bin/sh\nexec /usr/bin/security find-generic-password -s com.lyrastudio.Project-Auto.agent -a \"serverbox_password_${VELUM_SERVERBOX_HOST_ID}\" -w\n"
        try Data(body.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private static func workingDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("VelumServerBox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func run(url: URL, arguments: [String], timeout: TimeInterval,
                            onOutput: (@Sendable (String, Bool) -> Void)? = nil,
                            extraEnvironment: [String: String] = [:]) async throws -> SSHCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
            environment.merge(extraEnvironment) { _, new in new }
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            do { try process.run() }
            catch { throw SSHConnectionError.failed("无法启动 SSH：\(error.localizedDescription)") }
            let capture = PipeCapture(relay: onOutput)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                capture.append(data, error: false)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                capture.append(data, error: true)
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled { process.terminate(); break }
                if Date() >= deadline { process.terminate(); break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // Drain bytes not delivered before EOF/handler removal.
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            if !out.isEmpty { capture.append(out, error: false) }
            if !err.isEmpty { capture.append(err, error: true) }
            let (output, error) = capture.result()
            let timedOut = Date() >= deadline
            if timedOut { throw SSHConnectionError.timedOut }
            if Task.isCancelled { throw CancellationError() }
            return SSHCommandResult(stdout: output, stderr: error,
                                    exitCode: process.terminationStatus, timedOut: false)
        }.value
    }
}

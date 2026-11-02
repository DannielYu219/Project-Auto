import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let velumServerBoxSelectHost = Notification.Name("VelumServerBoxSelectHost")
}

nonisolated enum ServerAuthMethod: String, Codable, Sendable {
    case key, password

    var title: String { self == .key ? "SSH 密钥" : "密码" }
}

nonisolated struct ServerHost: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var name: String = "新主机"
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var identityBookmark: Data?
    var identityPath: String?
    var trustedHostKeys: [String] = []
    /// Optional so profiles written before password authentication still decode.
    var authMethod: ServerAuthMethod? = .key

    var authentication: ServerAuthMethod { authMethod ?? .key }
}

/// Explicit host profiles; identity is a user-selected bookmark and trust requires confirmation.
@MainActor
final class ServerBoxStore: ObservableObject {
    static let shared = ServerBoxStore()
    @Published private(set) var hosts: [ServerHost] = []
    @Published private(set) var errorMessage: String?
    private let storageKey = "velum.serverbox.hosts.v1"
    private var pending: [UUID: [String: String]] = [:]
    private var pendingPreviewLines: [UUID: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let loaded = try? JSONDecoder().decode([ServerHost].self, from: data) {
            hosts = loaded
        }
    }

    @discardableResult
    func addHost() -> UUID {
        let host = ServerHost()
        hosts.append(host)
        persist()
        return host.id
    }

    func update(_ profile: ServerHost) {
        guard let index = hosts.firstIndex(where: { $0.id == profile.id }) else { return }
        if hosts[index].hostname != profile.hostname || hosts[index].port != profile.port {
            var revised = profile
            revised.trustedHostKeys = []
            hosts[index] = revised
        } else { hosts[index] = profile }
        pending.removeValue(forKey: profile.id)
        persist()
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        pending.removeValue(forKey: id)
        AgentKeychain.delete(account: passwordAccount(id))
        persist()
    }

    func chooseIdentity(for id: UUID) async throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { throw SSHConnectionError.invalidHost }
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "使用此密钥"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        hosts[index].identityBookmark = bookmark
        hosts[index].identityPath = url.path
        persist()
    }

    private func passwordAccount(_ id: UUID) -> String { "serverbox_password_\(id.uuidString.lowercased())" }

    func hasPassword(for id: UUID) -> Bool {
        !(AgentKeychain.get(account: passwordAccount(id)) ?? "").isEmpty
    }

    func setPassword(_ value: String, for id: UUID) {
        if value.isEmpty { AgentKeychain.delete(account: passwordAccount(id)) }
        else { try? AgentKeychain.set(value, account: passwordAccount(id)) }
    }

    func deletePassword(for id: UUID) { AgentKeychain.delete(account: passwordAccount(id)) }

    nonisolated static func passwordAccount(_ id: UUID) -> String { "serverbox_password_\(id.uuidString.lowercased())" }

    func hostKeyPreview(id: UUID) async throws -> [String] {
        guard let host = hosts.first(where: { $0.id == id }) else { throw SSHConnectionError.invalidHost }
        let keys = try await SSHConnection.shared.scanHostKeys(host: host)
        pending[id] = Dictionary(uniqueKeysWithValues: keys.map { ($0.fingerprint, $0.line) })
        pendingPreviewLines[id] = keys.map { "\($0.fingerprint)  \($0.line)" }.joined(separator: "\n")
        return keys.map(\.fingerprint)
    }

    func hostKeyPreviewText(id: UUID) -> String? { pendingPreviewLines[id] }

    func trustHostKey(id: UUID, key fingerprint: String) async throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              let rawKey = pending[id]?[fingerprint] else {
            throw SSHConnectionError.failed("请先获取并核对当前主机公钥指纹")
        }
        let actualFingerprint = try await SSHConnection.shared.fingerprint(for: rawKey)
        guard actualFingerprint == fingerprint else { throw SSHConnectionError.keyChanged }
        if !hosts[index].trustedHostKeys.contains(rawKey) { hosts[index].trustedHostKeys.append(rawKey) }
        pending[id]?.removeValue(forKey: fingerprint)
        pendingPreviewLines.removeValue(forKey: id)
        persist()
    }

    func testConnection(id: UUID) async throws -> String {
        guard let host = hosts.first(where: { $0.id == id }) else { throw SSHConnectionError.invalidHost }
        switch host.authentication {
        case .key:
            guard host.identityBookmark != nil, !(host.identityPath ?? "").isEmpty else {
                throw SSHConnectionError.missingIdentity
            }
        case .password:
            guard hasPassword(for: id) else { throw SSHConnectionError.missingPassword }
        }
        let currentFingerprints = try await SSHConnection.shared.scanHostKeys(host: host).map(\.fingerprint)
        let trustedFingerprints = try await trustedFingerprints(for: host)
        guard !currentFingerprints.isEmpty,
              currentFingerprints.allSatisfy({ trustedFingerprints.contains($0) }) else {
            throw SSHConnectionError.untrustedHostKey
        }
        let result = try await SSHConnection.shared.exec(host: host, command: "printf 'Velum SSH connected'", timeout: 25)
        guard result.exitCode == 0 else {
            throw SSHConnectionError.failed(result.stderr.isEmpty ? "连接失败 (\(result.exitCode))" : result.stderr)
        }
        return result.stdout
    }

    private func trustedFingerprints(for host: ServerHost) async throws -> [String] {
        var result: [String] = []
        for key in host.trustedHostKeys {
            result.append(try await SSHConnection.shared.fingerprint(for: key))
        }
        return result
    }

    func host(_ id: UUID) -> ServerHost? { hosts.first(where: { $0.id == id }) }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}

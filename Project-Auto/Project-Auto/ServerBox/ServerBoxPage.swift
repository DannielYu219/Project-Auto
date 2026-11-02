import SwiftUI

/// SSH host profiles and their explicit trust flow.
///
/// The store remains the source of truth. This page owns only transient drafts and
/// the host-key preview state needed to make trust an intentional UI action.
struct ServerBoxPage: View {
    @ObservedObject private var store = ServerBoxStore.shared

    @State private var selection: UUID?
    @State private var nameDraft = ""
    @State private var hostnameDraft = ""
    @State private var portDraft = "22"
    @State private var usernameDraft = ""
    @State private var authMethodDraft: ServerAuthMethod = .key
    @State private var passwordDraft = ""
    @State private var hasStoredPassword = false
    @State private var testTask: Task<Void, Never>?
    @State private var isTesting = false

    @State private var hostKeyPreviewText: String?
    @State private var pendingFingerprints: [String] = []
    @State private var fingerprintToTrust: String?
    @State private var isWorking = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var showingTrustConfirmation = false
    @State private var showingRemoveConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)

            Rectangle()
                .fill(VelumPalette.line)
                .frame(width: 0.5)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(VelumPalette.ink)
        .onAppear(perform: selectInitialHost)
        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
        .onChange(of: selection) { _, id in
            loadDraft(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .velumServerBoxSelectHost)) { note in
            guard let raw = note.userInfo?["id"] as? String,
                  let id = UUID(uuidString: raw),
                  store.hosts.contains(where: { $0.id == id }) else { return }
            selection = id
            loadDraft(id)
        }
        .alert("ServerBox", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "信任此主机公钥？",
            isPresented: $showingTrustConfirmation,
            titleVisibility: .visible
        ) {
            Button("信任并保存") {
                trustPendingHostKey()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确认指纹与主机管理员提供的值一致。信任后，SSH 连接只接受这条公钥。")
        }
        .confirmationDialog(
            "删除此主机？",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除主机", role: .destructive) {
                removeSelectedHost()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已保存的主机设置和信任记录都会被移除。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ServerBox")
                        .font(.system(size: 20, weight: .semibold))
                    Text("安全保存 SSH 主机配置")
                        .font(.system(size: 10))
                        .foregroundStyle(VelumPalette.muted)
                }

                Spacer()

                Button {
                    addHost()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("添加主机")
            }

            if store.hosts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(VelumPalette.muted)
                    Text("还没有主机")
                        .font(.system(size: 12, weight: .medium))
                    Text("添加一台主机开始使用 SSH。")
                        .font(.system(size: 10))
                        .foregroundStyle(VelumPalette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.hosts) { host in
                            hostRow(host)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)

            Text("主机公钥必须逐台核对并明确授权。")
                .font(.system(size: 9))
                .foregroundStyle(VelumPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func hostRow(_ host: ServerHost) -> some View {
        Button {
            selection = host.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: host.trustedHostKeys.isEmpty ? "server.rack" : "checkmark.shield")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(host.trustedHostKeys.isEmpty ? VelumPalette.muted : VelumPalette.blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(host.name.isEmpty ? "未命名主机" : host.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(hostSummary(host))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(VelumPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 52)
            .velumSurface(
                selection == host.id ? .regular : .soft,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除主机", role: .destructive) {
                selection = host.id
                showingRemoveConfirmation = true
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailHeader

                    VStack(alignment: .leading, spacing: 13) {
                        Text("主机设置")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(VelumPalette.muted)

                        field("名称", placeholder: "例如：生产服务器", text: $nameDraft)
                        field("主机地址", placeholder: "example.com 或 192.168.1.20", text: $hostnameDraft)

                        HStack(spacing: 12) {
                            field("端口", placeholder: "22", text: $portDraft)
                                .frame(width: 140)
                            field("用户名", placeholder: "root", text: $usernameDraft)
                        }
                    }

                    identitySection
                    hostKeySection
                    connectionSection

                    if let notice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(VelumPalette.blue)
                    }

                    HStack(spacing: 8) {
                        Button("保存主机") {
                            saveDraft()
                        }
                        .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                        .disabled(isWorking)

                        Button("删除") {
                            showingRemoveConfirmation = true
                        }
                        .buttonStyle(VelumCapsuleButtonStyle())
                        .disabled(isWorking)

                        Spacer()

                        Text("主机地址或端口变更会清除旧信任记录。")
                            .font(.system(size: 9))
                            .foregroundStyle(VelumPalette.muted)
                    }
                }
                .padding(28)
            }
            .scrollIndicators(.hidden)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(VelumPalette.muted)
                Text("选择一台主机，或添加新的主机配置。")
                    .font(.system(size: 12))
                    .foregroundStyle(VelumPalette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(nameDraft.isEmpty ? "主机设置" : nameDraft)
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(1)
                Text("保存后，Agent 可以通过这台主机执行受控 SSH 命令。")
                    .font(.system(size: 10))
                    .foregroundStyle(VelumPalette.muted)
            }

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 5)
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("认证方式")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VelumPalette.muted)

            VelumCapsuleSelection(
                title: "认证方式",
                options: [(ServerAuthMethod.key.title, ServerAuthMethod.key),
                          (ServerAuthMethod.password.title, ServerAuthMethod.password)],
                selection: $authMethodDraft
            ).frame(width: 230)

            if authMethodDraft == .key {
                HStack(spacing: 10) {
                    Image(systemName: selectedHost?.identityPath == nil ? "key" : "key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selectedHost?.identityPath == nil ? VelumPalette.muted : VelumPalette.blue)
                    Text(identityLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("选择私钥") { chooseIdentity() }
                        .buttonStyle(VelumCapsuleButtonStyle())
                        .disabled(isWorking)
                }
                .padding(.horizontal, 12).frame(minHeight: 42)
                .velumSurface(.soft, in: Capsule())
            } else {
                HStack(spacing: 8) {
                    SecureField(hasStoredPassword ? "已保存密码，输入新密码可替换" : "输入 SSH 密码", text: $passwordDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    Button("保存密码") { savePassword() }
                        .buttonStyle(VelumCapsuleButtonStyle())
                        .disabled(passwordDraft.isEmpty)
                    Button("删除") { deletePassword() }
                        .buttonStyle(VelumCapsuleButtonStyle())
                        .disabled(!hasStoredPassword)
                }
                .padding(.horizontal, 12).frame(minHeight: 42)
                .velumSurface(.soft, in: Capsule())
                Text(hasStoredPassword ? "密码保存在本机 Keychain；SSH 通过一次性 askpass 读取，不写入命令行或日志。" : "密码保存在本机 Keychain，不写入主机配置文件。")
                    .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
            }
        }
    }

    private var hostKeySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("主机公钥")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VelumPalette.muted)
                    Text(trustStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(storeTrustColor)
                }

                Spacer()

                Button("获取并核对") {
                    previewHostKey()
                }
                .buttonStyle(VelumCapsuleButtonStyle())
                .disabled(isWorking || !canScanHost)
            }

            if let preview = hostKeyPreviewText {
                VStack(alignment: .leading, spacing: 9) {
                    Text(preview)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        if pendingFingerprints.count == 1, let fingerprint = pendingFingerprints.first {
                            Button("信任此公钥") {
                                fingerprintToTrust = fingerprint
                                showingTrustConfirmation = true
                            }
                            .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                            .disabled(isWorking)
                        }

                        Button("清除预览") {
                            clearHostKeyPreview()
                        }
                        .buttonStyle(VelumCapsuleButtonStyle())
                    }
                }
                .padding(12)
                .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var connectionSection: some View {
        HStack(spacing: 10) {
            Button {
                testConnection()
            } label: {
                Label(isTesting ? "测试中…" : "测试连接", systemImage: "bolt.horizontal")
            }
            .buttonStyle(VelumCapsuleButtonStyle())
            .disabled(isWorking || !canTestConnection)

            if isTesting {
                Button("取消测试") { cancelTest() }
                    .buttonStyle(VelumCapsuleButtonStyle())
            }

            Text(connectionHint)
                .font(.system(size: 10))
                .foregroundStyle(VelumPalette.muted)
                .lineLimit(2)
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VelumPalette.muted)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .velumSurface(.soft, in: Capsule())
        }
    }

    private var selectedHost: ServerHost? {
        guard let selection else { return nil }
        return store.hosts.first(where: { $0.id == selection })
    }

    private var identityLabel: String {
        guard let path = selectedHost?.identityPath, !path.isEmpty else {
            return "尚未选择私钥"
        }
        return path
    }

    private var trustStatus: String {
        guard let host = selectedHost else { return "尚未选择主机" }
        if !host.trustedHostKeys.isEmpty {
            return "已信任 \(host.trustedHostKeys.count) 条主机公钥"
        }
        return "尚未信任主机公钥"
    }

    private var storeTrustColor: Color {
        selectedHost?.trustedHostKeys.isEmpty == false ? VelumPalette.blue : VelumPalette.muted
    }

    private var canScanHost: Bool {
        !hostnameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validPort
    }

    private var canTestConnection: Bool {
        guard canScanHost, !usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = selectedHost, !host.trustedHostKeys.isEmpty else { return false }
        switch authMethodDraft {
        case .key: return host.identityPath != nil
        case .password: return store.hasPassword(for: host.id)
        }
    }

    private var validPort: Bool {
        guard let port = Int(portDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (1...65535).contains(port)
    }

    private var connectionHint: String {
        if selectedHost?.trustedHostKeys.isEmpty != false {
            return "先获取并核对主机公钥，再进行连接测试。"
        }
        if authMethodDraft == .key, selectedHost?.identityPath == nil {
            return "先选择 SSH 私钥，再进行连接测试。"
        }
        if authMethodDraft == .password, !store.hasPassword(for: selectedHost?.id ?? UUID()) {
            return "先保存 SSH 密码，再进行连接测试。"
        }
        return "连接测试会执行一条只读的确认命令。"
    }

    private func hostSummary(_ host: ServerHost) -> String {
        let address = host.hostname.isEmpty ? "未配置地址" : host.hostname
        return "\(host.username.isEmpty ? "未配置用户" : host.username)@\(address):\(host.port)"
    }

    private func selectInitialHost() {
        guard selection == nil else { return }
        selection = store.hosts.first?.id
        loadDraft(selection)
    }

    private func addHost() {
        let id = store.addHost()
        selection = id
        loadDraft(id)
        notice = "已添加主机草稿"
        errorMessage = nil
    }

    private func loadDraft(_ id: UUID?) {
        guard let id, let host = store.hosts.first(where: { $0.id == id }) else {
            if id == nil {
                nameDraft = ""
                hostnameDraft = ""
                portDraft = "22"
                usernameDraft = ""
            }
            clearHostKeyPreview()
            return
        }
        nameDraft = host.name
        hostnameDraft = host.hostname
        portDraft = String(host.port)
        usernameDraft = host.username
        authMethodDraft = host.authentication
        passwordDraft = ""
        hasStoredPassword = store.hasPassword(for: host.id)
        clearHostKeyPreview()
        notice = nil
    }

    @discardableResult
    private func saveDraft(showNotice: Bool = true) -> Bool {
        guard let id = selection else { return false }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = hostnameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "请先填写主机名称。"; return false
        }
        guard !hostname.isEmpty else {
            errorMessage = "请先填写主机地址。"; return false
        }
        guard let port = Int(portDraft.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            errorMessage = "端口必须是 1 到 65535 之间的数字。"; return false
        }
        guard !username.isEmpty else {
            errorMessage = "请先填写 SSH 用户名。"; return false
        }
        guard let existing = store.hosts.first(where: { $0.id == id }) else { return false }

        store.update(ServerHost(
            id: existing.id,
            name: name,
            hostname: hostname,
            port: port,
            username: username,
            identityBookmark: existing.identityBookmark,
            identityPath: existing.identityPath,
            trustedHostKeys: existing.trustedHostKeys,
            authMethod: authMethodDraft
        ))
        if showNotice { notice = "主机设置已保存" }
        errorMessage = nil
        return true
    }

    private func savePassword() {
        guard let id = selection else { return }
        store.setPassword(passwordDraft, for: id)
        passwordDraft = ""
        hasStoredPassword = store.hasPassword(for: id)
        notice = hasStoredPassword ? "SSH 密码已保存到 Keychain" : "SSH 密码已删除"
        errorMessage = nil
    }

    private func deletePassword() {
        guard let id = selection else { return }
        store.deletePassword(for: id)
        passwordDraft = ""
        hasStoredPassword = false
        notice = "SSH 密码已删除"
    }

    private func removeSelectedHost() {
        guard let id = selection else { return }
        store.remove(id: id)
        selection = store.hosts.first?.id
        loadDraft(selection)
        notice = "主机已删除"
    }

    private func chooseIdentity() {
        guard let id = selection else { return }
        isWorking = true
        notice = nil
        Task {
            do {
                try await store.chooseIdentity(for: id)
                await MainActor.run {
                    isWorking = false
                    notice = "SSH 私钥已保存"
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func previewHostKey() {
        guard let id = selection else { return }
        guard saveDraftIfValid(), canScanHost else { return }
        isWorking = true
        notice = nil
        Task {
            do {
                let fingerprints = try await store.hostKeyPreview(id: id)
                let preview = await MainActor.run { store.hostKeyPreviewText(id: id) ?? fingerprints.joined(separator: "\\n") }
                await MainActor.run {
                    hostKeyPreviewText = preview
                    pendingFingerprints = fingerprints
                    fingerprintToTrust = fingerprints.count == 1 ? fingerprints.first : nil
                    isWorking = false
                    notice = "请核对完整 SSH 主机密钥行和 SHA256 指纹"
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func trustPendingHostKey() {
        guard let id = selection, let fingerprint = fingerprintToTrust else { return }
        isWorking = true
        notice = nil
        Task {
            do {
                try await store.trustHostKey(id: id, key: fingerprint)
                await MainActor.run {
                    isWorking = false
                    hostKeyPreviewText = nil
                    pendingFingerprints = []
                    fingerprintToTrust = nil
                    notice = "主机公钥已信任并保存"
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func testConnection() {
        guard let id = selection else { return }
        guard saveDraftIfValid() else { return }
        guard canTestConnection else {
            errorMessage = selectedHost?.trustedHostKeys.isEmpty == false
                ? "请先完成认证配置（私钥或密码）。"
                : "请先获取并信任主机公钥。"
            return
        }
        isWorking = true
        isTesting = true
        notice = nil
        testTask?.cancel()
        testTask = Task {
            do {
                let result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await ServerBoxStore.shared.testConnection(id: id) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(40))
                        throw SSHConnectionError.timedOut
                    }
                    guard let value = try await group.next() else { throw SSHConnectionError.timedOut }
                    group.cancelAll()
                    return value
                }
                guard !Task.isCancelled else { return }
                isWorking = false
                isTesting = false
                testTask = nil
                notice = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "SSH 连接成功"
                    : result.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = nil
            } catch is CancellationError {
                isWorking = false
                isTesting = false
                testTask = nil
                notice = "已取消测试"
            } catch {
                guard !Task.isCancelled else { return }
                isWorking = false
                isTesting = false
                testTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isWorking = false
        isTesting = false
        notice = "已取消测试"
    }

    @discardableResult
    private func saveDraftIfValid() -> Bool {
        saveDraft(showNotice: false)
    }

    private func clearHostKeyPreview() {
        hostKeyPreviewText = nil
        pendingFingerprints = []
        fingerprintToTrust = nil
    }
}

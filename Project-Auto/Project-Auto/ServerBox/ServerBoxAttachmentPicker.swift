import SwiftUI

struct ServerBoxAttachmentPicker: View {
    @ObservedObject private var store = ServerBoxStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var error: String?
    let onAttach: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接到此任务").font(.system(size: 18, weight: .semibold))
            Text("所选主机仅对这次 Agent 会话开放。必须已选择私钥并明确确认主机指纹。")
                .font(.system(size: 11)).foregroundStyle(VelumPalette.muted)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.hosts) { host in
                        Button { selection = host.id } label: {
                            HStack(spacing: 9) {
                                Image(systemName: selection == host.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection == host.id ? VelumPalette.blue : VelumPalette.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.name).font(.system(size: 11, weight: .medium))
                                    Text("\(host.username)@\(host.hostname):\(host.port) · \(host.trustedHostKeys.count) 个可信密钥")
                                        .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10).frame(height: 44)
                            .velumSurface(selection == host.id ? .regular : .soft, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(VelumPalette.danger) }
            HStack {
                Button("取消") { dismiss() }.buttonStyle(VelumCapsuleButtonStyle())
                Spacer()
                Button("连接到任务") { attach() }
                    .buttonStyle(VelumCapsuleButtonStyle(prominent: true)).disabled(selection == nil)
            }
        }
        .padding(20).frame(width: 440, height: 430)
    }

    private func attach() {
        guard let selection, let host = store.host(selection) else { return }
        guard !host.hostname.isEmpty, !host.username.isEmpty,
              host.identityBookmark != nil, !host.trustedHostKeys.isEmpty else {
            error = "请先在 ServerBox 填写连接信息、选择 SSH 私钥并信任主机密钥。"
            return
        }
        onAttach(selection)
        dismiss()
    }
}

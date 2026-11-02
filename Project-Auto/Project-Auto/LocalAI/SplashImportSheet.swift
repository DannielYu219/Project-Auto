import SwiftUI
import UniformTypeIdentifiers

struct SplashImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = EnginePackageManager.shared
    @ObservedObject private var library = LocalModelLibrary.shared
    @State private var targets: [URL] = []
    @State private var draft: URL?
    @State private var mmproj: URL?
    @State private var importing = false
    @State private var error: String?

    private var ggufType: UTType { UTType(filenameExtension: "gguf") ?? .data }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入 Splash 本地模型").font(.system(size: 20, weight: .semibold))
                    Text("分别指定 DFlash2、GGUF 模型本体和可选的 mmproj。")
                        .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26).contentShape(Capsule())
                }.buttonStyle(.plain).help("取消")
            }

            selectionRow(title: "DFlash2", detail: draft?.path ?? "选择 DFlash2 目录（config.json + safetensors）",
                         button: "选择目录") { pickDraft() }
            selectionRow(title: "模型本体", detail: targets.isEmpty ? "选择一个或多个 GGUF（split 分片请一次全选）" : targets.map(\.lastPathComponent).joined(separator: "、"),
                         button: "选择 GGUF") { pickTargets() }
            selectionRow(title: "mmproj", detail: mmproj?.path ?? "可选：视觉投影 GGUF；纯文本模型可跳过",
                         button: mmproj == nil ? "选择文件" : "更换") { pickMMProj() }

            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(VelumPalette.danger).textSelection(.enabled)
            }
            if importing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在复制并准备模型文件，可能需要几分钟…")
                        .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                }
            }
            HStack {
                Text("文件会复制到 Velum 的独立模型目录；不会下载、执行仓库代码或修改引擎包。")
                    .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                Spacer()
                Button(importing ? "导入中…" : "开始导入") { startImport() }
                    .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                    .disabled(importing || draft == nil || targets.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func selectionRow(title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(VelumPalette.muted)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(button, action: action).buttonStyle(VelumCapsuleButtonStyle())
        }
        .padding(.horizontal, 14).frame(minHeight: 58)
        .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pickDraft() {
        let panel = NSOpenPanel()
        panel.title = "选择 DFlash2 目录"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            draft = url
        }
    }

    private func pickTargets() {
        let panel = NSOpenPanel()
        panel.title = "选择 GGUF 模型本体"
        panel.prompt = "使用这些文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [ggufType]
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            targets = panel.urls
        }
    }

    private func pickMMProj() {
        let panel = NSOpenPanel()
        panel.title = "选择 mmproj GGUF"
        panel.prompt = "使用此文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [ggufType]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            mmproj = url
        }
    }

    private func startImport() {
        guard !importing, let draft else { return }
        importing = true
        error = nil
        Task {
            do {
                let staged = try await LocalModelImporter.stageSplash(targets: targets, draft: draft, mmproj: mmproj)
                var body: [String: Any] = [
                    "target": staged.target,
                    "draft": staged.draft,
                    "capability": "chat",
                    "display_name": targets.first?.deletingLastPathComponent().lastPathComponent ?? "local-splash"
                ]
                if let value = staged.mmproj { body["mmproj"] = value }
                let payload = try JSONSerialization.data(withJSONObject: body)
                _ = try await manager.authorizedRequest(engineID: "splash", path: "/control/import",
                                                        method: "POST", body: payload)
                manager.selectedEngineID = "splash"
                await library.refresh()
                importing = false
                dismiss()
            } catch {
                importing = false
                self.error = error.localizedDescription
            }
        }
    }
}

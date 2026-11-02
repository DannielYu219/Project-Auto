import SwiftUI

/// Python is supplied by Velum; MLX, Splash and custom engine packages are independent imports.
struct LocalAIPage: View {
    @ObservedObject private var manager = EnginePackageManager.shared
    @ObservedObject private var library = LocalModelLibrary.shared
    @ObservedObject private var selection = LocalModelSelection.shared
    @State private var development = false
    @State private var useProxy = false
    @State private var busy = false
    @State private var error: String?
    @State private var repo = "mlx-community/embeddinggemma-2-4bit"
    @State private var revision = "8ab839e127cb8cb305edd71fb7a02c82f2d49ab3"
    @State private var capability = "embeddings"
    @State private var showSplashImport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本地 AI").font(.system(size: 24, weight: .semibold))
                        Text("App 仅提供 Python 基座 · 引擎包独立安装 · 无需配置 URL")
                            .font(.system(size: 11)).foregroundStyle(VelumPalette.muted)
                    }
                    Spacer()
                    Text(manager.state).font(.system(size: 11)).foregroundStyle(VelumPalette.muted)
                }
                pythonSection
                Divider()
                enginesSection
                Divider()
                modelsSection
                downloadSection
                if let error = error ?? manager.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(VelumPalette.danger).textSelection(.enabled)
                }
                Text(library.message).font(.system(size: 10)).foregroundStyle(VelumPalette.muted).textSelection(.enabled)
            }.padding(28)
        }
        .foregroundStyle(VelumPalette.ink)
        .task { await manager.refresh(); useProxy = manager.downloadProxy != nil }
        .sheet(isPresented: $showSplashImport) {
            SplashImportSheet()
        }
    }

    private var pythonSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 21, weight: .medium)).foregroundStyle(VelumPalette.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("CPython 3.12.16 · 随 App 提供").font(.system(size: 13, weight: .semibold))
                Text("不含 MLX、模型权重、pip 或其他引擎依赖。")
                    .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            }
            Spacer()
        }
    }

    private var enginesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("独立引擎包").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("导入／更新引擎包…") { Task { await manager.chooseAndInstall(allowDevelopment: development) } }
                    .buttonStyle(VelumCapsuleButtonStyle())
                    .disabled(manager.isRunning)
            }
            ForEach(manager.installations, id: \.id) { installed in
                engineRow(installed)
            }
            if manager.installations.isEmpty {
                Text("导入 MLX、Splash 或符合包协议的自定义引擎。引擎不会写入 App 包。")
                    .font(.system(size: 11)).foregroundStyle(VelumPalette.muted)
            }
            HStack(spacing: 8) {
                Button("启动所选引擎") { perform { try await manager.start(engineID: manager.selectedEngineID); await library.refresh() } }
                    .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                Button("停止") { perform { await manager.stop() } }.buttonStyle(VelumCapsuleButtonStyle())
                Button("回滚所选引擎") { perform { try await manager.rollback(engineID: manager.selectedEngineID) } }
                    .buttonStyle(VelumCapsuleButtonStyle())
                Button("刷新状态") { Task { await manager.refresh() } }.buttonStyle(VelumCapsuleButtonStyle())
            }.disabled(busy)
            Toggle("允许导入可信的自定义／本机开发包（未公证）", isOn: $development)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 10))
            Toggle("下载使用本机代理 127.0.0.1:7890", isOn: $useProxy)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 10)).disabled(manager.isRunning)
                .onChange(of: useProxy) { _, enabled in manager.downloadProxy = enabled ? "http://127.0.0.1:7890" : nil }
            Text("自定义包包含可执行代码；只导入你信任的来源。在线引擎目录尚未配置，当前通过构建包导入。")
                .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
        }
    }

    private func engineRow(_ installed: SplitEngineInstallation) -> some View {
        Button { manager.selectedEngineID = installed.manifest.id } label: {
            HStack(spacing: 9) {
                Image(systemName: manager.selectedEngineID == installed.manifest.id ? "checkmark.circle.fill" : "shippingbox")
                    .foregroundStyle(VelumPalette.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(installed.manifest.id) · \(installed.manifest.version)").font(.system(size: 12))
                    Text("\(installed.manifest.kind) · \(installed.manifest.architecture) · \(installed.manifest.declaredCapabilities.joined(separator: ", "))")
                        .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                }
                Spacer()
                Text(installed.previous ? "上一版本" : installed.active ? "当前版本" : "已安装")
                    .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
            }.padding(12).velumSurface(.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(.plain)
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("刷新所选引擎模型") { Task { await library.refresh() } }.buttonStyle(VelumCapsuleButtonStyle())
            }
            ForEach(library.models.filter { ($0.engineID ?? "mlx") == manager.selectedEngineID }) { model in
                HStack(spacing: 8) {
                    Image(systemName: model.capability == "embeddings" ? "square.3.layers.3d" : "bubble.left.and.text.bubble.right")
                        .foregroundStyle(VelumPalette.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.repo ?? model.id).font(.system(size: 12)).lineLimit(1)
                        Text("\(model.engineID ?? "mlx") · \(model.capability ?? "chat")")
                            .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                    }
                    Spacer()
                    if selection.selected?.id == model.id && (selection.selected?.engineID ?? "mlx") == (model.engineID ?? "mlx") { Text("Agent 当前").font(.system(size: 9)).foregroundStyle(VelumPalette.blue) }
                    Button(model.capability == "embeddings" ? "加载" : "用于 Agent") { Task { await library.load(model) } }
                        .buttonStyle(VelumCapsuleButtonStyle())
                }.padding(12).velumSurface(.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("下载模型 · \(manager.selectedEngineID)").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 7) {
                Button("EmbeddingGemma 2") {
                    repo = "mlx-community/embeddinggemma-2-4bit"
                    revision = "8ab839e127cb8cb305edd71fb7a02c82f2d49ab3"; capability = "embeddings"
                }.buttonStyle(VelumCapsuleButtonStyle()).disabled(manager.selectedEngineID != "mlx")
                Button("Splash Bonsai PQ2_0") {
                    repo = "prism-ml/Ternary-Bonsai-2-27B-gguf"
                    revision = "94dd51cdbbec5309ed8b76a12f3268bc4fdceb93"; capability = "chat"
                }.buttonStyle(VelumCapsuleButtonStyle()).disabled(manager.selectedEngineID != "splash")
            }
            TextField("模型 repo / 模型 ID", text: $repo).textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 12).frame(height: 36).velumSurface(.soft, in: Capsule())
            TextField("固定 revision（MLX 使用 40 位 SHA）", text: $revision).textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 12).frame(height: 36).velumSurface(.soft, in: Capsule())
            HStack {
                VelumCapsuleSelection(title: "用途", options: [("聊天", "chat"), ("向量", "embeddings")], selection: $capability).frame(width: 180)
                Spacer()
                Button(library.downloading ? "下载中…" : "下载") { Task { await library.download(repo: repo, revision: revision, capability: capability) } }
                    .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                    .disabled(library.downloading || (manager.selectedEngineID == "splash" && capability == "embeddings"))
            }
            Text(manager.selectedEngineID == "splash" ? "Splash 仅支持官方列出的模型家族，需配套 DFlash2 draft；不提供 EmbeddingGemma 向量接口。" : "按所选引擎支持的模型架构运行；不执行模型仓库自定义 Python。")
                .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            Divider()
            Text("导入本地模型").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Button("导入 MLX 模型文件夹…") { chooseMLXFolder() }
                    .buttonStyle(VelumCapsuleButtonStyle())
                    .disabled(manager.selectedEngineID != "mlx" || manager.isRunning || busy)
                Button("导入 Splash 模型组…") { showSplashImport = true }
                    .buttonStyle(VelumCapsuleButtonStyle())
                    .disabled(manager.selectedEngineID != "splash" || busy || (manager.isRunning && manager.activeEngineID != "splash"))
            }
            if busy { Text("正在准备本地模型文件…").font(.system(size: 10)).foregroundStyle(VelumPalette.muted) }
            Text(hintForImport)
                .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
        }
    }

    private var hintForImport: String {
        if manager.selectedEngineID == "mlx" {
            return manager.isRunning ? "导入 MLX 模型前请先停止当前引擎。" : "选择包含 config.json 与 safetensors 的本地文件夹；导入后会注册到 MLX 模型列表。"
        }
        return "Splash 导入会分别收集 DFlash2、GGUF 模型本体（可多选 split 分片）和可选 mmproj；不会执行模型仓库代码。"
    }

    private func chooseMLXFolder() {
        guard !manager.isRunning else { error = "请先停止当前引擎，再导入本地模型。"; return }
        let panel = NSOpenPanel()
        panel.title = "选择 MLX 模型文件夹"
        panel.prompt = "导入"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform {
                let modelID = try await LocalModelImporter.importMLX(folder: url, capability: capability)
                try await manager.start(engineID: "mlx")
                await library.refresh()
                self.error = nil
                _ = modelID
            }
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
}

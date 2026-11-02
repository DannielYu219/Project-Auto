import SwiftUI

struct ProvidersPage: View {
    @ObservedObject private var store = ProviderStore.shared
    @ObservedObject private var config = AgentConfig.shared
    @State private var selection: UUID?
    @State private var nameDraft = ""
    @State private var kindDraft: AgentProviderKind = .openAIChat
    @State private var endpointDraft = ""
    @State private var keyDraft = ""
    @State private var availableModels: [String] = []
    @State private var selectedModels: Set<String> = []
    @State private var manualModel = ""
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var saveNote: String?

    var body: some View {
        HStack(spacing: 0) {
            providerList.frame(width: 250)
            Rectangle().fill(VelumPalette.line).frame(width: 0.5)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(VelumPalette.ink)
        .onAppear { selectInitial() }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("供应商").font(.system(size: 20, weight: .semibold))
                    Text("多个运营商共同组成模型列表").font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                }
                Spacer()
                Button {
                    let id = store.addProfile()
                    selection = id
                    loadDraft(id)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28).contentShape(Capsule())
                }
                .buttonStyle(.plain).help("添加供应商")
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.profiles) { profile in
                        Button {
                            selection = profile.id
                            loadDraft(profile.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(profile.kind.title) · \(profile.models.count) 个已选模型")
                                    .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 50)
                            .velumSurface(selection == profile.id ? .regular : .soft,
                                          in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除供应商", role: .destructive) {
                                store.remove(profile.id)
                                selectInitial()
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text("\(store.options.count) 个已选模型").font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var detail: some View {
        if selection != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nameDraft.isEmpty ? "供应商" : nameDraft)
                                .font(.system(size: 22, weight: .semibold))
                            Text(store.selectedProviderID == selection ? "当前使用" : "保存后可设为当前")
                                .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                        }
                        Spacer()
                        if store.selectedProviderID != selection {
                            Button("设为当前") { saveDraft(select: true) }
                                .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                                .disabled(selectedModels.isEmpty)
                        }
                    }
                    field("名称") {
                        TextField("供应商名称", text: $nameDraft).textFieldStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("协议").font(.system(size: 10, weight: .semibold)).foregroundStyle(VelumPalette.muted)
                        VelumCapsuleSelection(
                            title: "协议",
                            options: [("Chat", AgentProviderKind.openAIChat),
                                      ("Responses", .openAIResponses),
                                      ("Anthropic", .anthropicMessages)],
                            selection: $kindDraft
                        ).frame(width: 300)
                    }
                    field("Endpoint") {
                        TextField("https://api.example.com/v1", text: $endpointDraft)
                            .textFieldStyle(.plain)
                    }
                    field("API Key") {
                        HStack(spacing: 8) {
                            SecureField("sk-…", text: $keyDraft).textFieldStyle(.plain)
                            Button("保存 Key") {
                                if let profile = constructedProfile() { store.setAPIKey(keyDraft, for: profile) }
                            }.buttonStyle(VelumCapsuleButtonStyle())
                            Button("删除") {
                                if let profile = constructedProfile() { store.setAPIKey("", for: profile) }
                                keyDraft = ""
                            }.buttonStyle(VelumCapsuleButtonStyle())
                        }
                    }
                    modelSection
                    HStack(spacing: 10) {
                        Button("保存供应商") { saveDraft(select: false) }
                            .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                        if let saveNote {
                            Text(saveNote).font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                        }
                        Spacer()
                        Text("Key 存在 Keychain；只有勾选模型会进入 Agent 列表。")
                            .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                    }
                    Divider()
                    modelChooser
                }
                .padding(28)
            }
        } else {
            Text("选择一个供应商，或新建一个。")
                .font(.system(size: 12)).foregroundStyle(VelumPalette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型列表").font(.system(size: 10, weight: .semibold)).foregroundStyle(VelumPalette.muted)
                    Text("默认全部不勾选；勾选后才进入 Agent 的模型列表。")
                        .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                }
                Spacer()
                Button(fetching ? "获取中…" : "自动获取模型") { fetchModels() }
                    .buttonStyle(VelumCapsuleButtonStyle())
                    .disabled(fetching)
            }
            if availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有模型列表。填写 Endpoint 和 API Key 后从供应商获取，或手动添加。")
                        .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                    manualModelRow
                }
            } else {
                HStack(spacing: 8) {
                    Text("已选 \(selectedModels.count) / \(availableModels.count)")
                        .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                    Spacer()
                    Button("全选") { selectedModels = Set(availableModels) }
                        .buttonStyle(VelumCapsuleButtonStyle())
                    Button("取消全选") { selectedModels = [] }
                        .buttonStyle(VelumCapsuleButtonStyle())
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(availableModels, id: \.self) { model in
                            Button { toggle(model) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: selectedModels.contains(model) ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(selectedModels.contains(model) ? VelumPalette.blue : VelumPalette.muted)
                                    Text(model).font(.system(size: 11)).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).frame(height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if model != availableModels.last {
                                Rectangle().fill(VelumPalette.line.opacity(0.55)).frame(height: 0.5).padding(.leading, 36)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .scrollIndicators(.hidden)
                .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                manualModelRow
            }
            if let fetchError {
                Text(fetchError).font(.system(size: 10)).foregroundStyle(VelumPalette.danger).textSelection(.enabled)
            }
        }
    }

    private var manualModelRow: some View {
        HStack(spacing: 8) {
            TextField("手动添加模型 ID", text: $manualModel)
                .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 34)
                .velumSurface(.soft, in: Capsule())
            Button("添加") { addManualModel() }
                .buttonStyle(VelumCapsuleButtonStyle())
                .disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var modelChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent 当前模型").font(.system(size: 10, weight: .semibold)).foregroundStyle(VelumPalette.muted)
            ForEach(store.options) { option in
                Button {
                    store.select(model: option)
                    config.model = option.modelID
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: store.selectedModel == option.modelID &&
                              store.selectedProviderID == option.providerID
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(VelumPalette.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.modelID).font(.system(size: 11)).lineLimit(1)
                            Text(option.providerName).font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 38)
                    .velumSurface(.soft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(VelumPalette.muted)
            content().padding(.horizontal, 12).frame(height: 38)
                .velumSurface(.soft, in: Capsule())
        }
    }

    private func selectInitial() {
        guard let id = store.selectedProviderID ?? store.profiles.first?.id else { return }
        selection = id
        loadDraft(id)
    }

    private func loadDraft(_ id: UUID?) {
        guard let id, let profile = store.profiles.first(where: { $0.id == id }) else { return }
        selection = id
        nameDraft = profile.name
        kindDraft = profile.kind
        endpointDraft = profile.endpoint
        keyDraft = store.apiKey(for: profile)
        availableModels = profile.availableModels ?? profile.models
        selectedModels = Set(profile.models)
        fetchError = nil
        saveNote = nil
    }

    private func toggle(_ model: String) {
        if selectedModels.contains(model) { selectedModels.remove(model) }
        else { selectedModels.insert(model) }
    }

    private func addManualModel() {
        let value = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !availableModels.contains(value) { availableModels.append(value) }
        selectedModels.insert(value)
        manualModel = ""
    }

    private func fetchModels() {
        guard let profile = constructedProfile() else { return }
        fetching = true
        fetchError = nil
        Task {
            do {
                let fetched = try await store.fetchModels(for: profile)
                await MainActor.run {
                    let previous = selectedModels
                    availableModels = fetched
                    selectedModels = previous.intersection(Set(fetched))
                    fetching = false
                    saveNote = "已获取 \(fetched.count) 个模型，未自动勾选"
                }
            } catch {
                await MainActor.run {
                    fetching = false
                    fetchError = error.localizedDescription
                }
            }
        }
    }

    private func selectedIDs() -> [String] {
        availableModels.filter { selectedModels.contains($0) }
    }

    private func constructedProfile() -> ModelProviderProfile? {
        guard let id = selection else { return nil }
        return ModelProviderProfile(id: id, name: nameDraft, kind: kindDraft,
                                    endpoint: endpointDraft, models: selectedIDs(),
                                    availableModels: availableModels.isEmpty ? nil : availableModels)
    }

    private func saveDraft(select: Bool) {
        guard let profile = constructedProfile() else { return }
        store.update(profile)
        saveNote = "已保存"
        if select {
            store.select(providerID: profile.id, model: profile.models.first ?? "")
            config.model = profile.models.first ?? ""
        }
    }
}

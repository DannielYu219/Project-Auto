import SwiftUI

/// Codex-style model + reasoning control used from the Agent top bar.
struct AgentModelPanel: View {
    @ObservedObject private var store = ProviderStore.shared
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var library = LocalModelLibrary.shared
    @ObservedObject private var localSelection = LocalModelSelection.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("模型").font(.system(size: 11, weight: .semibold))
                Text(localSelection.selected.map { "本地 · \($0.engineID ?? "mlx")" } ?? (store.selectedProfile?.name ?? "未配置"))
                    .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
                Spacer()
                Text(config.reasoningEffort.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VelumPalette.blue)
            }
            if store.options.isEmpty {
                Text("在「供应商」App 中添加模型")
                    .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.options) { option in
                            Button {
                                store.select(model: option)
                                config.model = option.modelID
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected(option) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(isSelected(option) ? VelumPalette.blue : VelumPalette.muted)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(option.modelID).font(.system(size: 11)).lineLimit(1)
                                        Text(option.providerName).font(.system(size: 8)).foregroundStyle(VelumPalette.muted)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 36)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 190)
                .scrollIndicators(.hidden)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(library.models.filter { $0.capability == "chat" }, id: \.key) { model in
                    Button {
                        localSelection.select(model.selection)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: localSelection.selected?.id == model.id && localSelection.selected?.engineID == model.engineID ? "checkmark.circle.fill" : "cpu")
                            Text(model.repo ?? model.id).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text("本地").font(.system(size: 8))
                        }.foregroundStyle(VelumPalette.blue).padding(.horizontal, 8).frame(height: 30)
                    }.buttonStyle(.plain)
                }
                Button("管理本地运行时与模型…") {
                    NotificationCenter.default.post(name: .velumOpenPage, object: nil,
                                                    userInfo: ["page": VelumTab.localAI.rawValue])
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(VelumPalette.blue).padding(.horizontal, 8)
            }
            Rectangle().fill(VelumPalette.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("推理等级").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(config.reasoningEffort.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                ReasoningEffortSlider(effort: $config.reasoningEffort)
                Text(config.reasoningEffort.detail)
                    .font(.system(size: 9)).foregroundStyle(VelumPalette.muted)
            }
        }
    }

    private func isSelected(_ option: ProviderModelOption) -> Bool {
        localSelection.selected == nil && store.selectedProviderID == option.providerID && store.selectedModel == option.modelID
    }
}

/// Continuous but snapped purple track; the white knob and sparkle field mirror Codex.
struct ReasoningEffortSlider: View {
    @Binding var effort: AgentReasoningEffort
    private let levels = AgentReasoningEffort.allCases
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let knob: CGFloat = 30
            let fraction = CGFloat(levels.firstIndex(of: effort) ?? 2) / CGFloat(max(1, levels.count - 1))
            let x = knob / 2 + fraction * (width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.40, green: 0.18, blue: 0.72),
                                                  Color(red: 0.68, green: 0.35, blue: 0.96)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        SparkleField().clipShape(Capsule()).opacity(0.9)
                    }
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
                    .position(x: x, y: geometry.size.height / 2)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let raw = (value.location.x - knob / 2) / max(1, width - knob)
                        let index = Int(round(min(1, max(0, raw)) * CGFloat(levels.count - 1)))
                        let next = levels[index]
                        if next != effort { effort = next }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 32)
        .animation(.snappy(duration: 0.18), value: effort)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("推理等级")
        .accessibilityValue(effort.title)
        .accessibilityAdjustableAction { direction in
            let index = levels.firstIndex(of: effort) ?? 2
            switch direction {
            case .increment: effort = levels[min(levels.count - 1, index + 1)]
            case .decrement: effort = levels[max(0, index - 1)]
            @unknown default: break
            }
        }
    }
}

private struct SparkleField: View {
    var body: some View {
        Canvas { context, size in
            let points: [(CGFloat, CGFloat, CGFloat)] = [
                (0.10, 0.34, 1.6), (0.19, 0.24, 1.0), (0.30, 0.62, 1.5),
                (0.38, 0.22, 1.2), (0.47, 0.48, 1.8), (0.56, 0.28, 1.0),
                (0.64, 0.60, 1.6), (0.72, 0.34, 1.2), (0.80, 0.62, 1.0),
                (0.89, 0.24, 1.4), (0.93, 0.50, 1.0)
            ]
            for (x, y, r) in points {
                let rect = CGRect(x: x * size.width - r, y: y * size.height - r,
                                  width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.75)))
            }
        }
        .allowsHitTesting(false)
    }
}

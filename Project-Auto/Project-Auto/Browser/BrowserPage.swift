import SwiftUI
import WebKit

/// Embed this page in the existing window content switch. Opening it creates one blank tab.
@MainActor
public struct BrowserPage: View {
    @ObservedObject private var controller: BrowserController

    public init(controller: BrowserController = .shared) { self.controller = controller }

    public var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if let error = controller.chromeError ?? controller.selectedTab?.error?.message {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").fontWeight(.bold)
                    Text(error).textSelection(.enabled).lineLimit(3)
                    Spacer(minLength: 4)
                    Button { controller.chromeError = nil; run(.reload) } label: {
                        Image(systemName: "arrow.clockwise").fontWeight(.bold)
                    }
                    .buttonStyle(.plain)
                    .help("重新加载页面")
                }
                .font(.system(size: 11))
                .foregroundStyle(VelumPalette.danger)
                .padding(.horizontal, VelumGeometry.panelContentInset)
                .padding(.bottom, 8)
            }
            ZStack(alignment: .top) {
                if let view = controller.selectedWebView {
                    BrowserWebView(webView: view)
                        .id(controller.selectedTabID)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "globe").font(.system(size: 28, weight: .light))
                        Text("没有打开的标签页").font(.system(size: 13))
                        Button("新标签页") { _ = controller.createTab() }
                            .buttonStyle(VelumCapsuleButtonStyle())
                    }
                    .foregroundStyle(VelumPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if controller.selectedTab?.loading == true {
                    ProgressView(value: controller.selectedTab?.estimatedProgress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(VelumPalette.blue)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: VelumGeometry.panelRadius, style: .continuous))
            .overlay {
                if controller.selectedTab?.isAgentControlled == true {
                    RoundedRectangle(cornerRadius: VelumGeometry.panelRadius, style: .continuous)
                        .strokeBorder(AngularGradient(colors: [.purple, .blue, .pink, .purple],
                                                      center: .center), lineWidth: 2)
                        .shadow(color: .purple.opacity(0.55), radius: 14)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if controller.selectedTab?.isAgentControlled == true {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                        Text("Agent 正在控制").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.purple.opacity(0.82), in: Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, VelumGeometry.contentInset)
            .padding(.bottom, VelumGeometry.contentInset)
        }
        .foregroundStyle(VelumPalette.ink)
        .onAppear {
            controller.openPageIfNeeded()
            controller.chromeError = nil
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(controller.tabs) { tab in
                        let isSelected = controller.selectedTabID == tab.id
                        let isAgent = tab.isAgentControlled
                        let accent = isAgent ? Color.purple : VelumPalette.blue
                        HStack(spacing: 2) {
                            Button {
                                controller.selectTab(tab.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: tab.loading ? "ellipsis" : (isAgent ? "sparkles" : "globe"))
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(isSelected ? accent : (isAgent ? Color.purple.opacity(0.8) : VelumPalette.muted))
                                    Text(tab.title)
                                        .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(isSelected ? accent : VelumPalette.ink)
                                        .lineLimit(1)
                                }
                                .frame(height: 26)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择标签页 \(tab.title)")
                            Button {
                                controller.closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(isSelected ? accent : VelumPalette.muted)
                                    .frame(width: 18, height: 26)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭标签页 \(tab.title)")
                        }
                        .padding(.leading, 9)
                        .padding(.trailing, 3)
                        .frame(width: 120)
                        .velumSurface(isSelected ? .regular : .soft, in: Capsule())
                        .overlay {
                            if isSelected || isAgent {
                                Capsule().fill(accent.opacity(isAgent ? 0.14 : 0.12))
                            }
                        }
                        .overlay {
                            Capsule().strokeBorder(isSelected ? accent.opacity(0.72) : .clear, lineWidth: 1)
                        }
                        .clipShape(Capsule())
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button {
                _ = controller.createTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .velumSurface(.soft, in: Capsule())
            .help("新标签页")
            .accessibilityLabel("新标签页")
        }
        .padding(.horizontal, VelumGeometry.contentInset)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func run(_ action: BrowserAction) {
        controller.chromeError = nil
        Task { controller.chromeError = await controller.execute(action: action).error?.message }
    }
}

@MainActor
private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        BrowserController.shared.prepareForDisplay(webView)
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // Agent tabs return to their offscreen window when the user leaves the tab.
        BrowserController.shared.rehomeIfAgent(nsView)
    }
}

//
//  VelumDesktopWindow.swift
//  Project-Auto
//
//  应用窗口外壳：顶部只承载窗口控制、功能胶囊与侧栏触发器；
//  无居中标题、无标题区横分割线。详情侧栏是同一个表面从右上角展开。
//  这里是原型桌面内的窗口，不是独立 NSWindow。
//

import SwiftUI
import AppKit

struct VelumDesktopWindow: View {
    var windowID: UUID = UUID()
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onMaximize: () -> Void = {}
    var onZoom: () -> Void = {}
    var onTile: (String) -> Void = { _ in }
    var onActivate: () -> Void = {}
    var onDragEnded: (CGSize) -> Void = { _ in }
    var requestedPage = "工作区"
    var isMaximized = false

    @StateObject private var model: VelumWindowModel
    @StateObject private var chat = AgentChatModel()
    @ObservedObject private var agentConfig = AgentConfig.shared
    @ObservedObject private var browser = BrowserController.shared
    @State private var browserAddress = ""
    @FocusState private var browserAddressFocused: Bool
    @State private var layoutMenuVisible = false
    private enum ToolbarMenu { case files, components, settings, model, serverBox }
    @State private var activeToolbarMenu: ToolbarMenu?
    @State private var hoverDismissal: Task<Void, Never>?
    @GestureState private var dragOffset: CGSize = .zero

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private var shouldReduceMotion: Bool { systemReduceMotion || settings.reduceMotion }
    private var shouldReduceTransparency: Bool { systemReduceTransparency || settings.reduceTransparency }
    private var showsInspector: Bool { model.selectedTab == .workspace }

    init(windowID: UUID = UUID(),
         onClose: @escaping () -> Void = {},
         onMinimize: @escaping () -> Void = {},
         onMaximize: @escaping () -> Void = {},
         onZoom: @escaping () -> Void = {},
         onTile: @escaping (String) -> Void = { _ in },
         onActivate: @escaping () -> Void = {},
         onDragEnded: @escaping (CGSize) -> Void = { _ in },
         requestedPage: String = "工作区",
         isMaximized: Bool = false) {
        self.windowID = windowID
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.onMaximize = onMaximize
        self.onZoom = onZoom
        self.onTile = onTile
        self.onActivate = onActivate
        self.onDragEnded = onDragEnded
        self.requestedPage = requestedPage
        self.isMaximized = isMaximized
        _model = StateObject(wrappedValue: VelumWindowModel(initialTab: VelumTab(rawValue: requestedPage) ?? .workspace))
    }

    var body: some View {
        mainWindow
            .overlay(alignment: .topLeading) {
                if layoutMenuVisible {
                    windowLayoutMenu
                        .padding(.leading, 8)
                        .padding(.top, 48)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let menu = activeToolbarMenu {
                    ZStack(alignment: .topTrailing) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { activeToolbarMenu = nil }
                        toolbarDropdown(menu)
                            .padding(.top, 52)
                            .padding(.trailing, VelumGeometry.contentInset)
                    }
                    .transition(.opacity)
                    .zIndex(300)
                }
            }
            .overlay {
                if model.showNotification { notificationToast }
            }
            .simultaneousGesture(TapGesture().onEnded { onActivate() })
            .onAppear {
                AppUIController.shared.register(windowID: windowID, chat: chat, model: model)
                if let tab = VelumTab(rawValue: requestedPage) { model.selectedTab = tab }
                if model.selectedTab == .browser {
                    browser.openPageIfNeeded()
                    browserAddress = browser.addressText
                }
            }
            .onChange(of: model.selectedTab) { _, tab in
                if tab == .browser {
                    browser.openPageIfNeeded()
                    browserAddress = browser.addressText
                }
            }
            .onChange(of: browser.addressText) { _, value in
                if !browserAddressFocused { browserAddress = value }
            }
            .onChange(of: browser.selectedTabID) { _, _ in
                browserAddress = browser.addressText
                browser.chromeError = nil
            }
            .onChange(of: browserAddressFocused) { _, focused in
                if !focused { browserAddress = browser.addressText }
            }
            .onDisappear {
                hoverDismissal?.cancel()
                AppUIController.shared.unregister(windowID: windowID)
            }
            .offset(dragOffset)
            .environment(\.velumSurfaceTint, settings.surfaceTint == .blue ? VelumPalette.blue.opacity(0.12) : .clear)
            .environment(\.velumReduceTransparency, shouldReduceTransparency)
            .preferredColorScheme(.light)
            .tint(VelumPalette.blue)
    }

    private func updateControlsHover(_ inside: Bool) {
        hoverDismissal?.cancel()
        if inside {
            layoutMenuVisible = true
        } else {
            hoverDismissal = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                layoutMenuVisible = false
            }
        }
    }

    @ViewBuilder
    private var browserChrome: some View {
        browserAddressBar
        browserTools
    }

    private var browserAddressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: browser.selectedTab?.url.hasPrefix("https://") == true ? "lock" : "globe")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(VelumPalette.muted)
            TextField("搜索或输入网址", text: $browserAddress)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($browserAddressFocused)
                .onSubmit { submitBrowserAddress() }
                .accessibilityLabel("浏览器地址或搜索")
        }
        .padding(.horizontal, 12)
        .frame(height: VelumGeometry.composerHeight)
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
        .velumSurface(.soft, in: Capsule())
        .overlay {
            Capsule().strokeBorder(browserAddressFocused ? VelumPalette.blue.opacity(0.55) : .clear, lineWidth: 1)
        }
        .disabled(browser.selectedTabID == nil)
    }

    private var browserTools: some View {
        HStack(spacing: 2) {
            browserToolButton("chevron.left", help: "后退", enabled: browser.selectedTab?.canGoBack == true) {
                runBrowser(.back)
            }
            browserToolButton("chevron.right", help: "前进", enabled: browser.selectedTab?.canGoForward == true) {
                runBrowser(.forward)
            }
            browserToolButton("arrow.clockwise", help: "刷新", enabled: browser.selectedTabID != nil) {
                runBrowser(.reload)
            }
        }
        .padding(.horizontal, VelumGeometry.controlInset)
        .frame(height: VelumGeometry.composerHeight)
        .velumSurface(.soft, in: Capsule())
    }

    private func browserToolButton(_ icon: String, help: String, enabled: Bool = true,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: VelumGeometry.controlDiameter, height: VelumGeometry.controlDiameter)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.36)
        .help(help)
        .accessibilityLabel(help)
    }

    private func submitBrowserAddress() {
        let submitted = browserAddress
        browserAddressFocused = false
        Task {
            let result = await browser.submitAddress(submitted)
            browser.chromeError = result.error?.message
            browserAddress = browser.addressText
        }
    }

    private func runBrowser(_ action: BrowserAction) {
        browser.chromeError = nil
        Task { browser.chromeError = await browser.execute(action: action).error?.message }
    }

    @ViewBuilder
    private var appToolbar: some View {
        switch model.selectedTab {
        case .workspace:
            toolbarControl("clock.arrow.circlepath", label: "会话历史") {
                withAnimation(.snappy(duration: 0.2)) {
                    chat.isHistoryVisible.toggle()
                }
            }
            toolbarControl("brain.head.profile", label: "模型与推理") {
                activeToolbarMenu = activeToolbarMenu == .model ? nil : .model
            }
            toolbarControl("plus", label: "新任务") {
                Task { await chat.newConversation() }
            }
        case .files:
            Button {
                activeToolbarMenu = activeToolbarMenu == .files ? nil : .files
            } label: {
                toolbarMenuLabel("folder")
            }
            .buttonStyle(.plain)
            .help("文件")
        case .components:
            Button {
                activeToolbarMenu = activeToolbarMenu == .components ? nil : .components
            } label: {
                toolbarMenuLabel("square.grid.2x2")
            }
            .buttonStyle(.plain)
            .help("组件")
        case .browser:
            toolbarControl("plus", label: "新建浏览器标签页") { BrowserController.shared.createTab() }
        case .providers:
            Button {
                activeToolbarMenu = activeToolbarMenu == .model ? nil : .model
            } label: {
                toolbarMenuLabel("slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("模型与推理")
        case .serverBox:
            Button {
                let id = ServerBoxStore.shared.addHost()
                NotificationCenter.default.post(name: .velumOpenPage, object: nil,
                                                userInfo: ["page": VelumTab.serverBox.rawValue])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(name: .velumServerBoxSelectHost,
                                                    object: nil, userInfo: ["id": id.uuidString])
                }
            } label: {
                toolbarMenuLabel("plus")
            }
            .buttonStyle(.plain)
            .help("添加主机")
        case .localAI:
            toolbarControl("arrow.clockwise", label: "刷新运行时状态") {
                Task { await EnginePackageManager.shared.refresh() }
            }
        case .settings:
            Button {
                activeToolbarMenu = activeToolbarMenu == .settings ? nil : .settings
            } label: {
                toolbarMenuLabel("gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private func toolbarDropdown(_ menu: ToolbarMenu) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch menu {
            case .files:
                dropdownButton("清除搜索") { model.searchText = "" }
                dropdownButton("在 Finder 中打开工作区") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: SmolvmRuntime.defaultWorkspacePath(), isDirectory: true)
                    )
                }
                dropdownButton("挂载 Mac 目录（只读）…") {
                    Task { _ = try? await HostMountCenter.shared.chooseDirectory(readOnly: true) }
                }
                dropdownButton("挂载 Mac 目录（可读写）…") {
                    Task { _ = try? await HostMountCenter.shared.chooseDirectory(readOnly: false) }
                }
                dropdownCaption("AI 产物 /workspace · 授权目录 /mnt/mac")
            case .components:
                dropdownButton("重置展台") {
                    NotificationCenter.default.post(name: .velumResetComponents, object: nil)
                }
                dropdownCaption("展台数值只影响本页")
            case .model:
                AgentModelPanel()
            case .serverBox:
                dropdownCaption("添加主机、选择 SSH 私钥并信任主机指纹")
            case .settings:
                Toggle("降低透明度", isOn: $settings.reduceTransparency)
                    .toggleStyle(.switch).controlSize(.small)
                    .padding(.horizontal, 8).frame(height: 32)
                Toggle("降低动态效果", isOn: $settings.reduceMotion)
                    .toggleStyle(.switch).controlSize(.small)
                    .padding(.horizontal, 8).frame(height: 32)
                Rectangle().fill(VelumPalette.line).frame(height: 1).padding(.vertical, 4)
                dropdownButton("恢复默认外观") { settings.reset() }
            }
        }
        .padding(10)
        .frame(width: menu == .model ? 300 : 220, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.7)
                }
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }

    private func dropdownButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            activeToolbarMenu = nil
        } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(VelumPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dropdownCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(VelumPalette.muted)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    private func toolbarMenuLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(VelumPalette.ink)
            .frame(width: VelumGeometry.controlDiameter, height: VelumGeometry.controlDiameter)
            .contentShape(Capsule())
    }

    private var windowLayoutMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("窗口布局").font(.system(size: 11, weight: .semibold)).foregroundStyle(VelumPalette.muted)
            HStack(spacing: 8) {
                layoutOption("rectangle.lefthalf.filled", "左半屏", "left")
                layoutOption("rectangle.righthalf.filled", "右半屏", "right")
                layoutOption("rectangle.tophalf.filled", "上半屏", "top")
                layoutOption("rectangle.bottomhalf.filled", "下半屏", "bottom")
            }
            HStack(spacing: 8) {
                layoutOption("rectangle.split.2x1", "双窗口分屏", "pair")
                layoutOption("arrow.up.left.and.arrow.down.right", "恢复大小", "restore")
                Button {
                    layoutMenuVisible = false
                    onMaximize()
                } label: {
                    Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 42, height: 32)
                }.buttonStyle(VelumCapsuleButtonStyle()).help(isMaximized ? "退出桌面全屏" : "桌面全屏")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .onHover(perform: updateControlsHover)
    }

    private func layoutOption(_ symbol: String, _ title: String, _ placement: String) -> some View {
        Button {
            layoutMenuVisible = false
            onTile(placement)
        } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                .frame(width: 28, height: 32)
        }
        .buttonStyle(VelumCapsuleButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private var mainWindow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Invisible capsule: same height/inset system as the composer.
                HStack(spacing: 4) {
                    windowControl("xmark", label: "关闭窗口")
                    windowControl("minus", label: "最小化窗口")
                    windowControl("square", label: "缩放窗口")
                }
                .padding(.horizontal, VelumGeometry.controlInset)
                .frame(height: VelumGeometry.composerHeight)
                .background(Color.clear, in: Capsule())
                .offset(x: -4, y: -4)
                .onHover(perform: updateControlsHover)

                if model.selectedTab == .browser {
                    browserChrome
                } else {
                    Spacer(minLength: 12)

                    HStack(spacing: 4) {
                        appToolbar
                    }
                    .padding(.horizontal, VelumGeometry.controlInset)
                    .frame(height: VelumGeometry.composerHeight)
                    .velumSurface(.soft, in: Capsule())
                }

                // Reserve the inspector's current width, plus the same 12pt gap
                // used between the expanded inspector and the composer.
                if showsInspector {
                    Color.clear
                        .frame(width: (model.detailsVisible ? VelumGeometry.inspectorWidth : VelumGeometry.inspectorButtonSize)
                               + VelumGeometry.contentInset - 8,
                               height: VelumGeometry.inspectorButtonSize)
                }
            }
            .padding(.horizontal, VelumGeometry.contentInset)
            .padding(.top, VelumGeometry.contentInset)
            .padding(.bottom, 4)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(windowDrag)
            }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, showsInspector && model.detailsVisible ? VelumGeometry.inspectorReservation : 0)
            if model.selectedTab == .workspace {
                VStack(alignment: .leading, spacing: 6) {
                    if !chat.attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(chat.attachments, id: \.self) { url in
                                    HStack(spacing: 5) {
                                        Image(systemName: "paperclip").font(.system(size: 9, weight: .semibold))
                                        Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1)
                                        Button { chat.removeAttachment(url) } label: {
                                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                        }.buttonStyle(.plain).accessibilityLabel("移除附件")
                                    }
                                    .foregroundStyle(VelumPalette.muted).padding(.horizontal, 10).frame(height: 24)
                                    .velumSurface(.soft, in: Capsule())
                                }
                            }
                        }
                    }
                    if let hostID = chat.attachedServerHostID {
                        HStack(spacing: 5) {
                            Image(systemName: "server.rack").font(.system(size: 9, weight: .semibold))
                            Text(chat.attachedServerName ?? "远程主机").font(.system(size: 10)).lineLimit(1)
                            Button { chat.detachServerHost(hostID) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }.buttonStyle(.plain).help("移除远程主机")
                        }.padding(.horizontal, 9).frame(height: 24).velumSurface(.soft, in: Capsule())
                    }
                    VelumComposer(
                        message: $chat.draft,
                        providerLabel: agentConfig.effectiveModelDisplayName,
                        isStreaming: chat.isStreaming,
                        onSend: { chat.send() },
                        onStop: { chat.stop() },
                        onAttach: { chat.chooseAttachments() },
                        onAttachServer: { chat.attachServerHost() }
                    )
                    .popover(isPresented: $chat.isServerPickerPresented, arrowEdge: .top) {
                        ServerBoxAttachmentPicker(onAttach: { id in
                            chat.setServerAttachment(id)
                        })
                    }
                }
                .padding(.leading, VelumGeometry.composerInset)
                .padding(.trailing, VelumGeometry.composerInset +
                         (showsInspector && model.detailsVisible ? VelumGeometry.inspectorReservation : 0))
                .padding(.bottom, VelumGeometry.composerInset)
                .padding(.top, 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsInspector {
                GeometryReader { geometry in
                    inspectorSurface(availableHeight: geometry.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .padding(VelumGeometry.contentInset)
            }
        }
        .velumSurface(.regular,
                      in: RoundedRectangle(cornerRadius: isMaximized ? 0 : VelumGeometry.windowRadius,
                                           style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: isMaximized ? 0 : VelumGeometry.windowRadius,
                                   style: .continuous))
        // Keep the moving window as one composited layer. Without this, the large
        // material surface and its shadow are resampled every drag frame.
        .compositingGroup()
        .shadow(color: VelumPalette.blue.opacity(0.2), radius: 28, y: 12)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.selectedTab {
        case .workspace:
            WorkspacePage(chat: chat,
                          approvals: chat.approvalCenter,
                          onOpenSettings: {
                              NotificationCenter.default.post(name: .velumOpenPage,
                                                              object: nil,
                                                              userInfo: ["page": VelumTab.settings.rawValue])
                          })
        case .files:
            FilesPage(model: model)
        case .components:
            ComponentsPage(onNotify: notify)
        case .browser:
            BrowserPage()
        case .providers:
            ProvidersPage()
        case .serverBox:
            ServerBoxPage()
        case .localAI:
            LocalAIPage()
        case .settings:
            SettingsPage()
        }
    }

    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                onDragEnded(value.translation)
            }
    }

    private func toolbarControl(_ symbol: String, label: String, enabled: Bool = true,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(VelumPalette.ink)
                .frame(width: VelumGeometry.controlDiameter, height: VelumGeometry.controlDiameter)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
    }

    private func windowControl(_ symbol: String, label: String) -> some View {
        Button {
            layoutMenuVisible = false
            switch symbol {
            case "xmark": onClose()
            case "minus": onMinimize()
            default:
                // 事件级修饰键判断：键盘或辅助操作下不会误读全局状态。
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { onZoom() }
                else { onMaximize() }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: VelumGeometry.controlDiameter, height: VelumGeometry.controlDiameter)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // A single persistent surface expands from the same top-right button.
    // Its top/right inset and corner radius do not change during expansion.
    private func inspectorSurface(availableHeight: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            if model.detailsVisible {
                detailPanel
                    .padding(.top, VelumGeometry.inspectorButtonSize)
                    .transition(.opacity)
            }
            Button {
                withAnimation(shouldReduceMotion ? nil : .snappy(duration: 0.28)) {
                    model.detailsVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(model.detailsVisible ? VelumPalette.ink : VelumPalette.muted)
                    .frame(width: VelumGeometry.inspectorButtonSize,
                           height: VelumGeometry.inspectorButtonSize)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(model.detailsVisible ? "收起任务详情" : "展开任务详情")
            .accessibilityLabel(model.detailsVisible ? "收起任务详情" : "展开任务详情")
            .accessibilityValue(model.detailsVisible ? "已展开" : "已收起")
        }
        .frame(width: model.detailsVisible ? VelumGeometry.inspectorWidth : VelumGeometry.inspectorButtonSize,
               height: model.detailsVisible ? availableHeight : VelumGeometry.inspectorButtonSize,
               alignment: .topTrailing)
        .velumSurface(.soft,
                      in: VelumTextShape(singleLineHeight: VelumGeometry.inspectorButtonSize))
        .clipShape(VelumTextShape(singleLineHeight: VelumGeometry.inspectorButtonSize))
        .shadow(color: VelumPalette.blue.opacity(0.12), radius: 10, x: -2, y: 4)
    }

    private var detailPanel: some View {
        AgentInspector(chat: chat)
    }

    private var notificationToast: some View {
        VStack {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle").foregroundStyle(VelumPalette.blue)
                Text("操作已在本地预览").font(.system(size: 12, weight: .medium))
                Button { model.showNotification = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .velumSurface(.soft, in: Capsule())
            .padding(.top, 64)
            Spacer()
        }
    }

    // 应用内提示可以在设置里关掉；关掉后不再出现这条胶囊提示。
    private func notify() {
        guard settings.inAppToast else { return }
        withAnimation(shouldReduceMotion ? nil : .snappy(duration: 0.24)) {
            model.showNotification = true
        }
    }
}



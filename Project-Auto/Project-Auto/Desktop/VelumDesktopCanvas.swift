//
//  VelumDesktopCanvas.swift
//  Project-Auto
//
//  原型桌面：壁纸层、独立 Dock（启动台 + 四个应用）、窗口摆放与管理、启动台。
//  全屏是原型桌面内全屏，不是 macOS 独立 Space；多个窗口是同一 SwiftUI
//  桌面内的窗口模型，不是多个 NSWindow 应用进程。
//

import SwiftUI

struct VelumDesktopCanvas: View {
    @State private var windows: [DesktopWindowItem] = []
    @State private var activeID: UUID?
    @State private var launcherVisible = false
    @State private var dockRevealed = false
    @State private var dockDismissal: Task<Void, Never>?
    @State private var dockAutoHide: Task<Void, Never>?
    // Applications may declare a launch mode; normal windows share the desktop default.
    private let manifests: [String: DesktopAppManifest] = [:]

    private var activeFullscreen: Bool {
        windows.contains { $0.id == activeID && $0.fullscreen && !$0.minimized }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.30, green: 0.65, blue: 0.82),
                                        Color(red: 0.15, green: 0.34, blue: 0.57)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                            launcherVisible.toggle()
                        }
                    } label: {
                        Image("DockLauncher")
                            .resizable().interpolation(.high).scaledToFit()
                            .frame(width: 44, height: 44)
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(.plain)
                    .help("启动台")
                    .accessibilityLabel("启动台")
                    ForEach(VelumTab.allCases) { tab in
                        dockApplication(tab.rawValue, in: geometry.size)
                    }
                }
                .velumSurface(.soft, in: Capsule())
                .position(x: activeFullscreen && !dockRevealed ? -48 : 48, y: geometry.size.height / 2)
                .onHover { inside in
                    dockDismissal?.cancel()
                    if inside {
                        dockRevealed = true
                        scheduleDockAutoHide()
                    } else {
                        dockAutoHide?.cancel()
                        dockDismissal = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            dockRevealed = false
                        }
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: dockRevealed)
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: activeFullscreen)
                .zIndex(201)

                if activeFullscreen {
                    Color.clear.frame(width: 3, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                dockDismissal?.cancel()
                                dockRevealed = true
                                scheduleDockAutoHide()
                            }
                        }
                        .zIndex(202)
                }

                ForEach(Array(windows.enumerated()), id: \.element.id) { index, item in
                    let visibleFrame = resolvedFrame(for: item, in: geometry.size)
                    Group {
                        VelumDesktopWindow(
                            windowID: item.id,
                            onClose: {
                                windows.removeAll { $0.id == item.id }
                                activeID = windows.last(where: { !$0.minimized })?.id
                            },
                            onMinimize: { minimize(item.id) },
                            onMaximize: { toggleFullscreen(item.id, in: geometry.size) },
                            onZoom: { toggleMaximized(item.id, in: geometry.size) },
                            onTile: { tile(item.id, placement: $0, in: geometry.size) },
                            onActivate: {
                                activeID = item.id
                                collapseDock()
                            },
                            onDragEnded: { commitDrag(item.id, translation: $0, in: geometry.size) },
                            requestedPage: item.page == "Agent" ? "工作区" : item.page,
                            isMaximized: item.fullscreen
                        )
                        .frame(width: visibleFrame.width, height: visibleFrame.height)
                        .overlay(alignment: .bottomTrailing) {
                            if !item.fullscreen && !item.maximized {
                                Image(systemName: "line.3.diagonal")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(VelumPalette.muted)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                                    .padding(3)
                                    .help("拖动调整窗口大小")
                                    .accessibilityLabel("调整窗口大小")
                                    .gesture(
                                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                            .onChanged { value in
                                                activeID = item.id
                                                resize(item.id, translation: value.translation, in: geometry.size)
                                            }
                                            .onEnded { _ in mutate(item.id) { $0.resizeOrigin = nil } }
                                    )
                            }
                        }
                        .scaleEffect(item.minimized && !reduceMotion ? 0.06 : 1)
                        .opacity(item.minimized ? 0 : 1)
                        .position(item.minimized ? dockPoint(for: item.page, in: geometry.size) :
                                    CGPoint(x: visibleFrame.midX, y: visibleFrame.midY))
                        .allowsHitTesting(!item.minimized)
                        .accessibilityHidden(item.minimized)
                        .zIndex(activeID == item.id ? 100 : Double(index + 1))
                        .id(item.id)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .velumOpenPage)) { note in
                if let page = note.userInfo?["page"] as? String {
                    open(page, in: geometry.size)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .velumActivateWindow)) { note in
                if let raw = note.userInfo?["id"] as? String, let id = UUID(uuidString: raw) {
                    activeID = id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .velumCloseWindow)) { note in
                if let raw = note.userInfo?["id"] as? String, let id = UUID(uuidString: raw) {
                    windows.removeAll { $0.id == id }
                    activeID = windows.last(where: { !$0.minimized })?.id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .velumMinimizeWindow)) { note in
                if let raw = note.userInfo?["id"] as? String, let id = UUID(uuidString: raw) {
                    minimize(id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .velumMaximizeWindow)) { note in
                if let raw = note.userInfo?["id"] as? String, let id = UUID(uuidString: raw) {
                    toggleFullscreen(id, in: geometry.size)
                }
            }
            .overlay {
                if launcherVisible {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                                    launcherVisible = false
                                }
                            }
                        VStack(alignment: .leading, spacing: 22) {
                            HStack {
                                Text("启动台").font(.system(size: 20, weight: .semibold))
                                Spacer()
                                Button {
                                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                                        launcherVisible = false
                                    }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                                }.buttonStyle(VelumCapsuleButtonStyle())
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 32)], spacing: 32) {
                                ForEach(VelumTab.allCases) { app in
                                    Button {
                                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                                            launcherVisible = false
                                        }
                                        open(app.rawValue, in: geometry.size)
                                    } label: {
                                        VStack(spacing: 10) {
                                            appIcon(app)
                                                .frame(width: 72, height: 72)
                                            Text(app.rawValue).font(.system(size: 13, weight: .medium))
                                        }.frame(height: 120)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 100)
                        .padding(.top, 64)
                        .padding(.bottom, 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear {
                AppUIController.shared.update(windows: windows, activeID: activeID)
            }
            .onChange(of: uiSignature) { _, _ in
                AppUIController.shared.update(windows: windows, activeID: activeID)
            }
            .onChange(of: geometry.size) { _, size in
                for item in windows {
                    mutate(item.id) { window in
                        if window.fullscreen { window.frame = fullscreenFrame(in: size) }
                        else if window.maximized { window.frame = maximizedFrame(in: size) }
                        else if !window.userAdjusted {
                            window.frame = defaultFrame(in: size)
                        } else {
                            window.frame.size.width = min(window.frame.width, max(360, size.width - 120))
                            window.frame.size.height = min(window.frame.height, max(300, size.height - 90))
                            window.frame.origin.x = min(max(100, window.frame.minX),
                                                        max(100, size.width - window.frame.width))
                            window.frame.origin.y = min(max(8, window.frame.minY),
                                                        max(8, size.height - window.frame.height - 12))
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(VelumPalette.blue)
    }

    private var uiSignature: [String] {
        windows.map { item in
            "\(item.id)|\(item.page)|\(item.frame.origin.x)|\(item.frame.origin.y)|\(item.frame.width)|\(item.frame.height)|\(item.minimized)|\(item.fullscreen)|\(item.maximized)|\(item.id == activeID)"
        }
    }

    private func mutate(_ id: UUID, _ update: (inout DesktopWindowItem) -> Void) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        update(&windows[index])
    }

    private func resolvedFrame(for item: DesktopWindowItem, in size: CGSize) -> CGRect {
        if item.fullscreen { return fullscreenFrame(in: size) }
        if item.maximized { return maximizedFrame(in: size) }
        return item.userAdjusted ? item.frame : defaultFrame(in: size)
    }

    private func defaultFrame(in size: CGSize) -> CGRect {
        let area = maximizedFrame(in: size)
        let width = area.width * 0.675
        let height = area.height * 0.69
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private func maximizedFrame(in size: CGSize) -> CGRect {
        CGRect(x: 108, y: 12, width: max(1, size.width - 120), height: max(1, size.height - 24))
    }

    private func fullscreenFrame(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    private func newWindow(_ page: String = "工作区", in size: CGSize) {
        var item = DesktopWindowItem()
        item.page = page
        let manifest = manifests[page] ?? DesktopAppManifest()
        item.frame = defaultFrame(in: size)
        // Place independently; do not copy another application's dimensions.
        let area = maximizedFrame(in: size)
        let step = CGFloat(windows.count % 5) * 30
        item.frame.origin.x = min(max(area.minX, item.frame.minX + step), area.maxX - item.frame.width)
        item.frame.origin.y = min(max(area.minY, item.frame.minY + step), area.maxY - item.frame.height)
        if let front = windows.first(where: { $0.id == activeID }),
           abs(front.frame.minX - item.frame.minX) < 20,
           abs(front.frame.minY - item.frame.minY) < 20 {
            item.frame.origin.x = item.frame.minX + 36 <= area.maxX - item.frame.width
                ? item.frame.minX + 36 : max(area.minX, item.frame.minX - 36)
            item.frame.origin.y = item.frame.minY + 30 <= area.maxY - item.frame.height
                ? item.frame.minY + 30 : max(area.minY, item.frame.minY - 30)
        }
        item.userAdjusted = true // Preserve the newly computed cascade position.
        switch manifest.defaultMode {
        case .windowed: break
        case .maximized:
            item.savedFrame = item.frame
            item.maximized = true
            item.frame = maximizedFrame(in: size)
        case .fullscreen:
            item.savedFrame = item.frame
            item.fullscreen = true
            item.frame = fullscreenFrame(in: size)
        }
        windows.append(item)
        activeID = item.id
    }

    private func dockPoint(for page: String, in size: CGSize) -> CGPoint {
        let index = VelumTab.allCases.firstIndex(where: { $0.rawValue == page }) ?? 0
        return CGPoint(x: 48, y: size.height / 2 - 64 + CGFloat(index) * 64)
    }

    @ViewBuilder
    private func appIcon(_ app: VelumTab) -> some View {
        if app == .browser || app == .providers || app == .serverBox || app == .localAI {
            let icon: String = switch app {
            case .browser: "globe"
            case .providers: "server.rack"
            case .serverBox: "externaldrive.connected.to.line.below"
            case .localAI: "cpu"
            default: "globe"
            }
            let color = app == .browser ? VelumPalette.blue
                : (app == .providers ? Color(red: 0.36, green: 0.28, blue: 0.64) : Color(red: 0.18, green: 0.55, blue: 0.48))
            ZStack {
                Circle().fill(color.gradient)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
            }
        } else {
            Image(app.dockIcon).resizable().interpolation(.high).scaledToFit()
        }
    }

    private func dockApplication(_ page: String, in size: CGSize) -> some View {
        let session = windows.first(where: { $0.page == page })
        let active = session.map { $0.id == activeID && !$0.minimized } ?? false
        let status = session == nil ? "未启动"
            : session!.minimized ? "已最小化，点击恢复"
            : active ? "当前运行" : "正在运行"
        let icon = VelumTab(rawValue: page)?.dockIcon ?? "DockWorkspace"
        return Button { open(page, in: size) } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(active ? 0.10 : 0))
                    .frame(width: 48, height: 48)
                appIcon(VelumTab(rawValue: page) ?? .workspace)
                    .frame(width: 44, height: 44)
                    .frame(width: 64, height: 64)
                if session != nil {
                    VelumSessionRing(active: active, minimized: session?.minimized == true)
                        .frame(width: 46, height: 46)
                }
            }
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(page) · \(status)")
        .accessibilityLabel(page)
        .accessibilityValue(status)
    }

    private func minimize(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            mutate(id) { $0.minimized = true }
            activeID = windows.last(where: { !$0.minimized })?.id
        }
    }

    private func open(_ page: String, in size: CGSize) {
        collapseDock()
        if let session = windows.first(where: { $0.page == page }) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                mutate(session.id) { $0.minimized = false }
                activeID = session.id
            }
        } else {
            newWindow(page, in: size)
        }
    }

    private func toggleFullscreen(_ id: UUID, in size: CGSize) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            mutate(id) { item in
                if !item.userAdjusted {
                    item.frame = defaultFrame(in: size)
                    item.userAdjusted = true
                }
                if item.fullscreen {
                    item.fullscreen = false
                    item.frame = item.maximized ? maximizedFrame(in: size)
                        : item.savedFrame ?? defaultFrame(in: size)
                    if !item.maximized { item.savedFrame = nil }
                } else {
                    if !item.maximized { item.savedFrame = item.frame }
                    item.frame = fullscreenFrame(in: size)
                    item.fullscreen = true
                }
            }
            dockRevealed = false
            activeID = id
        }
    }

    private func toggleMaximized(_ id: UUID, in size: CGSize) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            mutate(id) { item in
                if !item.userAdjusted {
                    item.frame = defaultFrame(in: size)
                    item.userAdjusted = true
                }
                if item.maximized {
                    item.frame = item.savedFrame ?? defaultFrame(in: size)
                    item.maximized = false
                    item.savedFrame = nil
                } else {
                    if !item.fullscreen { item.savedFrame = item.frame }
                    item.frame = maximizedFrame(in: size)
                    item.maximized = true
                }
                item.fullscreen = false
            }
            dockRevealed = false
            activeID = id
        }
    }

    private func commitDrag(_ id: UUID, translation: CGSize, in size: CGSize) {
        guard translation != .zero else { return }
        mutate(id) { item in
            guard !item.fullscreen && !item.maximized else { return }
            if !item.userAdjusted { item.frame = defaultFrame(in: size) }
            item.userAdjusted = true
            let origin = item.frame.origin
            item.frame.origin.x = min(max(0, origin.x + translation.width),
                                      max(0, size.width - item.frame.width))
            item.frame.origin.y = min(max(0, origin.y + translation.height),
                                      max(0, size.height - 100))
        }
    }

    private func scheduleDockAutoHide() {
        guard activeFullscreen else { return }
        dockAutoHide?.cancel()
        dockAutoHide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                dockRevealed = false
            }
        }
    }

    private func collapseDock() {
        dockAutoHide?.cancel()
        dockAutoHide = nil
        dockDismissal?.cancel()
        dockDismissal = nil
        if dockRevealed {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                dockRevealed = false
            }
        }
    }

    private func resize(_ id: UUID, translation: CGSize, in size: CGSize) {
        mutate(id) { item in
            guard !item.fullscreen && !item.maximized else { return }
            if !item.userAdjusted { item.frame = defaultFrame(in: size) }
            item.userAdjusted = true
            if item.resizeOrigin == nil { item.resizeOrigin = item.frame }
            guard let origin = item.resizeOrigin else { return }
            let availableWidth = max(1, size.width - origin.minX - 8)
            let availableHeight = max(1, size.height - origin.minY - 8)
            item.frame.size.width = min(availableWidth,
                                        max(min(440, availableWidth), origin.width + translation.width))
            item.frame.size.height = min(availableHeight,
                                         max(min(320, availableHeight), origin.height + translation.height))
        }
    }

    private func tile(_ id: UUID, placement: String, in size: CGSize) {
        if placement == "pair" {
            let other = windows.last(where: { $0.id != id && !$0.minimized })?.id
            if let other {
                tile(other, placement: "right", in: size)
            } else {
                let companion = windows.first(where: { $0.id == id })?.page == "文件" ? "工作区" : "文件"
                open(companion, in: size)
                if let newID = activeID { tile(newID, placement: "right", in: size) }
            }
            tile(id, placement: "left", in: size)
            return
        }
        let area = CGRect(x: 108, y: 12, width: max(600, size.width - 120),
                          height: max(420, size.height - 24))
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            mutate(id) { item in
                if !item.userAdjusted {
                    item.frame = defaultFrame(in: size)
                    item.userAdjusted = true
                }
                if placement == "restore" {
                    item.frame = item.savedFrame ?? defaultFrame(in: size)
                    item.savedFrame = nil
                } else {
                    if item.savedFrame == nil { item.savedFrame = item.frame }
                    switch placement {
                    case "left":
                        item.frame = CGRect(x: area.minX, y: area.minY,
                                            width: (area.width - 12) / 2, height: area.height)
                    case "right":
                        item.frame = CGRect(x: area.midX + 6, y: area.minY,
                                            width: (area.width - 12) / 2, height: area.height)
                    case "top":
                        item.frame = CGRect(x: area.minX, y: area.minY,
                                            width: area.width, height: (area.height - 12) / 2)
                    case "bottom":
                        item.frame = CGRect(x: area.minX, y: area.midY + 6,
                                            width: area.width, height: (area.height - 12) / 2)
                    default: break
                    }
                }
                item.fullscreen = false
                item.maximized = false
                item.minimized = false
            }
            activeID = id
        }
    }
}

#Preview {
    VelumDesktopCanvas()
        .environmentObject(AppSettings())
        .frame(minWidth: 1000, minHeight: 680)
}

//
//  Project_AutoApp.swift
//  Project-Auto
//
//  正式 macOS 宿主入口。首屏是 Velum 桌面骨架；
//  `--agent-selftest` 走不建窗口的本地验收路径。
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didEnterFullscreen = false
    private var fullscreenTransition = false
    private var fullscreenObserver: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        fullscreenObserver = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow,
                      window.styleMask.contains(.titled), window.level == .normal else { return }
                self?.enterFullscreen(window)
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.didEnterFullscreen = false
                self?.enterFullscreen(window)
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.findWindowAndEnterFullscreen(attempt: 0)
            }
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.findWindowAndEnterFullscreen(attempt: 0)
        }
    }

    private func findWindowAndEnterFullscreen(attempt: Int) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal
        }) else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.findWindowAndEnterFullscreen(attempt: attempt + 1)
                }
            }
            return
        }
        enterFullscreen(window)
    }

    private func enterFullscreen(_ window: NSWindow) {
        guard !fullscreenTransition, window.isVisible, window.isKeyWindow,
              window.styleMask.contains(.titled), window.level == .normal else { return }
        guard !window.styleMask.contains(.fullScreen) else { didEnterFullscreen = true; return }
        fullscreenTransition = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak window] in
            guard let self, let window else { return }
            self.fullscreenTransition = false
            self.didEnterFullscreen = window.styleMask.contains(.fullScreen)
            if !self.didEnterFullscreen { self.findWindowAndEnterFullscreen(attempt: 0) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in fullscreenObserver { NotificationCenter.default.removeObserver(observer) }
        LocalAIConnectionBridge.shared.requestStopOnTermination()
        LinuxHelperClient.makeDefault()?.stop()
    }
}

struct Project_AutoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            VelumDesktopCanvas()
                .environmentObject(settings)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 900)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}

@main
struct AppLauncher {
    static func main() {
        LocalAIConnectionBridge.install()
        if CommandLine.arguments.contains("--split-ai-selftest") {
            SplitAIAcceptance.runBlocking()
        }
        if CommandLine.arguments.contains("--local-ai-selftest") {
            LocalAIAcceptance.runBlocking()
        }
        if CommandLine.arguments.contains("--environment-selftest") {
            EnvironmentSelfTest.runBlocking()
        }
        if CommandLine.arguments.contains("--agent-selftest") {
            AgentSelfTest.runBlocking()
            exit(0)
        }
        if CommandLine.arguments.contains("--sandbox-selftest") {
            AgentSelfTest.runSandboxBlocking()
            exit(0)
        }
        Project_AutoApp.main()
    }
}

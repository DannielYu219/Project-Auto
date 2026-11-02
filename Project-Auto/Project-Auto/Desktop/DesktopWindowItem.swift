//
//  DesktopWindowItem.swift
//  Project-Auto
//
//  原型桌面内的窗口模型。它是同一个 SwiftUI 桌面里的窗口，
//  不是多个 NSWindow 应用进程；不要据此声称已完成系统级窗口管理。
//

import CoreGraphics
import Foundation

enum DesktopLaunchMode: String {
    case windowed, maximized, fullscreen
}

/// 第三方 / Agent 应用在这里声明默认启动方式。
struct DesktopAppManifest {
    var defaultMode: DesktopLaunchMode = .windowed
}

struct DesktopWindowItem: Identifiable {
    let id = UUID()
    var page = "工作区"
    var userAdjusted = false
    var frame = CGRect.zero
    var savedFrame: CGRect? = nil
    var minimized = false
    var fullscreen = false
    var maximized = false
    var dragOrigin: CGPoint? = nil
    var resizeOrigin: CGRect? = nil
}

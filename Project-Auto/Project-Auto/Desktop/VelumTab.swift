//
//  VelumTab.swift
//  Project-Auto
//
//  应用身份：Dock 与启动台共用同一份应用清单。
//  当前是原型内的应用模型，不是已发布的第三方插件 API。
//

import SwiftUI

enum VelumTab: String, CaseIterable, Identifiable {
    case workspace = "工作区"
    case files = "文件"
    case components = "组件"
    case settings = "设置"
    case browser = "浏览器"
    case providers = "供应商"
    case serverBox = "ServerBox"
    case localAI = "本地 AI"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .workspace: "rectangle.stack"
        case .files: "folder"
        case .components: "square.grid.2x2"
        case .settings: "gearshape"
        case .browser: "globe"
        case .providers: "server.rack"
        case .serverBox: "externaldrive.connected.to.line.below"
        case .localAI: "cpu"
        }
    }

    /// Dock 与启动台使用的圆形图标资源（圆外透明）。
    var dockIcon: String {
        switch self {
        case .workspace: "DockWorkspace"
        case .files: "DockFiles"
        case .components: "DockComponents"
        case .settings: "DockSettings"
        case .browser: ""
        case .providers: ""
        case .serverBox: ""
        case .localAI: ""
        }
    }
}

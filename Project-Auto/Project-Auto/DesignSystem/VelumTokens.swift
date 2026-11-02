//
//  VelumTokens.swift
//  Project-Auto
//
//  设计 token 的唯一来源。数值来自 VelumTestUI 原型与设计规范文稿，
//  不允许在各页面再发明一套相近数值。
//

import SwiftUI

// 统一推导：外半径 − 内缩 = 内半径；胶囊高度为半径的两倍。
enum VelumGeometry {
    static let windowRadius: CGFloat = 32
    static let contentInset: CGFloat = 12
    static let panelRadius = windowRadius - contentInset
    static let panelContentInset: CGFloat = 16
    static let inspectorWidth: CGFloat = 208
    static let inspectorButtonSize = composerHeight
    static let titlebarHeight = contentInset + composerHeight + 4
    static let controlInset = sendInset
    static let controlDiameter = sendDiameter
    static let inspectorReservation = inspectorWidth + contentInset
    static let composerInset = contentInset
    // Inner radius = outer radius - inset. A capsule's height is twice its radius.
    static let composerRadius = windowRadius - composerInset
    static let composerHeight = composerRadius * 2
    static let sendInset: CGFloat = 6
    static let sendDiameter = composerHeight - sendInset * 2
}

enum VelumPalette {
    static let blue = Color(red: 0.19, green: 0.40, blue: 0.69)
    static let ink = Color.black.opacity(0.84)
    static let muted = Color.black.opacity(0.54)
    static let line = Color.black.opacity(0.09)
    /// 降低透明度时的实色回退：不逐个组件另造材质。
    static let fallbackSurface = Color(red: 0.91, green: 0.94, blue: 0.97)
    static let danger = Color(red: 0.66, green: 0.22, blue: 0.20)
}

// Three shared recipes: regular base, softly lifted regular, and tinted solid.
// No refractive glassEffect, specular rim, or per-component opacity recipes.
enum VelumMaterial { case regular, soft, solid }

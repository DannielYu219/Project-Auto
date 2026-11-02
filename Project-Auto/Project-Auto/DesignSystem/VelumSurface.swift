//
//  VelumSurface.swift
//  Project-Auto
//
//  三种材质配方与降级路径的唯一入口。所有自定义表面都走这里，
//  不在组件里散布新的白底透明度和描边。
//

import SwiftUI

private struct VelumSurfaceTintKey: EnvironmentKey {
    static let defaultValue: Color = .clear
}

private struct VelumReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var velumSurfaceTint: Color {
        get { self[VelumSurfaceTintKey.self] }
        set { self[VelumSurfaceTintKey.self] = newValue }
    }
    var velumReduceTransparency: Bool {
        get { self[VelumReduceTransparencyKey.self] }
        set { self[VelumReduceTransparencyKey.self] = newValue }
    }
}

struct VelumSurface<SurfaceShape: Shape>: ViewModifier {
    let material: VelumMaterial
    let shape: SurfaceShape
    var tint: Color? = nil
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.velumReduceTransparency) private var reduceTransparency
    @Environment(\.velumSurfaceTint) private var surfaceTint

    func body(content: Content) -> some View {
        if material == .solid {
            content.background(tint ?? VelumPalette.blue, in: shape)
        } else if systemReduceTransparency || reduceTransparency {
            content.background {
                shape.fill(VelumPalette.fallbackSurface)
                    .overlay(shape.fill(.white.opacity(material == .soft ? 0.28 : 0)))
                    .overlay(shape.fill(tint ?? surfaceTint))
            }
        } else {
            content.background {
                shape.fill(.regularMaterial)
                    .opacity(material == .soft ? 0.72 : 0.82)
                    .overlay(shape.fill(.white.opacity(material == .soft ? 0.06 : 0)))
                    .overlay(shape.fill(tint ?? surfaceTint))
            }
        }
    }
}

extension View {
    func velumSurface<S: Shape>(_ material: VelumMaterial, in shape: S,
                                tint: Color? = nil) -> some View {
        modifier(VelumSurface(material: material, shape: shape, tint: tint))
    }
}

// The single-line height is the reference diameter, not the current total height.
// Wrapping adds height without increasing the corner radius.
struct VelumTextShape: Shape {
    var singleLineHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        if rect.height <= singleLineHeight + 1 {
            return Capsule().path(in: rect)
        }
        return RoundedRectangle(cornerRadius: singleLineHeight / 2, style: .continuous)
            .path(in: rect)
    }
}

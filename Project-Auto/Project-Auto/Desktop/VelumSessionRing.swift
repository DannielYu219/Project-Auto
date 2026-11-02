//
//  VelumSessionRing.swift
//  Project-Auto
//
//  当前应用：细环 + 缓慢旋转的亮弧；非当前应用：静态细环；最小化更淡。
//
//  这里故意不用 SwiftUI 的 TimelineView 常驻刷新。之前 24fps 的
//  TimelineView 会让整个 App 在空闲时也不断合成，原生全屏下尤其明显。
//  旋转/呼吸改为 Core Animation 图层动画：由 render server 合成，
//  不触发布局和 SwiftUI body 重算，代价只有一个小图层的合成。
//

import AppKit
import QuartzCore
import SwiftUI

struct VelumSessionRing: NSViewRepresentable {
    var active: Bool
    var minimized: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SessionRingLayerView {
        let view = SessionRingLayerView()
        view.configure(active: active, minimized: minimized, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: SessionRingLayerView, context: Context) {
        view.configure(active: active, minimized: minimized, reduceMotion: reduceMotion)
    }
}

final class SessionRingLayerView: NSView {
    private let baseRing = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var isActive = false
    private var isMinimized = false
    private var isReduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        baseRing.fillColor = .clear
        baseRing.lineWidth = 1.5
        arc.fillColor = .clear
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.shadowColor = NSColor(VelumPalette.blue).cgColor
        arc.shadowOpacity = 0.28
        arc.shadowRadius = 2
        arc.shadowOffset = .zero
        layer?.addSublayer(baseRing)
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        let lineInset: CGFloat = 1.5
        baseRing.frame = bounds
        baseRing.path = CGPath(ellipseIn: bounds.insetBy(dx: lineInset, dy: lineInset),
                               transform: nil)
        arc.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(1, min(bounds.width, bounds.height) / 2 - lineInset)
        let path = CGMutablePath()
        path.addArc(center: center,
                    radius: radius,
                    startAngle: 0,
                    endAngle: .pi * 2 * 0.24,
                    clockwise: false)
        arc.path = path
        CATransaction.commit()
    }

    func configure(active: Bool, minimized: Bool, reduceMotion: Bool) {
        guard active != isActive || minimized != isMinimized || reduceMotion != isReduceMotion else {
            return
        }
        isActive = active
        isMinimized = minimized
        isReduceMotion = reduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseRing.strokeColor = NSColor(VelumPalette.blue.opacity(minimized ? 0.42 : 0.65)).cgColor
        arc.isHidden = !active
        arc.strokeColor = NSColor(VelumPalette.blue).cgColor
        arc.opacity = active ? 0.9 : 0
        CATransaction.commit()

        guard active, !reduceMotion else {
            arc.removeAllAnimations()
            return
        }
        startAnimations()
    }

    private func startAnimations() {
        guard arc.animation(forKey: "rotation") == nil else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 4
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(rotation, forKey: "rotation")

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.72
        breathe.toValue = 1.0
        breathe.duration = 1.4
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arc.add(breathe, forKey: "breathe")
    }
}

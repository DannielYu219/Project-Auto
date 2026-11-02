//
//  AppSettings.swift
//  Project-Auto
//
//  应用级偏好：唯一真相来源，写入 UserDefaults，重启后恢复。
//  这里的每一项都已经接到真实行为上；没有接入的能力不放进设置页。
//

import Combine
import SwiftUI

final class AppSettings: ObservableObject {
    enum SurfaceTint: String, CaseIterable, Identifiable {
        case standard, blue

        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "标准"
            case .blue: "蓝色"
            }
        }
    }

    static let defaultShowDetailsKey = "velum.defaultShowDetails"
    static let bypassToolApprovalsKey = "velum.bypassToolApprovals"

    private enum Key {
        static let surfaceTint = "velum.surfaceTint"
        static let defaultShowDetails = AppSettings.defaultShowDetailsKey
        static let inAppToast = "velum.inAppToast"
        static let reduceMotion = "velum.reduceMotion"
        static let reduceTransparency = "velum.reduceTransparency"
        static let bypassToolApprovals = AppSettings.bypassToolApprovalsKey
    }

    @Published var surfaceTint: SurfaceTint {
        didSet { UserDefaults.standard.set(surfaceTint.rawValue, forKey: Key.surfaceTint) }
    }
    @Published var defaultShowDetails: Bool {
        didSet { UserDefaults.standard.set(defaultShowDetails, forKey: Key.defaultShowDetails) }
    }
    @Published var inAppToast: Bool {
        didSet { UserDefaults.standard.set(inAppToast, forKey: Key.inAppToast) }
    }
    @Published var reduceMotion: Bool {
        didSet { UserDefaults.standard.set(reduceMotion, forKey: Key.reduceMotion) }
    }
    @Published var reduceTransparency: Bool {
        didSet { UserDefaults.standard.set(reduceTransparency, forKey: Key.reduceTransparency) }
    }
    /// Bypass for command/file/UI approvals. Off by default; visible as a deliberate setting.
    @Published var bypassToolApprovals: Bool {
        didSet { UserDefaults.standard.set(bypassToolApprovals, forKey: Key.bypassToolApprovals) }
    }

    init() {
        let defaults = UserDefaults.standard
        surfaceTint = SurfaceTint(rawValue: defaults.string(forKey: Key.surfaceTint) ?? "") ?? .standard
        defaultShowDetails = defaults.bool(forKey: Key.defaultShowDetails)
        inAppToast = defaults.object(forKey: Key.inAppToast) as? Bool ?? true
        reduceMotion = defaults.bool(forKey: Key.reduceMotion)
        reduceTransparency = defaults.bool(forKey: Key.reduceTransparency)
        bypassToolApprovals = defaults.bool(forKey: Key.bypassToolApprovals)
    }

    func reset() {
        surfaceTint = .standard
        defaultShowDetails = false
        inAppToast = true
        reduceMotion = false
        reduceTransparency = false
        bypassToolApprovals = false
    }
}

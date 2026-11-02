import Foundation

nonisolated enum AgentReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case off, low, medium, high, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    var shortTitle: String { title }

    var detail: String {
        switch self {
        case .off: "不额外要求思考"
        case .low: "快速回答，少量推理"
        case .medium: "平衡速度与推理"
        case .high: "更多推理步骤"
        case .max: "尽可能深入推理"
        }
    }

    var instruction: String? {
        switch self {
        case .off: nil
        case .low: "推理等级：Low。直接给出结论，只在必要时做简短推理。"
        case .medium: "推理等级：Medium。先整理关键事实，再给出结论。"
        case .high: "推理等级：High。先充分分析、比较方案，再给出结论。"
        case .max: "推理等级：Max。进行尽可能充分的推理与验证，再给出结论；不要省略关键步骤。"
        }
    }
}

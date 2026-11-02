//
//  ApprovalCenter.swift
//  Project-Auto
//
//  审批 UI 的状态中心：Agent 请求高风险工具时挂起，等用户在对话里点允许/拒绝。
//  只读工具直接放行；写文件/执行命令必须经过这里。
//

import Combine
import Foundation

@MainActor
final class ApprovalCenter: ObservableObject {
    struct Request: Identifiable, Equatable {
        var id = UUID()
        var toolName: String
        var riskLabel: String
        var summary: String
    }

    @Published private(set) var pending: Request?
    @Published var allowAllInSession = false

    private var continuation: CheckedContinuation<Bool, Never>?

    func request(toolName: String, risk: ToolRisk, arguments: JSONValue) async -> ApprovalDecision {
        if risk == .readOnly {
            return .allow
        }
        if allowAllInSession {
            return .allow
        }
        let summary = Self.summarize(arguments)
        let request = Request(toolName: toolName,
                              riskLabel: risk == .writesFile ? "写文件"
                                  : risk == .controlsUI ? "控制界面"
                                  : "执行命令",
                              summary: summary)
        let approved = await withCheckedContinuation { continuation in
            self.pending = request
            self.continuation = continuation
        }
        return approved ? .allow : .deny(reason: "用户拒绝了本次操作")
    }

    func resolve(_ approved: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: approved)
    }

    func allowAlways() {
        allowAllInSession = true
        resolve(true)
    }

    private static func summarize(_ arguments: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: PiJSON.anyValue(arguments)),
              let text = String(data: data, encoding: .utf8) else {
            return "（无参数）"
        }
        return String(text.prefix(400))
    }
}

nonisolated struct InteractiveApprovalGate: ApprovalGate, @unchecked Sendable {
    let center: ApprovalCenter

    func decide(toolName: String, risk: ToolRisk, arguments: JSONValue) async -> ApprovalDecision {
        await center.request(toolName: toolName, risk: risk, arguments: arguments)
    }
}

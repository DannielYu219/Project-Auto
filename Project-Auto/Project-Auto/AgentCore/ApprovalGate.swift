//
//  ApprovalGate.swift
//  Project-Auto
//
//  审批闸门：对应 pi 的 beforeToolCall（参数校验之后、执行之前）。
//  pi 自己不做权限系统；这里按产品要求补上，并把「等待用户」做成可挂起的 broker。
//

import Foundation

nonisolated enum ToolRisk: Sendable, Equatable {
    case readOnly
    case writesFile
    case executesProcess
    case controlsUI
}

nonisolated enum ApprovalDecision: Sendable {
    case allow
    case deny(reason: String)
}

nonisolated protocol ApprovalGate: Sendable {
    func decide(toolName: String, risk: ToolRisk, arguments: JSONValue) async -> ApprovalDecision
}

/// 本地演示/自动化用：全部放行。不要用于写文件或执行命令的工具。
nonisolated struct AutoApprovalGate: ApprovalGate {
    func decide(toolName: String, risk: ToolRisk, arguments: JSONValue) async -> ApprovalDecision {
        .allow
    }
}

/// 默认策略：只读直接放行；写文件与执行命令必须经过用户审批。
/// 没有接入审批界面时一律拒绝，而不是偷偷执行。
nonisolated struct RiskPolicyGate: ApprovalGate {
    var broker: ApprovalBroker?

    func decide(toolName: String, risk: ToolRisk, arguments: JSONValue) async -> ApprovalDecision {
        switch risk {
        case .readOnly:
            return .allow
        case .writesFile, .executesProcess, .controlsUI:
            guard let broker else {
                return .deny(reason: "未接入审批界面，已拒绝高风险工具")
            }
            let approved = await broker.request(toolName: toolName, arguments: arguments)
            return approved ? .allow : .deny(reason: "用户拒绝了本次操作")
        }
    }
}

/// 把「等待用户点允许/拒绝」挂起成 continuation；UI 后续用 pendingRequest + resolve 接入。
nonisolated final class ApprovalBroker: @unchecked Sendable {
    struct Request: Identifiable, Sendable {
        var id = UUID()
        var toolName: String
        var summary: String
    }

    private let lock = NSLock()
    private var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    init() {}

    var pendingRequest: Request? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func request(toolName: String, arguments: JSONValue) async -> Bool {
        let summary = ApprovalBroker.summarize(arguments)
        return await withCheckedContinuation { continuation in
            lock.lock()
            pending = Request(toolName: toolName, summary: summary)
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ id: UUID, approved: Bool) {
        lock.lock()
        guard let request = pending, request.id == id else {
            lock.unlock()
            return
        }
        let continuation = self.continuation
        pending = nil
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: approved)
    }

    private static func summarize(_ arguments: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: PiJSON.anyValue(arguments)),
              let text = String(data: data, encoding: .utf8) else {
            return "（无参数）"
        }
        return String(text.prefix(300))
    }
}

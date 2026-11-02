//
//  AgentInspector.swift
//  Project-Auto
//
//  任务详情：真实显示当前会话、Provider、路由、token 与费用。
//  未接入的能力只写实情，不做在线状态装饰。
//

import SwiftUI

struct AgentInspector: View {
    @ObservedObject var chat: AgentChatModel
    @ObservedObject private var config = AgentConfig.shared
    @ObservedObject private var budget = BudgetGuard.shared

    private var routeText: String {
        if let local = config.selectedLocalModel { return "本机 · \(local.engineID ?? "mlx")" }
        if let host = URL(string: config.effectiveEndpoint)?.host, !host.isEmpty {
            return "云端 · \(host)"
        }
        return "云端"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("此会话").font(.system(size: 12, weight: .semibold))
                Text(chat.sessionTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(VelumPalette.muted)
                    .lineLimit(2)
            }
            Divider()
            row("模型", chat.providerLabel)
            row("路由", routeText)
            row("Tokens", "\(chat.promptTokens) ↑ / \(chat.completionTokens) ↓")
            row("费用", String(format: "$%.4f", chat.costUSD))
            row("缓存读", "\(chat.cacheReadTokens)")
            row("缓存写", "\(chat.cacheWriteTokens)")
            row("命中率", String(format: "%.0f%%", chat.cacheHitRate * 100))
            row("预算", String(format: "$%.2f / $%.2f", budget.sessionSpent, budget.limit.sessionUSD))
            Spacer(minLength: 16)
            Text("命令与界面操作经过审批。Mac 目录须选择授权后挂载；浏览器支持截图与直接控制。")
                .font(.system(size: 10))
                .foregroundStyle(VelumPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VelumGeometry.panelContentInset)
        .frame(width: VelumGeometry.inspectorWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(VelumPalette.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

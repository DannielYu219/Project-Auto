//
//  SettingsPage.swift
//  Project-Auto
//
//  真实设置：Agent Provider/模型/Keychain/预算来自移植的 Agent 数据层，
//  外观与辅助功能写入本机偏好。没有接入的能力不在这里冒充开关。
//

import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @ObservedObject private var agent = AgentConfig.shared
    @ObservedObject private var budget = BudgetGuard.shared

    @State private var endpointDraft = ""
    @State private var modelDraft = ""
    @State private var keyDraft = ""
    @State private var promptDraft = ""
    @State private var saveNote: String?
    @State private var draftsLoaded = false

    private var agentConfigured: Bool {
        !agent.apiKey.isEmpty && !agent.endpoint.isEmpty && !agent.model.isEmpty
    }

    private var effectiveSurface: String {
        if systemReduceTransparency || settings.reduceTransparency {
            return "当前表面：不透明回退（降低透明度）"
        }
        return "当前表面：regular 材质 · 着色\(settings.surfaceTint.title)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("让桌面适合你。").font(.system(size: 24, weight: .semibold))
                    Text(agentConfigured ? "Agent 已配置：\(agent.modelDisplayName)" : "Agent 尚未配置完整")
                        .font(.system(size: 12)).foregroundStyle(VelumPalette.muted)
                }

                SettingsSection("Agent") {
                    SettingsRow("供应商与模型",
                                detail: agentConfigured ? "当前：\(agent.modelDisplayName)" : "尚未配置") {
                        Button("打开供应商 App") {
                            NotificationCenter.default.post(name: .velumOpenPage, object: nil,
                                                            userInfo: ["page": VelumTab.providers.rawValue])
                        }.buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                    }
                    SettingsRow("系统指令", detail: "追加在默认提示之后；留空使用默认") {
                        PromptEditor(text: $promptDraft)
                    }
                }

                Divider()

                SettingsSection("预算") {
                    SettingsRow("本会话", detail: "已用 / 上限") {
                        budgetText(budget.sessionSpent, budget.limit.sessionUSD)
                    }
                    SettingsRow("今日", detail: "已用 / 上限") {
                        budgetText(budget.dailySpent, budget.limit.dailyUSD)
                    }
                    SettingsRow("本月", detail: "已用 / 上限") {
                        budgetText(budget.monthlySpent, budget.limit.monthlyUSD)
                    }
                    Button("重置会话预算") { budget.resetSession() }
                        .buttonStyle(VelumCapsuleButtonStyle())
                }

                Divider()

                SettingsSection("外观") {
                    SettingsRow("表面着色", detail: "只改变着色，不新增材质类型") {
                        VelumCapsuleSelection(
                            title: "表面着色",
                            options: [("标准", AppSettings.SurfaceTint.standard),
                                      ("蓝色", AppSettings.SurfaceTint.blue)],
                            selection: $settings.surfaceTint
                        ).frame(width: 185)
                    }
                    SettingsRow("启动时展开任务详情", detail: "只影响之后新建的窗口") {
                        Toggle("启动时展开任务详情", isOn: $settings.defaultShowDetails)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }

                Divider()

                SettingsSection("提示与辅助功能") {
                    SettingsRow("跳过工具审批（Bypass）",
                                detail: "命令、文件写入与浏览器操作直接执行；仅在你完全信任当前任务时开启") {
                        Toggle("跳过工具审批", isOn: $settings.bypassToolApprovals)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsRow("应用内提示", detail: "保存、演示等本地反馈以胶囊提示出现") {
                        Toggle("应用内提示", isOn: $settings.inAppToast)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsRow("降低动态效果", detail: "尊重系统设置，也可在此进一步降低") {
                        Toggle("降低动态效果", isOn: $settings.reduceMotion)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsRow("降低透明度", detail: "尊重系统设置并提供不透明表面") {
                        Toggle("降低透明度", isOn: $settings.reduceTransparency)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(effectiveSurface)
                        .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                    HStack(spacing: 10) {
                        Button("恢复默认") { settings.reset() }
                            .buttonStyle(VelumCapsuleButtonStyle())
                        Text("偏好保存在本机，重启后仍生效。")
                            .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
                    }
                }
                Text("已接入：云端 Provider、Linux 命令与真实文件、授权目录挂载、内置浏览器、App 内 UI 操作、附件与会话历史。浏览器默认由 Agent 直接控制，Needle 英文转换可选。")
                    .font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            }.padding(28)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(VelumPalette.ink)
        .onAppear(perform: loadDrafts)
    }

    private func budgetText(_ spent: Double, _ limit: Double) -> some View {
        Text(String(format: "$%.2f / $%.2f", spent, limit))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(VelumPalette.ink)
    }

    private func loadDrafts() {
        guard !draftsLoaded else { return }
        draftsLoaded = true
        endpointDraft = agent.endpoint
        modelDraft = agent.model
        promptDraft = agent.systemPrompt
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveNote = "请先输入 API Key"
            return
        }
        agent.apiKey = trimmed
        keyDraft = ""
        saveNote = "Key 已存入 Keychain"
    }

    private func deleteKey() {
        agent.apiKey = ""
        keyDraft = ""
        saveNote = "已删除 Key"
    }

    private func saveConfig() {
        let endpoint = endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty { agent.endpoint = endpoint }
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { agent.model = model }
        agent.systemPrompt = promptDraft
        saveNote = "配置已保存"
    }
}

// MARK: - 设置页的单行与多行输入
//
// 单行容器用 Capsule；多行保持单行胶囊对应的半径 20，不随高度增大。

private struct SettingsField: View {
    @Binding var text: String
    var placeholder = ""
    var width: CGFloat = 240

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(width: width, height: 34)
            .velumSurface(.soft, in: Capsule())
    }
}

private struct SecureSettingsField: View {
    @Binding var text: String
    var placeholder = ""
    var width: CGFloat = 240

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(width: width, height: 34)
            .velumSurface(.soft, in: Capsule())
            .accessibilityLabel("API Key")
    }
}

private struct PromptEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(width: 320, height: 96)
            .velumSurface(.soft, in: RoundedRectangle(cornerRadius: VelumGeometry.composerRadius,
                                                      style: .continuous))
            .accessibilityLabel("系统指令")
    }
}

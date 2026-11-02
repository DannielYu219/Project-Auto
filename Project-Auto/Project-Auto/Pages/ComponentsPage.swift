//
//  ComponentsPage.swift
//  Project-Auto
//
//  组件展台：每个控件都实际可操作，用开放分组与对齐组织。
//  展台里的值只属于展台本身，不冒充应用设置。
//

import SwiftUI

extension Notification.Name {
    static let velumResetComponents = Notification.Name("VelumResetComponents")
}

struct ComponentsPage: View {
    var onNotify: () -> Void

    @State private var workspaceName = "Velum 工作区"
    @State private var projectName = ""
    @State private var executionLocation = "自动"
    @State private var notificationEnabled = true
    @State private var localFilesOnly = true
    @State private var surfaceMode = 0
    @State private var volume = 0.62

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("组件").font(.system(size: 22, weight: .semibold))
                    Text("同一套材质、尺度与交互。可以直接操作。")
                        .font(.system(size: 12)).foregroundStyle(VelumPalette.muted)
                }
                HStack(alignment: .top, spacing: 34) {
                    VStack(alignment: .leading, spacing: 22) {
                        ShowcaseGroup("按钮", subtitle: "主操作只保留一个视觉重心") {
                            HStack(spacing: 8) {
                                Button("保存更改") { onNotify() }
                                    .buttonStyle(VelumCapsuleButtonStyle(prominent: true))
                                Button("取消") {}.buttonStyle(VelumCapsuleButtonStyle())
                                Button("了解更多") {}.buttonStyle(.plain)
                            }
                            Button { } label: { Label("新建文件", systemImage: "plus") }
                                .buttonStyle(VelumCapsuleButtonStyle())
                                .disabled(true)
                                .help("当前为本地展示")
                        }
                        ShowcaseGroup("输入", subtitle: "标签常驻，焦点与校验就地反馈") {
                            VelumInput(
                                title: "工作区名称",
                                placeholder: "为工作区命名",
                                text: $workspaceName
                            )
                            VelumInput(
                                title: "项目名称",
                                placeholder: "为项目命名",
                                text: $projectName,
                                required: true
                            )
                        }
                        ShowcaseGroup("分段选择", subtitle: "同一上下文中的轻量切换") {
                            VelumCapsuleSelection(
                                title: "执行位置",
                                options: [("自动", "自动"), ("本地", "本地"), ("云端", "云端")],
                                selection: $executionLocation
                            )
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 22) {
                        ShowcaseGroup("开关与选择", subtitle: "状态变化即时反馈") {
                            Toggle("完成时通知我", isOn: $notificationEnabled)
                                .toggleStyle(.switch).controlSize(.small)
                            Toggle("仅在本地处理文件", isOn: $localFilesOnly)
                                .toggleStyle(VelumCapsuleToggleStyle())
                            VelumCapsuleSelection(
                                title: "表面着色",
                                options: [("标准", 0), ("蓝色", 1)],
                                selection: $surfaceMode
                            )
                        }
                        ShowcaseGroup("滑块", subtitle: "连续值保持可读") {
                            HStack {
                                Label("提示音量", systemImage: "speaker.wave.2")
                                Spacer()
                                Text(volume, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }
                            Slider(value: $volume).accessibilityLabel("提示音量")
                        }
                        ShowcaseGroup("菜单与提示", subtitle: "命令、状态与辅助信息层级分明") {
                            HStack(spacing: 7) {
                                StatusBadge(text: "已完成", symbol: "checkmark")
                                StatusBadge(text: "仅本地", symbol: "internaldrive")
                                StatusBadge(text: "只读", symbol: nil)
                            }
                            Label("快速打开", systemImage: "command")
                                .font(.system(size: 11)).foregroundStyle(VelumPalette.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Label("SwiftUI · SF Symbols · 系统材质", systemImage: "square.stack.3d.up")
                    Spacer()
                    Text("本页数值只属于展台，不写入应用设置")
                }.font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            }
            .padding(26)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(VelumPalette.ink)
        .onReceive(NotificationCenter.default.publisher(for: .velumResetComponents)) { _ in
            workspaceName = "Velum 工作区"
            projectName = ""
            executionLocation = "自动"
            notificationEnabled = true
            localFilesOnly = true
            surfaceMode = 0
            volume = 0.62
        }
    }
}

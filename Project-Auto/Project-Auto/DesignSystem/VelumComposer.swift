//
//  VelumComposer.swift
//  Project-Auto
//
//  贴底会话输入：窗口内缩 12，高 40（半径 20），发送钮 28 右侧内缩 6。
//  运行时发送钮变成停止；空输入不可发送。
//

import SwiftUI

struct VelumComposer: View {
    @Binding var message: String
    var providerLabel = "Responses"
    var isStreaming = false
    var onSend: () -> Void
    var onStop: () -> Void
    var onAttach: () -> Void
    var onAttachServer: () -> Void = {}

    private var canSend: Bool {
        !isStreaming && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("添加文件…", systemImage: "paperclip", action: onAttach)
                Button("连接远程主机…", systemImage: "server.rack", action: onAttachServer)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .help("添加附件或远程主机")
            .accessibilityLabel("添加附件或远程主机")
            TextField("补充要求，或交给 Agent 一个新任务…", text: $message)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("任务内容")
                .onSubmit {
                    if canSend { onSend() }
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            Text(providerLabel)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: VelumGeometry.sendDiameter, height: VelumGeometry.sendDiameter)
                        .velumSurface(.solid, in: Capsule(), tint: .black)
                }
                .buttonStyle(.plain)
                .help("停止生成")
                .accessibilityLabel("停止生成")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: VelumGeometry.sendDiameter, height: VelumGeometry.sendDiameter)
                        .velumSurface(.solid, in: Capsule(), tint: .black)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .help("发送")
                .accessibilityLabel("发送")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, VelumGeometry.sendInset)
        .frame(height: VelumGeometry.composerHeight)
        .velumSurface(.soft, in: Capsule())
    }
}

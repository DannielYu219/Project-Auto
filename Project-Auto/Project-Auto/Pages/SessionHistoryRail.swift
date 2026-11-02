//
//  SessionHistoryRail.swift
//  Project-Auto
//
//  工作区左侧的会话历史栏：搜索、切换、新建和删除会话。
//

import SwiftUI

struct SessionHistoryRail: View {
    @ObservedObject var chat: AgentChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("会话历史")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VelumPalette.ink)
                Spacer(minLength: 8)
                Button {
                    Task { await chat.newConversation() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("新建会话")
                .accessibilityLabel("新建会话")
                Button {
                    withAnimation(.snappy(duration: 0.2)) { chat.isHistoryVisible = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("收起会话历史")
                .accessibilityLabel("收起会话历史")
            }
            .foregroundStyle(VelumPalette.muted)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VelumPalette.muted)
                TextField("搜索会话", text: $chat.sessionFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .velumSurface(.soft, in: Capsule())

            if chat.filteredSessions.isEmpty {
                Text(chat.historySessions.isEmpty ? "还没有会话" : "没有匹配的会话")
                    .font(.system(size: 11))
                    .foregroundStyle(VelumPalette.muted)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(chat.filteredSessions) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }

            Text("\(chat.historySessions.count) 个会话")
                .font(.system(size: 9))
                .foregroundStyle(VelumPalette.muted)
                .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let selected = session.id == chat.currentSessionID
        return Button {
            Task { await chat.selectSession(session.id) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(VelumPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if selected && chat.isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                }
                HStack(spacing: 6) {
                    Text(Self.relativeTime(session.updatedAt))
                    if session.messageCount > 0 {
                        Text("·")
                        Text("\(session.messageCount) 条")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(VelumPalette.muted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? VelumPalette.blue.opacity(0.12) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除会话", role: .destructive) {
                Task { await chat.deleteSession(session.id) }
            }
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 86400 * 7 { return "\(Int(interval / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

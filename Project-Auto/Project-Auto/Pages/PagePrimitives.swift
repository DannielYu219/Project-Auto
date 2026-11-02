//
//  PagePrimitives.swift
//  Project-Auto
//
//  页面的开放分组与行组件。默认不给每段文字、每条设置套卡片：
//  用标题、行、间距和细分隔组织。
//

import SwiftUI

struct VelumActivityRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark").foregroundStyle(VelumPalette.muted)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
        }.frame(height: 27)
    }
}

struct ShowcaseGroup<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            }
            content
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(VelumPalette.muted)
            content
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    let control: Control

    init(_ title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(VelumPalette.muted)
            }
            Spacer(minLength: 8)
            control
        }.padding(.vertical, 9)
    }
}

struct StatusBadge: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(text == "已完成" ? VelumPalette.blue : VelumPalette.muted)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .velumSurface(.soft, in: Capsule())
    }
}

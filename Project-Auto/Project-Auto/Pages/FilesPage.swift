//
//  FilesPage.swift
//  Project-Auto
//
//  真实文件浏览：显示 Linux 沙盒 /workspace 中的 AI 产物；宿主目录需显式挂载。
//

import SwiftUI

struct FilesPage: View {
    @ObservedObject var model: VelumWindowModel
    @StateObject private var browser = FileBrowserModel()
    @ObservedObject private var mounts = HostMountCenter.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("AI 产物") { Task { await browser.load("/workspace") } }
                            .buttonStyle(VelumCapsuleButtonStyle())
                        ForEach(mounts.mounts) { mount in
                            Button(mount.name + (mount.readOnly ? " · 只读" : "")) {
                                Task { await browser.load(mount.guestPath) }
                            }
                            .buttonStyle(VelumCapsuleButtonStyle())
                            .contextMenu {
                                Button("卸载目录") { Task { try? await mounts.remove(mount.id) } }
                            }
                        }
                    }.padding(.horizontal, 24)
                }.padding(.bottom, 10)
                if let error = mounts.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(VelumPalette.danger).padding(.horizontal, 24)
                }
                searchBar
                Rectangle().fill(VelumPalette.line).frame(height: 0.5)
                content
                Rectangle().fill(VelumPalette.line).frame(height: 0.5)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if browser.selected != nil {
                Divider()
                previewPane
                    .frame(width: 360)
            }
        }
        .foregroundStyle(VelumPalette.ink)
        .task { await browser.load("/workspace") }
        .onChange(of: model.searchText) { _, query in browser.searchText = query }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task { await browser.goUp() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("上一级")

            Image(systemName: "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VelumPalette.blue)
            Text(browser.currentPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Spacer()
            if browser.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await browser.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VelumPalette.muted)
            TextField("搜索当前目录", text: $model.searchText)
                .textFieldStyle(.plain)
            Text("Linux 工作区")
                .font(.system(size: 9))
                .foregroundStyle(VelumPalette.muted)
        }
        .font(.system(size: 12))
        .padding(11)
        .velumSurface(.soft, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let error = browser.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(VelumPalette.danger)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(VelumPalette.muted)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await browser.load() } }
                    .buttonStyle(VelumCapsuleButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.filteredEntries.isEmpty && !browser.isLoading {
            ContentUnavailableView(browser.searchText.isEmpty ? "目录为空" : "没有匹配的文件",
                                   systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(browser.filteredEntries) { file in
                        fileRow(file)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func fileRow(_ file: BrowserFile) -> some View {
        Button {
            Task { await browser.open(file) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: file))
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(file.isDirectory ? VelumPalette.blue : VelumPalette.muted)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(file.isDirectory ? "目录" : FileBrowserModel.sizeText(file.size))
                        .font(.system(size: 9))
                        .foregroundStyle(VelumPalette.muted)
                }
                Spacer()
                Text(file.modified, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 9))
                    .foregroundStyle(VelumPalette.muted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(VelumPalette.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .velumSurface(.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text("\(browser.filteredEntries.count) 项 · 真实 Linux 文件")
            Spacer()
            Text("/workspace")
                .font(.system(size: 9, design: .monospaced))
        }
        .font(.system(size: 10))
        .foregroundStyle(VelumPalette.muted)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.selected?.name ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let file = browser.selected {
                        Text("\(FileBrowserModel.sizeText(file.size)) · \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 9))
                            .foregroundStyle(VelumPalette.muted)
                    }
                }
                Spacer()
                Button {
                    browser.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                Text(browser.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VelumPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func icon(for file: BrowserFile) -> String {
        if file.isDirectory { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "md", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "webp", "gif": return "photo"
        case "mp4", "mov": return "video"
        default: return "doc"
        }
    }
}

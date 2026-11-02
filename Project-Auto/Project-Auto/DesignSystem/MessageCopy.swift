import AppKit
import SwiftUI

/// Hover affordance plus context menu for copying the raw message text.
/// Assistant markdown and user text both copy verbatim, not rendered fragments.
struct CopyableMessage<Content: View>: View {
    let text: String
    @ViewBuilder var content: Content
    @State private var hovering = false
    @State private var copied = false

    init(text: String, @ViewBuilder content: () -> Content) {
        self.text = text
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            content
            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(copied ? VelumPalette.blue : VelumPalette.muted)
                    .frame(width: 28, height: 28)
                    .velumSurface(.soft, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .opacity(hovering || copied ? 1 : 0)
            .help(copied ? "已复制" : "复制消息")
            .accessibilityLabel(copied ? "已复制消息" : "复制消息")
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(copied ? "已复制" : "复制消息") { copy() }
                .disabled(text.isEmpty)
        }
    }

    private func copy() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            copied = false
        }
    }
}

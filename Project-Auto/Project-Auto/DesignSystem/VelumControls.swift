//
//  VelumControls.swift
//  Project-Auto
//
//  基础控件：胶囊按钮、胶囊分段选择、胶囊开关、带常驻标签的输入。
//  全部沿用原型的 Capsule + soft / solid 配方。
//

import SwiftUI

struct VelumCapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 15)
            .frame(minHeight: 32)
            .foregroundStyle(prominent ? Color.white : VelumPalette.ink)
            .velumSurface(prominent ? .solid : .soft, in: Capsule(),
                          tint: prominent ? VelumPalette.blue : nil)
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
    }
}

struct VelumCapsuleSelection<Value: Hashable>: View {
    let title: String
    let options: [(String, Value)]
    @Binding var selection: Value
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection == option.1
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                        selection = option.1
                    }
                } label: {
                    Text(option.0)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundStyle(selected ? Color.white : VelumPalette.ink)
                        .background {
                            if selected {
                                Color.clear
                                    .velumSurface(.solid, in: Capsule(), tint: VelumPalette.blue)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title)，\(option.0)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .velumSurface(.soft, in: Capsule())
    }
}

struct VelumCapsuleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(configuration.isOn ? VelumPalette.blue : VelumPalette.muted)
                configuration.label.font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .velumSurface(.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
    }
}

struct VelumInput: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var required = false
    @FocusState private var focused: Bool
    @State private var didFinishEditing = false

    private var invalid: Bool {
        required && didFinishEditing && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VelumPalette.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(VelumPalette.ink)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .velumSurface(.soft, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(invalid ? Color.red.opacity(0.5) :
                                      focused ? VelumPalette.blue.opacity(0.55) : .clear,
                                      lineWidth: 1)
                }
                .focused($focused)
                .accessibilityLabel(title)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { didFinishEditing = true }
                }
                .onSubmit { didFinishEditing = true }
            if invalid {
                Label("请输入项目名称", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(VelumPalette.danger)
            }
        }
    }
}

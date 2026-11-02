//
//  VelumMessage.swift
//  Project-Auto
//
//  单行消息用 Capsule，换行后固定原单行半径。
//  真实文字高度由隐藏的测量文本决定，不写死某条消息永远是单行。
//

import SwiftUI

struct VelumMessage: View {
    let text: String
    @State private var singleLineHeight: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(VelumPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Text("测")
                    .font(.system(size: 13))
                    .fixedSize()
                    .padding(.vertical, 10)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        singleLineHeight = $0
                    }
            }
            .velumSurface(.soft, in: VelumTextShape(singleLineHeight: singleLineHeight))
    }
}

import SwiftUI

/// 内容不超过 cap 时按自然高度（不预留空白），超过则封顶并启用滚动。
/// macOS 上滚动走滚轮/触控板事件，与行内的点击/拖拽手势不冲突。
struct CappedScroll<Content: View>: View {
    let cap: CGFloat
    @ViewBuilder let content: Content
    @State private var contentH: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height },
                                  action: { contentH = $0 })
        }
        .frame(height: contentH == 0 ? nil : min(contentH, cap))
        .scrollDisabled(contentH <= cap)
    }
}

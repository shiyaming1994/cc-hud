import SwiftUI

/// 内容不超过 cap 时按自然高度（不预留空白），超过则封顶并启用滚动。
/// macOS 上滚动走滚轮/触控板事件，与行内的点击/拖拽手势不冲突。
/// scrollTopToken 变化时（如某行因完成/发消息冒到第一位）自动滑回最顶——否则封顶滚动后新置顶的行看不到。
struct CappedScroll<Content: View>: View {
    let cap: CGFloat
    var scrollTopToken: String? = nil
    @ViewBuilder let content: Content
    @State private var contentH: CGFloat = 0
    private let topAnchor = "__cappedscroll_top__"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(topAnchor)   // 顶部锚点（0 高，纯定位用）
                    content
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height },
                                  action: { contentH = $0 })
            }
            .frame(height: contentH == 0 ? nil : min(contentH, cap))
            .scrollDisabled(contentH <= cap)
            .onChange(of: scrollTopToken) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(topAnchor, anchor: .top) }
            }
        }
    }
}

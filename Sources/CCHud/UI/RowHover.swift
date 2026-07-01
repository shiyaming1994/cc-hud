import SwiftUI

/// 行矩形上报：把本行在窗口内容坐标系(SwiftUI .global)的矩形写入 HoverState，供 HUDPanel 做鼠标命中判定；
/// 行移除（会话结束）时清理，避免残留矩形误命中。列表行经 .rowHover 顺带上报，展开档 RowView 单独用它（自带更复杂底色）。
private struct RowRectReporter: ViewModifier {
    let id: String
    @EnvironmentObject private var hover: HoverState
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hover.rowRects[id] = $0 }
            .onDisappear { hover.rowRects[id] = nil }
    }
}

/// 行悬停高亮：不再用随内容缩放、又被隐藏探针重复一份的 NSTrackingArea（它在快速移动/布局变动时会漏发
/// enter/exit → 乱亮、多行同亮）。改为「鼠标位置 vs 行矩形」单一判定：HUDPanel.updateHover 写 hoveredRow，
/// 行只需 ①上报自身矩形（reportsRowRect）②按 hoveredRow==id 高亮。恰好一行、不漏、不重复。
private struct RowHoverModifier: ViewModifier {
    let id: String
    var radius: CGFloat
    var color: Color
    @EnvironmentObject private var hover: HoverState
    func body(content: Content) -> some View {
        let on = hover.hoveredRow == id
        content
            .background { RoundedRectangle(cornerRadius: radius).fill(color).opacity(on ? 1 : 0) }
            .reportsRowRect(id: id)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

extension View {
    /// 上报本行矩形（供鼠标命中判定），不含高亮——展开档 RowView 用它 + 自定义底色。
    func reportsRowRect(id: String) -> some View { modifier(RowRectReporter(id: id)) }

    /// 行悬停高亮（列表 / 展开里每行）。id 用于「鼠标命中哪行」的单一判定与矩形上报。
    func rowHover(id: String, radius: CGFloat, color: Color = Theme.rowHover) -> some View {
        modifier(RowHoverModifier(id: id, radius: radius, color: color))
    }
}

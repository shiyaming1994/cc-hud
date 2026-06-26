import SwiftUI
import AppKit

/// 悬停探针：本 app 是 accessory（终端聚焦时非 active），SwiftUI 自带的 `.onHover`
/// 用 `.activeInActiveApp` tracking——本 app 不在前台时不触发。这里用 `.activeAlways`
/// 的 NSTrackingArea，几何级 enter/exit（与 hitTest / 层级无关），非 active app 也报。
/// 只上报 hover 区间用于**行高亮**；不改光标——非活跃 app 调 NSCursor 会被 macOS 忽略、
/// cursorUpdate 也不触发（实测 + Apple 论坛 thread 738051 证实），所以光标做不了，不做。
/// hitTest=nil → 点击穿透，不拦截行的点按 / 拖拽排序。
struct HoverReporter: NSViewRepresentable {
    var onChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onChange = onChange
        return v
    }
    func updateNSView(_ v: TrackingView, context: Context) {
        v.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 点击穿透，仅做悬停跟踪

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }
        override func mouseEntered(with event: NSEvent) {
            if !inside { inside = true; onChange?(true) }
        }
        override func mouseExited(with event: NSEvent) {
            if inside { inside = false; onChange?(false) }
        }
    }
}

/// 行悬停背景高亮（--row-hover）。每个实例自持 hovering 状态。
private struct RowHoverModifier: ViewModifier {
    var radius: CGFloat
    var color: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius).fill(color).opacity(hovering ? 1 : 0)
            }
            .background(HoverReporter { hovering = $0 })
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// 行悬停高亮（列表 / 展开里每行）
    func rowHover(radius: CGFloat, color: Color = Theme.rowHover) -> some View {
        modifier(RowHoverModifier(radius: radius, color: color))
    }
}

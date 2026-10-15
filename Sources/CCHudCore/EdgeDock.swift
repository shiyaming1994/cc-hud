import Foundation
import CoreGraphics

/// 停靠锚点：停靠屏 UUID + 面板顶边相对该屏 frame 原点（左下）的高度。
/// 存档键 hud.anchor.v2 的格式 {screen, dx, dy} 不变（设计文档 4.5）：
/// 读时忽略 dx——横向永远贴右边缘；写时 dx 照写贴边值，装回旧版本读到的也是贴右边。
public struct DockAnchor: Equatable, Sendable {
    public var screen: String
    public var dy: CGFloat

    public init(screen: String, dy: CGFloat) {
        self.screen = screen
        self.dy = dy
    }

    /// UserDefaults 读出来的数字是 NSNumber，按 NSNumber 取，整数、小数都认
    public init?(archive d: [String: Any]) {
        guard let screen = d["screen"] as? String,
              let dy = (d["dy"] as? NSNumber)?.doubleValue, dy.isFinite else { return nil }
        self.init(screen: screen, dy: CGFloat(dy))
    }

    /// 写回存档。dx = 贴边时右边缘相对屏原点的偏移，只给旧版本看，本版读时不用。
    public func archive(screenFrame: CGRect, visibleFrame: CGRect) -> [String: Any] {
        ["screen": screen, "dx": Double(visibleFrame.maxX - screenFrame.minX), "dy": Double(dy)]
    }

    /// 全局坐标下的面板顶边
    public func top(screenFrame: CGRect) -> CGFloat { screenFrame.minY + dy }
}

/// 面板贴屏幕右边缘停靠的几何（设计文档 4.2–4.4）。坐标一律是 AppKit 全局屏幕坐标：左下原点、y 向上。
public enum EdgeDock {
    /// 默认位置（没有锚点时）：顶边离 visibleFrame 顶 8pt，沿用旧胶囊的默认高度
    public static let defaultTopInset: CGFloat = 8

    public static func defaultTop(visibleFrame v: CGRect) -> CGFloat { v.maxY - defaultTopInset }

    /// 停靠后的面板 frame，取整数点：
    /// - 横向：右边 = visibleFrame.maxX（程序坞放右边时不被它盖住）。
    /// - 纵向：顶边尽量放在 top；整个面板要落在 visibleFrame 里——下面放不下就整体上移（4.4），
    ///   顶边也不高过 visibleFrame 顶。比整块 visibleFrame 还高时，顶边贴 visibleFrame 顶，保住标题栏。
    public static func frame(size: CGSize, top: CGFloat, visibleFrame v: CGRect) -> CGRect {
        let w = size.width.rounded(), h = size.height.rounded()
        let maxTop = v.maxY.rounded(.down)
        let minTop = (v.minY + h).rounded(.up)
        let t = min(max(top.rounded(), minTop), maxTop)
        return CGRect(x: v.maxX.rounded(.down) - w, y: t - h, width: w, height: h)
    }

    /// 松手后停靠哪块屏，返回 screens 的下标：鼠标所在的屏 → 和面板重叠面积最大的屏 → nil（调用方取主屏）。
    /// screens 传各屏 frame，不是 visibleFrame：鼠标停在菜单栏、程序坞上也算这块屏。
    public static func pickScreen(mouse: CGPoint, panel: CGRect, screens: [CGRect]) -> Int? {
        if let i = screens.firstIndex(where: { $0.contains(mouse) }) { return i }
        var best: Int?
        var bestArea: CGFloat = 0
        for (i, s) in screens.enumerated() {
            let r = s.intersection(panel)
            let area = r.isNull ? 0 : r.width * r.height
            if area > bestArea {
                best = i
                bestArea = area
            }
        }
        return best
    }
}

import SwiftUI

/// 面板悬停态的唯一真相。由「鼠标位置 vs 窗口 frame」的监视器写入（见 AppDelegate），
/// 不再依赖随内容缩放而变的 SwiftUI tracking area——根除"展开→假退出→收起→再进入"的抖动环。
@MainActor
final class HoverState: ObservableObject {
    /// 驱动额度页脚展开（SwiftUI 读它）。由 HUDPanel.updateHover 依「鼠标 vs 可见玻璃」直接翻转；
    /// 展开/收起的平滑过渡由 SwiftUI 动画负责，窗口尺寸不变。
    @Published var footerExpanded = false

    /// 当前鼠标悬停的行 id（无则 nil）。由 HUDPanel.updateHover 依「鼠标位置 vs 各行矩形」判定——
    /// 单一真相、恰好一行，取代随内容缩放/被探针重复而漏发 enter/exit 的 NSTrackingArea。
    @Published var hoveredRow: String?
    /// 各行在「窗口内容坐标系」(左上原点, y 向下) 的矩形，由行经 onGeometryChange(.global) 上报。
    /// 非 @Published：仅供监视器读取判定，写入不触发重绘。
    var rowRects: [String: CGRect] = [:]
}

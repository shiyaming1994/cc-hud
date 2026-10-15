import SwiftUI
import AppKit
import CCHudCore

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var shape: EdgeShape.Kind = .box

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = EdgeEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.shape = shape
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        (nsView as? EdgeEffectView)?.shape = shape
    }
}

/// 用 maskImage 给毛玻璃裁外形，而不是 layer.mask / masksToBounds——
/// 后者会强制离屏合成、破坏 .behindWindow 透出桌面的毛玻璃效果；maskImage 是官方给毛玻璃做异形的方式。
/// 方框用九宫格遮罩：尺寸变化（悬停展开额度区的每一帧）只拉伸直边，不用重画；
/// 标签尺寸固定，按实际大小画一张，不拉伸（设计文档第 5 节）。
private final class EdgeEffectView: NSVisualEffectView {
    var shape: EdgeShape.Kind = .box {
        didSet { if shape != oldValue { needsLayout = true } }
    }
    private var maskKey = ""

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let key = shape == .box ? "box" : "tab \(bounds.width)x\(bounds.height)"
        guard key != maskKey else { return }
        maskKey = key
        maskImage = shape == .box ? Self.boxMask() : Self.mask(.tab, size: bounds.size)
    }

    private static func boxMask() -> NSImage {
        let img = mask(.box, size: EdgeShape.boxMaskSize)
        let i = EdgeShape.boxMaskInsets
        img.capInsets = NSEdgeInsets(top: i.top, left: i.left, bottom: i.bottom, right: i.right)
        img.resizingMode = .stretch
        return img
    }

    /// flipped：画的时候左上原点、y 向下，和 EdgeShape 的坐标系一致
    private static func mask(_ kind: EdgeShape.Kind, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(EdgeShape.path(kind, in: size))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
    }
}

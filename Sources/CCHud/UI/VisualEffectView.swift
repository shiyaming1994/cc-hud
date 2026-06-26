import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 12
    var isCapsule = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = RoundedEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.cornerRadius = cornerRadius
        v.isCapsule = isCapsule
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        if let r = nsView as? RoundedEffectView {
            r.cornerRadius = cornerRadius
            r.isCapsule = isCapsule
            r.needsLayout = true
        }
    }
}

/// 用 maskImage 给磨砂材质做圆角，而不是 layer.cornerRadius + masksToBounds——
/// masksToBounds 会强制离屏合成、破坏 .behindWindow 透出桌面的毛玻璃透明效果；
/// maskImage 是官方给毛玻璃做异形的方式，圆角与透明两全，且 resize 时随 bounds 自动拉伸。
private final class RoundedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 12
    var isCapsule = false
    private var lastRadius: CGFloat = -1
    override func layout() {
        super.layout()
        guard bounds.height > 1 else { return }
        let r = isCapsule ? bounds.height / 2 : cornerRadius
        if r != lastRadius {
            lastRadius = r
            maskImage = Self.mask(radius: r)
        }
    }
    private static func mask(radius r: CGFloat) -> NSImage {
        let d = max(1, r * 2 + 2)   // 9 宫格：四角固定 r，中间 1px 拉伸
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

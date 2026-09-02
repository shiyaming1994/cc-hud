import AppKit

/// 设计稿《菜单栏额度条 · 齐平》的全部数值。**改样式只改这里。**
///
/// 设计要点：全行只有一个字号 12pt（SF Pro · 等宽数字），百分比、百分号、标签、时刻、
/// token 一律等高；层级只交给字重（500/600/400，告警 700）与明度（L1/L2/L3）；
/// 分组只用空间（组内 4/1.5/5pt、组间 13pt），一个分隔符都不用；>50% 全线无彩色，
/// 色彩是留给紧张态的预算。光晕只挂在 5H 数值上，其余不加，避免整行发糊。
///
/// 本文件 `import AppKit`，明知会破「CCHudCore 不碰 AppKit」的既有约定 —— 那条约定的
/// 目的是"几何分支不单测必出事"，而文字度量同样是纯函数、同样需要测；而"段间距落成
/// 末字尾随 kern"这类算术正是上一轮栽过跟头的地方（自己算行宽算少了 2–3pt，窗口被
/// Auto Layout 撑开、右缘压过状态项左缘）。必须有测试兜着。
public enum StripStyle {
    public static let size: CGFloat = 12

    /// SF Pro · tabular-nums —— 数字等宽，数值跳动时后面的字不跟着左右晃
    public static func font(_ w: StripWeight) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight(w))
    }

    private static func weight(_ w: StripWeight) -> NSFont.Weight {
        switch w {
        case .label:   return .medium      // 500
        case .five:    return .semibold    // 600
        case .seven:   return .regular     // 400
        case .regular: return .regular     // 400
        case .alert:   return .bold        // 700
        }
    }

    public static func tracking(_ t: StripTracking) -> CGFloat {
        switch t {
        case .none:  return 0
        case .label: return 0.4
        case .time:  return 0.1
        case .token: return 0.2
        }
    }

    public static func gap(_ g: StripGap) -> CGFloat {
        switch g {
        case .labelToValue:   return 4
        case .valueToPercent: return 1.5
        case .percentToTime:  return 5
        case .groupGap:       return 13
        }
    }

    public static func color(_ ink: StripInk, dark: Bool) -> NSColor {
        switch ink {
        case .l1:      return hex(dark ? 0xFFFFFF : 0x1A1A1C)
        case .l2:      return hex(dark ? 0xC0C0C8 : 0x4F4F57)
        case .l3:      return hex(dark ? 0x8E8E97 : 0x6B6B72)
        case .caution: return hex(dark ? 0xFFB340 : 0x8A5300)
        case .alert:   return hex(dark ? 0xFF6257 : 0xC22A1F)
        }
    }

    /// 光晕的几何：设计稿 CSS `0 0.5px 1.5px`。AppKit 的 y 向上，投影在下方即负偏移。
    public static let glowOffset = NSSize(width: 0, height: -0.5)
    public static let glowBlurRadius: CGFloat = 1.5

    /// 光晕颜色：浅色菜单栏上用白色描边把深字托起来，深色反之。
    public static func glowColor(dark: Bool) -> NSColor {
        (dark ? NSColor.black : NSColor.white).withAlphaComponent(dark ? 0.55 : 0.60)
    }

    public static func glow(dark: Bool) -> NSShadow {
        shadow(color: glowColor(dark: dark))
    }

    static func shadow(color: NSColor) -> NSShadow {
        let s = NSShadow()
        s.shadowColor = color
        s.shadowOffset = glowOffset
        s.shadowBlurRadius = glowBlurRadius
        return s
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

public enum StripTitle {
    /// 把语义化的 run 序列拼成状态项标题。
    ///
    /// **段间距不用占位字符，而是加到前一段末字的尾随 kern 上。** 依据：`.kern` 会在
    /// 最后一个字符后面也加间距（实测 `"ABC"` kern=5 时宽度正好多 15pt = 3×5）。
    /// 这样宽度完全由系统度量（`NSStatusItem.variableLength`），我们不再自己算行宽 ——
    /// 上一轮就是自己算错才让窗口被撑开、右缘压过状态项左缘的。
    ///
    /// 颜色用 `NSColor(name:dynamicProvider:)` 包一层，深浅外观由系统在绘制时解析，
    /// 不需要我们监听外观变化重画。
    public static func attributed(_ runs: [StripRun]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in runs {
            switch run {
            case .text(let s, let weight, let ink, let tracking, let glow):
                guard !s.isEmpty else { continue }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: StripStyle.font(weight),
                    .foregroundColor: dynamic(ink),
                    .kern: StripStyle.tracking(tracking),
                ]
                if glow { attrs[.shadow] = dynamicGlow }
                out.append(NSAttributedString(string: s, attributes: attrs))
            case .gap(let g):
                // 没有可依附的前一段就丢掉（首位的间距）
                guard out.length > 0 else { continue }
                let i = out.length - 1
                let cur = out.attribute(.kern, at: i, effectiveRange: nil) as? CGFloat ?? 0
                out.addAttribute(.kern, value: cur + StripStyle.gap(g),
                                 range: NSRange(location: i, length: 1))
            }
        }
        return out
    }

    private static func dynamic(_ ink: StripInk) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return StripStyle.color(ink, dark: dark)
        }
    }

    /// 光晕的颜色同样包成动态色，深浅由系统在绘制时解析 —— 不必读 NSApp
    /// （那是 MainActor 隔离的，从这个纯函数里读会破隔离）。
    private static let dynamicGlow = StripStyle.shadow(color: NSColor(name: nil) { appearance in
        StripStyle.glowColor(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    })
}

import SwiftUI
import AppKit
import CCHudCore

enum Theme {
    // 状态色（styles.css :root）
    static let permission = Color(red: 1.0, green: 0.690, blue: 0.180)        // #FFB02E
    static let working = Color(red: 0.302, green: 0.651, blue: 1.0)          // #4DA6FF
    static let idle = Color(red: 0.275, green: 0.753, blue: 0.541)           // #46C08A
    static let dead = Color(red: 0.502, green: 0.518, blue: 0.561)           // #80848F
    static let critBar = Color(red: 1.0, green: 0.420, blue: 0.369)          // #FF6B5E
    static let critText = Color(red: 1.0, green: 0.518, blue: 0.471)         // #FF8478

    static let glass = Color(red: 22/255, green: 22/255, blue: 25/255).opacity(0.72)        // --glass
    static let glassCalm = Color(red: 22/255, green: 22/255, blue: 25/255).opacity(0.60)    // 全空闲更通透
    static let hairline = Color.white.opacity(0.10)
    static let txPrimary = Color.white.opacity(0.92)
    static let txSecondary = Color.white.opacity(0.50)
    static let txTertiary = Color.white.opacity(0.34)
    static let txFaint = Color.white.opacity(0.22)
    static let rowHover = Color.white.opacity(0.055)        // --row-hover
    static let permissionSoft = Color(red: 1.0, green: 0.690, blue: 0.180).opacity(0.16)    // --st-permission-soft
    static let permissionHover = Color(red: 1.0, green: 0.690, blue: 0.180).opacity(0.22)   // .row.is-permission:hover
    static let radius: CGFloat = 12

    static func statusColor(_ s: SessionStatus) -> Color {
        switch s {
        case .permission: return permission
        case .working: return working
        case .idle: return idle
        case .dead: return dead
        }
    }

    /// 上下文用量配色：已用 ≥90 crit，≥72 warn（components.jsx ctxClass）
    static func ctxColor(_ used: Double) -> Color {
        if used >= 90 { return critText }
        if used >= 72 { return permission }
        return txTertiary
    }
    static func ctxBarColor(_ used: Double) -> Color {
        if used >= 90 { return critBar }
        if used >= 72 { return permission }
        return idle
    }
    /// 配额剩余配色：剩余 ≤12 crit，≤30 warn（components.jsx remainClass）
    static func remainColor(_ remain: Double) -> Color {
        if remain <= 12 { return critText }
        if remain <= 30 { return permission }
        return txTertiary
    }
    static func remainBarColor(_ remain: Double) -> Color {
        if remain <= 12 { return critBar.opacity(0.85) }
        if remain <= 30 { return permission.opacity(0.7) }
        return Color.white.opacity(0.35)
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    // ===== 账户额度卡（standalone 重设计）：默认偏暗，仅剩余 <20% 转鲜红告警 =====
    static let quotaLabel  = rgb(110, 118, 129)   // #6e7681 5H/7D/今日 mono 小标签
    static let quotaHero   = rgb(219, 226, 232)   // #dbe2e8 5h 重置时刻（headline）
    static let quotaMuted  = rgb(139, 148, 158)   // #8b949e 时钟图标 / "重置"
    static let quotaSubtle = rgb(123, 132, 142)   // #7b848e 倒计时 / "tokens 已用"
    static let quotaToday  = rgb(194, 202, 209)   // #c2cad1 今日 token 数字
    static let quotaSage   = rgb(123, 154, 134)   // #7b9a86 剩余 >50 calm
    static let quotaAmber  = rgb(169, 140, 79)    // #a98c4f 剩余 20–50 watch
    static let quotaAlarm  = rgb(255, 93, 84)     // #ff5d54 剩余 <20 alarm
    static let quotaCardHi   = Color.white.opacity(0.04)    // 5h hero 卡底
    static let quotaCardLo   = Color.white.opacity(0.022)   // 7d / 今日 卡底
    static let quotaTrack    = Color.white.opacity(0.06)    // 进度条轨道
    static let quotaHairline = Color.white.opacity(0.06)    // hero 非告警描边

    /// 配额剩余配色（standalone level()）：>50 sage，20–50 amber，<20 alarm
    static func quotaColor(remain: Double) -> Color {
        if remain > 50 { return quotaSage }
        if remain >= 20 { return quotaAmber }
        return quotaAlarm
    }

    static let mono = Font.system(size: 11, design: .monospaced)

    /// 状态点基线对齐量：在 `.firstTextBaseline` 行内，让圆点中心落在该字号 x-height 视觉中线
    /// （而非行盒/大写中线）所需的"高出基线"距离。比起对齐行盒中心，更贴合小写项目名，
    /// 且直接由字体度量推导、随字号自适应（不用手填偏移量）。
    static func dotBaselineRise(forFontSize size: CGFloat) -> CGFloat {
        NSFont.systemFont(ofSize: size, weight: .semibold).xHeight / 2
    }
}

import SwiftUI
import CCHudCore

enum Theme {
    // 状态色（styles.css :root）
    static let permission = Color(red: 1.0, green: 0.690, blue: 0.180)        // #FFB02E
    static let working = Color(red: 0.302, green: 0.651, blue: 1.0)          // #4DA6FF
    static let idle = Color(red: 0.275, green: 0.753, blue: 0.541)           // #46C08A
    static let dead = Color(red: 0.502, green: 0.518, blue: 0.561)           // #80848F
    static let critBar = Color(red: 1.0, green: 0.420, blue: 0.369)          // #FF6B5E
    static let critText = Color(red: 1.0, green: 0.518, blue: 0.471)         // #FF8478

    static let glass = Color(red: 22/255, green: 22/255, blue: 25/255).opacity(0.72)
    static let hairline = Color.white.opacity(0.10)
    static let txPrimary = Color.white.opacity(0.92)
    static let txSecondary = Color.white.opacity(0.50)
    static let txTertiary = Color.white.opacity(0.34)
    static let txFaint = Color.white.opacity(0.22)
    static let rowHover = Color.white.opacity(0.055)
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

    static let mono = Font.system(size: 11, design: .monospaced)
}

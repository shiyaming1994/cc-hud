import Foundation

enum Format {
    /// token → "1.2M" / "240K"（components.jsx fmtTokens）
    static func tokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 1_000_000 {
            return n >= 10_000_000 ? String(format: "%.0fM", Double(n) / 1e6)
                                   : String(format: "%.1fM", Double(n) / 1e6)
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))K" }
        return "\(n)"
    }

    /// 重置倒计时 "2h14m" / "3d2h"（components.jsx fmtCountdown）
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// 时长 "2h14m" / "40m"（与 countdown 同格式，直接吃秒数）
    static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 燃尽卡时长 "4h27m" / "4h" / "25m"（吃分钟；有小时则分钟补零，对齐设计稿 fmtDur）
    static func burnDur(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(h)h" + String(format: "%02d", m) + "m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// 无响应粗粒度 "45s" / "3m"（components.jsx fmtCoarse）
    static func coarse(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }

    /// 用时 "4:32"（components.jsx fmtClock）
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

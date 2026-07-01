import Foundation

/// 展示层纯格式化（无 UI 依赖）：放在 CCHudCore 以便单测。app 各视图 import CCHudCore 后照常用 Format.xxx。
public enum Format {
    /// token → "1.2M" / "240K"（components.jsx fmtTokens）
    public static func tokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 1_000_000 {
            return n >= 10_000_000 ? String(format: "%.0fM", Double(n) / 1e6)
                                   : String(format: "%.1fM", Double(n) / 1e6)
        }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))K" }
        return "\(n)"
    }

    /// 重置倒计时 "2h14m" / "3d2h"（components.jsx fmtCountdown）
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// 时长 "2h14m" / "40m"（与 countdown 同格式，直接吃秒数）
    public static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 燃尽卡时长 "4h27m" / "4h" / "25m"（吃分钟；有小时则分钟补零，对齐设计稿 fmtDur）
    public static func burnDur(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(h)h" + String(format: "%02d", m) + "m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// 无响应粗粒度 "45s" / "3m"（components.jsx fmtCoarse）
    public static func coarse(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : "\(s / 60)m"
    }

    /// 用时 "4:32"（components.jsx fmtClock）
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "HH:mm"（24 小时，补零）
    public static func hhmm(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 5h 重置时刻（standalone fiveResetTime）：今日 "14:30"，跨天 "明日 09:00"
    public static func resetTimeShort(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        (calendar.isDate(date, inSameDayAs: now) ? "" : "明日 ") + hhmm(date, calendar: calendar)
    }

    /// 7d 重置时刻（standalone sevenResetTime）："7/3 14:30"
    public static func resetDateTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0) " + hhmm(date, calendar: calendar)
    }

    /// 倒计时（带空格、分钟补零，standalone fmtHM）：5h 用 "4h 50m" / "45m"
    public static func countdownHM(to date: Date, from now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let h = s / 3600, m = (s % 3600) / 60
        if h == 0 && m == 0 { return "<1m" }   // 不到 1 分钟：显示 <1m，不再显示 0m
        return h > 0 ? "\(h)h " + String(format: "%02d", m) + "m" : "\(m)m"
    }

    /// 倒计时（带空格，standalone fmtDH）：7d 用 "6d 18h" / "5h 30m" / "45m"
    public static func countdownDH(to date: Date, from now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h " + String(format: "%02d", m) + "m" }
        return m == 0 ? "<1m" : "\(m)m"
    }
}

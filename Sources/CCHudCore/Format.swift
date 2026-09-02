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

    /// 轮次用时,恒短两段式（宽度 ≤5 字符，HUD 行不换行）：
    /// <1h "分:秒"（4:32 / 10:20）；1–24h 换挡 "时:分"（1:01 / 13:05）；
    /// ≥24h 异常兜底 "Nd+"——正常一轮跑不了一天，精确值无意义，恒短即可。
    /// NaN/无穷/负数一律 "0:00"（Int(NaN) 会 trap，必须先挡）。
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = max(0, Int(seconds))
        if s < 3600 { return "\(s / 60):" + String(format: "%02d", s % 60) }
        if s < 86400 { return "\(s / 3600):" + String(format: "%02d", (s % 3600) / 60) }
        return "\(s / 86400)d+"
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

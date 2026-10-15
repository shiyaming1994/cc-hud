import Foundation

/// 标签（最小档）显示什么（设计文档 4.6）。按顺序判定，命中即停：
/// 有会话等确认权限 → 提示点；没有 5 小时数据 → 「—」；否则 5 小时剩余额度。
/// 叫 EdgeTabContent 不叫 TabContent：SwiftUI（macOS 15）已有同名协议，界面文件里会撞名。
public enum EdgeTabContent: Equatable, Sendable {
    /// 有会话等确认权限：数字藏起来，只显示提示点
    case attention
    /// 没有 5 小时数据：显示「—」
    case noData
    /// 5 小时剩余百分比（0–100，截断取整）；alarm = 剩余低于 AccountUsage.lowQuotaRemainPct
    case remaining(Int, alarm: Bool)

    /// 7 天额度不参与：菜单栏额度条上有 7D（设计文档第 3 节第 6 条）。
    public static func make(statuses: [SessionStatus], account: AccountUsage, now: Date) -> EdgeTabContent {
        if statuses.contains(.permission) { return .attention }
        // 过了重置时刻、还没收到新快照：按已用 0 算（和额度卡片同一个投影）
        let p = AccountUsage.project(usedPct: account.fiveHourUsedPct, resetsAt: account.fiveHourResetsAt,
                                     period: AccountUsage.fiveHourPeriod, now: now)
        // 非有限数直接当没数据：Int(NaN) 会崩
        guard let used = p.usedPct, used.isFinite else { return .noData }
        let remain = max(0, min(100, 100 - used))
        // 截断取整，和列表额度区的「剩 X%」一致；告急按没取整的值判，正好 20 不告急
        return .remaining(Int(remain), alarm: remain < AccountUsage.lowQuotaRemainPct)
    }
}

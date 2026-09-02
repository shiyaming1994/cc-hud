import XCTest
@testable import CCHudCore

/// 同一窗口内用量回落的两种成因，必须分开处理：
///   1. 乱序 / 迟到的旧快照 —— 带着旧数字回来，直接采纳会让显示在新旧值之间来回跳（原有的 max 规则挡的就是它）
///   2. 服务端把额度清了 —— 2026-09-02 发 Fable 5.1 当天就发生过：resets_at 没动，
///      used_percentage 从 15 掉到 2。这种必须认账，否则会一直钉着陈旧的高水位
/// 判据：连续两次报到同一水平才认账。乱序快照不会重复，真重置会一直重复。
@MainActor
final class AccountResetTests: XCTestCase {
    private let sevenReset: TimeInterval = 1_788_832_800

    private func status(_ used: Double, resetsAt: TimeInterval) -> Envelope {
        let json = """
        {"kind":"status","payload":{"session_id":"s1","cwd":"/Users/x/p",
         "rate_limits":{"seven_day":{"used_percentage":\(used),"resets_at":\(Int(resetsAt))}}}}
        """
        return try! JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
    }

    func testSingleLowReadingIsIgnored() {
        let s = StateStore()
        s.apply(status(15, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset))
        XCTAssertEqual(s.account.sevenDayUsedPct, 15, "孤零零一条报低 → 当乱序快照，不采纳")
    }

    func testTwoConsecutiveLowReadingsAreAccepted() {
        let s = StateStore()
        s.apply(status(15, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset))
        XCTAssertEqual(s.account.sevenDayUsedPct, 2, "连着两次都报到这个水平 → 服务端真清了，认账")
    }

    func testConfirmationToleratesUsageClimbingAfterReset() {
        // 重置后用量会立刻开始往上爬，两次确认的值不会完全相等
        let s = StateStore()
        s.apply(status(15, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset))
        s.apply(status(4, resetsAt: sevenReset))
        XCTAssertEqual(s.account.sevenDayUsedPct, 4)
    }

    func testSmallRegressionStillTakesMax() {
        // 1 个点的抖动不算"回落"，照旧取 max，不进确认流程
        let s = StateStore()
        s.apply(status(15, resetsAt: sevenReset))
        s.apply(status(14, resetsAt: sevenReset))
        s.apply(status(14, resetsAt: sevenReset))
        XCTAssertEqual(s.account.sevenDayUsedPct, 15)
    }

    func testWindowRollNeedsNoConfirmation() {
        // 重置时间前移一整个周期 = 窗口真滚了，立刻接受，不必等第二条
        let s = StateStore()
        s.apply(status(15, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset + 7 * 86400))
        XCTAssertEqual(s.account.sevenDayUsedPct, 2)
    }

    func testRisingReadingClearsPendingConfirmation() {
        // 报低一次后又回到高位 → 那条确实是乱序快照，确认态必须清掉，
        // 否则下一次真回落会被"上次那条"错误地确认掉
        let s = StateStore()
        s.apply(status(15, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset))
        s.apply(status(16, resetsAt: sevenReset))
        s.apply(status(2, resetsAt: sevenReset))
        XCTAssertEqual(s.account.sevenDayUsedPct, 16, "确认计数已被清零，这条又是孤例")
    }
}

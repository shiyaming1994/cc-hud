import XCTest
@testable import CCHudCore

/// 额度跨重启保活：同一窗口内用量只增不减是 absorbWindow 的既有不变量，
/// 但重启会把 store 清空、高水位丢失 —— 实测就是这样把 7d "已用 15%" 变回 "已用 1%" 的
/// （2026-09-01 10:00 开的窗口，晚上还剩 85%，次日反复重装后变成剩 99%）。
@MainActor
final class AccountPersistenceTests: XCTestCase {
    private func store(_ d: UserDefaults) -> StateStore { StateStore(defaults: d) }
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "cchud-test-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.dictionaryRepresentation().isEmpty ? "" : "")
        return d
    }

    /// 七天窗口：2026-09-01 10:00 开，2026-09-08 10:00 重置
    private let sevenReset: TimeInterval = 1_788_832_800

    private func status(sevenUsed: Double, resetsAt: TimeInterval) -> Envelope {
        let json = """
        {"kind":"status","payload":{"session_id":"s1","cwd":"/Users/x/p",
         "rate_limits":{"seven_day":{"used_percentage":\(sevenUsed),"resets_at":\(Int(resetsAt))}}}}
        """
        return try! JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
    }

    func testUsageSurvivesRestart() {
        let d = freshDefaults()
        let s1 = store(d)
        s1.apply(status(sevenUsed: 15, resetsAt: sevenReset))
        XCTAssertEqual(s1.account.sevenDayUsedPct, 15)

        // 重启：新建 store 读同一份存档
        let s2 = store(d)
        XCTAssertEqual(s2.account.sevenDayUsedPct, 15, "重启不该丢掉窗口内的高水位")
        XCTAssertEqual(s2.account.sevenDayResetsAt?.timeIntervalSince1970, sevenReset)
    }

    func testRestartThenLowerReadingKeepsHighWaterMark() {
        let d = freshDefaults()
        let s1 = store(d)
        s1.apply(status(sevenUsed: 15, resetsAt: sevenReset))

        let s2 = store(d)
        s2.apply(status(sevenUsed: 1, resetsAt: sevenReset))   // 同一窗口却报了更小的值
        XCTAssertEqual(s2.account.sevenDayUsedPct, 15,
                       "同窗口内用量不可能回落，取 max —— 这正是重启后 85% 变 99% 的那一幕")
    }

    func testWindowRollAfterRestartAcceptsReset() {
        let d = freshDefaults()
        let s1 = store(d)
        s1.apply(status(sevenUsed: 15, resetsAt: sevenReset))

        let s2 = store(d)
        s2.apply(status(sevenUsed: 2, resetsAt: sevenReset + 7 * 86400))  // 窗口真的滚了
        XCTAssertEqual(s2.account.sevenDayUsedPct, 2, "重置时间前移一整个周期 → 接受回落")
    }

    func testEmptyArchiveStartsClean() {
        XCTAssertNil(store(freshDefaults()).account.sevenDayUsedPct)
    }
}

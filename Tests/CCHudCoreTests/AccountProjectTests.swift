import XCTest
@testable import CCHudCore

/// 窗口过期的本地投影：resets_at 一旦过去，该窗口必然已重置——用量归零、
/// 重置点按固定周期滚到当前所在窗口。免得倒计时停在 0s、额度卡在旧值
/// （归零后无新事件，或休眠唤醒后时间跳变）。
final class AccountProjectTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)
    let h5: TimeInterval = 5 * 3600

    func testPeriodConstants() {
        XCTAssertEqual(AccountUsage.fiveHourPeriod, 5 * 3600)
        XCTAssertEqual(AccountUsage.sevenDayPeriod, 7 * 24 * 3600)
    }

    func testNotExpiredReturnsUnchanged() {
        let r = AccountUsage.project(usedPct: 97, resetsAt: t0.addingTimeInterval(600), period: h5, now: t0)
        XCTAssertEqual(r.usedPct, 97)
        XCTAssertEqual(r.resetsAt, t0.addingTimeInterval(600))
    }

    func testJustExpiredZeroesAndRollsOneWindow() {
        let reset = t0.addingTimeInterval(-10)   // 10s 前刚过期
        let r = AccountUsage.project(usedPct: 97, resetsAt: reset, period: h5, now: t0)
        XCTAssertEqual(r.usedPct, 0, "窗口过了 → 用量归零")
        XCTAssertEqual(r.resetsAt, reset.addingTimeInterval(h5), "重置点滚一个周期")
    }

    func testExpiredManyWindowsRollsToCurrent() {   // 休眠很久再唤醒
        let reset = t0.addingTimeInterval(-(h5 * 3 + 600))
        let r = AccountUsage.project(usedPct: 80, resetsAt: reset, period: h5, now: t0)
        XCTAssertEqual(r.usedPct, 0)
        XCTAssertNotNil(r.resetsAt)
        XCTAssertGreaterThan(r.resetsAt!, t0, "推到未来")
        XCTAssertLessThanOrEqual(r.resetsAt!, t0.addingTimeInterval(h5), "不超过一个周期")
    }

    func testAtExactResetInstantRolls() {
        let r = AccountUsage.project(usedPct: 50, resetsAt: t0, period: h5, now: t0)
        XCTAssertEqual(r.usedPct, 0)
        XCTAssertEqual(r.resetsAt, t0.addingTimeInterval(h5))
    }

    func testNilResetUnchanged() {
        let r = AccountUsage.project(usedPct: 50, resetsAt: nil, period: h5, now: t0)
        XCTAssertEqual(r.usedPct, 50)
        XCTAssertNil(r.resetsAt)
    }

    func testNonPositivePeriodGuard() {
        let r = AccountUsage.project(usedPct: 50, resetsAt: t0.addingTimeInterval(-10), period: 0, now: t0)
        XCTAssertEqual(r.usedPct, 50, "周期非法 → 不动")
    }
}

import XCTest
@testable import CCHudCore

/// 低额度告警窗口选取：剩余 <20% 才告警，两个窗口都低时挑最紧张的那个，
/// 且判断基于按当前时间投影后的剩余（过期窗口已归零就不该再告警）。
final class AccountAlertTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func acc(fiveUsed: Double? = nil, fiveReset: Double? = nil,
                     sevenUsed: Double? = nil, sevenReset: Double? = nil) -> AccountUsage {
        var a = AccountUsage()
        a.fiveHourUsedPct = fiveUsed
        a.fiveHourResetsAt = fiveReset.map { Date(timeIntervalSince1970: $0) }
        a.sevenDayUsedPct = sevenUsed
        a.sevenDayResetsAt = sevenReset.map { Date(timeIntervalSince1970: $0) }
        return a
    }

    func testNoWindowLowReturnsNil() {
        let a = acc(fiveUsed: 40, fiveReset: t0.addingTimeInterval(3600).timeIntervalSince1970)
        XCTAssertNil(a.alertWindow(now: t0), "剩余 60% → 不告警")
    }

    func testFiveHourLowDetected() {
        let a = acc(fiveUsed: 85, fiveReset: t0.addingTimeInterval(3600).timeIntervalSince1970)
        let w = a.alertWindow(now: t0)
        XCTAssertEqual(w?.label, "5h")
        XCTAssertEqual(w?.remainPct, 15)
    }

    func testExactlyTwentyNotAlerted() {
        let a = acc(fiveUsed: 80, fiveReset: t0.addingTimeInterval(3600).timeIntervalSince1970)
        XCTAssertNil(a.alertWindow(now: t0), "剩余正好 20% → 阈值是 <20，不告警")
    }

    func testPicksMostUrgentOfTwo() {
        let a = acc(fiveUsed: 85, fiveReset: t0.addingTimeInterval(3600).timeIntervalSince1970,
                    sevenUsed: 90, sevenReset: t0.addingTimeInterval(86400).timeIntervalSince1970)
        let w = a.alertWindow(now: t0)
        XCTAssertEqual(w?.label, "7d", "7d 剩 10% 比 5h 剩 15% 更紧张")
        XCTAssertEqual(w?.remainPct, 10)
    }

    func testExpiredWindowZeroedSoNoAlert() {
        // 5h 已用满但窗口已过期 → 投影归零（剩余 100%）→ 不该再告警
        let a = acc(fiveUsed: 95, fiveReset: t0.addingTimeInterval(-10).timeIntervalSince1970)
        XCTAssertNil(a.alertWindow(now: t0), "过期窗口投影归零，不告警")
    }

    func testNilUsageNoAlert() {
        XCTAssertNil(AccountUsage().alertWindow(now: t0), "没有任何额度数据 → 不告警")
    }
}

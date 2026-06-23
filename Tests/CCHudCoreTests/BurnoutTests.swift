import XCTest
@testable import CCHudCore

/// 5h 燃尽预测 + 升档去重：按当前速率会不会在重置前烧光，断档恶化才升级提醒。
final class BurnoutTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    // MARK: 纯预测

    func testHeavyUseWarns() {
        var a = AccountUsage()
        a.fiveHourUsedPct = 60                                  // 过 1h 用了 60%
        a.fiveHourResetsAt = t0.addingTimeInterval(4 * 3600)    // 距重置 4h
        let f = a.burnoutForecast(now: t0)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.dropMinutes, 200, accuracy: 1, "约第 2 小时见底，断档 ~200min")
        XCTAssertEqual(f!.remainingPct, 40, "剩余 40%")
    }

    func testLightUseNoWarn() {
        var a = AccountUsage()
        a.fiveHourUsedPct = 5
        a.fiveHourResetsAt = t0.addingTimeInterval(4 * 3600)
        XCTAssertNil(a.burnoutForecast(now: t0), "慢用撑得到重置 → 不警")
    }

    func testWarmupNoWarn() {
        var a = AccountUsage()
        a.fiveHourUsedPct = 50
        a.fiveHourResetsAt = t0.addingTimeInterval(5 * 3600 - 600)   // 才过 10min
        XCTAssertNil(a.burnoutForecast(now: t0), "预热期内速率噪声大 → 不警")
    }

    func testExpiredWindowNoWarn() {
        var a = AccountUsage()
        a.fiveHourUsedPct = 95
        a.fiveHourResetsAt = t0.addingTimeInterval(-10)   // 已过期 → 投影归零
        XCTAssertNil(a.burnoutForecast(now: t0), "窗口已重置，不警")
    }

    func testTierBoundaries() {
        XCTAssertEqual(AccountUsage.burnoutTier(dropMinutes: 29), 0)
        XCTAssertEqual(AccountUsage.burnoutTier(dropMinutes: 30), 1)
        XCTAssertEqual(AccountUsage.burnoutTier(dropMinutes: 60), 2)
        XCTAssertEqual(AccountUsage.burnoutTier(dropMinutes: 120), 3)
    }

    // MARK: StateStore 升档去重

    private func status(used: Double, resetsAt: Double) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: """
        {"kind":"status","claudePid":100,"tty":"ttys012","payload":{"session_id":"s1","cwd":"/x/p",
         "rate_limits":{"five_hour":{"used_percentage":\(used),"resets_at":\(resetsAt)}}}}
        """.data(using: .utf8)!)
    }

    @MainActor func testUpgradeFiresOnlyOnHigherTier() {
        let store = StateStore()
        var fires: [Double] = []
        store.onBurnoutWarning = { _, drop, _ in fires.append(drop) }
        let reset = t0.addingTimeInterval(4 * 3600).timeIntervalSince1970
        store.apply(status(used: 25, resetsAt: reset), at: t0)   // 断档 ~60min → tier2
        store.apply(status(used: 40, resetsAt: reset), at: t0)   // 断档 ~150min → tier3
        store.apply(status(used: 42, resetsAt: reset), at: t0)   // 仍 tier3 → 不弹
        XCTAssertEqual(fires.count, 2, "升档弹两次，同档不重复")
    }

    @MainActor func testNewWindowResetsTier() {
        let store = StateStore()
        var fires = 0
        store.onBurnoutWarning = { _, _, _ in fires += 1 }
        store.apply(status(used: 25, resetsAt: t0.addingTimeInterval(4 * 3600).timeIntervalSince1970), at: t0)
        XCTAssertEqual(fires, 1)
        let t1 = t0.addingTimeInterval(6 * 3600)   // 进了下一个窗口
        store.apply(status(used: 25, resetsAt: t1.addingTimeInterval(4 * 3600).timeIntervalSince1970), at: t1)
        XCTAssertEqual(fires, 2, "新窗口档位清零，同 tier 再次触发")
    }
}

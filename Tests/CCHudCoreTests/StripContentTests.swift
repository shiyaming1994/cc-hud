import XCTest
@testable import CCHudCore

/// 额度条"显示什么"的全部规则。这套逻辑原先埋在 MenuBarStripView 的 private 方法里、
/// 一条测试都没有 —— 搬进 CCHudCore 的首要目的就是把它测起来。
final class StripContentTests: XCTestCase {
    /// 2026-09-02 14:00:00 +08:00
    private let now = Date(timeIntervalSince1970: 1_788_328_800)

    /// 5H 剩 68%（已用 32），16:45 重置；7D 剩 96%（已用 4），6 天后重置
    private func account(fiveUsed: Double? = 32, fiveResetIn: TimeInterval? = 2.75 * 3600,
                         sevenUsed: Double? = 4, sevenResetIn: TimeInterval? = 6 * 86400)
        -> AccountUsage {
        var a = AccountUsage()
        a.fiveHourUsedPct = fiveUsed
        a.fiveHourResetsAt = fiveResetIn.map { now.addingTimeInterval($0) }
        a.sevenDayUsedPct = sevenUsed
        a.sevenDayResetsAt = sevenResetIn.map { now.addingTimeInterval($0) }
        return a
    }

    /// 只取文本，忽略间距 —— 断言"显示了哪些字"时用
    private func texts(_ runs: [StripRun]) -> [String] {
        runs.compactMap { if case .text(let s, _, _, _, _) = $0 { return s } else { return nil } }
    }

    // MARK: 五档各显示什么

    func testFullLevelShowsBothWindowsAndToken() {
        let r = StripContent.runs(account: account(), todayTokens: 59_000_000,
                                  level: .full, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45", "7D", "96", "%", "59M"])
    }

    func testNoTokenLevelDropsTheTokenSegment() {
        let r = StripContent.runs(account: account(), todayTokens: 59_000_000,
                                  level: .noToken, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45", "7D", "96", "%"])
    }

    func testNoFiveTimeLevelDropsTheFiveHourResetTime() {
        let r = StripContent.runs(account: account(), todayTokens: 59_000_000,
                                  level: .noFiveTime, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "7D", "96", "%"])
    }

    func testTightestWithTimeKeepsOnlyOneSegment() {
        let r = StripContent.runs(account: account(), todayTokens: 59_000_000,
                                  level: .tightestWithTime, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45"], "宽松时最紧的是 5H")
    }

    func testTightestDropsTheTime() {
        let r = StripContent.runs(account: account(), todayTokens: 59_000_000,
                                  level: .tightest, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%"])
    }

    // MARK: 最紧的那一段

    func testSevenDayBecomesTightestWhenItIsLower() {
        // 5H 剩 68、7D 剩 10 → 最紧的是 7D
        let a = account(sevenUsed: 90)
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(texts(r), ["7D", "10", "%"])
    }

    // MARK: 7D 倒计时的出没（相关性规则，与档位无关）

    func testSevenDayCountdownAppearsWhenQuotaLow() {
        // 7D 剩 10% < 20% → 多出倒计时
        let a = account(sevenUsed: 90)
        let r = StripContent.runs(account: a, todayTokens: 0, level: .noToken, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45", "7D", "10", "%", "6d 0h"])
    }

    func testSevenDayCountdownAppearsWhenResetIsNear() {
        // 7D 剩 96% 但只剩 23h 就重置 → 也要显示
        let a = account(sevenResetIn: 23 * 3600)
        let r = StripContent.runs(account: a, todayTokens: 0, level: .noToken, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45", "7D", "96", "%", "23h 00m"])
    }

    func testSevenDayCountdownHiddenWhenComfortable() {
        let r = StripContent.runs(account: account(), todayTokens: 0, level: .noToken, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45", "7D", "96", "%"])
    }

    // MARK: token

    func testTokenSegmentHiddenWhenZero() {
        // 扫描失败 / 未启动时恒返回 0（不是 nil），所以判 > 0 才算有数据
        let r = StripContent.runs(account: account(), todayTokens: 0, level: .full, now: now)
        XCTAssertEqual(texts(r), ["5H", "68", "%", "16:45", "7D", "96", "%"])
    }

    // MARK: 5H 重置时刻跨天

    func testFiveHourResetCrossingMidnightSaysTomorrow() {
        // 14:00 + 11.5h = 次日 01:30
        let a = account(fiveResetIn: 11.5 * 3600)
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightestWithTime, now: now)
        XCTAssertEqual(texts(r).last, "明日 01:30")
    }

    // MARK: 缺数据

    func testMissingFiveHourDropsThatSegment() {
        let a = account(fiveUsed: nil, fiveResetIn: nil)
        let r = StripContent.runs(account: a, todayTokens: 0, level: .noToken, now: now)
        XCTAssertEqual(texts(r), ["7D", "96", "%"])
    }

    func testMissingBothWindowsYieldsEmpty() {
        let a = account(fiveUsed: nil, fiveResetIn: nil, sevenUsed: nil, sevenResetIn: nil)
        XCTAssertTrue(StripContent.runs(account: a, todayTokens: 0, level: .full, now: now).isEmpty,
                      "两个窗口都没数据 → 空序列 → 状态项退回纯图标")
    }

    func testMissingBothWindowsStillEmptyEvenWithTokens() {
        let a = account(fiveUsed: nil, fiveResetIn: nil, sevenUsed: nil, sevenResetIn: nil)
        XCTAssertTrue(StripContent.runs(account: a, todayTokens: 59_000_000,
                                        level: .full, now: now).isEmpty,
                      "token 不能单独成条 —— 它没有标签，孤零零一个数字看不懂")
    }

    // MARK: 告警档位（边界）

    func testNoColourAboveFiftyPercentRemaining() {
        let a = account(fiveUsed: 49)          // 剩 51
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(r[2], .text("51", weight: .five, ink: .l1, tracking: .none, glow: true))
    }

    func testCautionAtFiftyPercentRemaining() {
        let a = account(fiveUsed: 50)          // 剩 50
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(r[2], .text("50", weight: .alert, ink: .caution, tracking: .none, glow: true))
    }

    func testCautionAtTwentyPercentRemaining() {
        let a = account(fiveUsed: 80)          // 剩 20
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(r[2], .text("20", weight: .alert, ink: .caution, tracking: .none, glow: true))
    }

    func testAlertBelowTwentyPercentRemaining() {
        let a = account(fiveUsed: 81)          // 剩 19
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(r[2], .text("19", weight: .alert, ink: .alert, tracking: .none, glow: true))
    }

    func testPercentSignFollowsTheValuesToneButKeepsL3WhenNormal() {
        let calm = StripContent.runs(account: account(), todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(calm[4], .text("%", weight: .five, ink: .l3, tracking: .none, glow: false))
        let hot = StripContent.runs(account: account(fiveUsed: 90), todayTokens: 0,
                                    level: .tightest, now: now)
        XCTAssertEqual(hot[4], .text("%", weight: .alert, ink: .alert, tracking: .none, glow: false))
    }

    // MARK: 段间距

    func testGapsWithinAndBetweenGroups() {
        let r = StripContent.runs(account: account(), todayTokens: 0, level: .noFiveTime, now: now)
        // 5H ⟨4⟩ 68 ⟨1.5⟩ % ⟨13⟩ 7D ⟨4⟩ 96 ⟨1.5⟩ %
        XCTAssertEqual(r[1], .gap(.labelToValue))
        XCTAssertEqual(r[3], .gap(.valueToPercent))
        XCTAssertEqual(r[5], .gap(.groupGap))
        XCTAssertEqual(r[7], .gap(.labelToValue))
    }

    func testTimeTailUsesPercentToTimeGap() {
        let r = StripContent.runs(account: account(), todayTokens: 0,
                                  level: .tightestWithTime, now: now)
        XCTAssertEqual(r[5], .gap(.percentToTime))
    }

    func testNoLeadingOrTrailingGap() {
        let r = StripContent.runs(account: account(), todayTokens: 59_000_000,
                                  level: .full, now: now)
        if case .gap = r.first! { XCTFail("首位不应是间距") }
        if case .gap = r.last! { XCTFail("末位不应是间距") }
    }

    // MARK: 过期窗口的本地校正

    func testExpiredWindowProjectsToFreshlyReset() {
        // resets_at 已过去 → AccountUsage.project 归零并把重置点滚到下一个窗口。
        // 只留 5H 一个窗口，免得归零后"最紧的一段"变成 7D 而测不到这一点。
        let a = account(fiveUsed: 90, fiveResetIn: -600, sevenUsed: nil, sevenResetIn: nil)
        let r = StripContent.runs(account: a, todayTokens: 0, level: .tightest, now: now)
        XCTAssertEqual(texts(r), ["5H", "100", "%"], "过期即已重置 → 剩余 100%")
    }

    func testExpiredWindowRollsResetTimeForward() {
        let a = account(fiveUsed: 90, fiveResetIn: -600, sevenUsed: nil, sevenResetIn: nil)
        let r = StripContent.runs(account: a, todayTokens: 0,
                                  level: .tightestWithTime, now: now)
        // 13:50 已过 → 滚到 +5h = 18:50
        XCTAssertEqual(texts(r).last, "18:50")
    }
}

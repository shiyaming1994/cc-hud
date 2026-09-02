import XCTest
@testable import CCHudCore

/// 7D 重置时刻值不值得占这点宽度：剩余低于 20%，或距重置不足 24h。
/// 判据从 MenuBarStrip 搬到 AccountUsage —— 它本就只依赖 AccountUsage.lowQuotaRemainPct。
final class AccountResetDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testShownWhenQuotaLow() {
        XCTAssertTrue(AccountUsage.showsSevenDayReset(
            remainPct: 19, resetsAt: now.addingTimeInterval(5 * 86400), now: now))
    }

    func testHiddenAtExactly20Percent() {
        XCTAssertFalse(AccountUsage.showsSevenDayReset(
            remainPct: 20, resetsAt: now.addingTimeInterval(5 * 86400), now: now),
                       "判据是「低于 20%」，20 本身不触发")
    }

    func testShownWhenResetWithin24h() {
        XCTAssertTrue(AccountUsage.showsSevenDayReset(
            remainPct: 80, resetsAt: now.addingTimeInterval(23 * 3600), now: now))
    }

    func testHiddenAtExactly24h() {
        XCTAssertFalse(AccountUsage.showsSevenDayReset(
            remainPct: 80, resetsAt: now.addingTimeInterval(24 * 3600), now: now))
    }

    func testHiddenWhenComfortable() {
        XCTAssertFalse(AccountUsage.showsSevenDayReset(
            remainPct: 41, resetsAt: now.addingTimeInterval(3 * 86400), now: now))
    }

    func testHiddenWithoutResetDate() {
        // 没有重置时刻可显示 → 只剩"低额度"这一条也没东西可展示
        XCTAssertFalse(AccountUsage.showsSevenDayReset(remainPct: 5, resetsAt: nil, now: now))
    }
}

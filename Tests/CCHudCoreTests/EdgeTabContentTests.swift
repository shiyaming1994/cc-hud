import XCTest
@testable import CCHudCore

/// 标签显示什么（设计文档 4.6）：等确认权限 → 提示点；没有 5 小时数据 → —；
/// 否则 5 小时剩余，截断取整，低于 20 告急。7 天额度不参与。
final class EdgeTabContentTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_765_000_000)

    /// 5 小时已用 used、resetIn 秒后重置；d7 = 7 天已用
    private func account(fiveHourUsed used: Double?, resetIn: TimeInterval = 3600,
                         sevenDayUsed d7: Double? = nil) -> AccountUsage {
        var a = AccountUsage()
        a.fiveHourUsedPct = used
        a.fiveHourResetsAt = used == nil ? nil : now.addingTimeInterval(resetIn)
        a.sevenDayUsedPct = d7
        a.sevenDayResetsAt = d7 == nil ? nil : now.addingTimeInterval(86_400)
        return a
    }

    private func make(_ statuses: [SessionStatus], _ a: AccountUsage) -> EdgeTabContent {
        EdgeTabContent.make(statuses: statuses, account: a, now: now)
    }

    func testPermissionWinsOverQuota() {
        XCTAssertEqual(make([.working, .permission], account(fiveHourUsed: 90)), .attention)
    }

    func testPermissionWinsEvenWithoutQuotaData() {
        XCTAssertEqual(make([.permission], AccountUsage()), .attention)
    }

    func testNoFiveHourDataShowsDash() {
        XCTAssertEqual(make([.idle], AccountUsage()), .noData)
    }

    func testRemainingTruncates() {
        XCTAssertEqual(make([.working], account(fiveHourUsed: 37.3)), .remaining(62, alarm: false),
                       "剩 62.7 → 显示 62，和列表额度区的「剩 X%」一样直接截断")
    }

    func testBelowTwentyIsAlarm() {
        XCTAssertEqual(make([], account(fiveHourUsed: 80.1)), .remaining(19, alarm: true))
    }

    func testExactlyTwentyIsNotAlarm() {
        XCTAssertEqual(make([], account(fiveHourUsed: 80)), .remaining(20, alarm: false))
    }

    func testExpiredWindowShowsHundred() {
        XCTAssertEqual(make([], account(fiveHourUsed: 95, resetIn: -10)), .remaining(100, alarm: false),
                       "过了重置时刻、还没收到新快照 → 按已用 0 算")
    }

    func testUsedOverHundredClampsToZero() {
        XCTAssertEqual(make([], account(fiveHourUsed: 104)), .remaining(0, alarm: true))
    }

    func testNegativeUsedClampsToHundred() {
        XCTAssertEqual(make([], account(fiveHourUsed: -3)), .remaining(100, alarm: false))
    }

    func testNonFiniteUsedIsNoData() {
        XCTAssertEqual(make([], account(fiveHourUsed: .nan)), .noData, "Int(NaN) 会崩，必须先挡")
        XCTAssertEqual(make([], account(fiveHourUsed: .infinity)), .noData)
    }

    func testSevenDayIsIgnored() {
        XCTAssertEqual(make([.working, .idle, .dead], account(fiveHourUsed: 10, sevenDayUsed: 95)),
                       .remaining(90, alarm: false), "7 天告急不在标签上提示")
    }
}

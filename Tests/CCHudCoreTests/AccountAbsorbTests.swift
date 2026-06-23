import XCTest
@testable import CCHudCore

/// 额度吸收的单调性：多会话各自上报快照，闲置会话的旧数字不能把显示拽回去。
@MainActor
final class AccountAbsorbTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func status(_ pct: Double, resetsAt: Double, sid: String = "s1") -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: """
        {"kind":"status","claudePid":100,"tty":"ttys012","payload":{"session_id":"\(sid)","cwd":"/x/p",
         "rate_limits":{"five_hour":{"used_percentage":\(pct),"resets_at":\(resetsAt)}}}}
        """.data(using: .utf8)!)
    }

    func testStaleLowerSnapshotDoesNotRegress() {
        let store = StateStore()
        store.apply(status(5, resetsAt: 1_765_008_000), at: t0)
        store.apply(status(3, resetsAt: 1_765_008_000, sid: "s2"), at: t0)   // 闲置会话的旧快照
        XCTAssertEqual(store.account.fiveHourUsedPct, 5, "同窗口内不回跳")
    }

    func testFresherHigherSnapshotWins() {
        let store = StateStore()
        store.apply(status(3, resetsAt: 1_765_008_000), at: t0)
        store.apply(status(5, resetsAt: 1_765_008_000, sid: "s2"), at: t0)
        XCTAssertEqual(store.account.fiveHourUsedPct, 5)
    }

    func testWindowRollAcceptsDrop() {
        let store = StateStore()
        store.apply(status(97, resetsAt: 1_765_008_000), at: t0)
        store.apply(status(2, resetsAt: 1_765_026_000), at: t0)   // 重置时间前移 5h：新窗口
        XCTAssertEqual(store.account.fiveHourUsedPct, 2, "窗口滚动后接受回落")
        XCTAssertEqual(store.account.fiveHourResetsAt, Date(timeIntervalSince1970: 1_765_026_000))
    }

    func testLateSnapshotFromOldWindowIgnored() {
        let store = StateStore()
        store.apply(status(2, resetsAt: 1_765_026_000), at: t0)
        store.apply(status(97, resetsAt: 1_765_008_000, sid: "s2"), at: t0)   // 旧窗口迟到快照
        XCTAssertEqual(store.account.fiveHourUsedPct, 2, "旧窗口快照整条忽略")
        XCTAssertEqual(store.account.fiveHourResetsAt, Date(timeIntervalSince1970: 1_765_026_000))
    }

    func testResetJitterTreatedAsSameWindow() {
        let store = StateStore()
        store.apply(status(5, resetsAt: 1_765_008_000), at: t0)
        store.apply(status(3, resetsAt: 1_765_008_030, sid: "s2"), at: t0)   // 30s 抖动
        XCTAssertEqual(store.account.fiveHourUsedPct, 5, "±60s 内视为同窗，不算滚动")
        XCTAssertEqual(store.account.fiveHourResetsAt, Date(timeIntervalSince1970: 1_765_008_000))
    }

    func testSevenDayIndependent() {
        let store = StateStore()
        store.apply(try! JSONDecoder().decode(Envelope.self, from: """
        {"kind":"status","claudePid":100,"tty":"ttys012","payload":{"session_id":"s1","cwd":"/x/p",
         "rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1765008000},
                        "seven_day":{"used_percentage":44,"resets_at":1765267200}}}}
        """.data(using: .utf8)!), at: t0)
        store.apply(try! JSONDecoder().decode(Envelope.self, from: """
        {"kind":"status","claudePid":101,"tty":"ttys013","payload":{"session_id":"s2","cwd":"/x/q",
         "rate_limits":{"seven_day":{"used_percentage":40,"resets_at":1765267200}}}}
        """.data(using: .utf8)!), at: t0)
        XCTAssertEqual(store.account.fiveHourUsedPct, 5, "缺 5h 字段的快照不影响 5h")
        XCTAssertEqual(store.account.sevenDayUsedPct, 44, "7d 同样不回跳")
    }
}

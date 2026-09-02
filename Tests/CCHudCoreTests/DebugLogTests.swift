import XCTest
@testable import CCHudCore

/// 诊断落盘的限速。限速键必须是**会话**而不是事件类型：
/// status 事件由每个已开会话各自上报，按类型限速的话最活跃的那个会把配额吃光，
/// 样本里永远看不到闲置会话报了什么 —— 而"闲置会话到底报不报陈旧额度"正是要取证的问题。
final class DebugLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRateLimitIsPerKeyNotGlobal() {
        var last: [String: Date] = [:]
        XCTAssertTrue(DebugLog.allowDump(key: "status/sess-a", at: t0, minInterval: 30, last: &last))
        XCTAssertTrue(DebugLog.allowDump(key: "status/sess-b", at: t0, minInterval: 30, last: &last),
                      "另一个会话的第一条不该被前一个会话的配额挡掉")
    }

    func testRepeatWithinIntervalIsSuppressed() {
        var last: [String: Date] = [:]
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0, minInterval: 30, last: &last))
        XCTAssertFalse(DebugLog.allowDump(key: "k", at: t0.addingTimeInterval(29),
                                          minInterval: 30, last: &last))
    }

    func testAllowedAgainOnceIntervalElapsed() {
        var last: [String: Date] = [:]
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0, minInterval: 30, last: &last))
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0.addingTimeInterval(30),
                                         minInterval: 30, last: &last))
    }

    func testSuppressedCallDoesNotPushTheWindowForward() {
        // 被挡掉的那条不能刷新时间戳，否则高频事件会把窗口一路推后、永远落不了盘
        var last: [String: Date] = [:]
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0, minInterval: 30, last: &last))
        _ = DebugLog.allowDump(key: "k", at: t0.addingTimeInterval(20), minInterval: 30, last: &last)
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0.addingTimeInterval(30),
                                         minInterval: 30, last: &last))
    }

    func testZeroIntervalNeverSuppresses() {
        var last: [String: Date] = [:]
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0, minInterval: 0, last: &last))
        XCTAssertTrue(DebugLog.allowDump(key: "k", at: t0, minInterval: 0, last: &last))
    }
}

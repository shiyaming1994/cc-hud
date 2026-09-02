import XCTest
@testable import CCHudCore

/// 状态项标题要在额度变化时重画。status 事件实测可达 2 条/300ms，所以回调必须只在
/// 值真的变了时触发 —— 否则菜单栏每秒重画好几次。
@MainActor
final class AccountChangeCallbackTests: XCTestCase {
    private let reset: TimeInterval = 1_788_832_800

    private func status(_ used: Double, resetsAt: TimeInterval) -> Envelope {
        let json = """
        {"kind":"status","payload":{"session_id":"s1","cwd":"/Users/x/p",
         "rate_limits":{"seven_day":{"used_percentage":\(used),"resets_at":\(Int(resetsAt))}}}}
        """
        return try! JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
    }

    func testFiresWhenAccountValuesChange() {
        let s = StateStore()
        var hits = 0
        s.onAccountChanged = { hits += 1 }
        s.apply(status(10, resetsAt: reset))
        XCTAssertEqual(hits, 1)
    }

    func testDoesNotFireWhenNothingChanged() {
        let s = StateStore()
        s.apply(status(10, resetsAt: reset))
        var hits = 0
        s.onAccountChanged = { hits += 1 }
        s.apply(status(10, resetsAt: reset))
        s.apply(status(10, resetsAt: reset))
        XCTAssertEqual(hits, 0, "同一份数字重复上报不该触发重画")
    }

    func testFiresAgainOnFurtherChange() {
        let s = StateStore()
        var hits = 0
        s.onAccountChanged = { hits += 1 }
        s.apply(status(10, resetsAt: reset))
        s.apply(status(10, resetsAt: reset))
        s.apply(status(11, resetsAt: reset))
        XCTAssertEqual(hits, 2)
    }
}

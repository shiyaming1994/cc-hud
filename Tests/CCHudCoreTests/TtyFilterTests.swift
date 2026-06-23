import XCTest
@testable import CCHudCore

@MainActor
final class TtyFilterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }

    func testHookWithoutTtyDoesNotCreateRow() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"hook","claudePid":500,"payload":{"hook_event_name":"SessionStart","session_id":"bg-1","cwd":"/Users/x/.claude"}}
        """), at: t0)
        XCTAssertTrue(store.sessions.isEmpty, "无 tty 的后台 claude 不上 HUD")
    }

    func testStatusWithoutTtyAbsorbsAccountOnly() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"status","claudePid":500,"payload":{"session_id":"bg-2","cwd":"/Users/x/.cache",
         "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1765008080}}}}
        """), at: t0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.account.fiveHourUsedPct, 40, "配额数据照常吸收")
    }

    func testEventWithTtyCreatesRow() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"hook","claudePid":501,"tty":"ttys009","payload":{"hook_event_name":"SessionStart","session_id":"fg-1","cwd":"/x/proj"}}
        """), at: t0)
        XCTAssertNotNil(store.sessions["fg-1"])
    }

    func testExistingSessionStillUpdatedEvenIfLaterEventLacksTty() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"hook","claudePid":501,"tty":"ttys009","payload":{"hook_event_name":"SessionStart","session_id":"fg-1","cwd":"/x/proj"}}
        """), at: t0)
        store.apply(env("""
        {"kind":"hook","payload":{"hook_event_name":"UserPromptSubmit","session_id":"fg-1","cwd":"/x/proj"}}
        """), at: t0.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["fg-1"]!.status, .working, "已存在的会话不受 tty 缺失影响")
    }
}

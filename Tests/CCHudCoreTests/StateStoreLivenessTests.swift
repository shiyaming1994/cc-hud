import XCTest
@testable import CCHudCore

@MainActor
final class StateStoreLivenessTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }

    func testStatusUpdatesCtxAndAccount() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"status","claudePid":100,"tty":"ttys012","payload":{"session_id":"s1","cwd":"/x/p",
         "model":{"display_name":"Fable"},"context_window":{"used_percentage":84},
         "rate_limits":{"five_hour":{"used_percentage":38,"resets_at":1765008080},
                        "seven_day":{"used_percentage":22,"resets_at":1765267200}}}}
        """), at: t0)
        XCTAssertEqual(store.sessions["s1"]!.ctxPct, 84)
        XCTAssertEqual(store.sessions["s1"]!.model, "Fable")
        XCTAssertEqual(store.account.fiveHourUsedPct, 38)
        XCTAssertEqual(store.account.sevenDayResetsAt, Date(timeIntervalSince1970: 1_765_267_200))
    }
}

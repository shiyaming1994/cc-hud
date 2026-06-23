import XCTest
@testable import CCHudCore

@MainActor
final class DisplayOrderTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }
    private func add(_ store: StateStore, sid: String, cwd: String, event: String, offset: TimeInterval) {
        store.apply(env("""
        {"kind":"hook","tty":"ttys-\(sid)","payload":{"hook_event_name":"\(event)","session_id":"\(sid)","cwd":"\(cwd)"}}
        """), at: t0.addingTimeInterval(offset))
    }

    func testUrgencyOrderThenRoundStart() {
        let store = StateStore()
        add(store, sid: "idle1", cwd: "/x/a", event: "SessionStart", offset: 0)
        add(store, sid: "work-late", cwd: "/x/b", event: "UserPromptSubmit", offset: 30)
        add(store, sid: "work-early", cwd: "/x/c", event: "UserPromptSubmit", offset: 10)
        add(store, sid: "perm1", cwd: "/x/d", event: "UserPromptSubmit", offset: 20)
        add(store, sid: "perm1", cwd: "/x/d", event: "PermissionRequest", offset: 21)
        let ids = store.displaySessions().map(\.id)
        XCTAssertEqual(ids, ["perm1", "work-early", "work-late", "idle1"])
    }

    func testManualOrderFirstThenRestByUrgency() {
        let store = StateStore()
        add(store, sid: "a", cwd: "/x/a", event: "SessionStart", offset: 0)
        add(store, sid: "b", cwd: "/x/b", event: "UserPromptSubmit", offset: 1)
        add(store, sid: "c", cwd: "/x/c", event: "UserPromptSubmit", offset: 2)
        let ids = store.displaySessions(manualOrder: ["c", "ghost", "a"]).map(\.id)
        XCTAssertEqual(ids, ["c", "a", "b"], "手动顺序优先，未列出的按紧急度追加，不存在的 id 忽略")
    }

    func testDupNumbersForSameProjectName() {
        let store = StateStore()
        add(store, sid: "s1", cwd: "/x/extension", event: "SessionStart", offset: 0)
        add(store, sid: "s2", cwd: "/y/extension", event: "SessionStart", offset: 1)
        add(store, sid: "s3", cwd: "/x/solo", event: "SessionStart", offset: 2)
        let list = store.displaySessions()
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        XCTAssertEqual(byId["s1"]!.dup, 1, "同名按 createdAt 顺序编号")
        XCTAssertEqual(byId["s2"]!.dup, 2)
        XCTAssertNil(byId["s3"]!.dup)
    }
}

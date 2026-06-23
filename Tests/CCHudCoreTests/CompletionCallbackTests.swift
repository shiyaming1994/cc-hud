import XCTest
@testable import CCHudCore

@MainActor
final class CompletionCallbackTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }
    private func hook(_ event: String, sid: String = "s1") -> Envelope {
        env("""
        {"kind":"hook","claudePid":100,"tty":"ttys001","payload":{"hook_event_name":"\(event)","session_id":"\(sid)","cwd":"/x/pigeon"}}
        """)
    }

    func testCompletionFiredOnWorkingToStop() {
        let store = StateStore()
        var fired: (name: String, elapsed: TimeInterval)? = nil
        store.onCompletion = { session, elapsed in
            fired = (session.projectName, elapsed)
        }
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("Stop"), at: t0.addingTimeInterval(272))
        XCTAssertEqual(fired?.name, "pigeon")
        XCTAssertEqual(fired?.elapsed, 272)
    }

    func testNoCompletionOnIdleStop() {
        let store = StateStore()
        var count = 0
        store.onCompletion = { _, _ in count += 1 }
        store.apply(hook("SessionStart"), at: t0)
        store.apply(hook("Stop"), at: t0.addingTimeInterval(1))
        XCTAssertEqual(count, 0, "本来就空闲的 Stop 不算完成")
    }

    func testCompletionFromPermissionStateAlsoFires() {
        let store = StateStore()
        var count = 0
        store.onCompletion = { _, _ in count += 1 }
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("PermissionRequest"), at: t0.addingTimeInterval(5))
        store.apply(hook("Stop"), at: t0.addingTimeInterval(9))
        XCTAssertEqual(count, 1)
    }
}

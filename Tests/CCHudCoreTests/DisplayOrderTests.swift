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

    /// 完成一轮（先 working 再 Stop），Stop(wasActive) 把 mruAt 刷成完成时刻。
    private func complete(_ store: StateStore, sid: String, cwd: String, start: TimeInterval, done: TimeInterval) {
        add(store, sid: sid, cwd: cwd, event: "UserPromptSubmit", offset: start)
        add(store, sid: sid, cwd: cwd, event: "Stop", offset: done)
    }

    func testAutoOrderByMRU() {
        let store = StateStore()
        // 权限（先 working 再请求权限）恒在最前
        add(store, sid: "perm", cwd: "/x/p", event: "UserPromptSubmit", offset: 10)
        add(store, sid: "perm", cwd: "/x/p", event: "PermissionRequest", offset: 11)
        complete(store, sid: "done-new", cwd: "/x/n", start: 5, done: 30)  // mruAt=30
        complete(store, sid: "done-old", cwd: "/x/o", start: 5, done: 20)  // mruAt=20
        add(store, sid: "running", cwd: "/x/r", event: "UserPromptSubmit", offset: 25)  // mruAt=25
        let ids = store.displaySessions().map(\.id)
        XCTAssertEqual(ids, ["perm", "done-new", "running", "done-old"],
                       "权限最前 → 其余按 mruAt 降序（最近发消息/完成的在上，与 idle/working 状态无关）")
    }

    /// MRU 三条规则：①发消息升顶 ②中间跑工具不动 ③完成升顶
    func testMRURaiseOnPromptAndCompletionNotOnTool() {
        let store = StateStore()
        add(store, sid: "A", cwd: "/x/a", event: "UserPromptSubmit", offset: 10)  // mruAt=10
        add(store, sid: "B", cwd: "/x/b", event: "UserPromptSubmit", offset: 20)  // mruAt=20
        XCTAssertEqual(store.displaySessions().map(\.id), ["B", "A"], "①后发消息的 B 在上")
        add(store, sid: "A", cwd: "/x/a", event: "PreToolUse", offset: 30)        // 跑工具：mruAt 不动
        XCTAssertEqual(store.displaySessions().map(\.id), ["B", "A"], "②A 跑工具不改位置，仍在 B 下")
        add(store, sid: "A", cwd: "/x/a", event: "Stop", offset: 40)             // 完成：mruAt=40
        XCTAssertEqual(store.displaySessions().map(\.id), ["A", "B"], "③A 完成后升到最顶")
    }

    func testNeverInteractedSinksToBottom() {
        let store = StateStore()
        add(store, sid: "seen", cwd: "/x/s", event: "SessionStart", offset: 0)     // 只 SessionStart → mruAt=nil
        add(store, sid: "used", cwd: "/x/u", event: "UserPromptSubmit", offset: 5) // 发过消息 → mruAt=5
        XCTAssertEqual(store.displaySessions().map(\.id), ["used", "seen"],
                       "从没交互过(mruAt=nil)的垫底")
    }

    func testPermissionAlwaysFirst() {
        let store = StateStore()
        complete(store, sid: "done", cwd: "/x/d", start: 1, done: 40)                // 刚完成，mruAt=40（很新）
        add(store, sid: "perm", cwd: "/x/p", event: "UserPromptSubmit", offset: 5)
        add(store, sid: "perm", cwd: "/x/p", event: "PermissionRequest", offset: 6)  // 权限
        XCTAssertEqual(store.displaySessions().map(\.id), ["perm", "done"],
                       "权限恒在最前，即便别的行 mruAt 更新")
    }

    /// 拖拽 = 纯数据改变（写 mruAt），与 MRU 同一把尺子：拖后即时生效，之后发消息仍按 MRU 上顶。
    func testReorderThenMRUStillGoverns() {
        let store = StateStore()
        add(store, sid: "A", cwd: "/x/a", event: "UserPromptSubmit", offset: 10)
        add(store, sid: "B", cwd: "/x/b", event: "UserPromptSubmit", offset: 20)
        add(store, sid: "C", cwd: "/x/c", event: "UserPromptSubmit", offset: 30)
        XCTAssertEqual(store.displaySessions().map(\.id), ["C", "B", "A"], "初始按 mruAt 降序")
        store.reorder(["A", "B", "C"], at: t0.addingTimeInterval(100))               // 拖成 A,B,C
        XCTAssertEqual(store.displaySessions().map(\.id), ["A", "B", "C"], "拖后顺序即时生效")
        add(store, sid: "C", cwd: "/x/c", event: "UserPromptSubmit", offset: 110)    // 给 C 发消息
        XCTAssertEqual(store.displaySessions().map(\.id), ["C", "A", "B"],
                       "发消息后 C 按 MRU 回到最顶，其余保持拖后相对序")
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

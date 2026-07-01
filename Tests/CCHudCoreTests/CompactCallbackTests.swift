import XCTest
@testable import CCHudCore

/// 手动 /compact 完成动画的触发链：PreCompact(manual) → SessionStart(source=compact)
@MainActor
final class CompactCallbackTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }
    private func hook(_ event: String, sid: String = "s1", extra: String = "") -> Envelope {
        env("""
        {"kind":"hook","claudePid":100,"tty":"ttys001","payload":{"hook_event_name":"\(event)","session_id":"\(sid)","cwd":"/x/pigeon"\(extra)}}
        """)
    }

    func testSourceAndTriggerDecode() {
        let e = hook("PreCompact", extra: #","trigger":"manual","source":"compact""#)
        XCTAssertEqual(e.payload.trigger, "manual")
        XCTAssertEqual(e.payload.source, "compact")
    }

    func testManualCompactFiresWithElapsed() {
        let store = StateStore()
        var fired: (name: String, elapsed: TimeInterval)? = nil
        store.onCompactDone = { s, e in fired = (s.projectName, e) }
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(hook("SessionStart", extra: #","source":"compact""#), at: t0.addingTimeInterval(42))
        XCTAssertEqual(fired?.name, "pigeon")
        XCTAssertEqual(fired?.elapsed, 42)
    }

    func testAutoCompactSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(hook("PreCompact", extra: #","trigger":"auto""#), at: t0)
        store.apply(hook("SessionStart", extra: #","source":"compact""#), at: t0.addingTimeInterval(30))
        XCTAssertEqual(count, 0, "auto 压缩不播动画")
    }

    func testAutoPreCompactClearsStaleManualMark() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)   // 被 esc 中断的手动压缩
        store.apply(hook("PreCompact", extra: #","trigger":"auto""#), at: t0.addingTimeInterval(60))
        store.apply(hook("SessionStart", extra: #","source":"compact""#), at: t0.addingTimeInterval(90))
        XCTAssertEqual(count, 0, "auto 压缩完成不得冒领此前被中断的手动压缩")
    }

    func testNonCompactSessionStartSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(hook("SessionStart", extra: #","source":"startup""#), at: t0.addingTimeInterval(5))
        XCTAssertEqual(count, 0)
    }

    func testExpiredManualMarkSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(hook("SessionStart", extra: #","source":"compact""#),
                    at: t0.addingTimeInterval(StateStore.compactExpiry + 100))
        XCTAssertEqual(count, 0, "超过有效期的手动标记视为已中断")
    }

    // ---- 兜底信号：statusline ctx% 骤降视为压缩完成 ----
    // SessionStart(compact) 在部分会话形态（resume 的旧会话）下不送达；
    // statusline 对所有已开会话持续流动，压缩完成瞬间 ctx% 大幅回落。
    private func status(pct: Double, sid: String = "s1") -> Envelope {
        env("""
        {"kind":"status","claudePid":100,"tty":"ttys001","payload":{"session_id":"\(sid)","cwd":"/x/pigeon","context_window":{"used_percentage":\(pct)}}}
        """)
    }

    func testStatusDropFiresCompactDone() {
        let store = StateStore()
        var fired: [(String, TimeInterval)] = []
        store.onCompactDone = { s, e in fired.append((s.projectName, e)) }
        store.apply(status(pct: 62), at: t0.addingTimeInterval(-5))
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(status(pct: 60), at: t0.addingTimeInterval(30))      // 压缩中波动，不触发
        store.apply(status(pct: 9), at: t0.addingTimeInterval(137))      // 骤降 → 完成
        store.apply(status(pct: 8), at: t0.addingTimeInterval(140))      // 标记已消费，不重复
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.0, "pigeon")
        XCTAssertEqual(fired.first?.1 ?? 0, 137, accuracy: 0.5)
    }

    func testStatusSmallDropSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(status(pct: 20), at: t0.addingTimeInterval(-5))
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(status(pct: 12), at: t0.addingTimeInterval(60))      // 降 8 个点 < 阈值
        XCTAssertEqual(count, 0, "小幅回落不视为压缩完成")
    }

    func testStatusDropWithoutMarkSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(status(pct: 62), at: t0)
        store.apply(status(pct: 9), at: t0.addingTimeInterval(10))
        XCTAssertEqual(count, 0, "没有手动压缩标记时骤降（如 auto 压缩）不触发")
    }

    func testStatusDropAfterAutoPreCompactSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(status(pct: 62), at: t0.addingTimeInterval(-5))
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)  // esc 中断
        store.apply(hook("PreCompact", extra: #","trigger":"auto""#), at: t0.addingTimeInterval(60))
        store.apply(status(pct: 9), at: t0.addingTimeInterval(90))
        XCTAssertEqual(count, 0, "auto 压缩的骤降不得冒领被中断的手动压缩")
    }

    func testStatusDropExpiredMarkSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(status(pct: 62), at: t0.addingTimeInterval(-5))
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(status(pct: 9), at: t0.addingTimeInterval(StateStore.compactExpiry + 100))
        XCTAssertEqual(count, 0, "过期标记不触发")
    }

    func testStatusDropThenSessionStartNoDoubleFire() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(status(pct: 62), at: t0.addingTimeInterval(-5))
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(status(pct: 9), at: t0.addingTimeInterval(137))
        store.apply(hook("SessionStart", extra: #","source":"compact""#), at: t0.addingTimeInterval(139))
        XCTAssertEqual(count, 1, "状态流先触发后，SessionStart(compact) 不得再触发")
    }

    func testStatusDropNoPriorPctSilent() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0)
        store.apply(status(pct: 9), at: t0.addingTimeInterval(137))
        XCTAssertEqual(count, 0, "标记前没有 ctx% 基线时不触发（无从判断骤降）")
        // 但 ctx% 照常被吸收
        XCTAssertEqual(store.sessions["s1"]?.ctxPct, 9)
    }

    func testCompletionUntouchedByCompactFlow() {
        // 压缩链路不影响既有完成回调
        let store = StateStore()
        var completions = 0, compacts = 0
        store.onCompletion = { _, _ in completions += 1 }
        store.onCompactDone = { _, _ in compacts += 1 }
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("Stop"), at: t0.addingTimeInterval(10))
        store.apply(hook("PreCompact", extra: #","trigger":"manual""#), at: t0.addingTimeInterval(20))
        store.apply(hook("SessionStart", extra: #","source":"compact""#), at: t0.addingTimeInterval(55))
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(compacts, 1)
    }

    /// 回归：手动 /compact 后进程以新 sid 重连、领养同 pid 旧会话——新会话不继承压缩标记，
    /// 故其首个 status 的 ctx 骤降不得误报一次"压缩完成"。
    func testAdoptedSessionDoesNotInheritCompactMark() {
        let store = StateStore()
        var count = 0
        store.onCompactDone = { _, _ in count += 1 }
        store.apply(status(pct: 80, sid: "s1"), at: t0)                                              // s1(pid100) ctx=80
        store.apply(hook("PreCompact", sid: "s1", extra: #","trigger":"manual""#), at: t0.addingTimeInterval(1))
        store.apply(status(pct: 50, sid: "s2"), at: t0.addingTimeInterval(2))                        // 新 sid 同 pid → 领养 s1，ctx 骤降 30
        XCTAssertEqual(count, 0, "领养的新会话不带 compactStartedAt，ctx 骤降不得误报压缩完成")
    }
}

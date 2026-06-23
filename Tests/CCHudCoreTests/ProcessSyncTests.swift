import XCTest
@testable import CCHudCore

@MainActor
final class ProcessSyncTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }
    private func proc(_ pid: Int32, tty: String? = "ttys001", cwd: String? = "/x/proj",
                      term: String? = "ghostty") -> DiscoveredProcess {
        DiscoveredProcess(pid: pid, tty: tty, cwd: cwd, termProgram: term)
    }

    func testDiscoveredProcessCreatesPlaceholder() {
        let store = StateStore()
        store.syncProcesses([proc(100, cwd: "/x/pigeon")], at: t0)
        XCTAssertEqual(store.sessions.count, 1)
        let s = store.sessions["proc-100"]!
        XCTAssertEqual(s.status, .idle)
        XCTAssertEqual(s.projectName, "pigeon")
        XCTAssertEqual(s.claudePid, 100)
        XCTAssertEqual(s.termProgram, "ghostty")
    }

    func testRealEventAdoptsPlaceholderByPid() {
        let store = StateStore()
        store.syncProcesses([proc(100, cwd: "/x/pigeon")], at: t0)
        store.apply(env("""
        {"kind":"hook","claudePid":100,"payload":{"hook_event_name":"UserPromptSubmit","session_id":"real-1","cwd":"/x/pigeon"}}
        """), at: t0.addingTimeInterval(5))
        XCTAssertEqual(store.sessions.count, 1, "占位行被真实会话取代")
        XCTAssertNil(store.sessions["proc-100"])
        let s = store.sessions["real-1"]!
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.createdAt, t0, "继承占位行的 createdAt 保持排序稳定")
    }

    func testResumeReplacesOldSessionWithSamePid() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"hook","claudePid":100,"tty":"ttys010","payload":{"hook_event_name":"SessionStart","session_id":"old","cwd":"/x/p"}}
        """), at: t0)
        store.apply(env("""
        {"kind":"hook","claudePid":100,"tty":"ttys010","payload":{"hook_event_name":"SessionStart","session_id":"new","cwd":"/x/p"}}
        """), at: t0.addingTimeInterval(10))
        XCTAssertEqual(store.sessions.count, 1, "同 PID 只保留最新会话（resume/clear 场景）")
        XCTAssertNotNil(store.sessions["new"])
    }

    func testProcessGoneMarksRealSessionDeadAndRemovesPlaceholderImmediately() {
        let store = StateStore()
        store.apply(env("""
        {"kind":"hook","claudePid":100,"tty":"ttys011","payload":{"hook_event_name":"SessionStart","session_id":"real-1","cwd":"/x/p"}}
        """), at: t0)
        store.syncProcesses([proc(200, cwd: "/x/other")], at: t0.addingTimeInterval(5))
        // real-1 的进程 100 不在运行列表 → dead；占位 proc-200 创建
        XCTAssertEqual(store.sessions["real-1"]!.status, .dead)
        XCTAssertNotNil(store.sessions["proc-200"])
        // 占位行的进程消失 → 立即移除（不留 10 分钟）
        store.syncProcesses([], at: t0.addingTimeInterval(10))
        XCTAssertNil(store.sessions["proc-200"])
        XCTAssertNotNil(store.sessions["real-1"], "真实会话保留至 retention 到期")
        // retention 到期移除
        store.syncProcesses([], at: t0.addingTimeInterval(5 + 601))
        XCTAssertNil(store.sessions["real-1"])
    }

    func testPlaceholderNotDuplicatedAcrossSyncs() {
        let store = StateStore()
        store.syncProcesses([proc(100)], at: t0)
        store.syncProcesses([proc(100)], at: t0.addingTimeInterval(5))
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testStatusEventAlsoAdoptsPlaceholder() {
        let store = StateStore()
        store.syncProcesses([proc(100, cwd: "/x/pigeon")], at: t0)
        store.apply(env("""
        {"kind":"status","claudePid":100,"payload":{"session_id":"real-9","cwd":"/x/pigeon","context_window":{"used_percentage":50}}}
        """), at: t0.addingTimeInterval(2))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions["real-9"]!.ctxPct, 50)
    }
}

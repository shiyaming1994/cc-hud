import XCTest
@testable import CCHudCore

@MainActor
final class StateStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func hook(_ event: String, sid: String = "s1", cwd: String = "/Users/x/pigeon",
                      tool: String? = nil, toolInput: JSONValue? = nil,
                      pid: Int32? = 100, tty: String? = "ttys002",
                      term: String? = "ghostty") -> Envelope {
        var p: [String: JSONValue] = [
            "hook_event_name": .string(event), "session_id": .string(sid), "cwd": .string(cwd),
        ]
        if let tool { p["tool_name"] = .string(tool) }
        if let toolInput { p["tool_input"] = toolInput }
        // 经 JSON 编解码构造 Envelope，避免给生产类型加测试用 init
        let payloadData = try! JSONSerialization.data(withJSONObject: jsonObject(.object(p)))
        let envJSON = """
        {"kind":"hook","claudePid":\(pid.map(String.init) ?? "null"),"tty":\(tty.map { "\"\($0)\"" } ?? "null"),
         "termProgram":\(term.map { "\"\($0)\"" } ?? "null"),"itermSessionId":null,
         "payload":\(String(data: payloadData, encoding: .utf8)!)}
        """
        return try! JSONDecoder().decode(Envelope.self, from: envJSON.data(using: .utf8)!)
    }

    private func jsonObject(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(jsonObject)
        case .object(let o): return o.mapValues(jsonObject)
        }
    }

    func testSessionStartCreatesIdle() {
        let store = StateStore()
        store.apply(hook("SessionStart"), at: t0)
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .idle)
        XCTAssertEqual(s.projectName, "pigeon")
        XCTAssertEqual(s.claudePid, 100)
        XCTAssertEqual(s.termProgram, "ghostty")
    }

    func testPromptToWorkingThinking() {
        let store = StateStore()
        store.apply(hook("SessionStart"), at: t0)
        store.apply(hook("UserPromptSubmit"), at: t0.addingTimeInterval(5))
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.activity, "思考中")
        XCTAssertEqual(s.roundStart, t0.addingTimeInterval(5))
    }

    func testPreToolUseSetsActivityAndPendingCommand() {
        let store = StateStore()
        store.apply(hook("UserPromptSubmit"), at: t0)   // 无 SessionStart 也要能自建会话
        store.apply(hook("PreToolUse", tool: "Bash",
                         toolInput: .object(["command": .string("git push"), "description": .string("Push")])),
                    at: t0.addingTimeInterval(1))
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.activity, "Push")
        XCTAssertEqual(s.pendingCommand, "Bash(git push)")
        XCTAssertEqual(s.roundStart, t0, "PreToolUse 不重置 roundStart")
    }

    func testPermissionRequestUsesPendingCommand() {
        let store = StateStore()
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("PreToolUse", tool: "Bash", toolInput: .object(["command": .string("rm -rf x")])), at: t0)
        store.apply(hook("PermissionRequest"), at: t0.addingTimeInterval(2))
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .permission)
        XCTAssertEqual(s.permissionCommand, "Bash(rm -rf x)")
        XCTAssertEqual(s.activity, "等待权限")
        XCTAssertEqual(s.roundStart, t0, "permission 不重置 roundStart")
    }

    func testPermissionRequestWithOwnToolInfo() {
        let store = StateStore()
        store.apply(hook("PermissionRequest", tool: "Write",
                         toolInput: .object(["file_path": .string("/a/b/.env")])), at: t0)
        XCTAssertEqual(store.sessions["s1"]!.permissionCommand, "Write(.env)")
    }

    func testApprovalResumesWorking() {
        let store = StateStore()
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("PreToolUse", tool: "Bash", toolInput: .object(["command": .string("ls")])), at: t0)
        store.apply(hook("PermissionRequest"), at: t0)
        store.apply(hook("PostToolUse", tool: "Bash"), at: t0.addingTimeInterval(3))
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.activity, "思考中")
        XCTAssertNil(s.permissionCommand)
    }

    func testStopGoesIdleWithJustDone() {
        let store = StateStore()
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("Stop"), at: t0.addingTimeInterval(10))
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .idle)
        XCTAssertEqual(s.activity, "空闲")
        XCTAssertEqual(s.justDoneUntil, t0.addingTimeInterval(12), "working→idle 高亮 2s")
    }

    func testStopFromIdleNoJustDone() {
        let store = StateStore()
        store.apply(hook("SessionStart"), at: t0)
        store.apply(hook("Stop"), at: t0.addingTimeInterval(1))
        XCTAssertNil(store.sessions["s1"]!.justDoneUntil)
    }

    func testSessionEndRemoves() {
        let store = StateStore()
        store.apply(hook("SessionStart"), at: t0)
        store.apply(hook("SessionEnd"), at: t0.addingTimeInterval(1))
        XCTAssertNil(store.sessions["s1"])
    }

    func testTwoSessionsIndependent() {
        let store = StateStore()
        store.apply(hook("UserPromptSubmit", sid: "s1"), at: t0)
        store.apply(hook("UserPromptSubmit", sid: "s2", cwd: "/Users/x/relay", pid: 200), at: t0)
        store.apply(hook("Stop", sid: "s1"), at: t0.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]!.status, .idle)
        XCTAssertEqual(store.sessions["s2"]!.status, .working)
    }
}

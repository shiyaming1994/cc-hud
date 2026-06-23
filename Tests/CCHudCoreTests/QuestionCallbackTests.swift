import XCTest
@testable import CCHudCore

/// AskUserQuestion 提问提示的触发链。实测信号形状（claude 2.1.x shim 抓包）：
/// PreToolUse(AskUserQuestion) → PermissionRequest(AskUserQuestion)（同内容重复）→
/// 全部答完一条 PostToolUse；逐题之间无事件。
@MainActor
final class QuestionCallbackTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    private func env(_ json: String) -> Envelope {
        try! JSONDecoder().decode(Envelope.self, from: json.data(using: .utf8)!)
    }
    private func hook(_ event: String, sid: String = "s1", extra: String = "") -> Envelope {
        env("""
        {"kind":"hook","claudePid":100,"tty":"ttys001","payload":{"hook_event_name":"\(event)","session_id":"\(sid)","cwd":"/x/pigeon"\(extra)}}
        """)
    }

    /// 实测 payload 的精简复刻：两题、各两选项、multiSelect=false
    private let askInput = #"""
    ,"tool_name":"AskUserQuestion","tool_input":{"questions":[
      {"question":"默认用哪种光效？","header":"默认光效","options":[
        {"label":"光环呼吸","description":"双层琥珀环"},{"label":"边缘光呼吸","description":"四边辉光"}],"multiSelect":false},
      {"question":"默认开还是关？","header":"默认开关","options":[
        {"label":"默认开启","description":"装好即生效"},{"label":"默认关闭","description":"保守起步"}],"multiSelect":true}
    ]}
    """#

    private func makeStore() -> (StateStore, () -> [(String, [QuestionItem])], () -> [String]) {
        let store = StateStore()
        var asked: [(String, [QuestionItem])] = []
        var resolved: [String] = []
        store.onQuestion = { s, q in asked.append((s.id, q)) }
        store.onQuestionResolved = { resolved.append($0) }
        return (store, { asked }, { resolved })
    }

    func testParserOnRealShape() {
        let e = hook("PreToolUse", extra: askInput)
        let items = QuestionParser.parse(e.payload.toolInput)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "默认用哪种光效？")
        XCTAssertEqual(items[0].header, "默认光效")
        XCTAssertEqual(items[0].optionLabels, ["光环呼吸", "边缘光呼吸"])
        XCTAssertFalse(items[0].multiSelect)
        XCTAssertTrue(items[1].multiSelect)
    }

    func testPreToolUseFiresOnceAndSetsWaitingState() {
        let (store, asked, _) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        XCTAssertEqual(asked().count, 1)
        XCTAssertEqual(asked()[0].0, "s1")
        XCTAssertEqual(asked()[0].1.count, 2)
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.status, .permission)
        XCTAssertEqual(s.activity, "等待选择")
        XCTAssertEqual(s.permissionCommand, "默认用哪种光效？")
        XCTAssertNotNil(s.questionPendingAt)
    }

    func testPermissionRequestDuplicateDoesNotRefire() {
        let (store, asked, _) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        store.apply(hook("PermissionRequest", extra: askInput), at: t0.addingTimeInterval(0.05))
        XCTAssertEqual(asked().count, 1, "PermissionRequest 是同一次提问的重复信号")
        XCTAssertEqual(store.sessions["s1"]?.activity, "等待选择", "不得被改写成等待权限")
    }

    func testPermissionRequestAloneAlsoFires() {
        // 防御：若 PreToolUse 缺席（事件丢失），PermissionRequest 也能独立触发
        let (store, asked, _) = makeStore()
        store.apply(hook("PermissionRequest", extra: askInput), at: t0)
        XCTAssertEqual(asked().count, 1)
    }

    func testPostToolUseResolves() {
        let (store, _, resolved) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        store.apply(hook("PostToolUse", extra: askInput), at: t0.addingTimeInterval(8))
        XCTAssertEqual(resolved(), ["s1"])
        let s = store.sessions["s1"]!
        XCTAssertNil(s.questionPendingAt)
        XCTAssertEqual(s.status, .working)
    }

    func testUserPromptSubmitAndStopResolve() {
        let (store, _, resolved) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        store.apply(hook("UserPromptSubmit"), at: t0.addingTimeInterval(3))
        XCTAssertEqual(resolved(), ["s1"])
        store.apply(hook("PreToolUse", extra: askInput), at: t0.addingTimeInterval(10))
        store.apply(hook("Stop"), at: t0.addingTimeInterval(12))
        XCTAssertEqual(resolved(), ["s1", "s1"])
    }

    func testSessionEndResolves() {
        let (store, _, resolved) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        store.apply(hook("SessionEnd"), at: t0.addingTimeInterval(3))
        XCTAssertEqual(resolved(), ["s1"])
        XCTAssertNil(store.sessions["s1"])
    }

    func testDeadProcessResolves() {
        let (store, _, resolved) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        store.syncProcesses([], at: t0.addingTimeInterval(5))   // pid 100 不在了
        XCTAssertEqual(resolved(), ["s1"])
        XCTAssertEqual(store.sessions["s1"]?.status, .dead)
    }

    func testOtherToolPreToolUseSilent() {
        let (store, asked, resolved) = makeStore()
        store.apply(hook("PreToolUse", extra: #","tool_name":"Bash","tool_input":{"command":"ls"}"#), at: t0)
        XCTAssertEqual(asked().count, 0)
        XCTAssertEqual(resolved().count, 0, "无挂起提问时不发 resolved")
    }

    func testChainedCallsFireAgain() {
        let (store, asked, resolved) = makeStore()
        store.apply(hook("PreToolUse", extra: askInput), at: t0)
        store.apply(hook("PostToolUse", extra: askInput), at: t0.addingTimeInterval(5))
        store.apply(hook("PreToolUse", extra: askInput), at: t0.addingTimeInterval(9))
        XCTAssertEqual(asked().count, 2, "答完一轮后的新调用要再次触发")
        XCTAssertEqual(resolved(), ["s1"])
    }

    func testStopAfterQuestionStillFiresCompletion() {
        // 等待选择中直接 Stop（用户在终端答完最后一题、回合随即结束的常见路径）：
        // 提问 resolved + 完成动画照常（wasActive 含 .permission）
        let (store, _, resolved) = makeStore()
        var completions = 0
        store.onCompletion = { _, _ in completions += 1 }
        store.apply(hook("UserPromptSubmit"), at: t0)
        store.apply(hook("PreToolUse", extra: askInput), at: t0.addingTimeInterval(1))
        store.apply(hook("Stop"), at: t0.addingTimeInterval(20))
        XCTAssertEqual(resolved(), ["s1"])
        XCTAssertEqual(completions, 1)
    }

    func testMalformedInputNoCallbackButStateSet() {
        let (store, asked, _) = makeStore()
        store.apply(hook("PreToolUse", extra: #","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"没题面"}]}"#), at: t0)
        XCTAssertEqual(asked().count, 0, "解析不出题面就不弹卡（没内容可展示）")
        XCTAssertEqual(store.sessions["s1"]?.activity, "等待选择", "行状态仍标等待选择")
    }
}

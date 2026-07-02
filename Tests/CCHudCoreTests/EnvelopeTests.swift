import XCTest
@testable import CCHudCore

final class EnvelopeTests: XCTestCase {
    func testDecodeHookEnvelope() throws {
        let json = """
        {"kind":"hook","claudePid":45508,"tty":"ttys002","termProgram":"ghostty","itermSessionId":null,
         "payload":{"hook_event_name":"PreToolUse","session_id":"abc-123","cwd":"/Users/x/proj",
           "transcript_path":"/Users/x/.claude/projects/p/abc.jsonl",
           "tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"Remove deps"}}}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(env.kind, "hook")
        XCTAssertEqual(env.claudePid, 45508)
        XCTAssertEqual(env.tty, "ttys002")
        XCTAssertEqual(env.termProgram, "ghostty")
        XCTAssertNil(env.itermSessionId)
        XCTAssertEqual(env.payload.hookEventName, "PreToolUse")
        XCTAssertEqual(env.payload.sessionId, "abc-123")
        XCTAssertEqual(env.payload.cwd, "/Users/x/proj")
        XCTAssertEqual(env.payload.toolName, "Bash")
        // tool_input 字典键必须原样保留（snake_case 不被转换）
        guard case .object(let obj)? = env.payload.toolInput,
              case .string(let cmd)? = obj["command"] else { return XCTFail("tool_input broken") }
        XCTAssertEqual(cmd, "rm -rf node_modules")
    }

    func testDecodeStatusEnvelope() throws {
        let json = """
        {"kind":"status","claudePid":45508,"tty":"ttys002","termProgram":"iTerm.app","itermSessionId":"w0t2p0:UUID-1",
         "payload":{"session_id":"abc-123","cwd":"/Users/x/proj",
           "model":{"id":"claude-fable-5","display_name":"Fable"},
           "context_window":{"used_percentage":62.5},
           "rate_limits":{"five_hour":{"used_percentage":38,"resets_at":1765400000},
                          "seven_day":{"used_percentage":22,"resets_at":1765800000}}}}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(env.kind, "status")
        XCTAssertEqual(env.itermSessionId, "w0t2p0:UUID-1")
        XCTAssertEqual(env.payload.model?.displayName, "Fable")
        XCTAssertEqual(env.payload.contextWindow?.usedPercentage, 62.5)
        XCTAssertEqual(env.payload.rateLimits?.fiveHour?.usedPercentage, 38)
        XCTAssertEqual(env.payload.rateLimits?.sevenDay?.resetsAt, 1_765_800_000)
    }

    /// SessionStart hook 的 model 是纯字符串（model id），statusline 的是对象——
    /// 两种形态都必须严格解码成功（真实样本：/tmp/cchud-decode-drift-*.json 全部因此失败）
    func testDecodeSessionStartWithModelIdString() throws {
        let json = """
        {"claudePid":94842,"kind":"hook","tty":"ttys003","termProgram":"ghostty",
         "payload":{"source":"compact","model":"claude-opus-4-8[1m]",
           "session_id":"95f9e64b-ae86-4340-9f77-856e8d32cd1c",
           "transcript_path":"/Users/x/.claude/projects/p/95f9e64b.jsonl",
           "prompt_id":"7e946154-1e35-416e-a23e-5fd5db6b5e54","cwd":"/Users/x/proj",
           "hook_event_name":"SessionStart"}}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(env.payload.hookEventName, "SessionStart")
        XCTAssertEqual(env.payload.source, "compact")
        XCTAssertEqual(env.payload.sessionId, "95f9e64b-ae86-4340-9f77-856e8d32cd1c")
        // 字符串形态不含显示名：displayName 为 nil（显示名由 statusline 的对象形态提供）
        XCTAssertNil(env.payload.model?.displayName)
    }

    func testUnknownFieldsIgnored() throws {
        let json = """
        {"kind":"hook","payload":{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false,"weird":[1,{"a":true}]}}
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(Envelope.self, from: json)
        XCTAssertEqual(env.payload.hookEventName, "Stop")
        XCTAssertNil(env.claudePid)
    }
}

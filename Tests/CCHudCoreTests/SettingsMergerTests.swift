import XCTest
@testable import CCHudCore

final class SettingsMergerTests: XCTestCase {
    let emit = "\"$HOME/.claude/cc-hud/emit\" hook"
    let status = "\"$HOME/.claude/cc-hud/emit\" status"

    func testMergeIntoEmptySettings() {
        let (out, original) = SettingsMerger.merge(settings: [:], emitCommand: emit, statusCommand: status)
        let hooks = out["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(SettingsMerger.hookEvents))
        let ss = hooks["SessionStart"] as! [[String: Any]]
        let inner = ss[0]["hooks"] as! [[String: Any]]
        XCTAssertEqual(inner[0]["command"] as! String, emit)
        XCTAssertEqual(inner[0]["type"] as! String, "command")
        let sl = out["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["command"] as! String, status)
        XCTAssertNil(original, "原本没有 statusline")
    }

    func testMergePreservesUserHooksAndExtractsStatusLine() {
        let settings: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "afplay /done.wav"]]]]],
            "statusLine": ["type": "command", "command": "~/.claude/statusline.sh"],
        ]
        let (out, original) = SettingsMerger.merge(settings: settings, emitCommand: emit, statusCommand: status)
        XCTAssertEqual(original, "~/.claude/statusline.sh")
        XCTAssertEqual(out["model"] as! String, "opus", "无关键原样保留")
        let stop = (out["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2, "用户原有 Stop hook 保留 + 我们的追加")
        let allCommands = stop.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        XCTAssertTrue(allCommands.contains("afplay /done.wav"))
        XCTAssertTrue(allCommands.contains(emit))
    }

    func testMergeIsIdempotent() {
        let (once, _) = SettingsMerger.merge(settings: [:], emitCommand: emit, statusCommand: status)
        let (twice, original2) = SettingsMerger.merge(settings: once, emitCommand: emit, statusCommand: status)
        XCTAssertNil(original2, "statusLine 已是我们的，不再当作 original")
        let h1 = try! JSONSerialization.data(withJSONObject: once, options: .sortedKeys)
        let h2 = try! JSONSerialization.data(withJSONObject: twice, options: .sortedKeys)
        XCTAssertEqual(h1, h2, "二次 merge 不产生重复条目")
    }

    func testRestoreRemovesOursKeepsUsers() {
        let settings: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay /done.wav"]]]]],
            "statusLine": ["type": "command", "command": "~/.claude/statusline.sh"],
        ]
        let (merged, original) = SettingsMerger.merge(settings: settings, emitCommand: emit, statusCommand: status)
        let restored = SettingsMerger.restore(settings: merged, emitCommand: emit,
                                              statusCommand: status, originalStatusLine: original)
        let hooks = restored["hooks"] as! [String: Any]
        XCTAssertNil(hooks["SessionStart"], "我们独占的事件键整个移除")
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as! String), "afplay /done.wav")
        XCTAssertEqual((restored["statusLine"] as! [String: Any])["command"] as! String, "~/.claude/statusline.sh")
    }

    func testRestoreWithoutOriginalRemovesStatusLine() {
        let (merged, _) = SettingsMerger.merge(settings: [:], emitCommand: emit, statusCommand: status)
        let restored = SettingsMerger.restore(settings: merged, emitCommand: emit,
                                              statusCommand: status, originalStatusLine: nil)
        XCTAssertNil(restored["statusLine"])
        XCTAssertNil(restored["hooks"], "全空时 hooks 键移除")
    }
}

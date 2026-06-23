import XCTest
@testable import CCHudCore

final class ClaudeProjectsTests: XCTestCase {
    func testSlugMatchesClaudeCodeRule() {
        XCTAssertEqual(ClaudeProjects.slug(forCwd: "/Users/x/Work/pigeon"),
                       "-Users-x-Work-pigeon")
        // 点、下划线、空格全部替换（与 Claude Code 实际目录名一致）
        XCTAssertEqual(ClaudeProjects.slug(forCwd: "/Users/x/.model-tokens-tracker"),
                       "-Users-x--model-tokens-tracker")
        XCTAssertEqual(ClaudeProjects.slug(forCwd: "/Users/x/next.js"),
                       "-Users-x-next-js")
        XCTAssertEqual(ClaudeProjects.slug(forCwd: "/Users/x/my_app/a b"),
                       "-Users-x-my-app-a-b")
    }
}

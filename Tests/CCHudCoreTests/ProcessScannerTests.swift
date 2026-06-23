import XCTest
@testable import CCHudCore

final class ProcessScannerTests: XCTestCase {
    /// 用"等于自身 pid"做目标匹配，应能扫描到自己并读出 cwd。
    func testScanFindsOwnProcess() {
        let me = getpid()
        let found = ProcessScanner.scan(isTarget: { $0 == me }, includeTTYless: true)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.pid, me)
        XCTAssertNotNil(found.first?.cwd, "应能读取进程 cwd")
    }

    func testClaudePathMatching() {
        XCTAssertTrue(ClaudeProcess.isClaude(path: "/Users/x/.local/share/claude/versions/2.1.170"))
        XCTAssertTrue(ClaudeProcess.isClaude(path: "/usr/local/bin/claude"))
        XCTAssertFalse(ClaudeProcess.isClaude(path: "/usr/local/bin/node"))
        XCTAssertFalse(ClaudeProcess.isClaude(path: "/Users/x/projects/claude/mytool"))
    }
}

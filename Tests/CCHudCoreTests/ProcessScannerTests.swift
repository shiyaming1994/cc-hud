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

    /// 进程状态过滤（sys/proc.h：SIDL=1 SRUN=2 SSLEEP=3 SSTOP=4 SZOMB=5）
    func testActiveStateFilter() {
        XCTAssertTrue(ProcessScanner.isActiveState(2), "运行中算活跃")
        XCTAssertTrue(ProcessScanner.isActiveState(3), "睡眠(等待)算活跃")
        XCTAssertFalse(ProcessScanner.isActiveState(4), "SSTOP 挂起（Ctrl-Z/作业控制遗留）→ 排除")
        XCTAssertFalse(ProcessScanner.isActiveState(5), "SZOMB 僵尸 → 排除")
    }

    /// 端到端：挂起(SIGSTOP)的子进程不应被扫描计入——正是"多了一行 stopped 终端"的场景。
    func testScanSkipsStoppedProcess() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        guard (try? p.run()) != nil else { XCTFail("无法起子进程"); return }
        let pid = p.processIdentifier
        defer { kill(pid, SIGKILL); p.waitUntilExit() }

        XCTAssertFalse(ProcessScanner.scan(isTarget: { $0 == pid }, includeTTYless: true).isEmpty,
                       "运行中的子进程应被扫到")

        kill(pid, SIGSTOP)   // 挂起
        var excluded = false
        for _ in 0..<20 {    // 轮询等内核状态生效（≤500ms）
            if ProcessScanner.scan(isTarget: { $0 == pid }, includeTTYless: true).isEmpty { excluded = true; break }
            usleep(25_000)
        }
        XCTAssertTrue(excluded, "SIGSTOP 挂起的进程应被扫描排除")
    }
}

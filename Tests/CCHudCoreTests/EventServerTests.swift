import XCTest
@testable import CCHudCore

final class EventServerTests: XCTestCase {
    func testReceivesEnvelopeOverUnixSocket() throws {
        let path = NSTemporaryDirectory() + "hud-test-\(UUID().uuidString.prefix(8)).sock"
        let exp = expectation(description: "envelope received")
        nonisolated(unsafe) var received: Envelope?
        let server = EventServer(socketPath: path) { env in
            received = env
            exp.fulfill()
        }
        try server.start()
        defer { server.stop() }

        // 客户端：connect + write + close（模拟 emit）
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        XCTAssertEqual(rc, 0, "connect failed errno=\(errno)")
        let msg = #"{"kind":"hook","payload":{"hook_event_name":"Stop","session_id":"s9"}}"#
        msg.withCString { _ = write(fd, $0, strlen($0)) }
        close(fd)

        wait(for: [exp], timeout: 2)
        XCTAssertEqual(received?.payload.sessionId, "s9")
        XCTAssertEqual(received?.payload.hookEventName, "Stop")
    }

    func testStartCleansStaleSocketFile() throws {
        let path = NSTemporaryDirectory() + "hud-stale-\(UUID().uuidString.prefix(8)).sock"
        FileManager.default.createFile(atPath: path, contents: nil)
        let server = EventServer(socketPath: path) { _ in }
        XCTAssertNoThrow(try server.start())
        server.stop()
    }

    /// 后启动的实例发现已有活实例在监听 → 让位(throw),且不得破坏先来者的 socket。
    /// 抢占会把先来者变成聋子(监听已 unlink 的 inode)且毫无感知——2026-07-03 事故根因。
    func testSecondServerYieldsToAliveFirst() throws {
        let path = NSTemporaryDirectory() + "hud-dual-\(UUID().uuidString.prefix(8)).sock"
        let exp = expectation(description: "first server still receives after second yields")
        let first = EventServer(socketPath: path) { _ in exp.fulfill() }
        try first.start()
        defer { first.stop() }

        let second = EventServer(socketPath: path) { _ in }
        XCTAssertThrowsError(try second.start()) { err in
            XCTAssertTrue(err is EventServerError, "应为 alreadyRunning,得到 \(err)")
        }

        // 先来者的 socket 未被破坏:仍能收到事件
        try Self.send(#"{"kind":"hook","payload":{"hook_event_name":"Stop","session_id":"dual"}}"#, to: path)
        wait(for: [exp], timeout: 2)
    }

    /// 无人监听的残留 socket 文件(真 socket,非普通文件)不阻碍新实例启动
    func testStartAfterDeadServerLeftRealSocketFile() throws {
        let path = NSTemporaryDirectory() + "hud-dead-\(UUID().uuidString.prefix(8)).sock"
        let dead = EventServer(socketPath: path) { _ in }
        try dead.start()
        dead.stop()   // stop 不 unlink(升级竞态注释)→ 留下真 socket 文件、无监听者
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "前提:残留文件存在")

        let next = EventServer(socketPath: path) { _ in }
        XCTAssertNoThrow(try next.start(), "对无监听者的残留 socket 应照常接管")
        next.stop()
    }

    /// 客户端 connect + write + close(模拟 emit)
    private static func send(_ json: String, to path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        XCTAssertEqual(rc, 0, "connect failed errno=\(errno)")
        json.withCString { _ = write(fd, $0, strlen($0)) }
    }
}

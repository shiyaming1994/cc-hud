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
}

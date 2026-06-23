import XCTest
@testable import CCHudCore

final class DailyTokenScannerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("proj-a"),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ lines: [String], to name: String) throws {
        let url = tmp.appendingPathComponent("proj-a").appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func entry(ts: String, id: String, input: Int = 1, output: Int = 2,
                       cacheC: Int = 3, cacheR: Int = 4) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","uuid":"u-\(id)","message":{"id":"\(id)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheC),"cache_read_input_tokens":\(cacheR)}}}
        """
    }

    func testSumsDedupesAndFiltersByDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-06-10T06:00:00Z")!
        try write([
            entry(ts: "2026-06-10T01:00:00.500Z", id: "m1"),                  // 计入：1+2+3+4 = 10
            entry(ts: "2026-06-10T02:00:00.000Z", id: "m1"),                  // 重复 id，去重
            entry(ts: "2026-06-09T23:59:59.000Z", id: "m2"),                  // 昨天，不计
            entry(ts: "2026-06-10T03:00:00.000Z", id: "m3", input: 100),      // 计入：100+2+3+4 = 109
            #"{"type":"user","timestamp":"2026-06-10T04:00:00Z","uuid":"u-x"}"#, // 无 usage，跳过
            "not json at all",                                                  // 坏行，跳过
        ], to: "a.jsonl")
        let scanner = DailyTokenScanner(projectsDir: tmp, calendar: cal)
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 119)
    }

    func testIncrementalAppendOnlyParsesNewBytes() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-06-10T06:00:00Z")!
        let url = tmp.appendingPathComponent("proj-a").appendingPathComponent("inc.jsonl")

        try (entry(ts: "2026-06-10T01:00:00Z", id: "m1") + "\n").write(to: url, atomically: false, encoding: .utf8)
        let scanner = DailyTokenScanner(projectsDir: tmp, calendar: cal)
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 10)

        // 追加一条：第二次扫描应增量拾取
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((entry(ts: "2026-06-10T02:00:00Z", id: "m2", input: 100) + "\n").utf8))
        try fh.close()
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 119)

        // 第三次无变化：结果不变
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 119)
    }

    func testRewrittenShorterFileResets() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-06-10T06:00:00Z")!
        let url = tmp.appendingPathComponent("proj-a").appendingPathComponent("rw.jsonl")

        try [entry(ts: "2026-06-10T01:00:00Z", id: "m1"),
             entry(ts: "2026-06-10T02:00:00Z", id: "m2", input: 100)].joined(separator: "\n")
            .write(to: url, atomically: false, encoding: .utf8)
        let scanner = DailyTokenScanner(projectsDir: tmp, calendar: cal)
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 119)

        // 重写为更短内容（size 收缩）→ 缓存重置，按新内容计
        try (entry(ts: "2026-06-10T03:00:00Z", id: "m9") + "\n").write(to: url, atomically: false, encoding: .utf8)
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 10)
    }

    func testFallbackToUuidWhenNoMessageId() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-06-10T06:00:00Z")!
        let noId = """
        {"type":"assistant","timestamp":"2026-06-10T01:00:00Z","uuid":"uu1","message":{"usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try write([noId, noId], to: "b.jsonl")
        let scanner = DailyTokenScanner(projectsDir: tmp, calendar: cal)
        XCTAssertEqual(scanner.scanTodayTokens(now: now), 10, "按 uuid 去重")
    }
}

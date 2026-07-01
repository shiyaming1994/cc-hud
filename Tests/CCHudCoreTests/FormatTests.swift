import XCTest
@testable import CCHudCore

final class FormatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_765_000_000)

    func testTokens() {
        XCTAssertEqual(Format.tokens(nil), "—")
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1000), "1K")
        XCTAssertEqual(Format.tokens(1499), "1K")
        XCTAssertEqual(Format.tokens(1500), "2K")
        XCTAssertEqual(Format.tokens(1_000_000), "1.0M")
        XCTAssertEqual(Format.tokens(12_000_000), "12M")
    }

    func testCountdownHM() {
        XCTAssertEqual(Format.countdownHM(to: t0.addingTimeInterval(30), from: t0), "<1m", "不到 1 分钟 → <1m，不再 0m")
        XCTAssertEqual(Format.countdownHM(to: t0, from: t0), "<1m", "到点(0s)也显示 <1m")
        XCTAssertEqual(Format.countdownHM(to: t0.addingTimeInterval(60), from: t0), "1m")
        XCTAssertEqual(Format.countdownHM(to: t0.addingTimeInterval(45 * 60), from: t0), "45m")
        XCTAssertEqual(Format.countdownHM(to: t0.addingTimeInterval(3600 + 5 * 60), from: t0), "1h 05m")
    }

    func testCountdownDH() {
        XCTAssertEqual(Format.countdownDH(to: t0.addingTimeInterval(6 * 86400 + 18 * 3600), from: t0), "6d 18h")
        XCTAssertEqual(Format.countdownDH(to: t0.addingTimeInterval(5 * 3600 + 30 * 60), from: t0), "5h 30m")
        XCTAssertEqual(Format.countdownDH(to: t0.addingTimeInterval(30), from: t0), "<1m")
    }

    func testClockAndBurnDur() {
        XCTAssertEqual(Format.clock(272), "4:32")
        XCTAssertEqual(Format.clock(5), "0:05")
        XCTAssertEqual(Format.burnDur(267), "4h27m")
        XCTAssertEqual(Format.burnDur(240), "4h")
        XCTAssertEqual(Format.burnDur(25), "25m")
    }

    func testResetTimeTomorrowPrefix() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Format.hhmm(t0, calendar: cal).count, 5)   // "HH:mm"
        XCTAssertFalse(Format.resetTimeShort(t0.addingTimeInterval(3600), now: t0, calendar: cal).hasPrefix("明日"),
                       "同日不加前缀")
        XCTAssertTrue(Format.resetTimeShort(t0.addingTimeInterval(86400), now: t0, calendar: cal).hasPrefix("明日"),
                      "跨日加“明日”")
    }
}

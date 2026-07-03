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

    /// 恒短两段式:超 1h 换挡为 时:分,超 24h 兜底 Nd+ —— 宽度封顶,HUD 行不换行
    func testClockStaysNarrowBeyondOneHour() {
        XCTAssertEqual(Format.clock(620), "10:20", "分钟态:分:秒")
        XCTAssertEqual(Format.clock(3599), "59:59", "1h 边界前仍是 分:秒")
        XCTAssertEqual(Format.clock(3600), "1:00", "满 1h 换挡:时:分")
        XCTAssertEqual(Format.clock(3661), "1:01", "秒被截断,不进位")
        XCTAssertEqual(Format.clock(13 * 3600 + 5 * 60), "13:05", "分钟补零")
        XCTAssertEqual(Format.clock(86399), "23:59", "24h 边界前仍是 时:分")
        XCTAssertEqual(Format.clock(86400), "1d+", "≥24h 异常态:天数兜底")
        XCTAssertEqual(Format.clock(31 * 86400 + 7200), "31d+", "月级也同一口径")
    }

    func testClockDefendsAbnormalInput() {
        XCTAssertEqual(Format.clock(-5), "0:00")
        XCTAssertEqual(Format.clock(.nan), "0:00", "NaN 不得 crash(Int(NaN) 会 trap)")
        XCTAssertEqual(Format.clock(.infinity), "0:00")
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

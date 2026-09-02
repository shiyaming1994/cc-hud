import XCTest
@testable import CCHudCore

/// 档位与开关的持久化。越界必须夹取 —— 未来减少档位数时，旧存档不能让状态项白屏。
final class StripSettingsTests: XCTestCase {
    private func fresh() -> UserDefaults {
        UserDefaults(suiteName: "cchud-strip-\(UUID().uuidString)")!
    }

    func testDefaultsToFullLevelAndDisabled() {
        let s = StripSettings(defaults: fresh())
        XCTAssertEqual(s.level, .full, "默认全档")
        XCTAssertFalse(s.enabled, "默认关闭")
    }

    func testLevelRoundTrips() {
        let d = fresh()
        let s = StripSettings(defaults: d)
        s.level = .tightest
        XCTAssertEqual(StripSettings(defaults: d).level, .tightest, "跨实例读同一份存档")
    }

    func testEnabledRoundTrips() {
        let d = fresh()
        let s = StripSettings(defaults: d)
        s.enabled = true
        XCTAssertTrue(StripSettings(defaults: d).enabled)
    }

    func testOutOfRangeLevelClampsToFull() {
        let d = fresh()
        d.set(99, forKey: StripSettings.levelKey)
        XCTAssertEqual(StripSettings(defaults: d).level, .full)
        d.set(-1, forKey: StripSettings.levelKey)
        XCTAssertEqual(StripSettings(defaults: d).level, .full)
    }

    func testAllLevelsAreOrderedRichestFirst() {
        XCTAssertEqual(StripLevel.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(StripLevel.allCases.first, .full)
    }
}

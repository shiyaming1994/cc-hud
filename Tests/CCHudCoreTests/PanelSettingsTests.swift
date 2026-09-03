import XCTest
@testable import CCHudCore

/// 会话浮窗显隐的存档。两条不变量都得钉死：
/// 默认必须是隐藏（1.4.0 定的默认，新装用户不该一上来就被占屏），
/// 而用户那一次点击必须记住（app 是 LSUIElement，唯一入口是菜单栏那一格；
/// 自动更新还会自己重启进程，不记就等于替用户把窗关了）。
final class PanelSettingsTests: XCTestCase {
    private func fresh() -> UserDefaults {
        UserDefaults(suiteName: "cchud-panel-\(UUID().uuidString)")!
    }

    func testDefaultsToHidden() {
        XCTAssertFalse(PanelSettings(defaults: fresh()).visible,
                       "key 未设 → 隐藏，与 1.4.0 定的默认一致")
    }

    func testShownRoundTrips() {
        let d = fresh()
        PanelSettings(defaults: d).visible = true
        XCTAssertTrue(PanelSettings(defaults: d).visible, "跨实例读同一份存档")
    }

    func testHiddenRoundTripsBack() {
        let d = fresh()
        let s = PanelSettings(defaults: d)
        s.visible = true
        s.visible = false
        XCTAssertFalse(PanelSettings(defaults: d).visible, "关掉也要记住，不能只记开")
    }
}

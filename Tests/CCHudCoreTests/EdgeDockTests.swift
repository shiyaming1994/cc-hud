import XCTest
import CoreGraphics
@testable import CCHudCore

/// 贴边停靠几何（设计文档 4.2–4.5）。坐标：AppKit 全局，左下原点、y 向上。
final class EdgeDockTests: XCTestCase {
    /// 用户主屏（1496 × 967，菜单栏 29、程序坞在底部 87）的 visibleFrame
    let visible = CGRect(x: 0, y: 87, width: 1496, height: 851)

    // MARK: 落位

    func testDockedFlushRightAtAnchorTop() {
        XCTAssertEqual(EdgeDock.frame(size: CGSize(width: 20, height: 51), top: 839, visibleFrame: visible),
                       CGRect(x: 1476, y: 788, width: 20, height: 51))
    }

    func testShiftsUpWhenBottomOverflows() {
        XCTAssertEqual(EdgeDock.frame(size: CGSize(width: 300, height: 380), top: 300, visibleFrame: visible),
                       CGRect(x: 1196, y: 87, width: 300, height: 380), "底边贴住 visibleFrame 底")
    }

    func testTopClampedBelowMenuBar() {
        XCTAssertEqual(EdgeDock.frame(size: CGSize(width: 208, height: 160), top: 2000, visibleFrame: visible),
                       CGRect(x: 1288, y: 778, width: 208, height: 160))
    }

    func testTallerThanScreenPinsTop() {
        XCTAssertEqual(EdgeDock.frame(size: CGSize(width: 300, height: 900), top: 500, visibleFrame: visible),
                       CGRect(x: 1196, y: 38, width: 300, height: 900), "顶边贴 visibleFrame 顶，保住标题栏")
    }

    func testRoundsToWholePoints() {
        XCTAssertEqual(EdgeDock.frame(size: CGSize(width: 208.4, height: 160.6), top: 700.4, visibleFrame: visible),
                       CGRect(x: 1288, y: 539, width: 208, height: 161))
    }

    func testDefaultTopIsEightBelowVisibleTop() {
        XCTAssertEqual(EdgeDock.defaultTop(visibleFrame: visible), 930)
    }

    // MARK: 选停靠屏

    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1920, height: 1080)

    func testPicksScreenUnderMouse() {
        XCTAssertEqual(EdgeDock.pickScreen(mouse: CGPoint(x: 500, y: 400), panel: .zero, screens: [left, right]), 0)
    }

    func testMouseOnSeamGoesToRightScreen() {
        XCTAssertEqual(EdgeDock.pickScreen(mouse: CGPoint(x: 1000, y: 400), panel: .zero, screens: [left, right]), 1,
                       "frame 的左边界算在内、右边界不算")
    }

    func testMouseOffScreensUsesLargestOverlap() {
        let panel = CGRect(x: 900, y: 100, width: 208, height: 100)   // 跨两屏，右屏占 108 宽
        XCTAssertEqual(EdgeDock.pickScreen(mouse: CGPoint(x: 1500, y: 1500), panel: panel, screens: [left, right]), 1)
    }

    func testNothingOverlapsReturnsNil() {
        let panel = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        XCTAssertNil(EdgeDock.pickScreen(mouse: CGPoint(x: 5000, y: 5000), panel: panel, screens: [left, right]))
    }

    // MARK: 锚点存档（hud.anchor.v2）

    func testAnchorIgnoresDx() {
        XCTAssertEqual(DockAnchor(archive: ["screen": "UUID-1", "dx": 1492.0, "dy": 839.0]),
                       DockAnchor(screen: "UUID-1", dy: 839))
    }

    func testAnchorAcceptsIntegerDy() {
        XCTAssertEqual(DockAnchor(archive: ["screen": "UUID-1", "dy": 839]), DockAnchor(screen: "UUID-1", dy: 839))
    }

    func testAnchorRejectsIncomplete() {
        XCTAssertNil(DockAnchor(archive: ["dx": 1.0, "dy": 2.0]), "没有屏")
        XCTAssertNil(DockAnchor(archive: ["screen": "U"]), "没有 dy")
        XCTAssertNil(DockAnchor(archive: ["screen": "U", "dy": Double.nan]), "dy 不是有限数")
    }

    func testAnchorArchiveWritesDockedDx() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1496, height: 967)
        let d = DockAnchor(screen: "U", dy: 839).archive(screenFrame: screenFrame, visibleFrame: visible)
        XCTAssertEqual(d["screen"] as? String, "U")
        XCTAssertEqual(d["dx"] as? Double, 1496, "dx 照写贴边值，装回旧版本也是贴右边")
        XCTAssertEqual(d["dy"] as? Double, 839)
    }

    func testAnchorTopIsRelativeToScreenOrigin() {
        let external = CGRect(x: 783, y: 967, width: 1920, height: 1080)
        XCTAssertEqual(DockAnchor(screen: "U", dy: 839).top(screenFrame: external), 1806)
    }
}

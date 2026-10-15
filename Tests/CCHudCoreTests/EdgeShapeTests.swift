import XCTest
import CoreGraphics
@testable import CCHudCore

/// 贴边外形（设计文档第 5 节、10.1、10.2）。坐标：左上原点、y 向下，x = 宽 是屏幕边缘。
/// 点击穿透直接用 path.contains 判定，所以这里按「点在不在外形里」来验。
final class EdgeShapeTests: XCTestCase {
    func testTabSize() {
        XCTAssertEqual(EdgeShape.tabShapeHeight, 50.596, accuracy: 0.01, "2·√((20+6)² − 6²)")
        XCTAssertEqual(EdgeShape.tabSize, CGSize(width: 20, height: 51))
    }

    func testBoxMaskNineSlice() {
        XCTAssertEqual(EdgeShape.boxMaskSize, CGSize(width: 18, height: 35))
        let i = EdgeShape.boxMaskInsets
        XCTAssertEqual([i.top, i.left, i.bottom, i.right], [17, 11, 17, 6], "上下 = f + r，左 = r，右 = f")
    }

    func testBoxContainsBodyAndFlareSlivers() {
        let p = EdgeShape.path(.box, in: CGSize(width: 208, height: 150))
        XCTAssertTrue(p.contains(CGPoint(x: 104, y: 75)), "主体中间")
        XCTAssertTrue(p.contains(CGPoint(x: 6, y: 20)), "左边缘、圆角以下")
        XCTAssertTrue(p.contains(CGPoint(x: 207.7, y: 3)), "右上外翻弧和屏幕边缘之间那一窄条")
        XCTAssertTrue(p.contains(CGPoint(x: 207.7, y: 147)), "右下外翻弧和屏幕边缘之间那一窄条")
    }

    func testBoxExcludesTransparentCorners() {
        let p = EdgeShape.path(.box, in: CGSize(width: 208, height: 150))
        XCTAssertFalse(p.contains(CGPoint(x: 1, y: 1)), "左上角")
        XCTAssertFalse(p.contains(CGPoint(x: 1, y: 8)), "左上圆角外侧")
        XCTAssertFalse(p.contains(CGPoint(x: 1, y: 142)), "左下圆角外侧")
        XCTAssertFalse(p.contains(CGPoint(x: 205, y: 3)), "主体顶边以上、外翻弧左侧")
        XCTAssertFalse(p.contains(CGPoint(x: 205, y: 147)), "主体底边以下、外翻弧左侧")
    }

    func testBoxBoundsFillSize() {
        let b = EdgeShape.path(.box, in: CGSize(width: 208, height: 150)).boundingBoxOfPath
        XCTAssertEqual(b.minX, 0, accuracy: 0.01)
        XCTAssertEqual(b.minY, 0, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 208, accuracy: 0.01)
        XCTAssertEqual(b.maxY, 150, accuracy: 0.01)
    }

    func testTabContainsAndExcludes() {
        let p = EdgeShape.path(.tab, in: EdgeShape.tabSize)
        XCTAssertTrue(p.contains(CGPoint(x: 10, y: 25.5)), "半圆中间")
        XCTAssertTrue(p.contains(CGPoint(x: 0.5, y: 25.5)), "半圆最左点附近")
        XCTAssertTrue(p.contains(CGPoint(x: 19.8, y: 3)), "上外翻弧和屏幕边缘之间")
        XCTAssertTrue(p.contains(CGPoint(x: 19.8, y: 48)), "下外翻弧和屏幕边缘之间")
        XCTAssertFalse(p.contains(CGPoint(x: 0.5, y: 2)), "左上角")
        XCTAssertFalse(p.contains(CGPoint(x: 0.5, y: 20)), "半圆外侧")
        XCTAssertFalse(p.contains(CGPoint(x: 15, y: 3)), "上外翻弧左侧")
    }

    func testTabCenteredVertically() {
        let b = EdgeShape.path(.tab, in: EdgeShape.tabSize).boundingBoxOfPath
        XCTAssertEqual(b.minX, 0, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 20, accuracy: 0.01)
        XCTAssertEqual(b.minY, 0.202, accuracy: 0.01, "外形高 50.6，在 51 高的窗口里上下各留 0.2")
        XCTAssertEqual(b.maxY, 50.798, accuracy: 0.01)
    }

    func testOutlineStopsAtScreenEdge() {
        let box = EdgeShape.outline(.box, in: CGSize(width: 208, height: 150))
        XCTAssertEqual(box.currentPoint.x, 208, accuracy: 0.01)
        XCTAssertEqual(box.currentPoint.y, 150, accuracy: 0.01, "开放路径停在右下角，不沿屏幕边缘回去")
        let tab = EdgeShape.outline(.tab, in: EdgeShape.tabSize)
        XCTAssertEqual(tab.currentPoint.x, 20, accuracy: 0.01)
        XCTAssertEqual(tab.currentPoint.y, 50.798, accuracy: 0.01)
    }
}

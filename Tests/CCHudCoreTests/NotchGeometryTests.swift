import XCTest
@testable import CCHudCore

final class NotchGeometryTests: XCTestCase {
    // 固件取自本机实测：内置屏 1496×967，刘海 160×28（左界 668 / 右界 828），中心 x=748
    private let builtIn = CGRect(x: 0, y: 0, width: 1496, height: 967)
    private let auxL = CGRect(x: 0, y: 939, width: 668, height: 28)
    private let auxR = CGRect(x: 828, y: 939, width: 668, height: 28)
    // 外接屏（无刘海），实测位置在内置屏正上方
    private let external = CGRect(x: -1137, y: 967, width: 1920, height: 1080)

    func testNotchRectFromBuiltInScreen() {
        let r = NotchGeometry.notchRect(screenFrame: builtIn, safeAreaTop: 28,
                                        auxLeft: auxL, auxRight: auxR)
        XCTAssertEqual(r, CGRect(x: 668, y: 939, width: 160, height: 28))
    }

    func testNoNotchWhenSafeAreaZero() {
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: external, safeAreaTop: 0,
                                             auxLeft: nil, auxRight: nil))
    }

    func testNoNotchWhenAuxAreaMissing() {
        // safeAreaTop > 0 但拿不到 aux 区（异常显示器）→ 当无刘海，调用方走胶囊版
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: builtIn, safeAreaTop: 28,
                                             auxLeft: nil, auxRight: auxR))
    }

    func testNoNotchWhenAuxAreasTouch() {
        // 左右辅助区贴合、中间没有间隙 → 没有刘海
        let l = CGRect(x: 0, y: 939, width: 748, height: 28)
        let r = CGRect(x: 748, y: 939, width: 748, height: 28)
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: builtIn, safeAreaTop: 28,
                                             auxLeft: l, auxRight: r))
    }

    func testIslandFrameCentersOnNotch() {
        let notch = CGRect(x: 668, y: 939, width: 160, height: 28)
        let f = NotchGeometry.islandFrame(screenFrame: builtIn, notch: notch,
                                          contentSize: CGSize(width: 360, height: 110))
        XCTAssertEqual(f, CGRect(x: 568, y: 857, width: 360, height: 110),
                       "顶边贴屏顶(967-110)，水平居中于刘海中心 748")
    }

    func testIslandFrameCentersOnScreenWhenNoNotch() {
        let f = NotchGeometry.islandFrame(screenFrame: external, notch: nil,
                                          contentSize: CGSize(width: 360, height: 110))
        XCTAssertEqual(f, CGRect(x: -357, y: 1937, width: 360, height: 110),
                       "无刘海 → 居中于屏心 -177，顶边贴屏顶 2047-110")
    }

    func testIslandFrameClampsOversizeContent() {
        let notch = CGRect(x: 668, y: 939, width: 160, height: 28)
        let f = NotchGeometry.islandFrame(screenFrame: builtIn, notch: notch,
                                          contentSize: CGSize(width: 2000, height: 110))
        XCTAssertEqual(f, CGRect(x: 0, y: 857, width: 1496, height: 110),
                       "内容超屏宽 → 夹到屏宽并贴左边界，不越界")
    }
}

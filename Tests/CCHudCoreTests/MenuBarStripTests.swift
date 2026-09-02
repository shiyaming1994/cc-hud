import XCTest
@testable import CCHudCore

/// 固件全部取自本机 CGWindowList + NSScreen 实测（三屏：内置刘海屏 + 上方两块 T2752U）：
///   主屏      NS frame (0,0,1496,967)      菜单栏 CG (0,0,1496,29)        状态项左缘 CG x=952
///   右外接屏  NS frame (783,967,1920,1080) 菜单栏 CG (783,-1080,1920,30)  状态项左缘 CG x=2157
///   左外接屏  NS frame (-1137,967,...)     菜单栏 CG (-1137,-1080,1920,30)
final class MenuBarStripTests: XCTestCase {
    private let primaryHeight: CGFloat = 967
    private let mainBar = CGRect(x: 0, y: 938, width: 1496, height: 29)
    private let rightBar = CGRect(x: 783, y: 2017, width: 1920, height: 30)
    private let notch = CGRect(x: 668, y: 939, width: 160, height: 28)

    // MARK: CG(左上原点、原点在主屏左上) → NS(左下原点)

    func testCGToNSOnMainScreen() {
        let r = MenuBarStrip.nsRect(fromCG: CGRect(x: 0, y: 0, width: 1496, height: 29),
                                    primaryHeight: primaryHeight)
        XCTAssertEqual(r, mainBar, "主屏菜单栏贴屏顶：967-0-29=938")
    }

    func testCGToNSOnScreenAboveMain() {
        // 外接屏在主屏正上方 → CG y 为负，转换后 NS y 必须落在主屏之上
        let r = MenuBarStrip.nsRect(fromCG: CGRect(x: 783, y: -1080, width: 1920, height: 30),
                                    primaryHeight: primaryHeight)
        XCTAssertEqual(r, rightBar, "967-(-1080)-30=2017，且 maxY 2047 = 该屏 frame.maxY")
    }

    func testCGToNSKeepsXUnchanged() {
        // 左外接屏 x 为负，横坐标两系一致、不能翻转
        let r = MenuBarStrip.nsRect(fromCG: CGRect(x: -1137, y: -1080, width: 1920, height: 30),
                                    primaryHeight: primaryHeight)
        XCTAssertEqual(r.minX, -1137)
    }

    // MARK: 条子 frame

    func testRightAlignsToStatusItems() {
        let f = MenuBarStrip.frame(bar: rightBar, statusItemsMinX: 2157, notch: nil,
                                   contentWidth: 240, gap: 12)
        XCTAssertEqual(f, CGRect(x: 1905, y: 2017, width: 240, height: 30),
                       "右缘贴状态项左缘 -12：2157-12-240=1905；高度取菜单栏实测高")
    }

    func testGrowsLeftwardWhenContentWidens() {
        // 内容变宽（7D 追加重置倒计时）→ 右缘不动、向左长
        let narrow = MenuBarStrip.frame(bar: rightBar, statusItemsMinX: 2157, notch: nil,
                                        contentWidth: 240, gap: 12)
        let wide = MenuBarStrip.frame(bar: rightBar, statusItemsMinX: 2157, notch: nil,
                                      contentWidth: 320, gap: 12)
        XCTAssertEqual(narrow.maxX, wide.maxX)
        XCTAssertLessThan(wide.minX, narrow.minX)
    }

    func testCentersWhenStatusItemsUnknown() {
        // 枚举不到状态项（探测失败/该屏无状态项）→ 退回居中，不硬贴屏右缘压住时钟
        let f = MenuBarStrip.frame(bar: rightBar, statusItemsMinX: nil, notch: nil,
                                   contentWidth: 240, gap: 12)
        XCTAssertEqual(f, CGRect(x: 1623, y: 2017, width: 240, height: 30),
                       "居中于菜单栏中心 1743")
    }

    func testPushedLeftOfNotchWhenOverlapping() {
        // 主屏实测：右对齐结果 952-12-240=700，与刘海 [668,828] 相交 → 整条推到刘海左侧
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 952, notch: notch,
                                   contentWidth: 240, gap: 12)
        XCTAssertEqual(f, CGRect(x: 416, y: 938, width: 240, height: 29),
                       "668-12-240=416，完整落在刘海左侧")
    }

    func testKeepsRightAlignWhenNotchNotInTheWay() {
        // 内容够窄，右对齐后整条都在刘海右侧 → 不必推走
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 952, notch: notch,
                                   contentWidth: 100, gap: 12)
        XCTAssertEqual(f.minX, 840)
    }

    func testClampsOversizeContentToBar() {
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 952, notch: nil,
                                   contentWidth: 3000, gap: 12)
        XCTAssertEqual(f, CGRect(x: 0, y: 938, width: 1496, height: 29),
                       "内容超菜单栏宽 → 夹到菜单栏宽并贴左缘")
    }

    func testClampsLeftEdgeIntoBar() {
        // 状态项异常靠左（枚举到了菜单区里的其他窗口）→ 左缘不得越出屏外
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 100, notch: nil,
                                   contentWidth: 240, gap: 12)
        XCTAssertEqual(f.minX, 0)
    }

    // MARK: 目标屏选择

    func testPrefersSavedScreenWhenPresent() {
        let i = MenuBarStrip.preferredScreenIndex(savedUUID: "B", uuids: ["A", "B", "C"],
                                                  hasNotch: [true, false, false],
                                                  minX: [0, 783, -1137])
        XCTAssertEqual(i, 1, "存档屏在场就用它，哪怕它不是最靠左的那块")
    }

    func testAutoPrefersScreenWithoutNotch() {
        // 「自动」不能选刘海屏：实测内置屏菜单栏被 App 菜单 + 刘海 + 状态项挤满，
        // 两段空隙只有 108pt / 86pt，条子放不下必然压住别人
        // 本机实测坐标：内置屏 0、T2752U(2) 在 783、T2752U(1) 在 -1137 → 自动取最靠左的 (1)
        let i = MenuBarStrip.preferredScreenIndex(savedUUID: nil, uuids: ["A", "B", "C"],
                                                  hasNotch: [true, false, false],
                                                  minX: [0, 783, -1137])
        XCTAssertEqual(i, 2, "两块无刘海屏 → 取最靠左的那块，不看 screens 顺序")
    }

    func testFallsBackToAutoWhenSavedScreenAbsent() {
        // 存档屏拔掉了 → 按「自动」规则临时落位（存档本身不动，由调用方保证）
        let i = MenuBarStrip.preferredScreenIndex(savedUUID: "GONE", uuids: ["A", "B"],
                                                  hasNotch: [true, false], minX: [0, 783])
        XCTAssertEqual(i, 1)
    }

    func testAutoFallsBackToMainWhenEveryScreenHasNotch() {
        // 只有内置屏（合盖外接全拔）→ 没得挑，落主屏
        let i = MenuBarStrip.preferredScreenIndex(savedUUID: nil, uuids: ["A"],
                                                  hasNotch: [true], minX: [0])
        XCTAssertEqual(i, 0)
    }

    func testNoScreenAtAll() {
        XCTAssertNil(MenuBarStrip.preferredScreenIndex(savedUUID: nil, uuids: [],
                                                       hasNotch: [], minX: []))
    }

    // MARK: 菜单栏矩形兜底（枚举不到 layer-24 菜单栏窗口时）

    func testFallbackBarUsesVisibleFrameTopInset() {
        // 主屏实测：frame 967 高、visibleFrame 顶部被菜单栏扣掉 29
        let bar = MenuBarStrip.fallbackBar(
            screenFrame: CGRect(x: 0, y: 0, width: 1496, height: 967),
            visibleFrame: CGRect(x: 0, y: 87, width: 1496, height: 851),
            defaultHeight: 24)
        XCTAssertEqual(bar, mainBar, "顶部内缩 967-938=29 即菜单栏高")
    }

    func testFallbackBarUsesDefaultHeightWhenNoTopInset() {
        // 外接屏实测：visibleFrame == frame（顶部不扣菜单栏）→ 推不出高度，用系统菜单栏厚度兜底
        let bar = MenuBarStrip.fallbackBar(
            screenFrame: CGRect(x: 783, y: 967, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 783, y: 967, width: 1920, height: 1080),
            defaultHeight: 24)
        XCTAssertEqual(bar, CGRect(x: 783, y: 2023, width: 1920, height: 24))
    }

    // MARK: 7D 重置展示判据（剩余 <20% 或 距重置 <24h）

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSevenDayResetShownWhenQuotaLow() {
        XCTAssertTrue(MenuBarStrip.showsSevenDayReset(
            remainPct: 19, resetsAt: now.addingTimeInterval(5 * 86400), now: now))
    }

    func testSevenDayResetHiddenAtExactly20Percent() {
        XCTAssertFalse(MenuBarStrip.showsSevenDayReset(
            remainPct: 20, resetsAt: now.addingTimeInterval(5 * 86400), now: now),
                       "判据是「低于 20%」，20 本身不触发")
    }

    func testSevenDayResetShownWhenResetWithin24h() {
        XCTAssertTrue(MenuBarStrip.showsSevenDayReset(
            remainPct: 80, resetsAt: now.addingTimeInterval(23 * 3600), now: now))
    }

    func testSevenDayResetHiddenAtExactly24h() {
        XCTAssertFalse(MenuBarStrip.showsSevenDayReset(
            remainPct: 80, resetsAt: now.addingTimeInterval(24 * 3600), now: now))
    }

    func testSevenDayResetHiddenWhenComfortable() {
        XCTAssertFalse(MenuBarStrip.showsSevenDayReset(
            remainPct: 41, resetsAt: now.addingTimeInterval(3 * 86400), now: now))
    }

    func testSevenDayResetHiddenWithoutResetDate() {
        // 没有重置时刻可显示 → 只剩"低额度"这一条也没东西可展示
        XCTAssertFalse(MenuBarStrip.showsSevenDayReset(remainPct: 5, resetsAt: nil, now: now))
    }

    // MARK: 同名显示器去重（本机就是两台同名 T2752U）

    func testLabelsDisambiguateSameNameByPosition() {
        let labels = MenuBarStrip.displayLabels([
            (name: "Color LCD", minX: 0),
            (name: "T2752U", minX: 783),
            (name: "T2752U", minX: -1137),
        ])
        XCTAssertEqual(labels, ["Color LCD", "T2752U（右）", "T2752U（左）"],
                       "同名按 x 排序标左右；唯一名保持原样；返回顺序与入参一致")
    }

    func testLabelsStripSystemNumberingBeforeGrouping() {
        // 实测：macOS 自己把两块同型号屏命名成 "T2752U (1)" / "T2752U (2)"，字符串并不相同，
        // 而编号与位置无关（本机 (1) 在左、(2) 在右）→ 必须先剥掉系统编号再按位置重标
        let labels = MenuBarStrip.displayLabels([
            (name: "Built-in Retina Display", minX: 0),
            (name: "T2752U (2)", minX: 783),
            (name: "T2752U (1)", minX: -1137),
        ])
        XCTAssertEqual(labels, ["Built-in Retina Display", "T2752U（右）", "T2752U（左）"])
    }

    func testLabelsKeepSystemNumberingWhenItIsTheOnlyOne() {
        // 只有一块带编号的屏 → 没什么可去重的，原样保留，别自作主张改名
        XCTAssertEqual(MenuBarStrip.displayLabels([(name: "T2752U (1)", minX: 0)]),
                       ["T2752U (1)"])
    }

    func testLabelsUseLeftMiddleRightForThree() {
        let labels = MenuBarStrip.displayLabels([
            (name: "S", minX: 100), (name: "S", minX: -100), (name: "S", minX: 0),
        ])
        XCTAssertEqual(labels, ["S（右）", "S（左）", "S（中）"])
    }

    func testLabelsFallBackToIndexBeyondThree() {
        let labels = MenuBarStrip.displayLabels([
            (name: "S", minX: 0), (name: "S", minX: 1),
            (name: "S", minX: 2), (name: "S", minX: 3),
        ])
        XCTAssertEqual(labels, ["S（1）", "S（2）", "S（3）", "S（4）"])
    }
}

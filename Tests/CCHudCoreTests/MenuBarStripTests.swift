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
        XCTAssertEqual(f, CGRect(x: 1617, y: 2017, width: 240, height: 30),
                       "居中于可用区 [783, 2691] 的中心 1737 → 1737-120")
    }

    func testNeverCrossesNotchEvenIfContentTooWide() {
        // 主屏实测：可用区只有 [828, 940] = 112pt。内容宣称 240 也只能占 112，
        // 且左缘不得越过刘海右缘去压 App 菜单（这正是 1.4.0 首次安装时撞上的问题）
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 952, notch: notch,
                                   contentWidth: 240, gap: 12)
        XCTAssertEqual(f, CGRect(x: 828, y: 938, width: 112, height: 29))
    }

    func testDefaultGapAlignsToStatusItemWindowEdge() {
        // 默认 gap = 0：右缘与状态项窗口左缘对齐。设计稿的"到图标 12pt"由图标自身的
        // 内边距(9.5–12.5pt)加末字边距(2–3.5pt)自然凑出，实测 11.5–16pt。
        let f = MenuBarStrip.frame(bar: rightBar, statusItemsMinX: 2157, notch: nil,
                                   contentWidth: 200)
        XCTAssertEqual(f.maxX, 2157)
    }

    // MARK: 可用宽度预算与降级选档

    func testBudgetIsNotchRightEdgeToStatusItems() {
        // 内置刘海屏实测：刘海右缘 828、状态项左缘 952 → 只有 112pt 可用
        XCTAssertEqual(MenuBarStrip.budget(bar: mainBar, statusItemsMinX: 952,
                                           notch: notch, gap: 12), 112)
    }

    func testBudgetOnNotchlessScreenIsWholeLeftSpan() {
        // 外接屏：左界就是菜单栏左缘 783，右界 2157-12 → 1362pt,整条随便放
        XCTAssertEqual(MenuBarStrip.budget(bar: rightBar, statusItemsMinX: 2157,
                                           notch: nil, gap: 12), 1362)
    }

    func testFittingVariantPicksRichestThatFits() {
        // 各档宽度由富到简；预算 112 → 跳过前两档，选第三档
        XCTAssertEqual(MenuBarStrip.fittingVariant(widths: [192, 150, 110, 78, 55], budget: 112), 2)
    }

    func testFittingVariantPicksFullWhenRoomy() {
        XCTAssertEqual(MenuBarStrip.fittingVariant(widths: [192, 150, 110, 78, 55], budget: 1362), 0)
    }

    func testFittingVariantNilWhenEvenSimplestDoesNotFit() {
        // 连最简的都塞不下（状态项多到把空隙吃光）→ 整条不上屏，不硬挤
        XCTAssertNil(MenuBarStrip.fittingVariant(widths: [192, 150, 110, 78, 55], budget: 40))
    }

    func testKeepsRightAlignWhenNotchNotInTheWay() {
        // 内容够窄，右对齐后整条都在刘海右侧 → 不必推走
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 952, notch: notch,
                                   contentWidth: 100, gap: 12)
        XCTAssertEqual(f.minX, 840)
    }

    func testClampsOversizeContentToAvailableSpan() {
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 952, notch: nil,
                                   contentWidth: 3000, gap: 12)
        XCTAssertEqual(f, CGRect(x: 0, y: 938, width: 940, height: 29),
                       "无刘海时左界是菜单栏左缘，右界仍是状态项左缘 -12,绝不压图标")
    }

    func testClampsLeftEdgeIntoBar() {
        // 状态项异常靠左（枚举到了菜单区里的其他窗口）→ 左缘不得越出屏外
        let f = MenuBarStrip.frame(bar: mainBar, statusItemsMinX: 100, notch: nil,
                                   contentWidth: 240, gap: 12)
        XCTAssertEqual(f.minX, 0)
    }

    // MARK: 渲染真宽（SwiftUI 逐段把 Text 宽度向上取整到整点）
    //
    // NSAttributedString 逐段求和会**少算**：SwiftUI 把每个 Text 的宽度向上取整到整点、
    // 最后整行再取整一次。少算的后果不是"差几个点"这么轻——NSHostingView 会用 Auto Layout
    // 把窗口按真实渲染宽度**向右撑开**，于是条子右缘越过状态项左缘（实测越出 2–3pt）。
    // 2026-09-02 用 14 个真实字串逐段对比 NSAttributedString.size() 向上取整 vs
    // NSHostingView(Text(…)).fittingSize，14/14 精确吻合。

    func testRenderWidthRoundsEachTextRunUpToWholePoints() {
        // 最简档「5H 68%」实测：三段 17.628 / 15.748 / 11.942，间距 4 + 1.5
        // 朴素求和 = 50.818（会少算），逐段取整 18+16+12 = 46，+5.5 → 51.5 → 整行取整 52
        // NSHostingView 实测正是 52
        XCTAssertEqual(MenuBarStrip.renderWidth(runs: [17.628, 15.748, 11.942], gaps: 5.5), 52)
    }

    func testRenderWidthOfFullRowMatchesMeasuredRender() {
        // 全档「5H 68% 14:50  7D 96%  59M」实测各段宽 + 间距合计 42
        // 朴素求和 191.39（这正是线上上报的值），真实渲染 196
        let runs: [CGFloat] = [17.628, 15.748, 11.942, 34.297, 17.351, 15.117, 11.104, 26.205]
        XCTAssertEqual(MenuBarStrip.renderWidth(runs: runs, gaps: 42), 196)
    }

    func testRenderWidthNeverUnderestimatesNaiveSum() {
        // 不变量：宁可多算也不能少算——少算就会被 Auto Layout 向右撑出去压到状态项
        let runs: [CGFloat] = [17.628, 15.748, 11.942, 34.297]
        XCTAssertGreaterThanOrEqual(MenuBarStrip.renderWidth(runs: runs, gaps: 10.5),
                                    runs.reduce(10.5, +))
    }

    func testRenderWidthOfEmptyRowIsZero() {
        XCTAssertEqual(MenuBarStrip.renderWidth(runs: [], gaps: 0), 0)
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
        // 该屏压根没给菜单栏留位置（visibleFrame == frame）→ 推不出高度，用系统菜单栏厚度兜底。
        // 注意别拿"外接屏"当这条的例子：非主屏的 visibleFrame 要进程初始化过 NSApplication
        // 才返回真值，真 app 里外接屏是照常内缩 30 的（裸脚本量出来的 0 是假象）。
        let bar = MenuBarStrip.fallbackBar(
            screenFrame: CGRect(x: 783, y: 967, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 783, y: 967, width: 1920, height: 1080),
            defaultHeight: 24)
        XCTAssertEqual(bar, CGRect(x: 783, y: 2023, width: 1920, height: 24))
    }

    // MARK: 菜单栏可见性（不可见时条子必须一并撤下）
    //
    // 判据 = 「该屏此刻有没有状态项」。2026-09-02 实测（自建窗口 toggleFullScreen 落到指定屏，
    // 每次用 AX 的 AXFullScreen 确认落点，两块屏各两次采样）：
    //
    //   被占的屏      topInset   layer24   状态项(排自己)
    //   左外接         30 不变      0          0
    //   内置           29 不变      1          0
    //   未被占的屏     不变         1         13
    //
    // 即：topInset 全屏时纹丝不动（不可用）；layer24 跨屏不一致（内置屏上全程在场，不可用）；
    // 只有「状态项归零」稳定且按屏精确。这份数据 MenuBarProbe 本来就在算，零新增开销。

    func testHiddenWhenSystemAutoHideMenuBarIsOn() {
        // 自动隐藏时菜单栏只在鼠标顶边时滑出，独立窗口跟不了这个滑出动作 → 一律不显示，
        // 否则它会长期悬在用户内容之上
        XCTAssertFalse(MenuBarStrip.menuBarVisible(autoHideEnabled: true, hasStatusItems: true))
    }

    func testHiddenWhenFullScreenAppOccupiesTheScreen() {
        // 全屏 App 占据该屏 → 该屏的状态项窗口整体离屏，枚举为空
        XCTAssertFalse(MenuBarStrip.menuBarVisible(autoHideEnabled: false, hasStatusItems: false))
    }

    func testVisibleWhenScreenShowsStatusItems() {
        XCTAssertTrue(MenuBarStrip.menuBarVisible(autoHideEnabled: false, hasStatusItems: true))
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

import XCTest
import AppKit
@testable import CCHudCore

/// [StripRun] → NSAttributedString 的拼装。重点测"段间距落成末字尾随 kern"这个映射 ——
/// 上一轮就是宽度算错(少算 2–3pt)导致窗口被 Auto Layout 撑开、右缘压过状态项左缘的。
final class StripTitleTests: XCTestCase {

    private func rgb(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let s = c.usingColorSpace(.sRGB)!
        return (s.redComponent, s.greenComponent, s.blueComponent)
    }

    func testEmptyRunsYieldEmptyString() {
        XCTAssertEqual(StripTitle.attributed([]).length, 0)
    }

    func testTextCarriesFontColorAndTracking() {
        let s = StripTitle.attributed([
            .text("5H", weight: .label, ink: .l3, tracking: .label, glow: false),
        ])
        XCTAssertEqual(s.string, "5H")
        XCTAssertEqual(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       StripStyle.font(.label))
        XCTAssertNotNil(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertNil(s.attribute(.shadow, at: 0, effectiveRange: nil), "未要求光晕就不该有 shadow")
    }

    func testGlowRunGetsShadow() {
        let s = StripTitle.attributed([
            .text("68", weight: .five, ink: .l1, tracking: .none, glow: true),
        ])
        XCTAssertNotNil(s.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow)
    }

    func testGapLandsAsTrailingKernOnPreviousRunsLastCharacter() {
        let s = StripTitle.attributed([
            .text("5H", weight: .label, ink: .l3, tracking: .label, glow: false),
            .gap(.labelToValue),
            .text("68", weight: .five, ink: .l1, tracking: .none, glow: true),
        ])
        let first = s.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
        let last = s.attribute(.kern, at: 1, effectiveRange: nil) as? CGFloat ?? 0
        XCTAssertEqual(first, StripStyle.tracking(.label), accuracy: 0.001,
                       "非末字只带本段字距")
        XCTAssertEqual(last, StripStyle.tracking(.label) + StripStyle.gap(.labelToValue),
                       accuracy: 0.001, "末字的 kern = 本段字距 + 间距")
    }

    func testLeadingGapIsIgnored() {
        let s = StripTitle.attributed([
            .gap(.groupGap),
            .text("5H", weight: .label, ink: .l3, tracking: .none, glow: false),
        ])
        XCTAssertEqual(s.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0, 0,
                       "首位的间距没有可依附的前一段，直接丢掉")
    }

    func testWidthEqualsRunWidthsPlusGaps() {
        // 这条断言证明 gap→kern 的映射无损。它不是与菜单栏之间的布局契约 ——
        // 上屏宽度由 NSStatusItem.variableLength 交给系统量。
        let runs: [StripRun] = [
            .text("5H", weight: .label, ink: .l3, tracking: .label, glow: false),
            .gap(.labelToValue),
            .text("68", weight: .five, ink: .l1, tracking: .none, glow: true),
            .gap(.valueToPercent),
            .text("%", weight: .five, ink: .l3, tracking: .none, glow: false),
        ]
        func w(_ s: String, _ weight: StripWeight, _ kern: CGFloat) -> CGFloat {
            NSAttributedString(string: s, attributes: [.font: StripStyle.font(weight),
                                                       .kern: kern]).size().width
        }
        let expected = w("5H", .label, StripStyle.tracking(.label))
            + StripStyle.gap(.labelToValue)
            + w("68", .five, 0)
            + StripStyle.gap(.valueToPercent)
            + w("%", .five, 0)
        XCTAssertEqual(StripTitle.attributed(runs).size().width, expected, accuracy: 0.5)
    }

    func testInkDiffersBetweenLightAndDark() {
        for ink in [StripInk.l1, .l2, .l3, .caution, .alert] {
            XCTAssertNotEqual(rgb(StripStyle.color(ink, dark: true)).0,
                              rgb(StripStyle.color(ink, dark: false)).0,
                              "\(ink) 的深浅两套色值不该相同")
        }
    }

    func testAllWeightsMapToTheSameSize() {
        for w in [StripWeight.label, .five, .seven, .regular, .alert] {
            XCTAssertEqual(StripStyle.font(w).pointSize, StripStyle.size,
                           "设计稿要求全行只有一个字号，层级只交给字重与明度")
        }
    }

    func testGapMagnitudesMatchTheDesign() {
        // 设计稿《菜单栏额度条 · 齐平》：组内 4 / 1.5 / 5，组间 13
        XCTAssertEqual(StripStyle.gap(.labelToValue), 4)
        XCTAssertEqual(StripStyle.gap(.valueToPercent), 1.5)
        XCTAssertEqual(StripStyle.gap(.percentToTime), 5)
        XCTAssertEqual(StripStyle.gap(.groupGap), 13)
    }
}

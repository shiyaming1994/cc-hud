import XCTest
import AppKit
import SwiftUI
@testable import CCHud

/// 面板窗口跟着内容换尺寸（设计文档 4.2、4.3）。用真的 NSPanel，从不上屏。
@MainActor
final class HUDPanelTests: XCTestCase {
    /// 松手吸附的 0.2 秒动画还在跑时内容尺寸变了（拖完标签松手、马上点开列表）：
    /// 新尺寸要留住，不能被动画剩下的帧盖回标签大小——否则窗口卡成标签大小、里面塞着列表，自己恢复不了。
    func testContentSizeChangeDuringSnapAnimationSticks() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "没有显示器：dock() 无处落位")
        let panel = HUDPanel(rootView: EmptyView())
        let f = panel.frame
        // 和松手吸附一样的 0.2 秒动画，目标是标签大小
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().setFrame(NSRect(x: f.maxX - 20, y: f.maxY - 51, width: 20, height: 51), display: true)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))   // 动画走到一半
        panel.applyContentSize(CGSize(width: 208, height: 160))       // 点开了列表
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))    // 等动画该结束的时候过去
        XCTAssertEqual(panel.frame.size, CGSize(width: 208, height: 160))
    }
}

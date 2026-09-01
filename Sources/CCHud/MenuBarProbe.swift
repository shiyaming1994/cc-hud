import AppKit
import CCHudCore

/// 菜单栏实测探针：一次 CGWindowList 枚举同时拿到「该屏菜单栏矩形」与「状态项左缘」。
///
/// 为什么不用 NSScreen 推算菜单栏：实测**外接屏的 visibleFrame 不扣菜单栏**（visible == frame），
/// 推不出来；菜单栏高度还随分辨率变（本机内置屏 1496 宽时 29pt、1728 宽时 33pt），不能硬编码。
///
/// 为什么状态项左缘只能枚举：只有真正的 NSStatusItem 才参与菜单栏布局、被系统自动挤开，
/// 而它由系统决定落在哪块屏——与「钉在指定显示器」互斥。我们是独立窗口，只能量邻居。
/// 好在 Big Sur 起所有状态项（含第三方：QQ / BetterDisplay / Tunnelblick / clash-verge…）
/// 都由「控制中心」进程托管，一次枚举拿得全，不是只算系统图标的估算。
enum MenuBarProbe {
    struct Layout: Equatable {
        /// 该屏菜单栏矩形（NS 坐标）；枚举不到就由 MenuBarStrip.fallbackBar 估一个，
        /// 绝不返回"没有"——否则用户选了某块屏却什么都不出现。
        let bar: CGRect
        /// 状态项区最左缘（NS 坐标）；枚举不到时 nil，调用方退回居中。
        let statusItemsMinX: CGFloat?
    }

    private static let menuBarLayer = 24     // Window Server 的菜单栏底板
    private static let statusItemLayer = 25  // 状态项（= NSStatusWindowLevel）

    static func layout(for screen: NSScreen) -> Layout {
        // CG 全局坐标以「主屏左上」为原点，主屏 = frame.origin 为零的那块
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
                             ?? NSScreen.screens.first)?.frame.height ?? screen.frame.height
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let myPid = ProcessInfo.processInfo.processIdentifier
        let sf = screen.frame
        var bar: CGRect?
        var minX: CGFloat?

        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  layer == menuBarLayer || layer == statusItemLayer,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let cw = b["Width"], let ch = b["Height"]
            else { continue }
            let r = MenuBarStrip.nsRect(fromCG: CGRect(x: x, y: y, width: cw, height: ch),
                                        primaryHeight: primaryHeight)
            // 只认「贴住该屏顶边、菜单栏高度量级」的窗口：把 .statusBar 级的普通浮窗
            // （我们自己的 HUD 就是一个）挡在外面
            guard r.height >= 16, r.height <= 48,
                  abs(r.maxY - sf.maxY) < 2,
                  r.midX > sf.minX, r.midX < sf.maxX else { continue }
            if layer == menuBarLayer {
                if bar == nil || r.width > bar!.width { bar = r }
            } else {
                // 我们自己的条子也在 25 层、也贴着菜单栏——按 PID 排除，否则会被自己顶着往左跑。
                // 状态项归「控制中心」所有，不受这条排除影响。
                let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
                guard pid != myPid else { continue }
                minX = min(minX ?? .greatestFiniteMagnitude, r.minX)
            }
        }
        return Layout(bar: bar ?? MenuBarStrip.fallbackBar(
                        screenFrame: sf, visibleFrame: screen.visibleFrame,
                        defaultHeight: NSStatusBar.system.thickness),
                      statusItemsMinX: minX)
    }
}

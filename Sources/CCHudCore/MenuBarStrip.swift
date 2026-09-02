import CoreGraphics
import Foundation

/// 菜单栏额度条的几何与展示判据。
/// 纯函数、不碰 AppKit（选屏与窗口枚举留给 app 层）——多屏 / 负坐标 / 刘海避让 / 边界夹取
/// 这些分支不单测必出事，与 NotchGeometry 同样的可测性考量。
public enum MenuBarStrip {
    /// 条子右缘相对状态项**窗口**左缘的偏移（负 = 越过窗口边界）。
    /// 设计稿要的是"到图标 12pt"，但我们只能量到窗口边界：实测该边界到图标墨迹还有 ~12.5pt
    /// 内边距，我们自己末字的右侧边距 ~3.5pt，故需越过 4pt 才得到 12pt 的视觉间距——
    /// 这 4pt 落在图标自己的空白内边距里，不会压到任何图标。
    public static let iconGap: CGFloat = 0

    /// CGWindowList 坐标（左上原点、y 向下、原点在主屏左上）→ NSScreen 坐标（左下原点、y 向上）。
    /// 主屏之上的显示器 CG y 为负，转换后 NS y 大于主屏高；x 两系一致、不翻转。
    public static func nsRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height,
               width: r.width, height: r.height)
    }

    /// 条子可用的横向预算：左界 = 刘海右缘（无刘海则菜单栏左缘），右界 = 状态项左缘 - gap。
    /// 内容按这个预算降级（见 fittingVariant），放不下就少显示几段，而不是推到刘海左侧去压
    /// App 菜单 —— 实测内置屏刘海左侧只有 ~108pt 且左界(App 菜单右缘)不可测，推过去必撞。
    public static func budget(bar: CGRect, statusItemsMinX: CGFloat?, notch: CGRect?,
                              gap: CGFloat = iconGap) -> CGFloat {
        let left = max(bar.minX, notch?.maxX ?? bar.minX)
        let right = (statusItemsMinX ?? bar.maxX) - gap
        return max(0, right - left)
    }

    /// 从"最全"到"最简"排好的各档宽度里，选第一个塞得下的；连最简的都塞不下返回 nil（整条不上屏）。
    public static func fittingVariant(widths: [CGFloat], budget: CGFloat) -> Int? {
        widths.indices.first { widths[$0] <= budget }
    }

    /// 条子 frame（NS 坐标）：整条填满菜单栏高度，右缘贴状态项左缘 - gap，内容变宽向左生长。
    /// - 拿不到状态项左缘（枚举失败 / 该屏无状态项）→ 居中于可用区，不硬贴屏右缘压住时钟。
    /// - 左界恒为刘海右缘：宁可少显示几段（调用方已按 budget 降级），也不越过刘海去压 App 菜单。
    public static func frame(bar: CGRect, statusItemsMinX: CGFloat?, notch: CGRect?,
                             contentWidth: CGFloat, gap: CGFloat = iconGap) -> CGRect {
        let left = max(bar.minX, notch?.maxX ?? bar.minX)
        let right = (statusItemsMinX ?? bar.maxX) - gap
        let w = min(contentWidth, max(0, right - left))
        let x = statusItemsMinX == nil ? (left + right) / 2 - w / 2 : right - w
        return CGRect(x: min(max(x, left), max(left, right - w)), y: bar.minY,
                      width: w, height: bar.height)
    }

    /// 目标屏下标：存档屏在场就用它；否则「自动」——**优先无刘海屏**。
    /// 刘海屏不能当自动首选：实测内置屏菜单栏被 App 菜单(~0–560) + 刘海(668–828) +
    /// 13 个状态项(914–1496) 挤满，剩下的两段空隙只有 108pt / 86pt，条子放不下，
    /// 落在哪边都会压住别人。全是刘海屏（合盖只剩内置屏）才退回主屏。
    /// 无刘海屏有多块时取**最靠左**的，不取 NSScreen.screens 的天然顺序 —— 实测两块同型号屏
    /// 在不同进程里顺序并不一致，靠它选屏会让条子在重启后自己跳到另一块屏上。
    public static func preferredScreenIndex(savedUUID: String?, uuids: [String?],
                                            hasNotch: [Bool], minX: [CGFloat]) -> Int? {
        guard !uuids.isEmpty else { return nil }
        if let savedUUID, let i = uuids.firstIndex(of: savedUUID) { return i }
        let plain = uuids.indices.filter { !hasNotch[$0] }
        return plain.min { minX[$0] < minX[$1] } ?? 0
    }

    /// 该屏菜单栏此刻是否可见。不可见时条子必须一并撤下 —— 它是 .statusBar 级窗口，
    /// 没人挡着，菜单栏一藏它就长期悬在用户内容之上。
    /// - autoHideEnabled: 系统「自动隐藏菜单栏」(NSGlobalDomain `_HIHideMenuBar`)。开着时
    ///   菜单栏平时是藏的、只在鼠标顶边时滑出，我们这种独立窗口跟不了滑出动作，一律不显示。
    /// - hasStatusItems: 该屏此刻枚举得到状态项（排除自身 PID 后）。**全屏 App 占据某块屏时，
    ///   该屏的状态项窗口会整体离屏**，这是目前唯一稳定且按屏精确的判据。
    ///
    /// 2026-09-02 实测（自建窗口 toggleFullScreen 落到指定屏，每次用 AX 的 AXFullScreen 确认落点）：
    ///
    ///   被占的屏     topInset    layer24   状态项(排自己)
    ///   左外接        30 不变       0           0
    ///   内置          29 不变       1           0
    ///   未被占的屏    不变          1          13
    ///
    /// 试过并证伪、别再重走的判据：
    ///   1. `frame.maxY - visibleFrame.maxY` —— 全屏时纹丝不动。（另注：非主屏的 visibleFrame
    ///      只有在进程初始化过 NSApplication 之后才返回真值，用裸脚本量会得到 0 的假象。）
    ///   2. layer-24 的 Window Server「Menubar」窗口 —— 跨屏不一致：内置屏上全屏期间照旧在场。
    ///   3. 枚举 layer-0 中与屏等大的窗口 —— 跨进程枚举里看不到全屏窗口。
    ///   4. 去掉 `.fullScreenAuxiliary` —— 无效，是 `.canJoinAllSpaces` 把窗口带进全屏空间的，
    ///      而去掉它条子就不跟随 Space 切换了，代价更大。
    ///   5. `NSApp.currentSystemPresentationOptions` 含 `.fullScreen` —— 可靠但**系统级不分屏**，
    ///      别的屏全屏也会把本屏的条子误撤。
    ///   6. AX 的 `AXFullScreen` —— 按屏精确、语义最准，但要遍历所有 app 做 IPC，5s 一次太贵。
    ///
    /// 枚举不到状态项也可能是探测失败或该屏真没有菜单栏（「显示器各自拥有独立空间」关闭时的副屏），
    /// 两种情形撤下条子都是正确行为；真是瞬时抖动，下一次轮询（5s）就会自己回来。
    public static func menuBarVisible(autoHideEnabled: Bool, hasStatusItems: Bool) -> Bool {
        if autoHideEnabled { return false }
        return hasStatusItems
    }

    /// 枚举不到 layer-24 菜单栏窗口时的兜底矩形：顶部内缩量推得出就用它，推不出（该屏根本
    /// 没给菜单栏留位置）才退回系统菜单栏厚度。宁可条子落在一个估出来的位置，也不能整条消失。
    /// 注意：**非主屏的 visibleFrame 只有在进程初始化过 NSApplication 之后才返回真值**，
    /// 裸脚本量出来的"外接屏内缩恒为 0"是假象；真 app 里每块屏都会扣掉自己的菜单栏高度。
    public static func fallbackBar(screenFrame: CGRect, visibleFrame: CGRect,
                                   defaultHeight: CGFloat) -> CGRect {
        let inset = screenFrame.maxY - visibleFrame.maxY
        let h = inset > 1 ? inset : defaultHeight
        return CGRect(x: screenFrame.minX, y: screenFrame.maxY - h,
                      width: screenFrame.width, height: h)
    }

    /// 7D 重置时刻是否值得占这点宽度：剩余低于 20%，或距重置不足 24h。
    /// 没有重置时刻就没东西可展示，直接不展示。
    public static func showsSevenDayReset(remainPct: Double, resetsAt: Date?, now: Date) -> Bool {
        guard let resetsAt else { return false }
        return remainPct < AccountUsage.lowQuotaRemainPct
            || resetsAt.timeIntervalSince(now) < 24 * 3600
    }

    /// 显示器菜单项文案：同型号的按 x 从左到右加方位后缀，唯一的保持原样。返回顺序与入参一致。
    /// 分组前先剥掉 macOS 自己加的 " (n)" 编号 —— 实测两块同型号屏的 localizedName 是
    /// "T2752U (1)" / "T2752U (2)"，字符串不同所以躲过朴素的同名判定，而那个编号与左右位置无关，
    /// 用户照着它选屏只能靠试。
    public static func displayLabels(_ screens: [(name: String, minX: CGFloat)]) -> [String] {
        let bases = screens.map { stripSystemNumbering($0.name) }
        var counts: [String: Int] = [:]
        for b in bases { counts[b, default: 0] += 1 }
        // 同名组内按 x 升序 → 该屏在组里的序号
        var ranks: [String: [Int]] = [:]   // 型号名 → 按 x 排序后的原始下标
        for base in counts.keys where counts[base]! > 1 {
            ranks[base] = screens.indices
                .filter { bases[$0] == base }
                .sorted { screens[$0].minX < screens[$1].minX }
        }
        return screens.indices.map { i in
            guard let order = ranks[bases[i]], let rank = order.firstIndex(of: i) else {
                return screens[i].name        // 不重名：连系统编号一起原样保留
            }
            return bases[i] + "（" + suffix(rank: rank, of: order.count) + "）"
        }
    }

    /// 去掉结尾的 " (n)"（macOS 给同型号显示器加的编号）
    private static func stripSystemNumbering(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let inside = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard !inside.isEmpty, inside.allSatisfy(\.isNumber),
              open > name.startIndex, name[name.index(before: open)] == " " else { return name }
        return String(name[name.startIndex..<name.index(before: open)])
    }

    private static func suffix(rank: Int, of total: Int) -> String {
        switch (total, rank) {
        case (2, 0), (3, 0): return "左"
        case (2, 1), (3, 2): return "右"
        case (3, 1): return "中"
        default: return "\(rank + 1)"    // 4 块以上同名：方位说不清了，退回序号
        }
    }
}

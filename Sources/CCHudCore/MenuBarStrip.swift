import CoreGraphics
import Foundation

/// 菜单栏额度条的几何与展示判据。
/// 纯函数、不碰 AppKit（选屏与窗口枚举留给 app 层）——多屏 / 负坐标 / 刘海避让 / 边界夹取
/// 这些分支不单测必出事，与 NotchGeometry 同样的可测性考量。
public enum MenuBarStrip {
    /// CGWindowList 坐标（左上原点、y 向下、原点在主屏左上）→ NSScreen 坐标（左下原点、y 向上）。
    /// 主屏之上的显示器 CG y 为负，转换后 NS y 大于主屏高；x 两系一致、不翻转。
    public static func nsRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height,
               width: r.width, height: r.height)
    }

    /// 条子 frame（NS 坐标）：整条填满菜单栏高度，右缘贴状态项左缘 - gap，内容变宽向左生长。
    /// - 拿不到状态项左缘（枚举失败 / 该屏无状态项）→ 居中于菜单栏，不硬贴屏右缘压住时钟。
    /// - 与刘海相交 → 整条推到刘海左侧（选到内置屏时才可能发生）。
    /// - 无论如何都夹在菜单栏矩形内，绝不越出屏外。
    public static func frame(bar: CGRect, statusItemsMinX: CGFloat?, notch: CGRect?,
                             contentWidth: CGFloat, gap: CGFloat = 12) -> CGRect {
        let w = min(contentWidth, bar.width)
        var x = statusItemsMinX.map { $0 - gap - w } ?? (bar.midX - w / 2)
        // 刘海避让：只在真相交时才推，够窄能落在刘海右侧就不动
        if let notch, x < notch.maxX, x + w > notch.minX {
            x = notch.minX - gap - w
        }
        x = min(max(x, bar.minX), bar.maxX - w)
        return CGRect(x: x, y: bar.minY, width: w, height: bar.height)
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

    /// 枚举不到 layer-24 菜单栏窗口时的兜底矩形：顶部内缩量推得出就用它（主屏会把菜单栏
    /// 从 visibleFrame 里扣掉），推不出就用系统菜单栏厚度（实测外接屏 visibleFrame == frame，
    /// 顶部什么都不扣）。宁可条子落在一个估出来的位置，也不能整条消失。
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

import SwiftUI
import AppKit
import CCHudCore

/// 条子的可用横向预算（由面板按实测菜单栏几何算出，见 MenuBarStrip.budget）。
/// 不能做成构造期常量：换屏 / 状态项增减都会改变它。
@MainActor
final class StripMetrics: ObservableObject {
    /// 初值给足，首帧按"全档"渲染；面板拿到探测结果后立刻回灌真值
    @Published var budget: CGFloat = .greatestFiniteMagnitude
}

/// 菜单栏额度条 —— 完全照《菜单栏额度条 · 齐平》设计稿实现，数值不要自行发挥。
///
/// 设计要点：**全行只有一个字号 12pt**（SF Pro · 等宽数字），百分比、百分号、标签、时刻、
/// token 一律等高；层级只交给字重（600/500/400，告警 700）与明度（L1/L2/L3）；
/// 分组只用空间（组内 4/1.5/5pt、组间 13pt），一个分隔符都不用；>50% 全线无彩色，
/// 色彩是留给紧张态的预算。光晕只挂在 5H 数值上，其余不加，避免整行发糊。
struct MenuBarStripView: View {
    let store: StateStore
    @ObservedObject var metrics: StripMetrics
    /// 内容自然宽度回灌（右缘固定、向左生长）；一段都放不下时上报 0，面板据此整体撤下
    var onWidthChange: (CGFloat) -> Void = { _ in }

    @State private var wakeTick = 0
    @Environment(\.colorScheme) private var scheme

    private var account: AccountUsage { store.account }
    /// 扫描失败 / 未启动时 DailyTokenScanner 恒返回 0（不是 nil），所以判 >0 才算"有数据"
    private var todayTokens: Int { store.todayTokens ?? 0 }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            let els = chosen(now: ctx.date)
            ZStack(alignment: .trailing) {
                Color.clear
                if !els.isEmpty {
                    row(els)
                        .fixedSize()
                        // 整行按数值的 cap-height 中心对齐条高中心（不是行盒中心），
                        // 条高在 29–33pt 之间变化时视觉位置不跳
                        .offset(y: Spec.capCenterOffset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { onWidthChange(reported(els)) }
            .onChange(of: reported(els)) { _, w in onWidthChange(w) }
        }
        .id(wakeTick)
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)) { _ in wakeTick &+= 1 }
    }

    private func reported(_ els: [Element]) -> CGFloat { els.isEmpty ? 0 : Spec.width(els) }

    // MARK: 降级阶梯（设计稿 03）

    /// 由富到简选第一个塞得下的。三源全无 / 连最简都放不下 → 空（整条不上屏）。
    private func chosen(now: Date) -> [Element] {
        let ladder = ladder(now: now)
        guard !ladder.isEmpty,
              let i = MenuBarStrip.fittingVariant(widths: ladder.map(Spec.width),
                                                  budget: metrics.budget)
        else { return [] }
        return ladder[i]
    }

    /// 1 全档 → 2 去 token → 3 去 5H 时刻 → 4 只留最紧的一段（带时间）→ 5 最简（该段去时间）
    private func ladder(now: Date) -> [[Element]] {
        let five = project(account.fiveHourUsedPct, account.fiveHourResetsAt,
                           AccountUsage.fiveHourPeriod, now)
        let seven = project(account.sevenDayUsedPct, account.sevenDayResetsAt,
                            AccountUsage.sevenDayPeriod, now)
        // 7D 倒计时只在剩余 <20% 或距重置 <24h 时出现
        let sevenUrgent = seven.map {
            MenuBarStrip.showsSevenDayReset(remainPct: $0.remain, resetsAt: $0.resetsAt, now: now)
        } ?? false

        func fiveGroup(time: Bool) -> [Element] {
            guard let five else { return [] }
            return group(label: "5H", remain: five.remain, baseWeight: Spec.fiveValue,
                         baseColor: Spec.l1(dark), glow: true,
                         tail: time ? five.resetsAt.map { Format.resetTimeShort($0, now: now) } : nil)
        }
        func sevenGroup(time: Bool) -> [Element] {
            guard let seven else { return [] }
            let tail = (time && sevenUrgent) ? seven.resetsAt.map { Format.countdownDH(to: $0, from: now) } : nil
            return group(label: "7D", remain: seven.remain, baseWeight: Spec.sevenValue,
                         baseColor: Spec.l2(dark), glow: false, tail: tail)
        }
        let token: [Element] = todayTokens > 0
            ? [.text(Format.tokens(todayTokens), Spec.regular, Spec.tokenTracking, Spec.l3(dark), false)]
            : []
        // 第 4/5 档保留"当前最紧的那一段"：宽松时是 5H，7D 更低时换成 7D
        let sevenIsTighter = (seven?.remain ?? .infinity) < (five?.remain ?? .infinity)
        func tightest(time: Bool) -> [Element] {
            sevenIsTighter ? sevenGroup(time: time) : fiveGroup(time: time)
        }

        var seen = Set<String>()
        return [
            join([fiveGroup(time: true), sevenGroup(time: true), token]),
            join([fiveGroup(time: true), sevenGroup(time: true)]),
            join([fiveGroup(time: false), sevenGroup(time: true)]),
            tightest(time: true),
            tightest(time: false),
        ].compactMap { els in
            guard !els.isEmpty else { return nil }
            // 缺数据时相邻档会退化成同一串，去重免得白测一遍
            return seen.insert(Spec.key(els)).inserted ? els : nil
        }
    }

    /// 一组 = 标签 4pt 数值 1.5pt 百分号 [5pt 时刻]。
    /// 剩余 20–50 / <20 时该段的数值与百分号一起换成 Bold 700 + 档位色（字号不变）。
    private func group(label: String, remain: Double, baseWeight: NSFont.Weight,
                       baseColor: Color, glow: Bool, tail: String?) -> [Element] {
        let alert = Spec.alert(remain: remain, dark: dark)
        let weight = alert == nil ? baseWeight : Spec.alertValue
        var els: [Element] = [
            .text(label, Spec.labelWeight, Spec.labelTracking, Spec.l3(dark), false),
            .gap(Spec.labelToValue),
            .text("\(Int(remain))", weight, 0, alert ?? baseColor, glow),
            .gap(Spec.valueToPercent),
            .text("%", weight, 0, alert ?? Spec.l3(dark), false),
        ]
        if let tail {
            els.append(.gap(Spec.percentToTime))
            els.append(.text(tail, Spec.regular, Spec.timeTracking, Spec.l2(dark), false))
        }
        return els
    }

    private func join(_ groups: [[Element]]) -> [Element] {
        let live = groups.filter { !$0.isEmpty }
        guard let first = live.first else { return [] }
        return live.dropFirst().reduce(first) { $0 + [.gap(Spec.groupGap)] + $1 }
    }

    private func project(_ used: Double?, _ resetsAt: Date?, _ period: TimeInterval, _ now: Date)
        -> (remain: Double, resetsAt: Date?)? {
        let p = AccountUsage.project(usedPct: used, resetsAt: resetsAt, period: period, now: now)
        guard let u = p.usedPct else { return nil }
        return (max(0, min(100, 100 - u)), p.resetsAt)
    }

    // MARK: 渲染

    private func row(_ els: [Element]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(els.enumerated()), id: \.offset) { _, el in
                switch el {
                case .gap(let w):
                    Color.clear.frame(width: w, height: 1)
                case .text(let s, let weight, let kern, let color, let glow):
                    let t = Text(s)
                        .font(Font(Spec.font(weight)))
                        .tracking(kern)
                        .foregroundColor(color)
                    if glow {
                        t.shadow(color: Spec.glow(dark), radius: Spec.glowRadius, y: Spec.glowY)
                    } else {
                        t
                    }
                }
            }
        }
    }

    enum Element {
        case gap(CGFloat)
        case text(String, NSFont.Weight, CGFloat, Color, Bool)   // 文本, 字重, 字距, 色, 光晕
    }
}

/// 设计稿《菜单栏额度条 · 齐平》的全部数值。改样式只改这里。
private enum Spec {
    static let size: CGFloat = 12
    static func font(_ w: NSFont.Weight) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: w)   // SF Pro · tabular-nums
    }

    // 字重：标签 500 / 5H 数值 600 / 7D 数值 400 / 告警 700
    static let labelWeight = NSFont.Weight.medium
    static let fiveValue = NSFont.Weight.semibold
    static let sevenValue = NSFont.Weight.regular
    static let regular = NSFont.Weight.regular
    static let alertValue = NSFont.Weight.bold

    // 字距
    static let labelTracking: CGFloat = 0.4
    static let timeTracking: CGFloat = 0.1
    static let tokenTracking: CGFloat = 0.2

    // 间距
    static let labelToValue: CGFloat = 4
    static let valueToPercent: CGFloat = 1.5
    static let percentToTime: CGFloat = 5
    static let groupGap: CGFloat = 13

    // 明度三级（浅 / 深）
    static func l1(_ dark: Bool) -> Color { dark ? hex(0xFFFFFF) : hex(0x1A1A1C) }
    static func l2(_ dark: Bool) -> Color { dark ? hex(0xC0C0C8) : hex(0x4F4F57) }
    static func l3(_ dark: Bool) -> Color { dark ? hex(0x8E8E97) : hex(0x6B6B72) }
    /// 20–50 注意 / <20 告警；>50 返回 nil（全线无彩色）
    static func alert(remain: Double, dark: Bool) -> Color? {
        if remain >= AccountUsage.lowQuotaRemainPct && remain <= 50 {
            return dark ? hex(0xFFB340) : hex(0x8A5300)
        }
        if remain < AccountUsage.lowQuotaRemainPct { return dark ? hex(0xFF6257) : hex(0xC22A1F) }
        return nil
    }

    /// 光晕：CSS `0 0.5px 1.5px`（CSS 模糊半径约为 SwiftUI 的两倍）
    static func glow(_ dark: Bool) -> Color {
        dark ? Color.black.opacity(0.55) : Color.white.opacity(0.60)
    }
    static let glowRadius: CGFloat = 0.75
    static let glowY: CGFloat = 0.5

    /// 行盒居中 → cap-height 居中的修正量（负 = 上移）。由字体度量推导，不写死。
    static let capCenterOffset: CGFloat = {
        let f = font(.regular)
        return (f.capHeight - f.ascender - f.descender) / 2
    }()

    static func width(_ els: [MenuBarStripView.Element]) -> CGFloat {
        els.reduce(0) { acc, el in
            switch el {
            case .gap(let w): return acc + w
            case .text(let s, let weight, let kern, _, _):
                return acc + NSAttributedString(
                    string: s, attributes: [.font: font(weight), .kern: kern]).size().width
            }
        }
    }

    static func key(_ els: [MenuBarStripView.Element]) -> String {
        els.map { if case .text(let s, _, _, _, _) = $0 { return s } else { return "|" } }.joined()
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}

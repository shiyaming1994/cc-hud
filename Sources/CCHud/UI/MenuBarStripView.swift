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

/// 菜单栏额度条：菜单栏里的一行字 —— `5H 62% 14:30 · 7D 41% · 1.2M`。
///
/// 整行用 Text 拼接而非 HStack：8pt 小标签与 12pt 数值必须共基线才像"一行字"，
/// Text 拼接天然共基线，HStack 还得靠 alignment 去凑。
///
/// **降级阶梯**：内置刘海屏实测只有 112pt 可用（刘海右缘 828 ↔ 状态项左缘 952），
/// 整条要 192pt，放不下。所以按预算从"最全"往"最简"退，宁可少显示几段，也不越过刘海
/// 去压 App 菜单（v1.4.0 首装时就是那样撞的）。各档宽度用 NSFont 度量直接算，
/// 与渲染共用同一份 run（`Font(nsFont)`），不靠渲染反馈循环。
///
/// 配色跟随系统外观，不跟随菜单栏的"失焦变灰"——那是系统给自己的菜单项加的，
/// 我们是独立窗口，画多亮就多亮，正好要的就是这个。
struct MenuBarStripView: View {
    let store: StateStore
    @ObservedObject var metrics: StripMetrics
    /// 内容自然宽度回灌（右缘固定、向左生长）；一段都放不下时上报 0，面板据此整体撤下
    var onWidthChange: (CGFloat) -> Void = { _ in }

    @State private var wakeTick = 0
    /// 菜单栏明暗随系统外观走，档位色要跟着换深浅（见 Theme.quotaColorOnMenuBar）
    @Environment(\.colorScheme) private var scheme

    private var account: AccountUsage { store.account }
    /// 扫描失败 / 未启动时 DailyTokenScanner 恒返回 0（不是 nil），所以判 >0 才算"有数据"
    private var todayTokens: Int { store.todayTokens ?? 0 }

    var body: some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            let runs = chosenRuns(now: ctx.date)
            ZStack(alignment: .trailing) {
                Color.clear
                if !runs.isEmpty {
                    text(runs)
                        .lineLimit(1)
                        .fixedSize()
                        .shadow(color: halo, radius: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, Self.trailingInset)
            .onAppear { report(runs) }
            .onChange(of: reportedWidth(runs)) { _, w in onWidthChange(w) }
        }
        .id(wakeTick)
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)) { _ in wakeTick &+= 1 }
    }

    private func reportedWidth(_ runs: [Run]) -> CGFloat {
        runs.isEmpty ? 0 : width(runs) + Self.trailingInset
    }
    private func report(_ runs: [Run]) { onWidthChange(reportedWidth(runs)) }

    /// 文字右缘到窗口右缘的留白：窗口右缘已经贴在状态项左缘 -gap 上，这里只留一点视觉呼吸
    private static let trailingInset: CGFloat = 2

    // MARK: 降级选档

    /// 由富到简的各档里挑第一个塞得下的。三源全无 / 连最简都放不下 → 空（整条不上屏）。
    private func chosenRuns(now: Date) -> [Run] {
        let ladder = ladder(now: now)
        guard !ladder.isEmpty,
              let i = MenuBarStrip.fittingVariant(widths: ladder.map(width),
                                                  budget: metrics.budget - Self.trailingInset)
        else { return [] }
        return ladder[i]
    }

    /// 阶梯（由富到简）：全档 → 去 token → 去 5H 重置时刻 → 只留紧张的那段 → 只留 5H 剩余。
    /// "低额度窗口的重置倒计时"排在 5H 重置时刻与 token 之前 —— 紧张的时候那个数最该看见。
    private func ladder(now: Date) -> [[Run]] {
        let five = project(account.fiveHourUsedPct, account.fiveHourResetsAt,
                           AccountUsage.fiveHourPeriod, now)
        let seven = project(account.sevenDayUsedPct, account.sevenDayResetsAt,
                            AccountUsage.sevenDayPeriod, now)
        let sevenUrgent = seven.map {
            MenuBarStrip.showsSevenDayReset(remainPct: $0.remain, resetsAt: $0.resetsAt, now: now)
        } ?? false

        let variants: [(fiveReset: Bool, sevenGroup: Bool, token: Bool)] = [
            (true,  true,        true),
            (true,  true,        false),
            (false, true,        false),
            (false, sevenUrgent, false),
            (false, false,       false),
        ]
        var seen = Set<String>()
        return variants.compactMap { v -> [Run]? in
            var groups: [[Run]] = []
            if let five {
                var g = label("5H") + value("\(Int(five.remain))%", level: five.remain)
                if v.fiveReset, let r = five.resetsAt {
                    g += gap + value(Format.resetTimeShort(r, now: now), color: neutral)
                }
                groups.append(g)
            }
            if v.sevenGroup, let seven {
                var g = label("7D") + value("\(Int(seven.remain))%", level: seven.remain)
                if sevenUrgent, let r = seven.resetsAt {
                    g += gap + value(Format.countdownDH(to: r, from: now), color: neutral)
                }
                groups.append(g)
            }
            if v.token, todayTokens > 0 {
                groups.append(value(Format.tokens(todayTokens), color: neutral))
            }
            guard !groups.isEmpty else { return nil }
            let runs = groups.dropFirst().reduce(groups[0]) { $0 + separator + $1 }
            // 缺数据时相邻档会退化成同一串（如无 7D 时"去 7D"那档），去重免得白测一遍
            return seen.insert(runs.map(\.text).joined()).inserted ? runs : nil
        }
    }

    private func project(_ used: Double?, _ resetsAt: Date?, _ period: TimeInterval, _ now: Date)
        -> (remain: Double, resetsAt: Date?)? {
        let p = AccountUsage.project(usedPct: used, resetsAt: resetsAt, period: period, now: now)
        guard let u = p.usedPct else { return nil }
        return (max(0, min(100, 100 - u)), p.resetsAt)
    }

    // MARK: run 模型（度量与渲染共用同一份，保证算出来的宽度就是画出来的宽度）

    private struct Run {
        let text: String
        let font: NSFont
        let color: Color
        var kern: CGFloat = 0
    }

    private func label(_ s: String) -> [Run] {
        [Run(text: s, font: .monospacedSystemFont(ofSize: 8, weight: .bold),
             color: labelTint, kern: 0.6)] + gap
    }
    private func value(_ s: String, color: Color) -> [Run] {
        [Run(text: s, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: color)]
    }
    private func value(_ s: String, level remain: Double) -> [Run] {
        value(s, color: Theme.quotaColorOnMenuBar(remain: remain, dark: scheme == .dark))
    }
    private var gap: [Run] {
        [Run(text: " ", font: .systemFont(ofSize: 12), color: .clear)]
    }
    private var separator: [Run] {
        [Run(text: "  ·  ", font: .systemFont(ofSize: 12), color: separatorTint)]
    }

    private func width(_ runs: [Run]) -> CGFloat {
        let s = NSMutableAttributedString()
        for r in runs {
            s.append(NSAttributedString(string: r.text,
                                        attributes: [.font: r.font, .kern: r.kern]))
        }
        return ceil(s.size().width)
    }

    private func text(_ runs: [Run]) -> Text {
        runs.dropFirst().reduce(swiftUIText(runs[0])) { $0 + swiftUIText($1) }
    }
    private func swiftUIText(_ r: Run) -> Text {
        Text(r.text).font(Font(r.font)).tracking(r.kern).foregroundColor(r.color)
    }

    // MARK: 配色

    private var neutral: Color { Color(nsColor: .labelColor).opacity(0.92) }
    private var labelTint: Color { Color(nsColor: .secondaryLabelColor) }
    private var separatorTint: Color { Color(nsColor: .labelColor).opacity(0.28) }
    /// 与文字反向的光晕：系统菜单栏文字也这么压壁纸，浅色壁纸下不至于糊掉
    private var halo: Color { Color(nsColor: .textBackgroundColor).opacity(0.45) }
}

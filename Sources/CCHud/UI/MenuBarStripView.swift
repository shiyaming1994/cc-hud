import SwiftUI
import AppKit
import CCHudCore

/// 菜单栏额度条：菜单栏里的一行字 —— `5H 62% 14:30 · 7D 41% · 1.2M`。
///
/// 整行用 Text 拼接而非 HStack：8pt 小标签与 12pt 数值必须共基线才像"一行字"，
/// Text 拼接天然共基线，HStack 还得靠 alignment 去凑，且分段有无时的间距更难对齐。
///
/// 配色跟随系统外观（labelColor / secondaryLabelColor），不跟随菜单栏的"失焦变灰"——
/// 那是系统给自己的菜单项和图标加的，我们是独立窗口，画多亮就多亮，正好要的就是这个。
struct MenuBarStripView: View {
    let store: StateStore
    /// 内容自然宽度回灌（右缘固定、向左生长）；三源全无时上报 0，面板据此整体撤下
    var onWidthChange: (CGFloat) -> Void = { _ in }

    @State private var wakeTick = 0
    /// 菜单栏明暗随系统外观走，档位色要跟着换深浅（见 Theme.quotaColorOnMenuBar）
    @Environment(\.colorScheme) private var scheme

    private var account: AccountUsage { store.account }
    /// 扫描失败 / 未启动时 DailyTokenScanner 恒返回 0（不是 nil），所以判 >0 才算"有数据"
    private var todayTokens: Int { store.todayTokens ?? 0 }
    /// 三源全无 → 不上屏（未登录 Pro/Max 时不要一行空字杵在菜单栏上）
    private var hasData: Bool {
        account.fiveHourUsedPct != nil || account.sevenDayUsedPct != nil || todayTokens > 0
    }

    // 明暗两种外观下都成立的中性色；档位色（sage/amber/alarm）沿用 Theme，两种底色都可读
    private var neutral: Color { Color(nsColor: .labelColor).opacity(0.92) }
    private var labelTint: Color { Color(nsColor: .secondaryLabelColor) }
    private var separatorTint: Color { Color(nsColor: .labelColor).opacity(0.28) }
    /// 与文字反向的光晕：系统菜单栏文字也这么压壁纸，浅色壁纸下不至于糊掉
    private var halo: Color { Color(nsColor: .textBackgroundColor).opacity(0.45) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            if hasData {
                TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
                    line(now: ctx.date)
                        .lineLimit(1)
                        .fixedSize()
                        .shadow(color: halo, radius: 1)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: {
                            onWidthChange($0.width + Self.trailingInset)
                        }
                }
                .id(wakeTick)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, Self.trailingInset)
        .onChange(of: hasData) { _, has in if !has { onWidthChange(0) } }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)) { _ in wakeTick &+= 1 }
    }

    /// 文字右缘到窗口右缘的留白：窗口右缘已经贴在状态项左缘 -gap 上，这里只留一点视觉呼吸
    private static let trailingInset: CGFloat = 2

    // MARK: 行内容

    private func line(now: Date) -> Text {
        var parts: [Text] = []
        if let five = fiveHour(now: now) { parts.append(five) }
        if let seven = sevenDay(now: now) { parts.append(seven) }
        if todayTokens > 0 { parts.append(value(Format.tokens(todayTokens), neutral)) }
        return parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { $0 + separator + $1 }
    }

    /// `5H 62% 14:30` —— 剩余百分比按档位上色，重置时刻恒中性
    private func fiveHour(now: Date) -> Text? {
        let p = AccountUsage.project(usedPct: account.fiveHourUsedPct,
                                     resetsAt: account.fiveHourResetsAt,
                                     period: AccountUsage.fiveHourPeriod, now: now)
        guard let used = p.usedPct else { return nil }
        let remain = clampRemain(used)
        var t = label("5H") + gap + value("\(Int(remain))%", Theme.quotaColorOnMenuBar(remain: remain, dark: scheme == .dark))
        if let reset = p.resetsAt {
            t = t + gap + value(Format.resetTimeShort(reset, now: now), neutral)
        }
        return t
    }

    /// `7D 41%`；剩余 <20% 或距重置 <24h 时追加倒计时 `2d 3h`，其余时候不占这点宽度
    private func sevenDay(now: Date) -> Text? {
        let p = AccountUsage.project(usedPct: account.sevenDayUsedPct,
                                     resetsAt: account.sevenDayResetsAt,
                                     period: AccountUsage.sevenDayPeriod, now: now)
        guard let used = p.usedPct else { return nil }
        let remain = clampRemain(used)
        var t = label("7D") + gap + value("\(Int(remain))%", Theme.quotaColorOnMenuBar(remain: remain, dark: scheme == .dark))
        if MenuBarStrip.showsSevenDayReset(remainPct: remain, resetsAt: p.resetsAt, now: now),
           let reset = p.resetsAt {
            t = t + gap + value(Format.countdownDH(to: reset, from: now), neutral)
        }
        return t
    }

    private func clampRemain(_ used: Double) -> Double { max(0, min(100, 100 - used)) }

    // MARK: 排版基元

    private func label(_ s: String) -> Text {
        Text(s)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundColor(labelTint)
    }

    private func value(_ s: String, _ color: Color) -> Text {
        Text(s)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(color)
    }

    /// 段内间隙（标签↔数值、数值↔重置时刻）
    private var gap: Text { Text(verbatim: " ").font(.system(size: 12)) }
    /// 段间分隔：` · `
    private var separator: Text {
        Text(verbatim: "  ·  ").font(.system(size: 12)).foregroundColor(separatorTint)
    }
}

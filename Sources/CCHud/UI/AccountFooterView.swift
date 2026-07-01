import SwiftUI
import AppKit
import Combine
import CCHudCore

/// 整块面板悬停态：由 HUDRootView 注入，驱动额度页脚展开。
private struct FooterExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var footerExpanded: Bool {
        get { self[FooterExpandedKey.self] }
        set { self[FooterExpandedKey.self] = newValue }
    }
}

/// 账户级页脚（standalone 重设计，悬停展开版）：
/// - 静息态：单行紧凑条 ——「5H ⏰ 重置时刻 重置 · 剩 X% ┊进度条┊| 今日 token」。
/// - 悬停态：完整版 —— 5h hero 卡 + 第二行 7d 卡 / 今日卡。
/// 两态瞬时切换；窗口尺寸由 HUDPanel 即时调整（固定右上角、整数像素、宿主 .duringViewResize 重绘，无残影）。
/// 配色默认偏暗（sage/amber），剩余 <20% 转鲜红告警。点击页脚 = 切换形态档；按住额度区 = 移动面板。
struct AccountFooterView: View {
    let account: AccountUsage
    let todayTokens: Int?
    var compact = false
    var showTopRule = true
    var onTap: (() -> Void)? = nil

    @Environment(\.footerExpanded) private var footerExpanded
    @State private var wakeTick = 0

    /// 60s 心跳锚点，对齐到整分钟 :00（referenceDate 2001-01-01 00:00:00 正好落在 :00）：
    /// 让倒计时/重置在每分钟 :00（含重置那一刻，如 15:10:00）准点刷新，而非从视图出现起偏移一个随机秒数、慢最多一分钟。
    private static let minuteAnchor = Date(timeIntervalSinceReferenceDate: 0)

    private var showSecond: Bool { footerExpanded }

    /// 非紧凑档（展开档 300pt = 原型 standalone(1).html 600pt 的 0.5×）：以下数值严格 = 原型各元素 ×0.5。
    private struct Metrics {
        // outerTop 与 outerBottom 不等是有意的：页脚下方还叠着档容器的 6pt 内边距（PillList/Expanded 的 .padding），
        // 故 顶隙=outerTop、底隙=outerBottom+6；取 7 / 1 → 两侧实际留白都是 7pt，静息条上下等距（对齐原型）。
        var outerTop: CGFloat = 7, outerBottom: CGFloat = 1, outerH: CGFloat = 8
        var sectionGap: CGFloat = 5      // 原型 hero→卡 margin-top 10
        var cardGap: CGFloat = 5         // 原型 7d↔今日 gap 10
        // 单行（原型静息条，元素 ×0.5）
        var restGap: CGFloat = 5         // 原型 flex gap 10
        var restLabel: CGFloat = 7.5     // 原型 5H/重置/今日 15
        var restIcon: CGFloat = 8.5      // 原型 clock 17
        var restValue: CGFloat = 10.5    // 原型 时刻/剩%/今日数 21
        var restBarW: CGFloat = 42       // 原型 84
        var restBarH: CGFloat = 4        // 原型 8
        var restDivH: CGFloat = 10       // 原型 20
        // hero（原型 5h 主卡）
        var heroPadTop: CGFloat = 6, heroPadBottom: CGFloat = 6.5, heroPadH: CGFloat = 7.5  // 原型 12/13/15
        var heroRowBarGap: CGFloat = 5   // 原型 bar margin-top 10
        var heroRadius: CGFloat = 6.5    // 原型 13
        var heroLeadGap: CGFloat = 4.5   // 原型 9
        var heroIcon: CGFloat = 9.5      // 原型 clock 19
        var heroTime: CGFloat = 16.5     // 原型 时刻 33
        var heroUnit: CGFloat = 9        // 原型 重置 18
        var heroPct: CGFloat = 11        // 原型 剩% 22
        var heroCd: CGFloat = 8.5        // 原型 倒计时 17
        var heroBar: CGFloat = 4         // 原型 8
        // 第二行卡（7d / 今日）
        var cardPadTop: CGFloat = 5, cardPadBottom: CGFloat = 5, cardPadH: CGFloat = 6.5  // 原型 10/10/13
        var cardGapV: CGFloat = 4        // 原型 7d 内 margin-top 8
        var cardRadius: CGFloat = 5.5    // 原型 11
        var sevenPct: CGFloat = 10.5     // 原型 21
        var smallBar: CGFloat = 3.5      // 原型 7
        var cdText: CGFloat = 8          // 原型 16
        var todayNum: CGFloat = 15.5     // 原型 31
        var todayUnit: CGFloat = 8       // 原型 16
        var todaySpacerMin: CGFloat = 5
        var label: CGFloat = 8           // 原型 hero/卡 标签 16
    }

    private var m: Metrics {
        guard compact else { return Metrics() }
        var c = Metrics()
        c.outerTop = 7; c.outerBottom = 1; c.outerH = 4
        c.sectionGap = 5; c.cardGap = 5
        c.restGap = 5; c.restLabel = 8; c.restIcon = 8; c.restValue = 10
        c.restBarW = 32; c.restBarH = 3.5; c.restDivH = 10
        c.heroPadTop = 5; c.heroPadBottom = 6; c.heroPadH = 9
        c.heroRowBarGap = 5; c.heroRadius = 8; c.heroLeadGap = 5
        c.heroIcon = 9; c.heroTime = 13; c.heroUnit = 8.5; c.heroPct = 10.5; c.heroCd = 8
        c.heroBar = 3.5
        c.cardPadTop = 5; c.cardPadBottom = 5; c.cardPadH = 7
        c.cardGapV = 4; c.cardRadius = 7
        c.sevenPct = 10; c.smallBar = 3; c.cdText = 8
        c.todayNum = 13; c.todayUnit = 8; c.todaySpacerMin = 5
        c.label = 8
        return c
    }

    var body: some View {
        if account.fiveHourUsedPct != nil || account.sevenDayUsedPct != nil || todayTokens != nil {
            VStack(spacing: 0) {
                if showSecond { expandedContent } else { restingContent }
            }
            .padding(EdgeInsets(top: m.outerTop, leading: m.outerH,
                                bottom: m.outerBottom, trailing: m.outerH))
            .overlay(alignment: .top) {
                if showTopRule {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .gesture(WindowDragGesture())
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification)) { _ in wakeTick &+= 1 }
        }
    }

    @ViewBuilder private var restingContent: some View {
        if let used = account.fiveHourUsedPct {
            restingRow(label: "5H", weekly: false, usedPct: used,
                       resetAt: account.fiveHourResetsAt, period: AccountUsage.fiveHourPeriod,
                       token: todayTokens)
        } else if let used = account.sevenDayUsedPct {
            restingRow(label: "7D", weekly: true, usedPct: used,
                       resetAt: account.sevenDayResetsAt, period: AccountUsage.sevenDayPeriod,
                       token: todayTokens)
        } else if let t = todayTokens {
            tokenCard(t)
        }
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(spacing: m.sectionGap) {
            if let used = account.fiveHourUsedPct {
                heroCard(label: "5H", weekly: false, usedPct: used,
                         resetAt: account.fiveHourResetsAt, period: AccountUsage.fiveHourPeriod)
                secondRow
            } else if let used = account.sevenDayUsedPct {
                heroCard(label: "7D", weekly: true, usedPct: used,
                         resetAt: account.sevenDayResetsAt, period: AccountUsage.sevenDayPeriod)
                if let t = todayTokens { todayCard(t) }
            } else if let t = todayTokens {
                tokenCard(t)
            }
        }
    }

    @ViewBuilder private var secondRow: some View {
        if account.sevenDayUsedPct != nil || todayTokens != nil {
            HStack(spacing: m.cardGap) {
                if let used = account.sevenDayUsedPct {
                    sevenCard(usedPct: used, resetAt: account.sevenDayResetsAt,
                              period: AccountUsage.sevenDayPeriod)
                }
                if let t = todayTokens { todayCard(t) }
            }
        }
    }

    // MARK: 静息单行
    private func restingRow(label: String, weekly: Bool, usedPct rawUsed: Double,
                            resetAt rawReset: Date?, period: TimeInterval, token: Int?) -> some View {
        TimelineView(.periodic(from: Self.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: rawUsed, resetsAt: rawReset, period: period, now: ctx.date)
            let used = p.usedPct ?? rawUsed
            let remain = max(0, min(100, 100 - used))
            let color = Theme.quotaColor(remain: remain)
            let alarm = remain < AccountUsage.lowQuotaRemainPct
            let resetText = p.resetsAt.map {
                weekly ? Format.resetDateTime($0) : Format.resetTimeShort($0, now: ctx.date)
            } ?? "—"
            HStack(alignment: .center, spacing: m.restGap) {
                Text(label).font(.system(size: m.restLabel, weight: .bold, design: .monospaced))
                    .tracking(0.6).foregroundStyle(Theme.quotaLabel).fixedSize()
                Image(systemName: "clock").font(.system(size: m.restIcon, weight: .semibold))
                    .foregroundStyle(Theme.quotaMuted)
                Text(resetText).font(.system(size: m.restValue, weight: .heavy))
                    .monospacedDigit().foregroundStyle(Theme.quotaHero).fixedSize()
                // 重置·剩% 收成一组、组内间距收紧且"·"两侧等距 → 既是原型"重置·剩"的紧凑观感，又左右对称
                HStack(spacing: 3) {
                    if !compact {
                        Text("重置").font(.system(size: m.restLabel, weight: .semibold))
                            .foregroundStyle(Theme.quotaMuted)
                    }
                    Text("·").font(.system(size: m.restValue, weight: .heavy)).foregroundStyle(color)
                    Text("剩 \(Int(remain))%").font(.system(size: m.restValue, weight: .heavy))
                        .monospacedDigit().foregroundStyle(color)
                }
                .fixedSize()
                Spacer(minLength: 8)
                if !compact {
                    fixedBar(remain: remain, color: color, glow: alarm)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: m.restDivH)
                }
                Text("今日").font(.system(size: m.restLabel, weight: .bold, design: .monospaced))
                    .tracking(0.6).foregroundStyle(Theme.quotaLabel).fixedSize()
                if let t = token {
                    Text(Format.tokens(t)).font(.system(size: m.restValue, weight: .heavy))
                        .monospacedDigit().foregroundStyle(Theme.quotaToday).fixedSize()
                }
            }
            .lineLimit(1).padding(.vertical, 4.5).padding(.horizontal, 2)   // 行高 = 文本 +9pt（收起态略高些，仍对称）
        }
        .id(wakeTick)
    }

    // MARK: 展开主卡（hero）
    private func heroCard(label: String, weekly: Bool, usedPct rawUsed: Double,
                          resetAt rawReset: Date?, period: TimeInterval) -> some View {
        TimelineView(.periodic(from: Self.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: rawUsed, resetsAt: rawReset, period: period, now: ctx.date)
            let used = p.usedPct ?? rawUsed
            let remain = max(0, min(100, 100 - used))
            let color = Theme.quotaColor(remain: remain)
            let alarm = remain < AccountUsage.lowQuotaRemainPct
            let resetText = p.resetsAt.map {
                weekly ? Format.resetDateTime($0) : Format.resetTimeShort($0, now: ctx.date)
            } ?? "—"
            VStack(spacing: m.heroRowBarGap) {
                HStack(alignment: .center, spacing: 6) {
                    HStack(alignment: .center, spacing: m.heroLeadGap) {
                        Text(label).font(.system(size: m.label, weight: .bold, design: .monospaced))
                            .tracking(0.6).foregroundStyle(Theme.quotaLabel)
                        Image(systemName: "clock").font(.system(size: m.heroIcon, weight: .semibold))
                            .foregroundStyle(Theme.quotaMuted)
                        Text(resetText).font(.system(size: m.heroTime, weight: .heavy))
                            .monospacedDigit().foregroundStyle(Theme.quotaHero)
                        Text("重置").font(.system(size: m.heroUnit, weight: .semibold))
                            .foregroundStyle(Theme.quotaMuted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        if let reset = p.resetsAt {           // 倒计时在上：heavy + quotaHero，粗细与颜色都对齐左侧重置时刻（仅尺寸小些）；语义变色仍归百分比
                            Text("\(Format.countdownHM(to: reset, from: ctx.date)) 后")
                                .font(.system(size: m.heroPct, weight: .heavy))
                                .monospacedDigit().foregroundStyle(Theme.quotaHero)
                        }
                        Text("剩 \(Int(remain))%")            // 剩% 在下：保留变色告警（小号 heavy + 额度色）
                            .font(.system(size: m.heroCd, weight: .heavy))
                            .monospacedDigit().foregroundStyle(color)
                    }
                    .fixedSize()
                }
                bar(remain: remain, color: color, height: m.heroBar, glow: alarm)
            }
            .padding(EdgeInsets(top: m.heroPadTop, leading: m.heroPadH,
                                bottom: m.heroPadBottom, trailing: m.heroPadH))
            .background(RoundedRectangle(cornerRadius: m.heroRadius).fill(Theme.quotaCardHi))
            .overlay(RoundedRectangle(cornerRadius: m.heroRadius)
                .stroke(alarm ? Theme.quotaAlarm.opacity(0.6) : Theme.quotaHairline, lineWidth: 1))
            .shadow(color: alarm ? Theme.quotaAlarm.opacity(0.3) : .clear, radius: alarm ? 11 : 0)
        }
        .id(wakeTick)
    }

    private func sevenCard(usedPct rawUsed: Double, resetAt rawReset: Date?,
                           period: TimeInterval) -> some View {
        TimelineView(.periodic(from: Self.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: rawUsed, resetsAt: rawReset, period: period, now: ctx.date)
            let used = p.usedPct ?? rawUsed
            let remain = max(0, min(100, 100 - used))
            let color = Theme.quotaColor(remain: remain)
            let alarm = remain < AccountUsage.lowQuotaRemainPct
            VStack(alignment: .leading, spacing: m.cardGapV) {
                HStack(alignment: .firstTextBaseline) {
                    Text("7D").font(.system(size: m.label, weight: .bold, design: .monospaced))
                        .tracking(0.6).foregroundStyle(Theme.quotaLabel)
                    Spacer()
                    Text("剩 \(Int(remain))%").font(.system(size: m.sevenPct, weight: .heavy))
                        .monospacedDigit().foregroundStyle(color)
                }
                bar(remain: remain, color: color, height: m.smallBar, glow: alarm)
                if let reset = p.resetsAt {
                    let cd = Format.countdownDH(to: reset, from: ctx.date)
                    let txt = compact ? cd : "\(cd) · \(Format.resetDateTime(reset))"
                    Text("\(Image(systemName: "clock")) \(txt)")
                        .font(.system(size: m.cdText, weight: .semibold))
                        .monospacedDigit().foregroundStyle(Theme.quotaSubtle)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(EdgeInsets(top: m.cardPadTop, leading: m.cardPadH,
                                bottom: m.cardPadBottom, trailing: m.cardPadH))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: m.cardRadius).fill(Theme.quotaCardLo))
        }
        .id(wakeTick)
    }

    private func todayCard(_ t: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("今日").font(.system(size: m.label, weight: .bold, design: .monospaced))
                .tracking(0.6).foregroundStyle(Theme.quotaLabel)
            Spacer(minLength: m.todaySpacerMin)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.tokens(t)).font(.system(size: m.todayNum, weight: .heavy))
                    .monospacedDigit().foregroundStyle(Theme.quotaToday)
                Text(compact ? "已用" : "tokens 已用").font(.system(size: m.todayUnit, weight: .semibold))
                    .foregroundStyle(Theme.quotaSubtle).lineLimit(1)
            }
        }
        .padding(EdgeInsets(top: m.cardPadTop, leading: m.cardPadH,
                            bottom: m.cardPadBottom, trailing: m.cardPadH))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius).fill(Theme.quotaCardLo))
    }

    private func tokenCard(_ t: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今日").font(.system(size: m.label, weight: .bold, design: .monospaced))
                .tracking(0.6).foregroundStyle(Theme.quotaLabel)
            Spacer()
            Text(Format.tokens(t)).font(.system(size: m.todayNum, weight: .heavy))
                .monospacedDigit().foregroundStyle(Theme.quotaToday)
            Text("tokens 已用").font(.system(size: m.todayUnit, weight: .semibold))
                .foregroundStyle(Theme.quotaSubtle)
        }
        .padding(EdgeInsets(top: m.cardPadTop, leading: m.cardPadH,
                            bottom: m.cardPadBottom, trailing: m.cardPadH))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius).fill(Theme.quotaCardLo))
    }

    private func bar(remain: Double, color: Color, height: CGFloat, glow: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.quotaTrack)
                Capsule().fill(color)
                    .frame(width: max(0, geo.size.width * remain / 100))
                    .shadow(color: glow ? color : .clear, radius: glow ? 6 : 0)
            }
        }
        .frame(height: height)
    }

    private func fixedBar(remain: Double, color: Color, glow: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.quotaTrack)
            Capsule().fill(color)
                .frame(width: max(0, m.restBarW * remain / 100))
                .shadow(color: glow ? color : .clear, radius: glow ? 6 : 0)
        }
        .frame(width: m.restBarW, height: m.restBarH)
    }
}

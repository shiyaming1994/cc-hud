import SwiftUI
import CCHudCore

/// 额度卡片的尺寸表。非紧凑档 = 设计稿 standalone(1).html 600pt 的 0.5×。
/// 原属 AccountFooterView 私有 Metrics，抽出后由最小胶囊（PillListView 传 compact: true）
/// 与页脚共用；数值一字未改。
struct QuotaMetrics {
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

    static let standard = QuotaMetrics()

    static let compact: QuotaMetrics = {
        var c = QuotaMetrics()
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
    }()
}

/// 60s 心跳锚点，对齐整分钟 :00（referenceDate 2001-01-01 00:00:00 正好落在 :00）：
/// 让倒计时/重置在每分钟 :00（含重置那一刻）准点刷新，而非从视图出现起偏移随机秒数。
enum QuotaClock {
    static let minuteAnchor = Date(timeIntervalSinceReferenceDate: 0)
}

struct QuotaBar: View {
    let remain: Double
    let color: Color
    let height: CGFloat
    let glow: Bool

    var body: some View {
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
}

struct QuotaFixedBar: View {
    let remain: Double
    let color: Color
    let glow: Bool
    let m: QuotaMetrics

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.quotaTrack)
            Capsule().fill(color)
                .frame(width: max(0, m.restBarW * remain / 100))
                .shadow(color: glow ? color : .clear, radius: glow ? 6 : 0)
        }
        .frame(width: m.restBarW, height: m.restBarH)
    }
}

/// 5h 主卡：重置时刻 + 倒计时 + 剩余% + 进度条
struct QuotaHeroCard: View {
    let label: String
    let weekly: Bool
    let usedPct: Double
    let resetAt: Date?
    let period: TimeInterval
    let m: QuotaMetrics
    let wakeTick: Int

    var body: some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: usedPct, resetsAt: resetAt,
                                         period: period, now: ctx.date)
            let used = p.usedPct ?? usedPct
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
                        if let reset = p.resetsAt {
                            // 倒计时在上：heavy + quotaHero，粗细与颜色对齐左侧重置时刻；语义变色仍归百分比
                            Text("\(Format.countdownHM(to: reset, from: ctx.date)) 后")
                                .font(.system(size: m.heroPct, weight: .heavy))
                                .monospacedDigit().foregroundStyle(Theme.quotaHero)
                        }
                        Text("剩 \(Int(remain))%")
                            .font(.system(size: m.heroCd, weight: .heavy))
                            .monospacedDigit().foregroundStyle(color)
                    }
                    .fixedSize()
                }
                QuotaBar(remain: remain, color: color, height: m.heroBar, glow: alarm)
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
}

/// 7d 卡：剩余% + 进度条 + 倒计时/重置时刻
struct QuotaSevenCard: View {
    let usedPct: Double
    let resetAt: Date?
    let period: TimeInterval
    let compact: Bool
    let m: QuotaMetrics
    let wakeTick: Int

    var body: some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: usedPct, resetsAt: resetAt,
                                         period: period, now: ctx.date)
            let used = p.usedPct ?? usedPct
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
                QuotaBar(remain: remain, color: color, height: m.smallBar, glow: alarm)
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
}

/// 今日 token 卡（竖排，与 7d 卡并列）
struct QuotaTodayCard: View {
    let tokens: Int
    let compact: Bool
    let m: QuotaMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("今日").font(.system(size: m.label, weight: .bold, design: .monospaced))
                .tracking(0.6).foregroundStyle(Theme.quotaLabel)
            Spacer(minLength: m.todaySpacerMin)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.tokens(tokens)).font(.system(size: m.todayNum, weight: .heavy))
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
}

/// 今日 token 卡（横排，无额度数据时独占一行）
struct QuotaTokenCard: View {
    let tokens: Int
    let m: QuotaMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今日").font(.system(size: m.label, weight: .bold, design: .monospaced))
                .tracking(0.6).foregroundStyle(Theme.quotaLabel)
            Spacer()
            Text(Format.tokens(tokens)).font(.system(size: m.todayNum, weight: .heavy))
                .monospacedDigit().foregroundStyle(Theme.quotaToday)
            Text("tokens 已用").font(.system(size: m.todayUnit, weight: .semibold))
                .foregroundStyle(Theme.quotaSubtle)
        }
        .padding(EdgeInsets(top: m.cardPadTop, leading: m.cardPadH,
                            bottom: m.cardPadBottom, trailing: m.cardPadH))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: m.cardRadius).fill(Theme.quotaCardLo))
    }
}

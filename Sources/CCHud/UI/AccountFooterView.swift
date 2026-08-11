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

    private var showSecond: Bool { footerExpanded }

    private var m: QuotaMetrics { compact ? .compact : .standard }

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
            QuotaTokenCard(tokens: t, m: m)
        }
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(spacing: m.sectionGap) {
            if let used = account.fiveHourUsedPct {
                QuotaHeroCard(label: "5H", weekly: false, usedPct: used,
                              resetAt: account.fiveHourResetsAt,
                              period: AccountUsage.fiveHourPeriod, m: m, wakeTick: wakeTick)
                secondRow
            } else if let used = account.sevenDayUsedPct {
                QuotaHeroCard(label: "7D", weekly: true, usedPct: used,
                              resetAt: account.sevenDayResetsAt,
                              period: AccountUsage.sevenDayPeriod, m: m, wakeTick: wakeTick)
                if let t = todayTokens { QuotaTodayCard(tokens: t, compact: compact, m: m) }
            } else if let t = todayTokens {
                QuotaTokenCard(tokens: t, m: m)
            }
        }
    }

    @ViewBuilder private var secondRow: some View {
        if account.sevenDayUsedPct != nil || todayTokens != nil {
            HStack(spacing: m.cardGap) {
                if let used = account.sevenDayUsedPct {
                    QuotaSevenCard(usedPct: used, resetAt: account.sevenDayResetsAt,
                                   period: AccountUsage.sevenDayPeriod,
                                   compact: compact, m: m, wakeTick: wakeTick)
                }
                if let t = todayTokens { QuotaTodayCard(tokens: t, compact: compact, m: m) }
            }
        }
    }

    // MARK: 静息单行
    private func restingRow(label: String, weekly: Bool, usedPct rawUsed: Double,
                            resetAt rawReset: Date?, period: TimeInterval, token: Int?) -> some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
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
                    QuotaFixedBar(remain: remain, color: color, glow: alarm, m: m)
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
}

import SwiftUI
import AppKit
import CCHudCore

/// 刘海岛：静息双翼（左 5H 剩余+重置时刻 / 右 7D 剩余+今日 token），悬停展开三卡。
/// 背景纯黑不透明 —— 要和刘海的物理黑块拼成一体，毛玻璃会透出桌面、一眼假。
struct NotchIslandView: View {
    let store: StateStore
    /// 刘海宽度；无刘海屏为 0，此时中间不留占位、渲染成一条完整胶囊。
    let notchWidth: CGFloat
    /// 静息态高度 = 刘海高。
    let notchHeight: CGFloat
    @ObservedObject var hover: HoverState
    var onSizeChange: (CGSize) -> Void = { _ in }
    var onVisibleRectChange: (CGRect) -> Void = { _ in }
    var onTap: () -> Void = {}

    @State private var wakeTick = 0

    private var account: AccountUsage { store.account }
    private var todayTokens: Int? { store.todayTokens }
    /// 四项全无 → 岛不上屏（未登录 Pro/Max 时不要一条空黑块杵在刘海上）
    private var hasData: Bool {
        account.fiveHourUsedPct != nil || account.sevenDayUsedPct != nil || todayTokens != nil
    }

    var body: some View {
        if hasData {
            ZStack(alignment: .top) {
                // 尺寸探针：恒展开、隐藏、不参与命中 → 窗口恒为展开尺寸，静息时只画中间一块
                expandedIsland
                    .hidden()
                    .allowsHitTesting(false)
                // 可见岛体（.global 在 NSHostingView 下即窗口内容坐标，左上原点——同 HoverState.rowRects 的上报口径）
                Group {
                    if hover.footerExpanded { expandedIsland } else { restingIsland }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    onVisibleRectChange($0)
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                .animation(.easeOut(duration: 0.2), value: hover.footerExpanded)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification)) { _ in wakeTick &+= 1 }
        }
    }

    // MARK: 静息态：左翼 | 刘海占位 | 右翼

    private var restingIsland: some View {
        HStack(spacing: 0) {
            leftWing
            Color.clear.frame(width: notchWidth)   // 刘海占位：一个像素都不画
            rightWing
        }
        .frame(height: notchHeight)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                                          bottomTrailingRadius: 10, topTrailingRadius: 0))
    }

    /// 左翼：5H 剩余% + 重置时刻（贴刘海左缘，内容右对齐）
    private var leftWing: some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: account.fiveHourUsedPct,
                                         resetsAt: account.fiveHourResetsAt,
                                         period: AccountUsage.fiveHourPeriod, now: ctx.date)
            HStack(spacing: 5) {
                Text("5H").font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.6).foregroundStyle(Theme.quotaLabel)
                if let used = p.usedPct {
                    let remain = max(0, min(100, 100 - used))
                    Text("\(Int(remain))%").font(.system(size: 11, weight: .heavy))
                        .monospacedDigit().foregroundStyle(Theme.quotaColor(remain: remain))
                }
                if let reset = p.resetsAt {
                    Text(Format.resetTimeShort(reset, now: ctx.date))
                        .font(.system(size: 11, weight: .heavy))
                        .monospacedDigit().foregroundStyle(Theme.quotaHero)
                }
            }
            .lineLimit(1).fixedSize()
            .padding(.leading, 12).padding(.trailing, 8)
        }
        .id(wakeTick)
    }

    /// 右翼：7D 剩余% + 今日 token（贴刘海右缘，内容左对齐）
    private var rightWing: some View {
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: account.sevenDayUsedPct,
                                         resetsAt: account.sevenDayResetsAt,
                                         period: AccountUsage.sevenDayPeriod, now: ctx.date)
            HStack(spacing: 5) {
                if let used = p.usedPct {
                    let remain = max(0, min(100, 100 - used))
                    Text("7D").font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6).foregroundStyle(Theme.quotaLabel)
                    Text("\(Int(remain))%").font(.system(size: 11, weight: .heavy))
                        .monospacedDigit().foregroundStyle(Theme.quotaColor(remain: remain))
                }
                if let t = todayTokens {
                    Text(Format.tokens(t)).font(.system(size: 11, weight: .heavy))
                        .monospacedDigit().foregroundStyle(Theme.quotaToday)
                }
            }
            .lineLimit(1).fixedSize()
            .padding(.leading, 8).padding(.trailing, 12)
        }
        .id(wakeTick)
    }

    // MARK: 展开态：复用 QuotaCards 三卡

    private var expandedIsland: some View {
        VStack(spacing: QuotaMetrics.compact.sectionGap) {
            if let used = account.fiveHourUsedPct {
                QuotaHeroCard(label: "5H", weekly: false, usedPct: used,
                              resetAt: account.fiveHourResetsAt,
                              period: AccountUsage.fiveHourPeriod,
                              m: .compact, wakeTick: wakeTick)
                HStack(spacing: QuotaMetrics.compact.cardGap) {
                    if let seven = account.sevenDayUsedPct {
                        QuotaSevenCard(usedPct: seven, resetAt: account.sevenDayResetsAt,
                                       period: AccountUsage.sevenDayPeriod,
                                       compact: true, m: .compact, wakeTick: wakeTick)
                    }
                    if let t = todayTokens {
                        QuotaTodayCard(tokens: t, compact: true, m: .compact)
                    }
                }
            } else if let used = account.sevenDayUsedPct {
                QuotaHeroCard(label: "7D", weekly: true, usedPct: used,
                              resetAt: account.sevenDayResetsAt,
                              period: AccountUsage.sevenDayPeriod,
                              m: .compact, wakeTick: wakeTick)
                if let t = todayTokens { QuotaTodayCard(tokens: t, compact: true, m: .compact) }
            } else if let t = todayTokens {
                QuotaTokenCard(tokens: t, m: .compact)
            }
        }
        .padding(8)
        .frame(width: 320)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                                          bottomTrailingRadius: 14, topTrailingRadius: 0))
    }
}

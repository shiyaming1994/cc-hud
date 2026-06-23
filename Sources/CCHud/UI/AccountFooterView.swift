import SwiftUI
import AppKit
import Combine
import CCHudCore

/// 账户级页脚（styles.css .acct）：5h/7d 配额 + 今日 token。
/// 设计稿 grid：.ag-win = 20|1fr|30|42 gap7（compact 18|1fr|28|38 gap6）；.ag-tok = 20|1fr|auto。
/// 点击页脚 = 切换形态档位（onTap）。
struct AccountFooterView: View {
    let account: AccountUsage
    let todayTokens: Int?
    var compact = false
    /// 顶部分隔线：上方有内容（会话行/标题）才画——空面板时它会贴着圆角边缘发亮
    var showTopRule = true
    var onTap: (() -> Void)? = nil

    /// 休眠唤醒后 +1：强制重建窗口的 TimelineView，立即按当前时间校正，
    /// 不然倒计时/额度会停在休眠前
    @State private var wakeTick = 0

    private var labelW: CGFloat { compact ? 18 : 20 }
    private var pctW: CGFloat { compact ? 28 : 30 }
    // 设计稿 38/42，SF Symbol 比 ↻ 字符宽，放大避免 "5d16h" 截断
    private var resetW: CGFloat { compact ? 44 : 48 }
    private var gap: CGFloat { compact ? 6 : 7 }

    var body: some View {
        if account.fiveHourUsedPct != nil || account.sevenDayUsedPct != nil || todayTokens != nil {
            VStack(alignment: .leading, spacing: compact ? 4 : 5) {
                if let used = account.fiveHourUsedPct {
                    gauge(label: "5h", usedPct: used, resetAt: account.fiveHourResetsAt,
                          period: AccountUsage.fiveHourPeriod)
                }
                if let used = account.sevenDayUsedPct {
                    gauge(label: "7d", usedPct: used, resetAt: account.sevenDayResetsAt,
                          period: AccountUsage.sevenDayPeriod)
                }
                if let t = todayTokens {
                    HStack(alignment: .firstTextBaseline, spacing: gap) {
                        footLabel("今日")
                        Spacer(minLength: 4)
                        Text(Format.tokens(t))
                            .font(.system(size: compact ? 11 : 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.txSecondary)
                        Text("token").font(.system(size: 10)).foregroundStyle(Theme.txFaint)
                    }
                }
            }
            .padding(EdgeInsets(top: compact ? 6 : 7, leading: compact ? 2 : 8,
                                bottom: compact ? 3 : 5, trailing: compact ? 2 : 8))
            .opacity(0.82)
            .overlay(alignment: .top) {
                if showTopRule {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .gesture(WindowDragGesture())   // 额度区 = 移动面板的把手
            // 休眠唤醒：主动校正一次，倒计时/额度不停在休眠前
            .onReceive(NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification)) { _ in
                wakeTick &+= 1
            }
        }
    }

    private func footLabel(_ s: String, color: Color = Theme.txFaint) -> some View {
        Text(s)
            .font(.system(size: compact ? 9.5 : 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .frame(width: labelW, alignment: .leading)
    }

    /// 用量条 + 倒计时随时间走；resets_at 一过即本地视为窗口已重置（用量归零、
    /// 重置点滚到下一周期），免得倒计时停在 0s、额度卡在旧值。整条放进 TimelineView
    /// 才能让百分比也随时间校正——否则只有倒计时会动。
    private func gauge(label: String, usedPct rawUsed: Double, resetAt rawReset: Date?,
                       period: TimeInterval) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let p = AccountUsage.project(usedPct: rawUsed, resetsAt: rawReset, period: period, now: ctx.date)
            let used = p.usedPct ?? rawUsed
            let remain = max(0, min(100, 100 - used))
            let alert = remain < AccountUsage.lowQuotaRemainPct   // 剩余 <20：整条告警高亮，尤其倒计时
            let tint = Theme.remainColor(remain)
            HStack(spacing: gap) {
                footLabel(label, color: alert ? tint : Theme.txFaint)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Theme.remainBarColor(remain))
                            .frame(width: geo.size.width * remain / 100)
                    }
                }
                .frame(height: 3)
                Text("\(Int(remain))%")
                    .font(.system(size: compact ? 9.5 : 10.5, weight: alert ? .semibold : .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.remainColor(remain))
                    .frame(width: pctW, alignment: .trailing)
                Group {
                    if let resetAt = p.resetsAt {
                        // 图标内联进 Text：随字体基线对齐，不再偏移
                        Text("\(Image(systemName: "arrow.clockwise"))\(Format.countdown(to: resetAt, from: ctx.date))")
                            .font(.system(size: compact ? 9.5 : 10, weight: alert ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(alert ? tint : Theme.txFaint)
                    } else {
                        Text("")
                    }
                }
                .frame(width: resetW, alignment: .trailing)
                .lineLimit(1)
            }
        }
        .id(wakeTick)   // 唤醒时重建 → 立即用当前时间求值，不等下一个 60s tick
    }
}

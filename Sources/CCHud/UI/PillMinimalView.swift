import SwiftUI
import AppKit
import Combine
import CCHudCore

/// M 档：轮播 working/permission 会话（项目 + 用时）+ 各状态计数 + 今日 token（components.jsx PillCycle）。
struct PillMinimalView: View {
    let items: [DisplaySession]
    let account: AccountUsage
    let todayTokens: Int?
    @State private var idx = 0
    @State private var now = Date()
    private let cycleTimer = Timer.publish(every: 2.7, on: .main, in: .common).autoconnect()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var active: [DisplaySession] {
        items.filter { $0.session.status == .working || $0.session.status == .permission }
    }
    private var counts: [(SessionStatus, Int)] {
        SessionStatus.allCases.compactMap { st in
            let c = items.filter { $0.session.status == st }.count
            return c > 0 ? (st, c) : nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if active.isEmpty {
                Circle().fill(Theme.idle).frame(width: 6, height: 6)
                Text("空闲").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.txSecondary)
            } else {
                let cur = active[idx % active.count]
                StatusDotView(status: cur.session.status)
                Text(cur.session.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.txPrimary)
                    .lineLimit(1)
                if let dup = cur.dup {
                    Text("#\(dup)").font(.system(size: 11)).foregroundStyle(Theme.txFaint)
                }
                Text(timerInterval: cur.session.roundStart...Date.distantFuture, countsDown: false)
                    .font(Theme.mono).monospacedDigit()
                    .foregroundStyle(Theme.statusColor(cur.session.status))
            }
            if !counts.isEmpty {
                Divider().frame(height: 10).overlay(Theme.hairline)
                HStack(spacing: 6) {
                    ForEach(counts, id: \.0) { st, c in
                        HStack(spacing: 3) {
                            Circle().fill(Theme.statusColor(st)).frame(width: 5, height: 5)
                                .opacity(st == .dead ? 0.55 : 1)
                            Text("\(c)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.txSecondary).monospacedDigit()
                        }
                    }
                }
            }
            // 今日 token（.cyc-tok：左分隔线 + 等宽 12 半粗）
            if let t = todayTokens {
                Text(Format.tokens(t))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.txSecondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1, height: 12)
                    }
            }
            // 额度告警：5h/7d 任一剩余 <20% 才冒出来——胶囊从简，只留剩余百分比（去掉窗口名/倒计时）
            if let w = account.alertWindow(now: now) {
                HStack(spacing: 4) {
                    Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1, height: 12)
                        .padding(.trailing, 2)
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text("\(Int(w.remainPct))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                }
                .foregroundStyle(Theme.remainColor(w.remainPct))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .onReceive(cycleTimer) { _ in
            if active.count > 1 { idx = (idx + 1) % active.count }
        }
        .onReceive(clock) { now = $0 }
        // 休眠唤醒：立即重算告警窗口（投影依赖当前时间）
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)) { _ in now = Date() }
    }
}

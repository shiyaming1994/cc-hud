import SwiftUI
import AppKit
import CCHudCore

/// 标签（最小档）：显示 5 小时剩余额度；有会话等确认权限时换成提示点（设计文档 4.6、10.1）。
/// 显示什么由 EdgeTabContent.make 判定，这里只管画。
struct EdgeTabView: View {
    let statuses: [SessionStatus]
    let account: AccountUsage
    @State private var wakeTick = 0

    var body: some View {
        // 额度会随时间变（到点重置）：每分钟 :00 重算；休眠唤醒立刻重算（换 id 重建 TimelineView）
        TimelineView(.periodic(from: QuotaClock.minuteAnchor, by: 60)) { ctx in
            content(EdgeTabContent.make(statuses: statuses, account: account, now: ctx.date))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(wakeTick)
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)) { _ in wakeTick &+= 1 }
    }

    @ViewBuilder private func content(_ c: EdgeTabContent) -> some View {
        switch c {
        case .attention:
            Circle().fill(Theme.permission).frame(width: 6, height: 6)
        case .noData:
            number("—", alarm: false)
        case let .remaining(n, alarm):
            number("\(n)", alarm: alarm)
        }
    }

    /// 三位数（100）字号缩到 9，半径 20 的半圆里才放得下
    private func number(_ text: String, alarm: Bool) -> some View {
        Text(text)
            .font(.system(size: text.count >= 3 ? 9 : 11, weight: .semibold))
            .monospacedDigit()
            .tracking(-0.22)
            .foregroundStyle(alarm ? Theme.quotaAlarm : Color.white.opacity(0.94))
            .lineLimit(1)
            .fixedSize()
    }
}

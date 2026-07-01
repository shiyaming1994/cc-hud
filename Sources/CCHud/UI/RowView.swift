import SwiftUI
import CCHudCore

/// 展开档单行（styles.css .row）：grid 14 | 1fr | ctx | time，gap 8，min-height 30。
/// 时间列在最右且恒定占位；ctx = 22x4 进度条 + 百分比。
struct RowView: View {
    let item: DisplaySession
    var isJustDone: Bool
    @EnvironmentObject private var hover: HoverState

    private var s: Session { item.session }
    private var hovering: Bool { hover.hoveredRow == item.id }

    /// 行底色（styles.css .row 系列）：完成高亮 > 悬停 > 权限常驻底 > 透明。
    /// 权限行常驻橙底（--st-permission-soft），悬停加深到 0.22；普通行悬停 = --row-hover。
    private var bgColor: Color {
        if isJustDone { return Theme.idle.opacity(0.3) }
        let perm = s.status == .permission
        if hovering { return perm ? Theme.permissionHover : Theme.rowHover }
        return perm ? Theme.permissionSoft : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    StatusDotView(status: s.status)
                        .frame(width: 14)
                        // 基线对齐：圆点中心落到名字 x-height 视觉中线（见 Theme.dotBaselineRise）
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Theme.dotBaselineRise(forFontSize: 13) }
                    Text(s.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.txPrimary)
                        .lineLimit(1)
                    if let dup = item.dup {
                        Text("#\(dup)").font(.system(size: 11)).foregroundStyle(Theme.txFaint)
                    }
                    Text(s.activity)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.txSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ctxView
                timeView
                    .frame(width: 42, alignment: .trailing)   // 固定宽（不自动增宽，避免随秒数变化的抖动/样式问题）
            }
            if s.status == .permission, let cmd = s.permissionCommand {
                HStack(spacing: 5) {
                    Text("└").foregroundStyle(Theme.txFaint)
                    Text(cmd).lineLimit(1)
                }
                .font(Theme.mono)
                .foregroundStyle(Theme.permission.opacity(0.9))
                .padding(.leading, 22)
            }
        }
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 8))
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(bgColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        // 行矩形上报（clip 之后不被裁）：鼠标位置命中判定悬停，取代非 active app 下易漏事件的 NSTrackingArea
        .reportsRowRect(id: item.id)
        .animation(.easeOut(duration: 0.6), value: isJustDone)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var timeView: some View {
        switch s.status {
        case .working, .permission:
            // render-server 自更新计时，app 进程零开销
            Text(timerInterval: s.roundStart...Date.distantFuture, countsDown: false)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(s.status == .permission ? Theme.permission : Theme.txTertiary)
                .monospacedDigit()
        case .dead:
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(Format.coarse(since: s.roundStart, now: ctx.date))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.txFaint)
            }
        case .idle:
            Text("")
        }
    }

    @ViewBuilder private var ctxView: some View {
        if let ctx = s.ctxPct {
            HStack(spacing: 3) {   // 进度条与 % 收紧成一组，与后面的时间自然分开（不再额外加间距）
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Theme.ctxBarColor(ctx))
                            .frame(width: geo.size.width * min(1, ctx / 100))
                    }
                }
                .frame(width: 22, height: 4)
                Text("\(Int(ctx))%")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.ctxColor(ctx))
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
    }
}

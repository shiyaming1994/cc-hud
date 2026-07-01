import SwiftUI
import CCHudCore

/// E 档列表（styles.css .el-row）：grid 7 | 1fr | 32 | 42，gap 8，行高 24，行内边距 0 8。
/// 时间列 42 而非设计稿的 34：等宽 12pt 下两位数分钟 "12:34" 约 36pt，34 会截尾。
/// 时间列恒定占位 → 没有时间的行 ctx% 依然对齐。
/// 行：点击跳转 / 拖拽换序；页脚：点击展开 / 拖动移面板。
struct PillListView: View {
    let items: [DisplaySession]
    let account: AccountUsage
    let todayTokens: Int?
    let isJustDone: (String) -> Bool
    let onRowTap: (Session) -> Void
    let onReorder: ([String]) -> Void
    let onFooterTap: () -> Void

    var body: some View {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 0) {
            // 超过 4 行才滚动（行高 24pt，无行距）；置顶行变化（完成/发消息冒顶）→ 自动滑回最顶
            CappedScroll(cap: 24 * 4, scrollTopToken: items.first?.id) {
                ReorderableRows(ids: items.map(\.id), enabled: true, onReorder: onReorder) { id, dragging in
                    if let item = byId[id] {
                        rowView(item, dragging: dragging)
                    }
                }
            }
            AccountFooterView(account: account, todayTokens: todayTokens, compact: true,
                              showTopRule: !items.isEmpty, onTap: onFooterTap)
        }
        .padding(EdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 5))   // .pill.list { padding: 6px 5px }
    }

    private func rowView(_ item: DisplaySession, dragging: Bool) -> some View {
        let s = item.session
        return HStack(spacing: 8) {
            Circle().fill(Theme.statusColor(s.status)).frame(width: 7, height: 7)
                .opacity(s.status == .dead ? 0.55 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(s.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.txPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)   // 名字过长 → "…"
                if let dup = item.dup {
                    Text("#\(dup)").font(.system(size: 11)).foregroundStyle(Theme.txFaint)
                        .fixedSize()         // #n 序号不被挤掉
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let ctx = s.ctxPct {
                    Text("\(Int(ctx))%").font(Theme.mono).monospacedDigit()
                        .foregroundStyle(Theme.ctxColor(ctx))
                } else {
                    Text("")
                }
            }
            .frame(width: 32, alignment: .trailing)
            timeText(s)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(dragging ? Color.white.opacity(0.08)
                             : (isJustDone(s.id) ? Theme.idle.opacity(0.3) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.15), value: dragging)
        .animation(.easeOut(duration: 0.6), value: isJustDone(s.id))
        .rowHover(id: s.id, radius: 6)   // 悬停高亮（鼠标位置判定，见 HoverState.hoveredRow）
        .contentShape(Rectangle())
        .onTapGesture { onRowTap(s) }
    }

    @ViewBuilder private func timeText(_ s: Session) -> some View {
        switch s.status {
        case .working, .permission:
            Text(timerInterval: s.roundStart...Date.distantFuture, countsDown: false)
                .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                .foregroundStyle(Theme.statusColor(s.status))
        case .dead:
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(Format.coarse(since: s.roundStart, now: ctx.date))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.txFaint)
            }
        case .idle:
            Text("")
        }
    }
}

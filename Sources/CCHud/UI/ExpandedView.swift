import SwiftUI
import CCHudCore

/// 展开档：完整行 + 丝滑拖拽排序 + 点击跳转 + 账户 footer（components.jsx ExpandedWidget）。
/// 头部与额度区 = 移动面板的把手；中间行拖拽 = 换顺序。
struct ExpandedView: View {
    let items: [DisplaySession]
    let account: AccountUsage
    let todayTokens: Int?
    let isJustDone: (String) -> Bool
    let onReorder: ([String]) -> Void
    let onRowTap: (Session) -> Void
    let onHeaderTap: () -> Void
    let onFooterTap: () -> Void

    var body: some View {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("✳").font(.system(size: 12)).foregroundStyle(Theme.txTertiary)
                Text("Claude Code").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.txPrimary)
                Text("· \(items.count)").font(.system(size: 12)).foregroundStyle(Theme.txTertiary)
                Spacer()
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.txTertiary)
            }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture(perform: onHeaderTap)
            .gesture(WindowDragGesture())   // 头部 = 移动面板的把手

            // .w-list { max-height: 264px } —— 行多时内部滚动
            CappedScroll(cap: 264) {
                ReorderableRows(ids: items.map(\.id), enabled: true, onReorder: onReorder) { id, dragging in
                    if let item = byId[id] {
                        RowView(item: item, isJustDone: isJustDone(item.id))
                            .background(dragging ? Color.white.opacity(0.08) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .scaleEffect(dragging ? 1.015 : 1)
                            .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 9, y: 3)
                            .animation(.easeOut(duration: 0.15), value: dragging)
                            .contentShape(Rectangle())
                            .onTapGesture { onRowTap(item.session) }
                    }
                }
            }
            AccountFooterView(account: account, todayTokens: todayTokens, onTap: onFooterTap)
        }
        .padding(6)   // .widget.expanded { padding: 6px } —— 行高亮与容器边缘的间距
    }
}

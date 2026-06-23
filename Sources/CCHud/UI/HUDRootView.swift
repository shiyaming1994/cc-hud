import SwiftUI
import CCHudCore

/// 三档形态：0=M 轮播药丸，1=E 列表，2=展开。点击循环切换。
struct HUDRootView: View {
    let store: StateStore
    let onRowTap: (Session) -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }
    @AppStorage("hud.stage") private var stage = 1
    @AppStorage("hud.manualOrder") private var manualOrderJSON = ""

    private var manualOrder: [String]? {
        guard !manualOrderJSON.isEmpty,
              let data = manualOrderJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr
    }

    var body: some View {
        let items = store.displaySessions(manualOrder: manualOrder)
        Group {
            switch stage {
            case 0:
                PillMinimalView(items: items, account: store.account, todayTokens: store.todayTokens)
                    .contentShape(Rectangle())
                    .onTapGesture { stage = 1 }
                    .gesture(WindowDragGesture())   // 最小档整体 = 移动面板
                    .fixedSize()
            case 1:
                // 行：点击跳转 / 拖拽换序；额度区：点击展开 / 拖动移面板
                PillListView(items: items, account: store.account,
                             todayTokens: store.todayTokens, isJustDone: isJustDone,
                             onRowTap: onRowTap,
                             onReorder: { ids in
                                 manualOrderJSON = (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                             },
                             onFooterTap: { stage = 2 })
                    .frame(width: 208)   // 时间列 +8（两位数分钟），名字列空间不变
                    .fixedSize(horizontal: false, vertical: true)
            default:
                ExpandedView(items: items, account: store.account, todayTokens: store.todayTokens,
                             isJustDone: isJustDone,
                             onReorder: { ids in
                                 manualOrderJSON = (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                             },
                             onRowTap: onRowTap,
                             onHeaderTap: { stage = 0 },
                             onFooterTap: { stage = 0 })
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background {
            ZStack {
                VisualEffectView()
                Theme.glass
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 1))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }

    private func isJustDone(_ id: String) -> Bool {
        guard let until = store.sessions[id]?.justDoneUntil else { return false }
        return until > Date()
    }
}

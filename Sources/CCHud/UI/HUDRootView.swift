import SwiftUI
import CCHudCore

/// 三档形态：0=M 轮播药丸，1=E 列表，2=展开。点击循环切换。
struct HUDRootView: View {
    let store: StateStore
    let onRowTap: (Session) -> Void
    /// 窗口尺寸 = 展开态尺寸（由隐藏探针给出，恒定），悬停不改窗口。
    var onSizeChange: (CGSize) -> Void = { _ in }
    /// 可见玻璃高度（静息 < 展开）：面板据此定悬停命中区、透明预留区穿透点击、随动阴影。
    var onVisibleHeightChange: (CGFloat) -> Void = { _ in }
    /// 悬停态：由「鼠标位置 vs 可见玻璃 frame」的监视器写入（AppDelegate），面板缩放不会误翻它。
    @ObservedObject var hover: HoverState
    @AppStorage("hud.stage") private var stage = 1

    // 收起药丸（M 档）= 整颗胶囊（原型 .pill border-radius:999，全圆端）；列表/展开 = 12 圆角矩形
    private var pillShape: AnyShape {
        stage == 0 ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    var body: some View {
        let items = store.displaySessions()
        // 全空闲（无 working/permission）→ 玻璃更通透（.calm）
        let calm = !items.contains { $0.session.status.isActive }
        // 固定尺寸窗口 + 内容内平滑展开：窗口恒为「展开态」大小，悬停时窗口一动不动，
        // 只有可见内容在其中平滑长出/收起——彻底避开 AppKit 窗口与 SwiftUI 内容跨帧不同步的闪跳。
        ZStack(alignment: .topTrailing) {
            // 尺寸探针：footer 恒展开、隐藏、不参与命中 —— 让 ZStack（→窗口）恒为展开高度。
            stageContent(items: items, calm: calm)
                .environment(\.footerExpanded, true)
                .hidden()
                .allowsHitTesting(false)
            // 可见内容：footer 随悬停平滑展开/收起；玻璃只贴合可见内容（静息时短），顶（右上）对齐。
            stageContent(items: items, calm: calm)
                .environment(\.footerExpanded, hover.footerExpanded)
                .background {
                    ZStack {
                        // .hudWindow：经典深色毛玻璃，会透出并模糊桌面
                        VisualEffectView(material: .hudWindow,
                                         cornerRadius: Theme.radius, isCapsule: stage == 0)
                        (calm ? Theme.glassCalm : Theme.glass)
                    }
                }
                .clipShape(pillShape)
                .overlay(pillShape.stroke(Theme.hairline, lineWidth: 1))
                // 平滑：悬停翻转时，footer 的高度变化 + 内容淡入淡出一起做 0.2s 缓动
                .animation(.easeOut(duration: 0.2), value: hover.footerExpanded)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onVisibleHeightChange($0) }
        }
        // 投影由系统窗口投影负责（HUDPanel.hasShadow）——按可见玻璃 alpha 描边，透明预留区不投影
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .environmentObject(hover)   // 供各行读 hoveredRow / 上报行矩形（鼠标位置驱动的行悬停）
    }

    /// 三档内容（可见/探针共用，仅注入的 footerExpanded 不同）。
    @ViewBuilder private func stageContent(items: [DisplaySession], calm: Bool) -> some View {
        switch stage {
        case 0:
            PillMinimalView(items: items, account: store.account, todayTokens: store.todayTokens)
                .contentShape(Rectangle())
                .onTapGesture { stage = 1 }
                .gesture(WindowDragGesture())   // 最小档整体 = 移动面板
                .frame(width: 235)              // 整颗胶囊定宽：长名截断、计数靠右、图标不动
                .fixedSize(horizontal: false, vertical: true)
        case 1:
            // 行：点击跳转 / 拖拽换序；额度区：点击展开 / 拖动移面板
            PillListView(items: items, account: store.account,
                         todayTokens: store.todayTokens, isJustDone: isJustDone,
                         onRowTap: onRowTap,
                         onReorder: { ids in store.reorder(ids) },
                         onFooterTap: { stage = 2 })
                .frame(width: 208)   // 时间列 +8（两位数分钟），名字列空间不变
                .fixedSize(horizontal: false, vertical: true)
        default:
            ExpandedView(items: items, account: store.account, todayTokens: store.todayTokens,
                         isJustDone: isJustDone,
                         onReorder: { ids in store.reorder(ids) },
                         onRowTap: onRowTap,
                         onHeaderTap: { stage = 0 },
                         onFooterTap: { stage = 0 })
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isJustDone(_ id: String) -> Bool {
        guard let until = store.sessions[id]?.justDoneUntil else { return false }
        return until > Date()
    }
}

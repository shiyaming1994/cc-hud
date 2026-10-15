import SwiftUI
import CCHudCore

/// 三档形态：0 = 标签，1 = 列表，2 = 展开。点击循环切换。三档都贴屏幕右边缘（设计文档第 4 节）。
struct HUDRootView: View {
    let store: StateStore
    let onRowTap: (Session) -> Void
    /// 窗口尺寸 = 展开态尺寸（由隐藏探针给出，恒定），悬停不改窗口。
    var onSizeChange: (CGSize) -> Void = { _ in }
    /// 可见玻璃高度（静息 < 展开）：面板据此定悬停命中区、透明预留区穿透点击、随动阴影。
    var onVisibleHeightChange: (CGFloat) -> Void = { _ in }
    /// 当前档的外形：面板按真实外形判定点击是否穿透（设计文档 4.7）。
    var onShapeChange: (EdgeShape.Kind) -> Void = { _ in }
    /// 悬停态：由「鼠标位置 vs 可见玻璃 frame」的监视器写入（AppDelegate），面板缩放不会误翻它。
    @ObservedObject var hover: HoverState
    @AppStorage("hud.stage") private var stage = 1

    private var shapeKind: EdgeShape.Kind { stage == 0 ? .tab : .box }

    var body: some View {
        let items = store.displaySessions()
        // 全空闲（无 working/permission）→ 玻璃更通透（.calm）
        let calm = !items.contains { $0.session.status.isActive }
        // 固定尺寸窗口 + 内容内平滑展开：窗口恒为「展开态」大小，悬停时窗口一动不动，
        // 只有可见内容在其中平滑长出/收起——彻底避开 AppKit 窗口与 SwiftUI 内容跨帧不同步的闪跳。
        ZStack(alignment: .topTrailing) {
            // 尺寸探针：footer 恒展开、隐藏、不参与命中 —— 让 ZStack（→窗口）恒为展开高度。
            stageContent(items: items)
                .environment(\.footerExpanded, true)
                .hidden()
                .allowsHitTesting(false)
            // 可见内容：footer 随悬停平滑展开/收起；玻璃只贴合可见内容（静息时短），顶（右上）对齐。
            stageContent(items: items)
                .environment(\.footerExpanded, hover.footerExpanded)
                .background {
                    ZStack {
                        // .hudWindow：经典深色毛玻璃，会透出并模糊桌面；外形由遮罩裁出
                        VisualEffectView(material: .hudWindow, shape: shapeKind)
                        (calm ? Theme.glassCalm : Theme.glass)
                    }
                }
                .clipShape(EdgeTabShape(kind: shapeKind))
                // 描边只描外形的非贴边部分（开放路径），贴屏幕边缘那条不描
                .overlay(EdgeTabShape(kind: shapeKind, closed: false).stroke(Theme.hairline, lineWidth: 1))
                // 平滑：悬停翻转时，footer 的高度变化 + 内容淡入淡出一起做 0.2s 缓动
                .animation(.easeOut(duration: 0.2), value: hover.footerExpanded)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onVisibleHeightChange($0) }
        }
        // 投影由系统窗口投影负责（HUDPanel.hasShadow）——按可见玻璃 alpha 描边，透明预留区不投影
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .onChange(of: stage, initial: true) { _, s in onShapeChange(s == 0 ? .tab : .box) }
        .environmentObject(hover)   // 供各行读 hoveredRow / 上报行矩形（鼠标位置驱动的行悬停）
    }

    /// 三档内容（可见/探针共用，仅注入的 footerExpanded 不同）。
    /// 方框上下各留外翻弧的高度（EdgeShape.ear），内容落在主体里，不压到外翻弧上。
    @ViewBuilder private func stageContent(items: [DisplaySession]) -> some View {
        switch stage {
        case 0:
            EdgeTabView(statuses: items.map(\.session.status), account: store.account)
                .frame(width: EdgeShape.tabSize.width, height: EdgeShape.tabSize.height)
                .contentShape(EdgeTabShape(kind: .tab))
                .onTapGesture { stage = 1 }
                .gesture(WindowDragGesture())   // 标签整体 = 移动面板的把手
        case 1:
            // 行：点击跳转 / 拖拽换序；额度区：点击展开 / 拖动移面板
            PillListView(items: items, account: store.account,
                         todayTokens: store.todayTokens, isJustDone: isJustDone,
                         onRowTap: onRowTap,
                         onReorder: { ids in store.reorder(ids) },
                         onFooterTap: { stage = 2 })
                .frame(width: 208)   // 时间列 +8（两位数分钟），名字列空间不变
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, EdgeShape.ear)
        default:
            ExpandedView(items: items, account: store.account, todayTokens: store.todayTokens,
                         isJustDone: isJustDone,
                         onReorder: { ids in store.reorder(ids) },
                         onRowTap: onRowTap,
                         onHeaderTap: { stage = 0 },
                         onFooterTap: { stage = 0 })
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, EdgeShape.ear)
        }
    }

    private func isJustDone(_ id: String) -> Bool {
        guard let until = store.sessions[id]?.justDoneUntil else { return false }
        return until > Date()
    }
}

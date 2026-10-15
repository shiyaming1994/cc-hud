import AppKit
import SwiftUI
import CCHudCore

/// 非激活浮窗：点击不抢终端焦点，所有 Space + 全屏可见。
/// 三档都贴屏幕右边缘（设计文档第 4 节）：横向永远贴停靠屏 visibleFrame 的右边，
/// 纵向以锚点（停靠屏 UUID + 面板顶边高度）为唯一真相。
/// 锚点按【屏 UUID + 屏内偏移】持久化——多屏拔插/睡眠时全局坐标会漂移（排列原点变了），
/// 系统还会把窗口搬去幸存屏，绝对坐标既存不住"在哪块屏"，还会被系统搬窗覆写。
/// 只有用户拖动、松手吸附之后才写存档；存档屏不在场时临时贴主屏，屏一回来立即归位。
final class HUDPanel: NSPanel {
    private static let anchorKey = "hud.anchor.v2"             // {screen: 显示器 UUID, dx: 贴边值（只给旧版本看）, dy: 顶边相对屏 origin}
    private static let legacyAnchorKey = "hud.anchorTopRight"  // v1 全局绝对坐标，读到即迁移
    private var programmaticMove = false
    /// 显隐存档。走 CCHudCore 是为了让「默认隐藏 + 记住用户那次点击」这两条有单测兜着。
    private let visibility = PanelSettings(defaults: .standard)
    private var settleTask: Task<Void, Never>?
    /// 用户拖动中：盯着鼠标键，松开即吸附。WindowDragGesture 是系统级窗口拖动，
    /// 松手不一定以 mouseUp 送到 app，所以轮询（只在拖动期间跑）。
    private var dragWatch: Timer?
    /// 当前档的外形（标签 / 方框），点击按它判定是否穿透（设计文档 4.7）
    private var shapeKind: EdgeShape.Kind = .box
    /// 悬停态由 AppDelegate 的鼠标监视器经此写入（用可见玻璃 frame 命中判定，不依赖会被内容缩放扰动的 tracking area）。
    weak var hoverState: HoverState?
    private var isHovering = false
    /// 可见玻璃当前高度（静息 < 窗口高；展开 = 窗口高）。窗口恒为展开尺寸、下方留透明预留区，
    /// 所以：悬停命中区按此高度（不含预留，避免在空白处误触发）、预留区 hitTest 穿透点击、系统阴影按此贴合。
    /// 默认 = 启动窗口高，首帧测量后即校正。
    var visibleHeight: CGFloat = 120
    /// 收起判定的外扩量：贴边小幅移动落在此余量内不收起（空间迟滞，避免边缘横跳）
    private let hoverMargin: CGFloat = 24

    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true   // 系统窗口投影：沿玻璃外形描一圈柔和投影；贴边一侧落在屏幕外，看不到
        isMovableByWindowBackground = false  // 移窗只在指定区域（WindowDragGesture），行区留给拖拽排序
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true   // app 处于 active 时，本地鼠标监视器靠它收到 mouseMoved（非 active 走全局监视器）
        // PassThroughHostingView：窗口恒为展开尺寸，静息时玻璃只占顶部、下方是透明预留区；
        // 该子类让预留区和外形外的透明角落的点击穿透到下方窗口（否则会挡住终端）。
        let host = PassThroughHostingView(rootView: rootView)
        host.layerContentsRedrawPolicy = .duringViewResize
        contentView = host

        dock()

        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
        // 显示器拔插 / 睡眠醒来：每次变化都重新落位。外接屏上电慢（插线后几秒才注册），
        // 注册那一刻系统会再发一次本通知，所以无论多慢，屏到场即归位，无需重启。
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // 等重排尘埃落定再落位；2s 后再校一次，防系统迟到的搬窗又把面板挪走
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.dock()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.dock()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 显隐的唯一入口：上/下屏与落存档绑在一起，免得再出现「用户点了却没记下来」。
    func setVisible(_ visible: Bool) {
        if visible { orderFrontRegardless() } else { orderOut(nil) }
        visibility.visible = visible
    }

    /// 菜单「显示 / 隐藏 HUD」
    func toggleVisible() { setVisible(!isVisible) }

    /// 启动时按存档恢复。存档为假就什么都不做 —— 不回写，省得每次启动都惊动 cfprefsd。
    func restoreVisibility() {
        if visibility.visible { orderFrontRegardless() }
    }

    /// 悬停判定入口（AppDelegate 的鼠标监视器在每次鼠标移动时调用，传入屏幕坐标）。
    /// 命中区 = 面板右上角向下 `可见玻璃高度` 的矩形（**不含**下方透明预留区，故在空白处不会误触发）；
    /// 已悬停时四周外扩 margin 形成迟滞死区，贴边小幅移动不横跳。展开时玻璃填满窗口 → 命中区即整窗。
    /// 用实际 frame 而不是存档锚点：下面放不下时面板会临时上移，锚点不跟着变（设计文档 4.4）。
    func updateHover(at point: NSPoint) {
        // 行悬停（每次移动都判定）：屏幕鼠标 → 窗口内容坐标（左上原点、y 向下），命中哪行矩形就高亮哪行。
        // 单一真相 = 恰好一行（或无），免疫 NSTrackingArea 漏 enter/exit 与探针重复导致的"乱亮/多行同亮"。
        if let hoverState {
            let g = frame.windowContentPoint(fromScreen: point)
            let row = hoverState.rowRects.first { $0.value.contains(g) }?.key
            if hoverState.hoveredRow != row { hoverState.hoveredRow = row }
        }
        // 页脚展开悬停（迟滞判定，仅在跨越可见玻璃边界时翻转）
        let h = max(visibleHeight, 1)
        let m = isHovering ? hoverMargin : 0
        let inside = NSRect(x: frame.minX - m, y: frame.maxY - h - m,
                            width: frame.width + 2 * m, height: h + 2 * m).contains(point)
        guard inside != isHovering else { return }
        isHovering = inside
        hoverState?.footerExpanded = inside   // 只翻转内容展开态；窗口尺寸不变，内容在窗口内平滑伸缩
    }

    /// SwiftUI 内容尺寸（= 展开态尺寸，由隐藏探针恒定给出）变化 → 按锚点重新贴边落位（瞬时）。
    /// 下面放不下时整体上移、锚点不变；变小后自然回到锚点高度（设计文档 4.4）。
    /// 悬停不改变此尺寸（探针恒展开），故此函数在悬停时空跑；只在行数增减 / 换档时真正重排。
    /// 拖动中例外：只换尺寸、右上角跟手不动，松手再吸附——否则行数一变面板就从手里跳回锚点。
    func applyContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        if dragWatch != nil {
            let w = size.width.rounded(), h = size.height.rounded()
            place(NSRect(x: frame.maxX.rounded() - w, y: frame.maxY.rounded() - h, width: w, height: h))
        } else {
            dock(size: size)
        }
    }

    /// 可见玻璃高度变化（含悬停动画每帧）→ 更新命中区基准、预留区穿透阈值（PassThroughHostingView 经 visibleContentContains 读它）、
    /// 并重算系统阴影使其随玻璃高度伸缩（窗口不缩放，阴影只能靠 invalidate 跟上玻璃 alpha）。
    func setVisibleHeight(_ h: CGFloat) {
        guard h > 1, abs(h - visibleHeight) > 0.5 else { return }
        visibleHeight = h
        invalidateShadow()
    }

    /// 换档后外形变了（标签 ↔ 方框）：点击判定跟着换，阴影重算
    func setShape(_ kind: EdgeShape.Kind) {
        guard kind != shapeKind else { return }
        shapeKind = kind
        invalidateShadow()
    }

    /// 用户拖动（按着鼠标、非程序移动）→ 开始盯松手；锚点等松手吸附后再存（设计文档 4.3）。
    /// 程序性 setFrame 与系统搬窗都不算：拔屏/睡眠重排时 window server 搬窗没有按着鼠标，
    /// v1 把它当用户拖动存了档，拔一次屏锚点就被主屏坐标覆写——这正是"重插不回原位"的根因。
    @objc private func didMove() {
        guard !programmaticMove, NSEvent.pressedMouseButtons != 0, dragWatch == nil else { return }
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDragRelease() }
        }
    }

    private func pollDragRelease() {
        guard dragWatch != nil, NSEvent.pressedMouseButtons == 0 else { return }
        dragWatch?.invalidate()
        dragWatch = nil
        snapToEdge()
    }

    /// 松手吸附：停靠屏 = 鼠标所在的屏 → 和面板重叠最多的屏 → 主屏；
    /// 横向贴它的右边缘、纵向夹进 visibleFrame，0.2 秒缓出移过去；存锚点。
    private func snapToEdge() {
        let screens = NSScreen.screens
        let picked = EdgeDock.pickScreen(mouse: NSEvent.mouseLocation, panel: frame,
                                         screens: screens.map(\.frame))
        guard let s = picked.map({ screens[$0] }) ?? screens.first, let uuid = s.displayUUID else { return }
        let target = EdgeDock.frame(size: frame.size, top: frame.maxY, visibleFrame: s.visibleFrame)
        let anchor = DockAnchor(screen: uuid, dy: target.maxY - s.frame.minY)
        UserDefaults.standard.set(anchor.archive(screenFrame: s.frame, visibleFrame: s.visibleFrame),
                                  forKey: Self.anchorKey)
        // 动画途中的 didMove 不会被当成拖动：那时鼠标键已经松开
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }

    /// 按锚点贴边落位（瞬时）。存档屏在场 → 贴它的右边缘、锚点高度（被系统搬走也拉回）；
    /// 不在场或没存档 → 临时贴主屏右边缘的默认高度，存档不动，屏回来即恢复（设计文档 4.5）。
    private func dock(size: CGSize? = nil) {
        guard let t = dockTarget() else { return }
        place(EdgeDock.frame(size: size ?? frame.size, top: t.top, visibleFrame: t.screen.visibleFrame))
    }

    private func dockTarget() -> (screen: NSScreen, top: CGFloat)? {
        if let a = savedAnchor(), let s = NSScreen.screens.first(where: { $0.displayUUID == a.screen }) {
            return (s, a.top(screenFrame: s.frame))
        }
        guard let primary = NSScreen.screens.first else { return nil }
        return (primary, EdgeDock.defaultTop(visibleFrame: primary.visibleFrame))
    }

    /// 程序移窗的唯一出口：标记为非用户拖动；尺寸变了重算系统阴影。
    /// 走零时长动画组、不直接 setFrame：松手吸附的 0.2 秒动画还在跑时，直接 setFrame 会被动画剩下的帧盖回去
    /// （松手后马上点开列表，窗口就卡在标签大小）。零时长的 animator().setFrame 当场生效、顶掉进行中的动画，
    /// 移动/缩放通知也和直接 setFrame 一样在调用返回前发完，programmaticMove 照样罩得住。
    private func place(_ f: NSRect) {
        guard f != frame else { return }
        let resized = f.size != frame.size
        programmaticMove = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            animator().setFrame(f, display: true)
        }
        programmaticMove = false
        if resized { invalidateShadow() }
    }

    /// 解析存档（dx 不用，横向永远贴边）。所在屏是否在场由调用方判断。
    private func savedAnchor() -> DockAnchor? {
        if let d = UserDefaults.standard.dictionary(forKey: Self.anchorKey), let a = DockAnchor(archive: d) {
            return a
        }
        // v1 绝对坐标存档：能定位到所在屏就迁移成 v2（找不到屏说明那块屏不在场，留待回场或用户重拖）
        if let arr = UserDefaults.standard.array(forKey: Self.legacyAnchorKey) as? [Double], arr.count == 2 {
            let p = CGPoint(x: arr[0], y: arr[1])
            if let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(p) }),
               let uuid = s.displayUUID {
                let a = DockAnchor(screen: uuid, dy: p.y - s.frame.minY)
                UserDefaults.standard.set(a.archive(screenFrame: s.frame, visibleFrame: s.visibleFrame),
                                          forKey: Self.anchorKey)
                UserDefaults.standard.removeObject(forKey: Self.legacyAnchorKey)
                return a
            }
        }
        return nil
    }
}

extension NSRect {
    /// 屏幕坐标(左下原点)的点 → 以本 rect 为窗口时的内容坐标(左上原点、y 向下)，
    /// 用于和 SwiftUI `.frame(in: .global)` 上报的矩形做命中判定。HUD 与预警卡共用。
    func windowContentPoint(fromScreen p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - minX, y: maxY - p.y)
    }
}

/// 窗口向宿主视图声明「哪些点落在可见内容上」（窗口内容坐标系，左上原点、y 向下）：
/// 其余是透明预留区或外形外的透明角落，点击必须穿透到下方窗口。
@MainActor
protocol VisibleContentProviding: AnyObject {
    func visibleContentContains(_ point: CGPoint) -> Bool
}

extension HUDPanel: VisibleContentProviding {
    /// 可见玻璃 = 顶对齐、宽满窗口、高 visibleHeight 的那块，再按真实外形裁：
    /// 外翻弧外侧、圆头外侧的透明角落不接点击（设计文档 4.7）。
    func visibleContentContains(_ point: CGPoint) -> Bool {
        EdgeShape.path(shapeKind, in: CGSize(width: frame.width, height: visibleHeight)).contains(point)
    }
}

/// 宿主视图：窗口恒为展开尺寸，静息时可见内容只占其中一块，其余是透明预留区。
/// 让预留区和外形外透明角落的点击**穿透**到下方窗口（不然会挡住终端 / 菜单栏）；外形内正常命中 SwiftUI 子视图。
final class PassThroughHostingView<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let provider = window as? VisibleContentProviding else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // 统一到窗口内容坐标（左上原点、y 向下），与 visibleContentContains 同系
        let p = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        guard provider.visibleContentContains(p) else { return nil }
        return super.hitTest(point)
    }
}

import AppKit
import SwiftUI
import CCHudCore

/// 菜单栏额度条面板：钉在用户指定的显示器菜单栏上，右缘贴状态项左缘、内容变宽向左生长。
/// 全窗穿透（`ignoresMouseEvents`）——悬停不响应、点击直接落到菜单栏本身，
/// 所以不需要 HUDPanel 那套可见矩形 / hitTest 穿透机制。
///
/// 位置不做"用户拖动"这种交互：条子的落点由菜单栏实测结果唯一决定（见 MenuBarProbe），
/// 用户能选的只有「在哪块屏」，按显示器 UUID 存档（与 HUDPanel 同一套身份）。
@MainActor
final class MenuBarStripPanel: NSPanel {
    /// 沿用刘海岛时代的 key：已经把岛打开的用户升级后直接得到条子，不用再去菜单里点一次
    static let enabledKey = "hud.notchIsland"
    static let screenKey = "hud.menuBarStrip.screen"
    /// 系统「自动隐藏菜单栏」开关（NSGlobalDomain）。standard 的搜索链含全局域，直接读得到。
    static var autoHideMenuBar: Bool { UserDefaults.standard.bool(forKey: "_HIHideMenuBar") }

    /// 内容自然宽度（SwiftUI 侧 .fixedSize() 后实测回灌）
    private var contentWidth: CGFloat = 240
    /// 模式开关的意愿；真正上不上屏还要看有没有数据（三源全无时内容宽度为 0）
    private var wantsVisible = false
    /// 视图侧的可用宽度预算（内容按它降级）；与窗口落位同源刷新
    let metrics: StripMetrics
    private var settleTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// 兜底轮询间隔。状态项增减（输入法切换、时间机器图标冒出来…）没有公开通知，只能轮询兜底。
    /// 单次探测实测 1.06ms，5s 一次 ≈ 0.02% 单核；高频变化都走事件驱动（见 init 里的观察者），
    /// 所以这条只决定"别的 App 新增状态图标后多久躲开"，最坏 5s。
    private static let pollInterval: TimeInterval = 5

    init(rootView: some View, metrics: StripMetrics) {
        self.metrics = metrics
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 24),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar          // 25：与状态项同级，能盖住菜单栏；菜单展开时 popUpMenu(101) 在其上
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false           // 条子是菜单栏上的一行字，系统投影会描出一圈灰边、露馅
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true   // 全窗穿透：悬停无反应，点击落到菜单栏
        let host = NSHostingView(rootView: rootView)
        host.layerContentsRedrawPolicy = .duringViewResize
        contentView = host

        let nc = NotificationCenter.default
        // 外接屏拔插 / 分辨率变化：菜单栏高度与坐标系都会变，600ms + 2s 两次校准
        // （外接屏上电慢，注册那一刻系统会再发一次本通知 → 开机插线再晚也会自己归位）
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(refreshNow),
                        name: NSWorkspace.didWakeNotification, object: nil)
        // App 切换会带动状态项变化（输入法指示器、随前台应用出没的图标）→ 立即重测
        wnc.addObserver(self, selector: #selector(refreshNow),
                        name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Space 切换（进出全屏、换桌面）：菜单栏在新空间里可能压根不存在，必须立即重判。
        // 实测该通知在转场开始约 0.8s 后才到（此时该屏状态项已经归零），比兜底轮询快得多。
        wnc.addObserver(self, selector: #selector(refreshNow),
                        name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: 开关与选屏

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static func setEnabled(_ on: Bool) { UserDefaults.standard.set(on, forKey: enabledKey) }

    /// 常驻显示器的 UUID；nil = 自动（主屏）
    static var savedScreenUUID: String? {
        UserDefaults.standard.string(forKey: screenKey).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func setScreenUUID(_ uuid: String?) {
        UserDefaults.standard.set(uuid ?? "", forKey: screenKey)
    }

    /// 目标屏：存档屏在场就用它；不在场（还没插上 / 已拔掉）按「自动」临时落位，**存档不动**，
    /// 屏一回来 didChangeScreenParameters 就会把条子接回去。选屏规则见 MenuBarStrip.preferredScreenIndex。
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let i = MenuBarStrip.preferredScreenIndex(
                savedUUID: Self.savedScreenUUID,
                uuids: screens.map(\.displayUUID),
                hasNotch: screens.map { $0.safeAreaInsets.top > 0 },
                minX: screens.map(\.frame.minX))
        else { return nil }
        return screens[i]
    }

    // MARK: 显隐与落位

    func setVisible(_ on: Bool) {
        wantsVisible = on
        if on {
            startPolling()
            refresh()
        } else {
            stopPolling()
            hideStrip()
        }
    }

    /// 菜单里换了常驻显示器 → 立刻搬过去（瞬时，不做跨屏动画）
    func applyScreenSelection() {
        refresh(animated: false)
    }

    /// SwiftUI 内容自然宽度变化（数据变化 / 7D 重置段出没）→ 右缘不动、向左重新生长。
    /// 宽度 0 表示三源全无，条子整体撤下。
    func applyContentWidth(_ w: CGFloat) {
        let rounded = w.rounded()
        guard abs(rounded - contentWidth) > 0.5 else { return }
        contentWidth = rounded
        refresh(animated: false)
    }

    /// 撤下 / 上屏都先动 `alphaValue`，不再依赖 `orderOut` 的时效。
    ///
    /// 我们不是菜单栏的正式居民：菜单栏底板是 Window Server 的 layer-24 窗口、状态项是
    /// 「控制中心」进程的 layer-25 窗口，进全屏时它们作为 Space 转场的一部分被原子撤掉；
    /// 条子只是我们自己进程的一个同级独立窗口，没人负责撤它，只能自己发现邻居没了再撤。
    /// 而**窗口排序在转场期间被 Space 机制锁住**——2026-09-02 实测 `orderOut` 要迟 1.15s
    /// 才生效，条子会在全屏画面上回闪一下；`alphaValue` 是窗口自身的合成属性，同一时刻
    /// 设 0 立即生效（`kCGWindowAlpha` 当场读到 0）。orderOut 照旧调用，只是不指望它及时。
    private func hideStrip() {
        alphaValue = 0
        if isVisible { orderOut(nil) }
    }

    private func showStrip() {
        alphaValue = 1
        if !isVisible { orderFrontRegardless() }
    }

    @objc private func refreshNow() { refresh() }

    private func refresh(animated: Bool = true) {
        guard wantsVisible, let screen = targetScreen() else {
            hideStrip()
            return
        }
        let layout = MenuBarProbe.layout(for: screen)
        DebugLog.log("strip: probe minX=\(layout.statusItemsMinX.map { "\($0)" } ?? "nil") " +
                     "bar=\(layout.bar.minX)…\(layout.bar.maxX) w=\(contentWidth) " +
                     "frame=\(frame.minX)…\(frame.maxX) alpha=\(alphaValue) vis=\(isVisible)")
        let notch = NotchGeometry.notchRect(screenFrame: screen.frame,
                                            safeAreaTop: screen.safeAreaInsets.top,
                                            auxLeft: screen.auxiliaryTopLeftArea,
                                            auxRight: screen.auxiliaryTopRightArea)
        // 预算无条件回灌，必须在任何提前 return 之前：视图据此选档，一旦因"隐藏"跳过回灌，
        // 视图会停在"一档都放不下"的 0 宽度上，而 0 宽度又让本函数继续提前 return，
        // 两边互锁、条子再也回不来（2026-09-02 全屏退出后不复现的那次回归）。
        // 预算只取决于菜单栏几何、与内容宽度无关，所以回灌不会成环。
        let b = MenuBarStrip.budget(bar: layout.bar, statusItemsMinX: layout.statusItemsMinX,
                                    notch: notch)
        if abs(metrics.budget - b) > 0.5 { metrics.budget = b }

        // 菜单栏藏起来时（系统自动隐藏 / 该屏被全屏 App 占据）条子一并撤下，
        // 否则它会长期悬在用户内容之上。全屏的判据是"该屏状态项整体离屏"，
        // 而不是 visibleFrame 的顶部内缩（全屏时它纹丝不动）——见 MenuBarStrip.menuBarVisible。
        let visible = MenuBarStrip.menuBarVisible(autoHideEnabled: Self.autoHideMenuBar,
                                                  hasStatusItems: layout.statusItemsMinX != nil)
        guard visible, contentWidth > 1 else {
            DebugLog.log("strip: 撤下 (visible=\(visible) w=\(contentWidth))")
            hideStrip()
            return
        }
        let f = MenuBarStrip.frame(bar: layout.bar, statusItemsMinX: layout.statusItemsMinX,
                                   notch: notch, contentWidth: contentWidth)
        place(f, animated: animated)
        showStrip()
    }

    /// 纯平移且幅度不大（状态项增减把条子挤了一格）→ 0.16s 缓动跟进，不硬跳；
    /// 换屏 / 改尺寸一律瞬时（动画期间 SwiftUI 内容会跟着重排，反而更晃）。
    private func place(_ f: CGRect, animated: Bool) {
        guard f != frame else { return }
        if animated, f.size == frame.size, abs(f.minX - frame.minX) < 240 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(f, display: true)
            }
        } else {
            setFrame(f, display: true)
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func screensChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refresh(animated: false)
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refresh(animated: false)
        }
    }
}

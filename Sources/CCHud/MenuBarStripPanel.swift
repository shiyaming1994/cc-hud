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

    /// 内容自然宽度（SwiftUI 侧 .fixedSize() 后实测回灌）
    private var contentWidth: CGFloat = 240
    /// 模式开关的意愿；真正上不上屏还要看有没有数据（三源全无时内容宽度为 0）
    private var wantsVisible = false
    /// 视图侧的可用宽度预算（内容按它降级）；与窗口落位同源刷新
    let metrics: StripMetrics
    private var settleTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// 兜底轮询间隔。状态项增减（输入法切换、时间机器图标冒出来…）没有公开通知，
    /// 只能兜底轮询；真正的高频变化都走事件驱动（见 init 里的观察者）。
    private static let pollInterval: TimeInterval = 2

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
            orderOut(nil)
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

    @objc private func refreshNow() { refresh() }

    private func refresh(animated: Bool = true) {
        guard wantsVisible, contentWidth > 1, let screen = targetScreen() else {
            if isVisible { orderOut(nil) }
            return
        }
        let layout = MenuBarProbe.layout(for: screen)
        let notch = NotchGeometry.notchRect(screenFrame: screen.frame,
                                            safeAreaTop: screen.safeAreaInsets.top,
                                            auxLeft: screen.auxiliaryTopLeftArea,
                                            auxRight: screen.auxiliaryTopRightArea)
        // 预算先回灌：视图据此选档 → 新宽度经 applyContentWidth 回来，不会成环
        // （预算只取决于菜单栏几何，与内容宽度无关）
        let b = MenuBarStrip.budget(bar: layout.bar, statusItemsMinX: layout.statusItemsMinX,
                                    notch: notch)
        if abs(metrics.budget - b) > 0.5 { metrics.budget = b }
        let f = MenuBarStrip.frame(bar: layout.bar, statusItemsMinX: layout.statusItemsMinX,
                                   notch: notch, contentWidth: contentWidth)
        place(f, animated: animated)
        if !isVisible { orderFrontRegardless() }
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

import AppKit
import SwiftUI
import CCHudCore

/// 额度燃尽预警卡：全屏一次性提示，停留数秒自动淡出。无交互、点击穿透。
/// 弹的频率由 StateStore 的升档去重控制（这里只负责显示一次）；不做焦点静默
/// （账户级提醒，正看着哪个终端都该提示）。面板按需创建、播完即毁，平时零常驻。
@MainActor
final class BurnoutAlertController {
    static let enabledKey = "burnout.alertEnabled"
    /// 默认开启
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static func setEnabled(_ on: Bool) { UserDefaults.standard.set(on, forKey: enabledKey) }

    /// 出现在用户焦点屏（与完成动画/提问卡同策略）
    var screenProvider: () -> NSScreen? = { nil }
    private var panel: NSPanel?
    private var model: BurnoutCardModel?
    private var task: Task<Void, Never>?
    private var hoverMonitors: [Any] = []
    private var isHovering = false

    func present(remainingPct: Double, dropMinutes: Double, timeLeft: TimeInterval) {
        teardown()   // 升档新卡直接替换旧卡，不叠加
        let model = BurnoutCardModel()
        let root = BurnoutAlertView(remainingPct: remainingPct, dropMinutes: dropMinutes,
                                    timeLeft: timeLeft, model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let screen = screenProvider() ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true        // 初始穿透；鼠标移到卡上时临时关掉(见 updateHover)，让卡吃点击、不漏到后面
        panel.acceptsMouseMovedEvents = true   // 关穿透后仍要收到 mouseMoved，才能检测"离开卡片"
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model

        // 悬停保活：全局+本地监听鼠标移动（和 HUD 同款——只判定位置、不抢事件，保持点击穿透）
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        let gMon = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
        }
        let lMon = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
            return e
        }
        if let gMon { hoverMonitors.append(gMon) }
        if let lMon { hoverMonitors.append(lMon) }

        // 设计稿动效：纯淡入淡出，无位移。in 340ms（delay 60）→ hold 3.2s → out 560ms
        // 悬停保活：至少显示 fade-in+hold；之后「消失 = 到点 且 鼠标不在卡上」；
        // 淡出途中鼠标又移回 → 取消淡出、重新亮起（多次移入移出也稳）。
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.34)) { model.shown = true }
            try? await Task.sleep(for: .milliseconds(340 + 3200))
            guard !Task.isCancelled else { return }
            while true {
                while self?.isHovering == true {           // 停在卡上 → 一直挂着
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                withAnimation(.easeInOut(duration: 0.56)) { model.shown = false }   // 离开 → 淡出
                var revived = false
                for _ in 0..<8 {                           // 淡出 ~560ms 内每 70ms 探一次是否移回
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled else { return }
                    if self?.isHovering == true { revived = true; break }
                }
                if revived {
                    withAnimation(.easeInOut(duration: 0.34)) { model.shown = true }   // 移回 → 重新亮起
                    continue
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    /// 鼠标是否停在卡片上：屏幕坐标(左下原点) → SwiftUI 全局坐标(左上原点，即 cardRect 所在系)。
    /// 全屏面板 origin = 屏 origin，故 g = (mx - frame.minX, frame.maxY - my)，与 HUDPanel.updateHover 同法。
    private func updateHover(at point: NSPoint) {
        guard let panel, let rect = model?.cardRect, rect != .zero else { isHovering = false; return }
        isHovering = rect.contains(panel.frame.windowContentPoint(fromScreen: point))
        panel.ignoresMouseEvents = !isHovering   // 停在卡上→卡片吃点击(不穿透到后面)；离开→恢复穿透
    }

    private func teardown() {
        task?.cancel()
        task = nil
        for m in hoverMonitors { NSEvent.removeMonitor(m) }
        hoverMonitors.removeAll()
        isHovering = false
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}

/// 进出场状态（@Observable，controller 改、卡片视图读 → 隐式动画）
@MainActor @Observable final class BurnoutCardModel {
    var shown = false
    /// 卡片在 SwiftUI 全局坐标（左上原点）的矩形，由卡片上报，供 controller 做悬停命中判定
    var cardRect: CGRect = .zero
}

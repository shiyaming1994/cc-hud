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
        panel.ignoresMouseEvents = true        // 点击穿透：对正常操作零影响
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model

        // 设计稿动效：纯淡入淡出，无位移。in 340ms（delay 60）→ hold 3.2s → out 560ms
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeInOut(duration: 0.34)) { model.shown = true }
            try? await Task.sleep(for: .milliseconds(340 + 3200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.56)) { model.shown = false }
            try? await Task.sleep(for: .milliseconds(560 + 80))
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    private func teardown() {
        task?.cancel()
        task = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}

/// 进出场状态（@Observable，controller 改、卡片视图读 → 隐式动画）
@MainActor @Observable final class BurnoutCardModel {
    var shown = false
}

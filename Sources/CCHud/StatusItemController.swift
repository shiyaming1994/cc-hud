import AppKit
import ServiceManagement
import ApplicationServices

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let togglePanel: () -> Void
    private let reinstall: () -> Void
    private let uninstallAction: () -> Void
    private let previewAnimation: (String) -> Void
    private let eventStatus: () -> String
    private let previewBurnout: () -> Void
    private(set) var installStatusText = "未安装"

    init(togglePanel: @escaping () -> Void, reinstall: @escaping () -> Void,
         uninstall: @escaping () -> Void, eventStatus: @escaping () -> String,
         previewAnimation: @escaping (String) -> Void,
         previewBurnout: @escaping () -> Void) {
        self.togglePanel = togglePanel
        self.reinstall = reinstall
        self.uninstallAction = uninstall
        self.eventStatus = eventStatus
        self.previewAnimation = previewAnimation
        self.previewBurnout = previewBurnout
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack.fill",
                                     accessibilityDescription: "CC HUD")
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
    }

    func setInstallStatus(_ text: String) {
        installStatusText = text
        rebuildMenu()
    }

    /// 菜单每次打开时重建——授权状态、登录项状态实时刷新
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuildMenu() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = NSMenuItem(title: "接入状态：\(installStatusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        // 事件链路健康：最近事件时间 + 解析失败计数（排障一眼可见）
        let health = NSMenuItem(title: eventStatus(), action: nil, keyEquivalent: "")
        health.isEnabled = false
        menu.addItem(health)
        menu.addItem(.separator())
        menu.addItem(makeItem("显示 / 隐藏 HUD", #selector(togglePanelAction)))
        let launch = makeItem("登录时启动", #selector(toggleLaunchAtLogin))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())
        // 提示动画（完成动画 + 提问提示成对生效）：关闭 / 光环 / 打字机 / 呼吸灯
        // 配对关系：光环↔光环呼吸、打字机↔逐字打出、呼吸灯↔边缘光呼吸
        let animMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: CompletionAnimator.styleKey) ?? "a"
        let styles: [(String, String)] = [
            ("off", "关闭"), ("a", "光环"), ("b", "打字机"), ("c", "呼吸灯"),
        ]
        for (key, name) in styles {
            let mi = NSMenuItem(title: name, action: #selector(pickAnimStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            mi.state = current == key ? .on : .off
            animMenu.addItem(mi)
        }
        let animRoot = NSMenuItem(title: "提示动画（完成 / 提问）", action: nil, keyEquivalent: "")
        animRoot.submenu = animMenu
        menu.addItem(animRoot)
        // 焦点静默：正看着的终端 tab 不弹完成动画/提问提示
        let focusItem = makeItem("焦点会话不提示", #selector(toggleFocusSuppress))
        focusItem.state = TerminalFocus.suppressEnabled ? .on : .off
        menu.addItem(focusItem)
        // 额度燃尽预警：5h 按当前速率会提前烧光时全屏提示（升档才弹，不静默）
        let burnoutItem = makeItem("额度燃尽预警", #selector(toggleBurnout))
        burnoutItem.state = BurnoutAlertController.enabled ? .on : .off
        menu.addItem(burnoutItem)
        menu.addItem(.separator())
        let axOK = AXIsProcessTrusted()
        menu.addItem(makeItem(axOK ? "辅助功能：已授权 ✓" : "授权辅助功能（Ghostty 跳转）…",
                              #selector(openAccessibilitySettings)))
        menu.addItem(makeItem("自动化授权设置（iTerm2/终端跳转）…", #selector(openAutomationSettings)))
        menu.addItem(.separator())
        menu.addItem(makeItem("重新安装接入", #selector(reinstallAction)))
        menu.addItem(makeItem("卸载接入（还原 settings.json）", #selector(uninstallMenuAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", #selector(quit)))
    }

    private func makeItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        return mi
    }

    @objc private func togglePanelAction() { togglePanel() }
    @objc private func pickAnimStyle(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            UserDefaults.standard.set(key, forKey: CompletionAnimator.styleKey)
            if key != "off" { previewAnimation(key) }   // 切换即预览一次
        }
        rebuildMenu()
    }
    @objc private func toggleFocusSuppress() {
        TerminalFocus.setSuppress(!TerminalFocus.suppressEnabled)
        rebuildMenu()
    }
    @objc private func toggleBurnout() {
        let on = !BurnoutAlertController.enabled
        BurnoutAlertController.setEnabled(on)
        if on { previewBurnout() }   // 开启即演示一次，让用户知道卡片长什么样
        rebuildMenu()
    }
    @objc private func openAccessibilitySettings() {
        if !AXIsProcessTrusted() { _ = JumpService.ensureAccessibility() }
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
    @objc private func toggleLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        rebuildMenu()
    }
    @objc private func reinstallAction() { reinstall() }
    @objc private func uninstallMenuAction() { uninstallAction() }
    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import ServiceManagement
import ApplicationServices
import CCHudCore

/// 接入状态的结构化表达——菜单状态行按 case 渲染:正常灰色一行,异常显眼可点
enum InstallState {
    case ok
    case failed(String)
    case uninstalled
    case serverError(String)
    /// 开发构建(非生产 bundle id):不接生产事件链路,只听 hud-dev.sock 的假事件
    case devMode
}

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
    private let stripModeChanged: () -> Void
    private let stripScreenChanged: () -> Void
    private let updateController: UpdateController
    private var installState: InstallState = .failed("未安装")
    /// 当前菜单里的更新横幅项(仅可点状态);高亮切换时在 accent 蓝与系统反白之间换色
    private weak var bannerItem: NSMenuItem?

    init(updateController: UpdateController,
         togglePanel: @escaping () -> Void, reinstall: @escaping () -> Void,
         uninstall: @escaping () -> Void, eventStatus: @escaping () -> String,
         previewAnimation: @escaping (String) -> Void,
         previewBurnout: @escaping () -> Void,
         stripModeChanged: @escaping () -> Void,
         stripScreenChanged: @escaping () -> Void) {
        self.updateController = updateController
        self.togglePanel = togglePanel
        self.reinstall = reinstall
        self.uninstallAction = uninstall
        self.eventStatus = eventStatus
        self.previewAnimation = previewAnimation
        self.previewBurnout = previewBurnout
        self.stripModeChanged = stripModeChanged
        self.stripScreenChanged = stripScreenChanged
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack.fill",
                                     accessibilityDescription: "CC HUD")
        menu.delegate = self
        item.menu = menu
        // 更新状态变化(发现新版/下载进度)→ 即时重建,菜单开着也能看到进度跳动
        updateController.onStateChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
    }

    func setInstallState(_ state: InstallState) {
        installState = state
        rebuildMenu()
    }

    /// 菜单每次打开时重建——授权状态、登录项状态实时刷新
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuildMenu() }
    }

    /// 横幅的 attributedTitle 固定了 accent 蓝,会盖掉系统高亮反白 → 高亮时手动切白、
    /// 移开恢复蓝。只有横幅需要:其他项都是普通 title,系统自己处理。
    nonisolated func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // NSMenuItem 非 Sendable,不能带进 MainActor 闭包(Swift 6 release 构建报 sending 风险)
        // ——闭包外先取指针身份(ObjectIdentifier 是 Sendable),闭包内按身份比较
        let highlightedID = item.map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            guard let banner = bannerItem else { return }
            banner.attributedTitle = Self.bannerTitle(
                banner.title, highlighted: highlightedID == ObjectIdentifier(banner))
        }
    }

    private static func bannerTitle(_ text: String, highlighted: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor
                                          : NSColor.controlAccentColor,
        ])
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        // ── 状态行:版本+接入状态合并一行;正常零噪音,异常显眼可点
        switch installState {
        case .ok:
            let s = NSMenuItem(title: "CC HUD v\(AppInfo.version) · 运行正常",
                               action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
        case .failed(let why):
            let s = makeItem("⚠ 接入失败 · 点击重新安装", #selector(reinstallAction))
            s.toolTip = why
            menu.addItem(s)
        case .uninstalled:
            menu.addItem(makeItem("已卸载接入 · 点击恢复", #selector(reinstallAction)))
        case .serverError(let why):
            let s = NSMenuItem(title: "⚠ 事件服务启动失败", action: nil, keyEquivalent: "")
            s.isEnabled = false
            s.toolTip = why   // 端口占用等,重装修不了——只展示原因
            menu.addItem(s)
        case .devMode:
            let s = NSMenuItem(title: "CC HUD v\(AppInfo.version) · 开发构建(未接生产事件)",
                               action: nil, keyEquivalent: "")
            s.isEnabled = false
            s.toolTip = "开发实例只听 hud-dev.sock(send-fake.sh 发假事件);生产 HUD 与接入不受影响"
            menu.addItem(s)
        }
        // ── 更新横幅(有新版 / 下载中 / 安装中才出现)
        let pres = updateController.state.menuPresentation
        bannerItem = nil
        if let banner = pres.bannerTitle {
            if pres.bannerEnabled {
                let b = makeItem(banner, #selector(updateBannerAction))
                b.attributedTitle = Self.bannerTitle(banner, highlighted: false)
                bannerItem = b
                menu.addItem(b)
            } else {
                let b = NSMenuItem(title: banner, action: nil, keyEquivalent: "")
                b.isEnabled = false
                menu.addItem(b)
            }
        }
        menu.addItem(.separator())
        let stripItem = makeItem("菜单栏额度条", #selector(toggleStripMode))
        stripItem.state = MenuBarStripPanel.enabled ? .on : .off
        stripItem.toolTip = "在指定显示器的菜单栏上常驻一行额度,隐藏会话浮窗;条子不吃鼠标,看会话列表走下面的「显示 / 隐藏 HUD」"
        menu.addItem(stripItem)
        let screenRoot = NSMenuItem(title: "常驻显示器", action: nil, keyEquivalent: "")
        screenRoot.submenu = buildScreenMenu()
        menu.addItem(screenRoot)
        menu.addItem(makeItem("显示 / 隐藏 HUD", #selector(togglePanelAction)))
        menu.addItem(.separator())
        // ── 设置(高频开关留顶层,随手可切)
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
        let focusItem = makeItem("焦点会话不提示", #selector(toggleFocusSuppress))
        focusItem.state = TerminalFocus.suppressEnabled ? .on : .off
        menu.addItem(focusItem)
        let burnoutItem = makeItem("额度燃尽预警", #selector(toggleBurnout))
        burnoutItem.state = BurnoutAlertController.enabled ? .on : .off
        menu.addItem(burnoutItem)
        let launch = makeItem("登录时启动", #selector(toggleLaunchAtLogin))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())
        // ── 权限与排障(低频,收进子菜单;事件心跳明细在这里)
        let diag = NSMenu()
        let ev = NSMenuItem(title: eventStatus(), action: nil, keyEquivalent: "")
        ev.isEnabled = false
        diag.addItem(ev)
        let axOK = AXIsProcessTrusted()
        diag.addItem(makeItem(axOK ? "辅助功能：已授权 ✓" : "授权辅助功能（Ghostty 跳转）…",
                              #selector(openAccessibilitySettings)))
        diag.addItem(makeItem("自动化授权设置（iTerm2/终端跳转）…", #selector(openAutomationSettings)))
        diag.addItem(.separator())
        diag.addItem(makeItem("重新安装接入", #selector(reinstallAction)))
        diag.addItem(makeItem("卸载接入（还原 settings.json）", #selector(uninstallMenuAction)))
        let diagRoot = NSMenuItem(title: "权限与排障", action: nil, keyEquivalent: "")
        diagRoot.submenu = diag
        menu.addItem(diagRoot)
        // ── 检查更新 + 退出
        if pres.checkItemEnabled {
            menu.addItem(makeItem(pres.checkItemTitle, #selector(checkUpdateAction)))
        } else {
            let c = NSMenuItem(title: pres.checkItemTitle, action: nil, keyEquivalent: "")
            c.isEnabled = false
            menu.addItem(c)
        }
        menu.addItem(makeItem("退出", #selector(quit)))
    }

    /// 常驻显示器子菜单：自动 + 在场各屏。同名显示器按 x 从左到右加方位后缀
    /// （本机就是两台同名 T2752U）；存档屏不在场时补一行灰字说明，免得用户以为设置丢了。
    /// 「自动」的实际规则见 MenuBarStrip.preferredScreenIndex —— 文案必须跟它一致。
    private func buildScreenMenu() -> NSMenu {
        let m = NSMenu()
        let saved = MenuBarStripPanel.savedScreenUUID
        let auto = NSMenuItem(title: "自动（优先无刘海的屏）", action: #selector(pickStripScreen(_:)),
                              keyEquivalent: "")
        auto.toolTip = "有外接屏时落最靠左的那块;只剩内置刘海屏时才用它(刘海屏菜单栏空隙小,内容会降级)"
        auto.target = self
        auto.representedObject = ""
        auto.state = saved == nil ? .on : .off
        m.addItem(auto)
        m.addItem(.separator())
        let screens = NSScreen.screens
        let labels = MenuBarStrip.displayLabels(screens.map { ($0.localizedName, $0.frame.minX) })
        var sawSaved = false
        for (i, s) in screens.enumerated() {
            guard let uuid = s.displayUUID else { continue }
            let mi = NSMenuItem(title: labels[i], action: #selector(pickStripScreen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = uuid
            mi.state = saved == uuid ? .on : .off
            if saved == uuid { sawSaved = true }
            m.addItem(mi)
        }
        if let saved, !sawSaved {
            let miss = NSMenuItem(title: "上次选择的显示器未连接 · 暂按「自动」落位", action: nil,
                                  keyEquivalent: "")
            miss.isEnabled = false
            miss.state = .on
            miss.toolTip = "存档没有被覆盖,那块屏一插回来条子就自己回去（UUID \(saved)）"

            m.addItem(.separator())
            m.addItem(miss)
        }
        return m
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
    @objc private func toggleStripMode() {
        MenuBarStripPanel.setEnabled(!MenuBarStripPanel.enabled)
        stripModeChanged()
        rebuildMenu()
    }
    @objc private func pickStripScreen(_ sender: NSMenuItem) {
        let uuid = sender.representedObject as? String
        MenuBarStripPanel.setScreenUUID(uuid?.isEmpty == false ? uuid : nil)
        stripScreenChanged()
        rebuildMenu()
    }
    @objc private func reinstallAction() { reinstall() }
    @objc private func uninstallMenuAction() { uninstallAction() }
    @objc private func updateBannerAction() { updateController.presentUpdateAlert() }
    @objc private func checkUpdateAction() { updateController.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }
}

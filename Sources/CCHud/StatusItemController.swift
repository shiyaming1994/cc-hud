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
    /// 按档位产出额度条内容（由 AppDelegate 提供，读 store）
    private let stripRuns: @MainActor (StripLevel) -> [StripRun]
    private let settings = StripSettings(defaults: .standard)
    /// 没有额度可显示时的兜底图标 —— 状态项不能完全空，否则点不到菜单
    private static let fallbackIcon = NSImage(systemSymbolName: "rectangle.stack.fill",
                                              accessibilityDescription: "CC HUD")
    private let updateController: UpdateController
    private var installState: InstallState = .failed("未安装")
    /// 当前菜单里的更新横幅项(仅可点状态);高亮切换时在 accent 蓝与系统反白之间换色
    private weak var bannerItem: NSMenuItem?

    init(updateController: UpdateController,
         togglePanel: @escaping () -> Void, reinstall: @escaping () -> Void,
         uninstall: @escaping () -> Void, eventStatus: @escaping () -> String,
         previewAnimation: @escaping (String) -> Void,
         previewBurnout: @escaping () -> Void,
         stripRuns: @escaping @MainActor (StripLevel) -> [StripRun]) {
        self.updateController = updateController
        self.togglePanel = togglePanel
        self.reinstall = reinstall
        self.uninstallAction = uninstall
        self.eventStatus = eventStatus
        self.previewAnimation = previewAnimation
        self.previewBurnout = previewBurnout
        self.stripRuns = stripRuns
        // 变宽：宽度由系统按标题量（额度条关掉时标题为空，退回图标那么宽）。
        // 图标不无条件挂 —— 有额度可显示时只显示文字，见 refreshStripTitle。
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // 显示文字时 image = nil，图标上那句 accessibilityDescription 就跟着没了，
        // VoiceOver 只剩裸标题可读 —— 而间距走 kern 不走字符，标题串里一个空格都没有
        // （"5H68%16:457D96%59M"）。标签挂在按钮上，两种形态都认得出这一格是谁。
        item.button?.setAccessibilityLabel("CC HUD")
        // 自动启用会按「有没有 action / 子菜单里有没有可用项」自己算 isEnabled，
        // 把手写的 isEnabled 覆盖掉 —— 档位那一项带子菜单，恒被算成可用，
        // 关掉额度条也灰不下去。根菜单里该灰的信息行本来就各自写了 isEnabled = false，
        // 关掉自动启用后那些写法才真正生效（子菜单是各自独立的 NSMenu，不受影响）。
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        // 更新状态变化(发现新版/下载进度)→ 即时重建,菜单开着也能看到进度跳动
        updateController.onStateChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        refreshStripTitle()
    }

    /// 重画状态项标题。有额度可显示 → 只有文字（不挂图标，省 ~19pt 菜单栏）；
    /// 关闭额度条、或两个额度窗口都还没数据 → 退回纯图标，否则状态项全空就点不到菜单。
    /// 全屏 / 自动隐藏 / 按屏取舍全部由系统负责，我们不判也不管 —— 这正是从独立窗口
    /// 换成真状态项的全部理由。
    func refreshStripTitle() {
        let runs = settings.enabled ? stripRuns(settings.level) : []
        guard !runs.isEmpty else {
            item.button?.image = Self.fallbackIcon
            item.button?.attributedTitle = NSAttributedString()
            return
        }
        item.button?.image = nil
        item.button?.attributedTitle = StripTitle.attributed(runs)
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
        stripItem.state = settings.enabled ? .on : .off
        stripItem.toolTip = "在菜单栏里显示一行额度(每块屏都显示);空间不够时系统会自行取舍该屏的图标"
        menu.addItem(stripItem)
        let levelRoot = NSMenuItem(title: "档位", action: nil, keyEquivalent: "")
        levelRoot.submenu = buildLevelMenu()
        levelRoot.isEnabled = settings.enabled
        menu.addItem(levelRoot)
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

    /// 档位子菜单：菜单项标题就是该档的实际内容，选完长什么样一眼看到，不用抽象词。
    /// 真状态项只有一个全局宽度、所有屏一样，所以详略只能由用户显式选（见 StripLevel）。
    ///
    /// 样本一律不着色（`colored: false`）——菜单高亮行会把写死的前景色留在 accent 底上，
    /// 标签 / `%` / token 直接溶掉。撞脸的档退回文字描述（见 StripContent.dedupe）。
    private func buildLevelMenu() -> NSMenu {
        let m = NSMenu()
        let levels = StripLevel.allCases
        for (level, runs) in zip(levels, StripContent.dedupe(levels.map(stripRuns))) {
            let mi = NSMenuItem(title: "", action: #selector(pickStripLevel(_:)), keyEquivalent: "")
            // runs == nil：还没收到 status（没样本可展示），或与前一档撞脸 —— 都退回档位描述
            mi.attributedTitle = runs.map { StripTitle.attributed($0, colored: false) }
                ?? NSAttributedString(string: Self.levelFallbackTitle(level))
            mi.target = self
            mi.tag = level.rawValue
            mi.state = settings.level == level ? .on : .off
            m.addItem(mi)
        }
        return m
    }

    private static func levelFallbackTitle(_ level: StripLevel) -> String {
        switch level {
        case .full:             return "5H + 7D + 今日 token"
        case .noToken:          return "5H + 7D"
        case .noFiveTime:       return "5H + 7D（不带时刻）"
        case .tightestWithTime: return "只显示最紧的一段（带时刻）"
        case .tightest:         return "只显示最紧的一段"
        }
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
        settings.enabled = !settings.enabled
        refreshStripTitle()
        rebuildMenu()
    }
    @objc private func pickStripLevel(_ sender: NSMenuItem) {
        settings.level = StripLevel(rawValue: sender.tag) ?? .full
        refreshStripTitle()
        rebuildMenu()
    }
    @objc private func reinstallAction() { reinstall() }
    @objc private func uninstallMenuAction() { uninstallAction() }
    @objc private func updateBannerAction() { updateController.presentUpdateAlert() }
    @objc private func checkUpdateAction() { updateController.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }
}

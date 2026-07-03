import AppKit
import CCHudCore

/// 更新编排:定时调度、状态持有、弹窗交互。
/// 检查/下载/替换的可测逻辑都在 CCHudCore(UpdateChecker / UpdateInstaller),这里只做 UI 编排。
@MainActor
final class UpdateController {
    private(set) var state: UpdateState = .idle {
        didSet { onStateChange?() }
    }
    /// 状态变化 → 菜单重建(StatusItemController 注册)
    var onStateChange: (() -> Void)?

    private let checker: UpdateChecker?
    private let installer = UpdateInstaller()
    private var periodicTimer: Timer?
    private var firstCheckTask: Task<Void, Never>?

    init() {
        checker = UpdateChecker(currentVersionString: AppInfo.version)
    }

    /// 启动后 ~10s 首查(避开启动高峰),之后每 24h 一次;自动检查静默,只亮菜单不弹窗
    func startAutomaticChecks() {
        firstCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.check(userInitiated: false)
        }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.check(userInitiated: false) }
        }
    }

    /// 菜单「检查更新…」入口:有弹窗反馈(已最新/失败都提示)
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard let checker else {
            if userInitiated { info("检查更新失败", "当前版本号无法解析(\(AppInfo.version))。") }
            return
        }
        switch state {
        case .downloading, .installing, .checking: return   // 更新流程进行中不重入
        case .idle, .available: break
        }
        state = .checking
        do {
            if let release = try await checker.checkLatest() {
                state = .available(release)
                if userInitiated { presentUpdateAlert() }
            } else {
                state = .idle
                if userInitiated { info("已是最新版本", "当前 v\(AppInfo.version) 即最新发布版本。") }
            }
        } catch {
            state = .idle
            DebugLog.log("update: 检查失败 \(error.localizedDescription)")
            if userInitiated { info("检查更新失败", "请稍后重试:\(error.localizedDescription)") }
        }
    }

    /// 更新确认窗:changelog(markdown 简单渲染,失败退回纯文本)+ [立即更新][稍后]
    func presentUpdateAlert() {
        guard case .available(let release) = state else { return }
        let alert = NSAlert()
        alert.messageText = "CC HUD \(release.tagName)"
        alert.informativeText = "发现新版本(当前 v\(AppInfo.version)),更新日志:"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        text.isEditable = false
        text.drawsBackground = false
        if let md = try? AttributedString(
            markdown: release.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            var styled = md
            styled.foregroundColor = NSColor.labelColor
            text.textStorage?.setAttributedString(NSAttributedString(styled))
        } else {
            text.string = release.body
            text.textColor = .labelColor
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        alert.accessoryView = scroll

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            startDownload(release)
        }
    }

    private func startDownload(_ release: ReleaseInfo) {
        // 期望 Team 取自当前运行 app(证书轮换同 Team 仍通过);
        // ad-hoc 开发构建无 Team → 拒绝自动更新,避免开发时误替换 /Applications
        guard let team = UpdateInstaller.teamIdentifier(of: Bundle.main.bundleURL) else {
            info("无法自动更新", "当前为开发构建(无稳定签名身份),请用 build-app.sh 部署或手动更新。")
            return
        }
        state = .downloading(0)
        let installer = self.installer
        Task {
            do {
                try await installer.downloadAndInstall(release, expectedTeam: team) { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.state { self?.state = .downloading(p) }
                    }
                }
                state = .installing
                installer.scheduleRelaunch()
                NSApp.terminate(nil)
            } catch {
                state = .idle
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "更新失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "前往 Releases 页面")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "https://github.com/shiyaming1994/cc-hud/releases")!)
        }
    }

    private func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

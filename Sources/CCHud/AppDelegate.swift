import AppKit
import SwiftUI
import CCHudCore

@MainActor
final class WeakPanelRef {
    weak var panel: HUDPanel?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = StateStore()
    let animator = CompletionAnimator()
    let questionPrompt = QuestionPromptController()
    let burnoutAlert = BurnoutAlertController()
    var server: EventServer?
    var panel: HUDPanel?
    var statusItem: StatusItemController?
    var livenessTimer: Timer?
    var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    private var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    private var installer: Installer {
        // emit 二进制：app bundle Resources，开发时退回构建目录
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("cc-hud-emit"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cc-hud-emit"),
        ].compactMap { $0 }
        let src = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        return Installer(claudeDir: claudeDir, emitSourceURL: src)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 0. 覆盖安装后双击新版本：让旧实例退出（socket 由本实例接管）。
        // 等旧实例真正退完再继续——否则它退出时的清理会与本实例的 bind 竞态。
        if let bid = Bundle.main.bundleIdentifier, !bid.isEmpty {
            let myPid = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != myPid }
            for other in others { other.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
                usleep(50_000)
            }
            for other in others where !other.isTerminated { other.forceTerminate() }
        }

        // 1. 安装接入（尊重用户的卸载意愿：卸载过则不自动重装）
        runInstall(force: false)

        // 2. 事件服务 + 完成动画 / 提问提示触发（均带焦点静默：正看着的终端 tab 不弹）
        store.onCompletion = { [weak self] session, elapsed in
            let item = CompletionItem(
                name: session.projectName,
                time: Format.clock(elapsed),
                task: SessionTitleResolver.title(for: session) ?? "")
            self?.triggerUnlessFocused(session, kind: "完成") { $0.animator.trigger(item) }
        }
        store.onCompactDone = { [weak self] session, elapsed in
            let item = CompletionItem(
                name: session.projectName,
                time: Format.clock(elapsed),
                task: SessionTitleResolver.title(for: session) ?? "",
                verb: "上下文已压缩")
            self?.triggerUnlessFocused(session, kind: "压缩完成") { $0.animator.trigger(item) }
        }
        store.onQuestion = { [weak self] session, questions in
            let item = QuestionPromptItem(sid: session.id,
                                          project: session.projectName,
                                          questions: questions)
            self?.triggerUnlessFocused(session, kind: "提问") { $0.questionPrompt.present(item) }
        }
        store.onQuestionResolved = { [weak self] sid in
            self?.questionPrompt.resolve(sid: sid)
        }
        // 额度燃尽预警：5h 按当前速率会提前烧光时弹全屏卡（升档才弹、不静默——账户级提醒）
        store.onBurnoutWarning = { [weak self] remainingPct, dropMinutes, timeLeft in
            guard BurnoutAlertController.enabled else { return }
            self?.burnoutAlert.present(remainingPct: remainingPct, dropMinutes: dropMinutes, timeLeft: timeLeft)
        }
        questionPrompt.onJump = { [weak self] sid in
            guard let s = self?.store.sessions[sid] else { return }
            JumpService.jump(to: s)
        }
        // 动画出现在用户焦点屏（前台窗口所在屏），不是 HUD 挂着的屏——
        // HUD 常驻副屏 1、人在副屏 2 干活时，提示要追人不追面板
        animator.screenProvider = { FocusedScreen.current() }
        burnoutAlert.screenProvider = { FocusedScreen.current() }
        let server = EventServer(socketPath: installer.socketPath, onEnvelope: { [weak self] env in
            Task { @MainActor in
                // 诊断探针：用信封里的真实身份跑一遍焦点判定，只写日志、不进会话列表
                if env.payload.hookEventName == "CCHudFocusProbe" {
                    self?.runFocusProbe(env)
                    return
                }
                self?.store.apply(env)
            }
        }, onDecodeFailure: { [weak self] in
            Task { @MainActor in self?.store.noteDecodeFailure() }
        })
        var serverError: String? = nil
        do { try server.start() } catch { serverError = "事件服务启动失败：\(error.localizedDescription)" }
        self.server = server

        // 3. HUD 面板（尺寸由 SwiftUI 内容驱动，经弱引用回灌面板）
        let panelRef = WeakPanelRef()
        let root = HUDRootView(store: store,
                               onRowTap: { session in JumpService.jump(to: session) },
                               onSizeChange: { size in panelRef.panel?.applyContentSize(size) })
        let panel = HUDPanel(rootView: root)
        panelRef.panel = panel
        panel.orderFrontRegardless()
        self.panel = panel

        // 4. 菜单栏
        statusItem = StatusItemController(
            togglePanel: { [weak self] in
                guard let p = self?.panel else { return }
                p.isVisible ? p.orderOut(nil) : p.orderFrontRegardless()
            },
            reinstall: { [weak self] in self?.runInstall(force: true) },
            uninstall: { [weak self] in
                guard let self else { return }
                try? self.installer.uninstall()
                UserDefaults.standard.set(true, forKey: Self.uninstalledKey)
                self.statusItem?.setInstallStatus("已卸载（菜单可重新安装）")
            },
            eventStatus: { [weak self] in
                guard let self else { return "" }
                let fails = self.store.decodeFailures
                let failNote = fails > 0 ? "（解析失败 \(fails)）" : ""
                guard let last = self.store.lastEventReceivedAt else { return "事件：尚未收到\(failNote)" }
                let s = Int(Date().timeIntervalSince(last))
                let age = s < 60 ? "\(s) 秒前" : (s < 3600 ? "\(s / 60) 分钟前" : "\(s / 3600) 小时前")
                return "事件：\(age)\(failNote)"
            },
            previewAnimation: { [weak self] _ in
                // 成对预览：先播完成动画，播完接提问卡片（同一方案族）。
                // 重置式：每次切换先清掉上一次预览（取消挂起的提问任务 + 中断在播的完成动画
                // + 撤掉预览提问卡），再干净播新的——否则快速连点会跨系统叠加。
                guard let self else { return }
                self.previewTask?.cancel()
                self.animator.reset()
                self.questionPrompt.resolve(sid: "preview")
                let name = self.store.displaySessions().first?.session.projectName ?? "pigeon"
                self.animator.trigger(CompletionItem(name: name, time: "2:34", task: "完成动画预览"))
                self.previewTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3.2))   // 三种完成动画最长 ~2.5s
                    guard let self, !Task.isCancelled else { return }
                    self.questionPrompt.preview(project: name)
                }
            },
            previewBurnout: { [weak self] in
                // 设计稿示例：剩 8% · 25min 见底 · 距重置 4h52m → 断档 4h27m（重度）
                self?.burnoutAlert.present(remainingPct: 8, dropMinutes: 267, timeLeft: 292 * 60)
            })
        if let serverError {
            statusItem?.setInstallStatus(serverError)
        } else if UserDefaults.standard.bool(forKey: Self.uninstalledKey) {
            statusItem?.setInstallStatus("已卸载（菜单可重新安装）")
        } else {
            statusItem?.setInstallStatus(installer.isInstalled() ? "正常" : "失败")
        }

        // 5. 进程对账（启动立即一次，之后 5s）：扫描真实 claude 进程，
        //    没发过事件的会话也立刻显示；进程消失即转无响应/移除。
        syncProcessesNow()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncProcessesNow() }
        }

        // 6. 今日 token 扫描（启动即扫一次，之后 60s；detached 任务在后台线程扫，主 actor 写回）
        let scanner = DailyTokenScanner(projectsDir: claudeDir.appendingPathComponent("projects"))
        let store = self.store
        scanTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let tokens = scanner.scanTodayTokens()
                await MainActor.run { store.todayTokens = tokens }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// 焦点静默：用户正看着该会话的终端 tab → 不打全屏提示（菜单「焦点会话不提示」可关）。
    /// 检测最长 ~400ms（Ghostty 标记探测），不阻塞事件主流程。
    private func triggerUnlessFocused(_ session: Session, kind: String,
                                      _ fire: @escaping @MainActor (AppDelegate) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if TerminalFocus.suppressEnabled {
                let t0 = Date()
                let focused = await TerminalFocus.isFocused(on: session)
                DebugLog.log("trigger[\(kind)] \(session.projectName) pid=\(session.claudePid.map(String.init) ?? "nil") " +
                             "tty=\(session.tty ?? "nil") term=\(session.termProgram ?? "nil") " +
                             "focused=\(focused) dt=\(Int(Date().timeIntervalSince(t0) * 1000))ms → \(focused ? "静默" : "提示")")
                if focused { return }
            } else {
                DebugLog.log("trigger[\(kind)] \(session.projectName) 静默开关关闭 → 提示")
            }
            fire(self)
        }
    }

    /// 焦点判定诊断探针（emit 发 hook_event_name=CCHudFocusProbe 触发）
    private func runFocusProbe(_ env: Envelope) {
        let s = Session(id: "focus-probe", cwd: env.payload.cwd ?? "?",
                        transcriptPath: env.payload.transcriptPath,
                        claudePid: env.claudePid, tty: env.tty, termProgram: env.termProgram,
                        itermSessionId: env.itermSessionId)
        Task { @MainActor in
            let t0 = Date()
            let focused = await TerminalFocus.isFocused(on: s)
            DebugLog.log("probe 判定=\(focused ? "聚焦(会静默)" : "未聚焦(会提示)") " +
                         "dt=\(Int(Date().timeIntervalSince(t0) * 1000))ms " +
                         "pid=\(env.claudePid.map(String.init) ?? "nil") tty=\(env.tty ?? "nil") term=\(env.termProgram ?? "nil")")
        }
    }

    private func syncProcessesNow() {
        let store = self.store
        Task.detached(priority: .utility) {
            let procs = ProcessScanner.scan()
            await MainActor.run { store.syncProcesses(procs) }
        }
    }

    static let uninstalledKey = "install.userUninstalled"

    private func runInstall(force: Bool) {
        if !force && UserDefaults.standard.bool(forKey: Self.uninstalledKey) { return }
        if force { UserDefaults.standard.set(false, forKey: Self.uninstalledKey) }
        do {
            _ = try installer.install()
            statusItem?.setInstallStatus("正常")
        } catch {
            statusItem?.setInstallStatus("失败：\(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanTask?.cancel()
        server?.stop()
    }
}

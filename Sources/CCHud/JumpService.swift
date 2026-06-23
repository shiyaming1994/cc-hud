import AppKit
import CCHudCore
import ApplicationServices

@MainActor
enum JumpService {
    static func jump(to session: Session) {
        switch session.termProgram {
        case "iTerm.app":
            jumpITerm(session)
        case "Apple_Terminal":
            jumpTerminal(session)
        case "ghostty":
            jumpGhostty(session)
        default:
            // vscode 及其分叉（Cursor/Windsurf TERM_PROGRAM 同为 vscode）、Warp/Alacritty/kitty
            // 等任意终端：不猜 bundle id，沿会话进程祖先链找到宿主 GUI App 直接激活
            if !activateHostApp(of: session), session.termProgram == "vscode" {
                activate(bundleId: "com.microsoft.VSCode")   // npm 安装无 pid 时的最后兜底
            }
        }
    }

    /// 沿 claudePid 祖先链找第一个常规 GUI 进程（Dock 可见的 App）并激活。
    private static func activateHostApp(of session: Session) -> Bool {
        guard let pid = session.claudePid else { return false }
        for p in ProcessScanner.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: p),
               app.activationPolicy == .regular {
                app.activate()
                return true
            }
        }
        return false
    }

    // iTerm2：优先 ITERM_SESSION_ID（"w0t2p0:UUID" 取 UUID）；占位会话没有 env，退而按 tty 匹配
    private static func jumpITerm(_ session: Session) {
        let condition: String
        if let raw = session.itermSessionId,
           let uuid = raw.split(separator: ":").last.map(String.init) {
            condition = "unique id of s is \"\(uuid)\""
        } else if let tty = session.tty {
            condition = "tty of s is \"/dev/\(tty)\""
        } else {
            activate(bundleId: "com.googlecode.iterm2")
            return
        }
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(condition) then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        runAppleScript(script, fallbackBundleId: "com.googlecode.iterm2")
    }

    // Terminal.app：按 tty 匹配 tab
    private static func jumpTerminal(_ session: Session) {
        guard let tty = session.tty else {
            activate(bundleId: "com.apple.Terminal")
            return
        }
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        runAppleScript(script, fallbackBundleId: "com.apple.Terminal")
    }

    /// 辅助功能授权提示：每次启动最多弹一次，之后静默降级（避免每次点击都骚扰）。
    private static var axPromptShown = false

    static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !axPromptShown {
            axPromptShown = true
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        return false
    }

    // Ghostty：无 AppleScript 接口。原生 macOS 标签页的关键事实：
    // - kAXWindows 只含每个窗口"当前选中"的 tab；未选中 tab 要从窗口的 AXTabGroup
    //   里找 radio button（其标题 = tab 标题），AXPress 即切换。
    // claude 会把 tab 标题设为会话任务名（transcript 的 ai-title）→ 用它匹配。
    private static func jumpGhostty(_ session: Session) {
        let bundleId = "com.mitchellh.ghostty"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return
        }
        guard ensureAccessibility() else {
            app.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else {
            app.activate()
            return
        }

        // 异步执行：标记轮询最长 ~400ms，不阻塞主线程的其余 UI
        Task { @MainActor in
            // 首选（确定性）：往会话 tty 写一次性标记标题（OSC 0），按标记找 tab，
            // 提升后立刻恢复原标题——与任务标题/同名/新会话完全无关。
            if let tty = session.tty, await jumpByTTYMarker(tty: tty, app: app, axApp: axApp) {
                return
            }
            jumpGhosttyByTitle(session, app: app, windows: windows)
        }
    }

    /// 标题匹配兜底（tmux 等转义被截获、tty 写入失败时）
    private static func jumpGhosttyByTitle(_ session: Session, app: NSRunningApplication,
                                           windows: [AXUIElement]) {
        var needles: [String] = []
        if let t = SessionTitleResolver.title(for: session) {
            needles.append(t)
            needles.append(session.projectName)
        } else {
            // 全新会话还没生成任务标题：tab 是通用标题「✳ Claude Code」，作最后兜底
            needles.append(session.projectName)
            needles.append("Claude Code")
        }

        for needle in needles {
            // 1) 各窗口当前选中 tab（窗口标题）
            for win in windows {
                if axTitle(win)?.localizedCaseInsensitiveContains(needle) == true {
                    raiseWindow(win, app: app)
                    return
                }
            }
            // 2) 各窗口 TabGroup 里的全部 tab（含未选中）。
            // 注意顺序：必须先提升窗口组、再 AXPress 切 tab——
            // win 引用的是旧选中 tab 的 NSWindow，press 之后再 raise 它会把旧 tab 顶回来。
            for win in windows {
                for btn in tabButtons(in: win) {
                    if axTitle(btn)?.localizedCaseInsensitiveContains(needle) == true {
                        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                        app.activate()
                        AXUIElementPerformAction(btn, kAXPressAction as CFString)
                        return
                    }
                }
            }
        }
        app.activate()   // 没匹配上：至少把 Ghostty 带到前台
    }

    /// 经会话 tty 的标记标题定位 tab：写 OSC 标记 → AX 找标题命中的元素 →
    /// 提升窗口（必要时切 tab）→ 恢复原标题。成功返回 true；任何失败静默返回 false 走标题兜底。
    private static func jumpByTTYMarker(tty: String, app: NSRunningApplication,
                                        axApp: AXUIElement) async -> Bool {
        let fd = open("/dev/" + tty, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        struct Snap {
            let el: AXUIElement
            let title: String
            let win: AXUIElement
            let isTab: Bool
        }
        func snapshot() -> [Snap] {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
                  let wins = v as? [AXUIElement] else { return [] }
            var out: [Snap] = []
            for w in wins {
                if let t = axTitle(w) { out.append(Snap(el: w, title: t, win: w, isTab: false)) }
                for b in tabButtons(in: w) {
                    if let t = axTitle(b) { out.append(Snap(el: b, title: t, win: w, isTab: true)) }
                }
            }
            return out
        }

        let before = snapshot()
        let marker = "⌖cchud-" + UUID().uuidString.prefix(8)
        func setTitle(_ s: String) {
            let osc = "\u{1B}]0;\(s)\u{07}"
            _ = osc.withCString { write(fd, $0, strlen($0)) }
        }
        setTitle(marker)
        defer {
            // 恢复原标题：取命中元素在快照里的旧值；找不到就清空（claude 下轮会自己重设）
            let now = snapshot()
            if let hit = now.first(where: { $0.title.contains(marker) }),
               let old = before.first(where: { CFEqual($0.el, hit.el) })?.title {
                setTitle(old)
            } else if now.contains(where: { $0.title.contains(marker) }) {
                setTitle("")
            }
        }

        // 终端消化转义需要一拍：轮询至多 ~400ms
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = snapshot()
            guard let hit = now.first(where: { $0.title.contains(marker) }) else { continue }
            // 已经就在目标上（App 前台 + 窗口为主窗 + tab 已选中）→ 无需任何动作
            var mainRef: CFTypeRef?
            AXUIElementCopyAttributeValue(hit.win, kAXMainAttribute as CFString, &mainRef)
            let winIsMain = (mainRef as? Bool) ?? false
            var tabSelected = true
            if hit.isTab {
                var valRef: CFTypeRef?
                AXUIElementCopyAttributeValue(hit.el, kAXValueAttribute as CFString, &valRef)
                tabSelected = ((valRef as? Int) ?? 0) == 1
            }
            if app.isActive && winIsMain && tabSelected { return true }

            AXUIElementPerformAction(hit.win, kAXRaiseAction as CFString)
            app.activate()
            if hit.isTab {
                AXUIElementPerformAction(hit.el, kAXPressAction as CFString)
            } else {
                AXUIElementSetAttributeValue(hit.win, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            return true
        }
        return false
    }

    /// 只读探测（TerminalFocus 用）：该会话的 Ghostty tab 当前是否就是焦点。
    /// 路 1（主路，零写入）：内容匹配——claude 会把任务标题（transcript 的 ai-title）
    ///   持续写进终端标题，拿它对 AX 窗口/tab 标题做后缀匹配即可定位本会话的 tab。
    ///   流式输出时 claude 每帧重写标题，写入式标记必被冲掉（实测），内容匹配反而最稳。
    /// 路 2（兜底）：OSC 标记探测——标题被 shell 覆盖等场景，安静 tty 下可靠。
    /// 任何不确定 → false ＝ 照常提示。
    static func ghosttyTabIsFocused(_ session: Session) async -> Bool {
        guard AXIsProcessTrusted() else {
            DebugLog.log("ghostty-focus: AX 未授权 → false"); return false
        }
        guard let tty = session.tty else {
            DebugLog.log("ghostty-focus: session 无 tty → false"); return false
        }
        guard let app = NSRunningApplication
                  .runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else {
            DebugLog.log("ghostty-focus: 找不到 ghostty 进程 → false"); return false
        }
        guard app.isActive else {
            DebugLog.log("ghostty-focus: ghostty 非前台 → false"); return false
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // ---- 路 1：标题内容匹配（太短的标题后缀误命中风险高 → 交给兜底）----
        if let task = SessionTitleResolver.title(for: session), task.count >= 4 {
            let snaps = ghosttySnapshot(axApp)
            let hits = snaps.filter { $0.title.hasSuffix(task) }
            if !hits.isEmpty {
                // 同名标题撞车且主从状态不一致 → 分不清是谁 → 保守按未聚焦
                let verdicts = Set(hits.map { ghosttyVerdict($0, app: app) })
                let v = verdicts == [true]
                DebugLog.log("ghostty-focus: 标题匹配「…\(task.suffix(20))」×\(hits.count) → \(v)")
                return v
            }
            DebugLog.log("ghostty-focus: 标题「…\(task.suffix(20))」无匹配（快照: " +
                         snaps.map { "\($0.isTab ? "tab" : "win")「\($0.title.prefix(24))」" }
                             .joined(separator: " ") + "），退回标记探测")
        }

        // ---- 路 2：OSC 标记探测 ----
        let fd = open("/dev/" + tty, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            DebugLog.log("ghostty-focus: open /dev/\(tty) 失败 errno=\(errno) → false"); return false
        }
        defer { close(fd) }

        let before = ghosttySnapshot(axApp)
        let marker = "⌖cchud-" + UUID().uuidString.prefix(8)
        func setTitle(_ s: String) {
            let osc = "\u{1B}]0;\(s)\u{07}"
            _ = osc.withCString { write(fd, $0, strlen($0)) }
        }
        setTitle(marker)
        defer {
            let now = ghosttySnapshot(axApp)
            if let hit = now.first(where: { $0.title.contains(marker) }),
               let old = before.first(where: { CFEqual($0.el, hit.el) })?.title {
                setTitle(old.hasPrefix("⌖cchud-") ? "" : old)   // 残留的旧标记别写回去
            } else {
                // 标记还没传播到 AX（后台窗口可迟到数秒）——无条件排队清空：
                // tty 流有序，清空必然在标记之后应用，标记不可能卡在标题上
                setTitle("")
            }
        }

        // 12×50ms：聚焦窗口的标题传播实测 <100ms，后台窗口/负载尖峰会拖到数百毫秒
        for i in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let hit = ghosttySnapshot(axApp).first(where: { $0.title.contains(marker) }) else {
                setTitle(marker)   // claude 重写标题会冲掉标记——每轮补写
                continue
            }
            let verdict = ghosttyVerdict(hit, app: app)
            DebugLog.log("ghostty-focus: 标记第\(i)轮命中 isTab=\(hit.isTab) → \(verdict)")
            return verdict
        }
        DebugLog.log("ghostty-focus: 12 轮(600ms)未见标记 → false")
        return false
    }

    private typealias GhosttySnap = (el: AXUIElement, title: String, win: AXUIElement, isTab: Bool)

    /// Ghostty 的 AX 标题快照：每个窗口标题 + 各 tab 按钮标题
    private static func ghosttySnapshot(_ axApp: AXUIElement) -> [GhosttySnap] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return [] }
        var out: [GhosttySnap] = []
        for w in wins {
            if let t = axTitle(w) { out.append((w, t, w, false)) }
            for b in tabButtons(in: w) {
                if let t = axTitle(b) { out.append((b, t, w, true)) }
            }
        }
        return out
    }

    /// 命中元素是否"用户正看着的 tab"：App 前台 + 窗口为主窗 + （tab 时）tab 选中
    private static func ghosttyVerdict(_ hit: GhosttySnap, app: NSRunningApplication) -> Bool {
        var mainRef: CFTypeRef?
        AXUIElementCopyAttributeValue(hit.win, kAXMainAttribute as CFString, &mainRef)
        let winIsMain = (mainRef as? Bool) ?? false
        var tabSelected = true
        if hit.isTab {
            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(hit.el, kAXValueAttribute as CFString, &valRef)
            tabSelected = ((valRef as? Int) ?? 0) == 1
        }
        return app.isActive && winIsMain && tabSelected
    }

    private static func raiseWindow(_ win: AXUIElement, app: NSRunningApplication) {
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        app.activate()
    }

    // ---- AX 工具 ----
    private static func axTitle(_ el: AXUIElement) -> String? {
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t) == .success else { return nil }
        return t as? String
    }
    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var c: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success else { return [] }
        return (c as? [AXUIElement]) ?? []
    }
    private static func axRole(_ el: AXUIElement) -> String? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success else { return nil }
        return r as? String
    }
    /// 窗口里的 tab radio buttons（递归找 AXTabGroup，深度限 5）
    private static func tabButtons(in win: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 5 else { return [] }
        var found: [AXUIElement] = []
        for child in axChildren(win) {
            let role = axRole(child)
            if role == "AXTabGroup" {
                found += axChildren(child).filter { axRole($0) == "AXRadioButton" }
            } else {
                found += tabButtons(in: child, depth: depth + 1)
            }
        }
        return found
    }

    private static func activate(bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate()
    }

    private static func runAppleScript(_ source: String, fallbackBundleId: String) {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if error != nil { activate(bundleId: fallbackBundleId) }
    }
}

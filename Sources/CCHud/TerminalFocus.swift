import AppKit
import CCHudCore

/// 「用户焦点是否正落在该会话的终端 tab 上」——是则静默全屏提示（人正看着，无需提醒）。
/// 原则：只有确凿证据才返回 true；任何不确定 → false（宁可多提示，不可漏提示）。
/// 必须做到 tab 级：同一终端 App 开多个 claude tab、焦点在别的 tab 时照常提示。
@MainActor
enum TerminalFocus {
    static let suppressKey = "focus.suppress"
    /// 默认开启（用户拍板：看着的终端不用弹）
    static var suppressEnabled: Bool {
        UserDefaults.standard.object(forKey: suppressKey) as? Bool ?? true
    }
    static func setSuppress(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: suppressKey)
    }

    static func isFocused(on session: Session) async -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            DebugLog.log("focus: 取不到前台 App → false")
            return false
        }
        // 第一道（零成本）：会话宿主 GUI App（沿进程祖先链找）必须就是前台 App
        guard let host = hostApp(of: session) else {
            DebugLog.log("focus: pid=\(session.claudePid.map(String.init) ?? "nil") 找不到宿主 GUI App → false（前台=\(front.localizedName ?? "?")）")
            return false
        }
        guard host.processIdentifier == front.processIdentifier else {
            DebugLog.log("focus: 宿主=\(host.localizedName ?? "?")(\(host.processIdentifier)) ≠ 前台=\(front.localizedName ?? "?")(\(front.processIdentifier)) → false")
            return false
        }
        // 第二道：tab 级确认
        DebugLog.log("focus: 宿主即前台(\(front.localizedName ?? "?"))，进入 tab 级检查 term=\(session.termProgram ?? "nil") tty=\(session.tty ?? "nil")")
        switch session.termProgram {
        case "iTerm.app": return iTermCurrentMatches(session)
        case "Apple_Terminal": return terminalCurrentMatches(session)
        case "ghostty": return await JumpService.ghosttyTabIsFocused(session)
        default:
            DebugLog.log("focus: 未支持的终端 \(session.termProgram ?? "nil") → false")
            return false   // vscode 等：终端面板是否可见无从判断 → 照常提示
        }
    }

    private static func hostApp(of session: Session) -> NSRunningApplication? {
        guard let pid = session.claudePid else { return nil }
        for p in ProcessScanner.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: p),
               app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    // iTerm2：当前窗口当前 tab 的当前 session，比对 unique id（ITERM_SESSION_ID 的 UUID 段）或 tty
    private static func iTermCurrentMatches(_ s: Session) -> Bool {
        let script = """
        tell application "iTerm2" to tell current session of current tab of current window to get (unique id) & "|" & (tty)
        """
        guard let out = runScript(script) else {
            DebugLog.log("iterm-focus: AppleScript 失败（自动化权限/无窗口）→ false")
            return false
        }
        if let raw = s.itermSessionId,
           let uuid = raw.split(separator: ":").last.map(String.init),
           !uuid.isEmpty, out.localizedCaseInsensitiveContains(uuid) {
            DebugLog.log("iterm-focus: unique id 命中 → true")
            return true
        }
        if let tty = s.tty, out.contains("/dev/" + tty) {
            DebugLog.log("iterm-focus: tty 命中 → true")
            return true
        }
        DebugLog.log("iterm-focus: 当前 session=\(out) ≠ 会话(\(s.tty ?? "nil")) → false")
        return false
    }

    // Terminal.app：前窗选中 tab 的 tty
    private static func terminalCurrentMatches(_ s: Session) -> Bool {
        guard let tty = s.tty else { return false }
        let script = #"tell application "Terminal" to get tty of selected tab of front window"#
        return runScript(script) == "/dev/" + tty
    }

    private static func runScript(_ src: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil { return nil }
        return result?.stringValue
    }
}

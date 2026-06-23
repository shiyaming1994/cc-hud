import Foundation
import Darwin
import CCHudCore

// cc-hud-emit：被 Claude Code hooks / statusline 调用的上报工具。
// 用法：emit hook | emit status
// 硬约束：任何路径 exit 0；socket connect 100ms 超时；HUD 未运行时对 Claude Code 零影响。

let home = NSHomeDirectory()
// CC_HUD_SOCK 仅供集成测试隔离使用
let sockPath = ProcessInfo.processInfo.environment["CC_HUD_SOCK"]
    ?? home + "/.claude/cc-hud/hud.sock"
let configPath = home + "/.claude/cc-hud/config.json"
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hook"

// ---- 读 stdin（hook/statusline 的 JSON payload）----
let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// ---- 祖先链找 claude（按可执行路径匹配——p_comm 是版本号，不能用）：返回 (pid, tty) ----
func processInfo(_ pid: pid_t) -> (ppid: pid_t, tdev: Int32)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return (info.kp_eproc.e_ppid, Int32(info.kp_eproc.e_tdev))
}

func findClaudeAncestor() -> (pid: pid_t, tty: String?)? {
    var pid = getppid()
    for _ in 0..<15 {
        guard pid > 1, let info = processInfo(pid) else { return nil }
        if ClaudeProcess.isClaude(pid: pid) {
            var tty: String? = nil
            if info.tdev != -1, let name = devname(dev_t(info.tdev), S_IFCHR) {
                tty = String(cString: name)   // e.g. "ttys002"
            }
            return (pid, tty)
        }
        pid = info.ppid
    }
    return nil
}

// ---- 组信封 ----
/// 大字符串截断（Write/MultiEdit 的 tool_input 可含整个文件内容，超 2MB 会被
/// server 掐掉整条事件——恰好砸在最该显示权限态的大操作上）。UI 最多展示 60 字符。
func truncateStrings(_ any: Any, depth: Int = 0) -> Any {
    if depth > 3 { return any }
    if let s = any as? String, s.count > 2000 { return String(s.prefix(2000)) + "…[截断]" }
    if let arr = any as? [Any] { return arr.map { truncateStrings($0, depth: depth + 1) } }
    if let dict = any as? [String: Any] {
        var out = dict
        for (k, v) in dict { out[k] = truncateStrings(v, depth: depth + 1) }
        return out
    }
    return any
}

func buildEnvelope() -> Data? {
    guard let payload = try? JSONSerialization.jsonObject(with: stdinData) else { return nil }
    var payloadOut = payload
    if var p = payloadOut as? [String: Any], let ti = p["tool_input"] {
        p["tool_input"] = truncateStrings(ti)
        payloadOut = p
    }
    let claude = findClaudeAncestor()
    var envelope: [String: Any] = ["kind": mode == "status" ? "status" : "hook", "payload": payloadOut]
    if let c = claude {
        envelope["claudePid"] = Int(c.pid)
        if let t = c.tty { envelope["tty"] = t }
    } else if let own = processInfo(getpid()), own.tdev != -1,
              let name = devname(dev_t(own.tdev), S_IFCHR) {
        // 找不到 claude 祖先（npm/node 形态安装）：退而取自身控制终端的 tty，
        // 保证会话仍可显示（无 pid → 存活检查跳过，靠 SessionEnd 移除）
        envelope["tty"] = String(cString: name)
    }
    let env = ProcessInfo.processInfo.environment
    if let tp = env["TERM_PROGRAM"] { envelope["termProgram"] = tp }
    if let iterm = env["ITERM_SESSION_ID"] { envelope["itermSessionId"] = iterm }
    return try? JSONSerialization.data(withJSONObject: envelope)
}

// ---- 写 socket：非阻塞 connect，100ms 超时；失败静默 ----
func sendToSocket(_ data: Data) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    sockPath.withCString { src in
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    if rc != 0 {
        guard errno == EINPROGRESS else { return }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 100) > 0, pfd.revents & Int16(POLLOUT) != 0 else { return }
        var soErr: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
        guard soErr == 0 else { return }
    }
    // 回到阻塞模式写（数据可能大于缓冲区）
    flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

if let envelope = buildEnvelope() {
    sendToSocket(envelope)
}

// ---- status 模式：透传原 statusline（终端显示保持不变）；无原配置则输出最简默认 ----
if mode == "status" {
    var original: String? = nil
    if let cfgData = FileManager.default.contents(atPath: configPath),
       let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
       let cmd = cfg["originalStatusLine"] as? String, !cmd.isEmpty {
        original = cmd
    }
    if let original {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")   // 与 CC 执行 statusline 的 shell 惯例一致
        p.arguments = ["-c", original]
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        if (try? p.run()) != nil {
            inPipe.fileHandleForWriting.write(stdinData)
            inPipe.fileHandleForWriting.closeFile()
            p.waitUntilExit()
        }
    } else if let payload = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] {
        // 默认状态栏：模型 · 目录（接入前没有 statusline 的用户不至于一片空白）
        let model = (payload["model"] as? [String: Any])?["display_name"] as? String ?? ""
        let dir = ((payload["cwd"] as? String ?? "") as NSString).lastPathComponent
        print([model, dir].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}
exit(0)

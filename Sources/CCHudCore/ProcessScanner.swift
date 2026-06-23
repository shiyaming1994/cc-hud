import Foundation
import Darwin

/// 扫描系统中的 claude 交互进程：pid、tty、cwd、宿主终端 App。
/// 过滤规则：默认只要有 tty 的（交互式），且祖先链里没有另一个目标进程（排除子进程/一次性 claude -p）。
public enum ProcessScanner {
    /// 祖先 comm（16 字符截断）→ TERM_PROGRAM 风格标识
    private static let terminalMap: [(prefix: String, term: String)] = [
        ("ghostty", "ghostty"),
        ("iTerm2", "iTerm.app"),
        ("Terminal", "Apple_Terminal"),
        ("Electron", "vscode"),
        ("Code Helper", "vscode"),
    ]

    public static func scan(isTarget: (pid_t) -> Bool = { ClaudeProcess.isClaude(pid: $0) },
                            includeTTYless: Bool = false,
                            skipNested: Bool = true) -> [DiscoveredProcess] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }

        let myUid = getuid()
        var result: [DiscoveredProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard isTarget(pid), let info = kinfo(pid),
                  info.uid == myUid else { continue }   // 共享 Mac：别人的会话不进自己的 HUD
            let tty = ttyName(info.tdev)
            if tty == nil && !includeTTYless { continue }

            // 祖先链：排除嵌套目标进程；顺便识别宿主终端
            var termProgram: String? = nil
            var nested = false
            var p = info.ppid
            for _ in 0..<20 {
                guard p > 1, let pi = kinfo(p) else { break }
                if skipNested, isTarget(p) { nested = true; break }
                if termProgram == nil {
                    termProgram = terminalMap.first { pi.comm.hasPrefix($0.prefix) }?.term
                }
                p = pi.ppid
            }
            if nested { continue }

            result.append(DiscoveredProcess(pid: pid, tty: tty, cwd: cwdPath(pid), termProgram: termProgram))
        }
        return result
    }

    /// 祖先 PID 链（不含自身，至多 maxDepth 层）——用于反查宿主 GUI App
    public static func ancestors(of pid: pid_t, maxDepth: Int = 25) -> [pid_t] {
        var out: [pid_t] = []
        var p = pid
        for _ in 0..<maxDepth {
            guard let info = kinfo(p), info.ppid > 1 else { break }
            out.append(info.ppid)
            p = info.ppid
        }
        return out
    }

    static func kinfo(_ pid: pid_t) -> (ppid: pid_t, comm: String, tdev: Int32, uid: uid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        guard !comm.isEmpty else { return nil }
        return (info.kp_eproc.e_ppid, comm, Int32(info.kp_eproc.e_tdev), info.kp_eproc.e_ucred.cr_uid)
    }

    static func ttyName(_ tdev: Int32) -> String? {
        guard tdev != -1, let name = devname(dev_t(tdev), S_IFCHR) else { return nil }
        return String(cString: name)
    }

    static func cwdPath(_ pid: pid_t) -> String? {
        var vinfo = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vinfo,
                                Int32(MemoryLayout<proc_vnodepathinfo>.stride))
        guard size > 0 else { return nil }
        return withUnsafeBytes(of: vinfo.pvi_cdir.vip_path) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

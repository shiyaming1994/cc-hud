import Foundation
import Darwin

/// claude 主进程判定。
/// 注意：claude launcher 会 exec 版本号命名的真实二进制（如 ~/.local/share/claude/versions/2.1.170），
/// 所以 p_comm 是 "2.1.170" 而不是 "claude"——必须按可执行路径匹配。
/// （npm/node 形态的安装跑在 node 进程里，此规则不覆盖，相关功能自动降级。）
public enum ClaudeProcess {
    public static func isClaude(path: String) -> Bool {
        let base = (path as NSString).lastPathComponent
        if base == "claude" { return true }
        return path.contains("/claude/versions/")
    }

    public static func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public static func isClaude(pid: pid_t) -> Bool {
        guard let p = pidPath(pid) else { return false }
        return isClaude(path: p)
    }
}

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
        // 优先用实际可执行路径判定；当 claude 自动升级把旧版本二进制清理删除后，
        // proc_pidpath 会失败（macOS 对已删除的可执行文件不返回路径）——此时回退到
        // execve 记录的 exec_path（KERN_PROCARGS2，进程启动时拷贝、不依赖文件存在）。
        // 否则跨越多次升级的长寿会话会被漏扫，且存活对账(syncProcesses)会误判其无响应。
        if let p = pidPath(pid) { return isClaude(path: p) }
        if let e = execPath(pid) { return isClaude(path: e) }
        return false
    }

    /// execve 时内核记录的可执行路径（KERN_PROCARGS2 头部段）。二进制即便随版本升级被删，此串仍在。
    static func execPath(_ pid: pid_t) -> String? {
        let headerSize = MemoryLayout<CInt>.stride      // 头部是 int argc，exec_path 紧随其后
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > headerSize else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        var end = headerSize
        while end < buf.count, buf[end] != 0 { end += 1 }   // exec_path 读到第一个 \0
        guard end > headerSize else { return nil }
        return String(decoding: buf[headerSize..<end], as: UTF8.self)
    }
}

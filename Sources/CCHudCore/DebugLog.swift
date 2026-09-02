import Foundation

/// 现场诊断日志（默认关闭，零开销）：
/// `defaults write io.github.shiyaming.cc-hud debug.log -bool true` 开启后追加到 /tmp/cchud-debug.log。
/// 用于排查肉眼不可见的链路：焦点静默判定、事件解码失败等。
public enum DebugLog {
    public static let key = "debug.log"
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    private static let path = "/tmp/cchud-debug.log"

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Self.timestamp()) \(message())\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    /// 每个限速键上次落盘的时刻。EventServer 的解码全在同一条串行队列上跑（cc-hud.event-server），
    /// 这里只被它调用，故不加锁；nonisolated(unsafe) 是对这个前提的显式声明。
    nonisolated(unsafe) private static var lastDumpAt: [String: Date] = [:]

    /// 限速判据（纯函数，便于单测）：同一个键在 minInterval 内只放行一次。
    /// 被挡掉的调用**不刷新**时间戳，否则高频事件会把窗口一路往后推、永远落不了盘。
    static func allowDump(key: String, at now: Date, minInterval: TimeInterval,
                          last: inout [String: Date]) -> Bool {
        guard minInterval > 0 else { return true }
        if let t = last[key], now.timeIntervalSince(t) < minInterval { return false }
        last[key] = now
        return true
    }

    /// 原始报文落盘（同一开关）。
    /// - label: 文件名里的分类，只影响落盘路径。
    /// - rateKey: 限速键，缺省同 label。**多来源的高频事件必须按来源给键**——比如 status
    ///   由每个已开会话各自上报，按 label 限速会让最活跃的会话吃光配额，样本里永远看不到
    ///   闲置会话报了什么。
    /// - minInterval: 同一限速键的最小落盘间隔，挂在高频事件上时必须给（status 事件实测
    ///   可达 2 条/300ms，不限速的话调试开关忘关就会在 /tmp 堆出成千上万个碎文件）。
    public static func dump(_ data: Data, label: String, rateKey: String? = nil,
                            minInterval: TimeInterval = 0) {
        guard enabled else { return }
        guard allowDump(key: rateKey ?? label, at: Date(), minInterval: minInterval,
                        last: &lastDumpAt) else { return }
        let p = "/tmp/cchud-\(label)-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        try? data.write(to: URL(fileURLWithPath: p))
        log("dumped \(label) → \(p) (\(data.count)B)")
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func timestamp() -> String { fmt.string(from: Date()) }
}

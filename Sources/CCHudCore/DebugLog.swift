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

    /// 解码失败的原始报文落盘（同一开关），返回落盘路径
    public static func dump(_ data: Data, label: String) {
        guard enabled else { return }
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

import Foundation

/// 系统中扫描到的一个交互式 claude 进程（事件到来前的"地面真相"）。
public struct DiscoveredProcess: Sendable {
    public let pid: Int32
    public let tty: String?
    public let cwd: String?
    public let termProgram: String?

    public init(pid: Int32, tty: String?, cwd: String?, termProgram: String?) {
        self.pid = pid
        self.tty = tty
        self.cwd = cwd
        self.termProgram = termProgram
    }
}

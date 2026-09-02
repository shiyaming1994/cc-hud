import Foundation

public enum EventServerError: LocalizedError {
    /// 已有活实例在监听同一 socket——本实例让位,绝不抢占。
    /// 抢占(unlink+bind)会把先来者变成聋子:它监听已删除的 inode,事件全进黑洞
    /// 且毫无感知(额度冻结/会话永远计时)。见 2026-07-03 开发实例抢占事故。
    case alreadyRunning
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "已有 CC HUD 实例在监听事件(本实例让位)"
        }
    }
}

/// Unix domain socket 服务器。每连接一条 JSON（EOF 为界），解码成 Envelope 回调。
/// 回调在内部串行队列触发，调用方自行 hop 到 MainActor。
public final class EventServer: @unchecked Sendable {
    private let socketPath: String
    private let onEnvelope: @Sendable (Envelope) -> Void
    private let onDecodeFailure: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "cc-hud.event-server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    private static let maxPayload = 2 * 1024 * 1024

    public init(socketPath: String, onEnvelope: @escaping @Sendable (Envelope) -> Void,
                onDecodeFailure: (@Sendable () -> Void)? = nil) {
        self.socketPath = socketPath
        self.onEnvelope = onEnvelope
        self.onDecodeFailure = onDecodeFailure
    }

    public func start() throws {
        // bind 前探测:能连通 = 有活实例在监听 → 让位。连不通(refused/不存在/非 socket)
        // 才是无主残留,照常清理接管。正常覆盖升级时旧实例已被 terminate 等待退出,不受影响。
        if Self.isSocketAlive(at: socketPath) { throw EventServerError.alreadyRunning }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = Self.makeAddr(socketPath)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for (fd, conn) in connections { conn.source.cancel(); close(fd) }
            connections.removeAll()
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            // 不 unlink：覆盖升级时旧实例退出晚于新实例 bind，unlink 会删掉
            // 新实例的 socket 文件（升级竞态）。残留文件由下次 start() 清理，
            // 无监听者的 stale socket 对 emit 只是立即 ECONNREFUSED，无害。
        }
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        connections[fd] = (source, Data())
        source.setEventHandler { [weak self] in self?.readConnection(fd) }
        source.resume()
    }

    private func readConnection(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            connections[fd]?.buffer.append(contentsOf: buf[0..<n])
            if let size = connections[fd]?.buffer.count, size > Self.maxPayload {
                closeConnection(fd)
            }
            return
        }
        // n == 0: EOF → 解码；n < 0: 错误 → 丢弃
        if n == 0, let data = connections[fd]?.buffer, !data.isEmpty {
            if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
                // 额度对不上时的唯一取证手段：Claude Code 发来的原始 status 报文
                // （含我们没解的字段）。默认关闭,开:
                // defaults write io.github.shiyaming.cc-hud debug.log -bool true
                // 10s 限速：status 是高频事件，取证要的是"当前值长什么样"，不是每一条
                if env.kind == "status" { DebugLog.dump(data, label: "status", minInterval: 10) }
                onEnvelope(env)
            } else if let env = Self.minimalEnvelope(from: data) {
                // schema 漂移（某字段类型变化）：宽松提取核心字段，生命周期照常工作
                onEnvelope(env)
                onDecodeFailure?()
                DebugLog.dump(data, label: "decode-drift")
            } else {
                onDecodeFailure?()
                DebugLog.dump(data, label: "decode-fail")
            }
        }
        closeConnection(fd)
    }

    private func closeConnection(_ fd: Int32) {
        connections[fd]?.source.cancel()
        connections[fd] = nil
        close(fd)
    }

    private static func makeAddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
        return addr
    }

    /// 该路径上是否有活实例在监听。unix socket 对活监听者 connect 立即成功、
    /// 对无主残留立即 ECONNREFUSED,无需超时。
    static func isSocketAlive(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = makeAddr(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return rc == 0
    }

    /// 严格解码失败时的兜底：只提取生命周期必需的核心字段重建信封。
    static func minimalEnvelope(from data: Data) -> Envelope? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        if let v = obj["kind"] as? String { out["kind"] = v }
        if let v = obj["claudePid"] as? Int { out["claudePid"] = v }
        for k in ["tty", "termProgram", "itermSessionId"] {
            if let v = obj[k] as? String { out[k] = v }
        }
        var p: [String: Any] = [:]
        if let payload = obj["payload"] as? [String: Any] {
            for k in ["hook_event_name", "session_id", "cwd", "transcript_path", "tool_name"] {
                if let v = payload[k] as? String { p[k] = v }
            }
        }
        out["payload"] = p
        guard let mini = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: mini)
    }
}

import Foundation

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
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                _ = strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
            }
        }
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

import Foundation
import CCHudCore

/// 会话的"任务标题"（claude 写进 transcript 的 ai-title，也是它设置的终端标题）。
/// 占位会话（无 transcriptPath）按 cwd 反查项目目录里最近修改的 transcript。
enum SessionTitleResolver {
    static func title(for session: Session) -> String? {
        let path = session.transcriptPath ?? latestTranscript(forCwd: session.cwd)
        guard let path, let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let window: UInt64 = 512 * 1024
        let readLen = min(size, window)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.readToEnd() else { return nil }
        if let t = lastTitle(in: data) { return t }
        // 尾窗未命中（相邻 ai-title 间隔可超过窗口）：回扫文件头部一段
        //（首个 ai-title 通常在文件很靠前的位置）
        if size > readLen {
            try? fh.seek(toOffset: 0)
            if let head = try? fh.read(upToCount: 256 * 1024), let t = lastTitle(in: head) {
                return t
            }
        }
        return nil
    }

    private static func lastTitle(in data: Data) -> String? {
        let marker = Data("ai-title".utf8)
        var title: String? = nil
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let lineData = Data(line)
            guard lineData.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let t = obj["aiTitle"] as? String, !t.isEmpty else { continue }
            title = t
        }
        return title
    }

    static func latestTranscript(forCwd cwd: String) -> String? {
        let slug = ClaudeProjects.slug(forCwd: cwd)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").appendingPathComponent(slug)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        let newest = files.max { a, b in
            let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ma < mb
        }
        return newest?.path
    }
}

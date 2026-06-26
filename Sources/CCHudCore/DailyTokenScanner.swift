import Foundation

/// 今日 token 扫描（口径与 statusline.sh / ccusage 一致：
/// message.id // uuid 去重，input + output + cache_creation + cache_read 合计）。
///
/// 增量解析：transcript 是只追加的 JSONL——按文件记录已消费的字节偏移，
/// 每轮只读取并解析新增的完整行（残尾留待下次）；文件收缩视为重写，重置该文件缓存。
/// 未变化的文件零成本。仅设计为单一后台任务串行调用。
public final class DailyTokenScanner: @unchecked Sendable {
    private struct Entry {
        let ts: String      // ISO 时间戳（字典序可比）
        let id: String
        let tokens: Int
    }
    private struct FileCache {
        var offset: UInt64 = 0
        var entries: [Entry] = []
    }

    let projectsDir: URL
    let calendar: Calendar
    private var cache: [String: FileCache] = [:]

    public init(projectsDir: URL, calendar: Calendar = .current) {
        self.projectsDir = projectsDir
        self.calendar = calendar
    }

    public func scanTodayTokens(now: Date = Date()) -> Int {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]   // UTC，无毫秒；前缀字典序与 jsonl 时间戳兼容
        let startISO = fmt.string(from: dayStart)
        let endISO = fmt.string(from: dayEnd)

        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return 0 }

        let cutoff = now.addingTimeInterval(-86400)
        var liveFiles = Set<String>()

        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = rv.contentModificationDate, mtime >= cutoff else { continue }
            let path = url.path
            liveFiles.insert(path)
            let size = UInt64(rv.fileSize ?? 0)

            var fc = cache[path] ?? FileCache()
            if size < fc.offset { fc = FileCache() }          // 文件被重写 → 重置
            if size > fc.offset, let fh = FileHandle(forReadingAtPath: path) {
                defer { try? fh.close() }
                try? fh.seek(toOffset: fc.offset)
                if let data = try? fh.readToEnd(), !data.isEmpty {
                    var lineStart = data.startIndex
                    var consumed = 0
                    while let nl = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                        parse(line: data[lineStart..<nl], into: &fc)
                        consumed = data.distance(from: data.startIndex, to: nl) + 1
                        lineStart = data.index(after: nl)
                    }
                    // 未换行的尾巴：若已是完整 JSON 就消费（文件结尾无换行的情况）；
                    // 否则视为写入中，留待下次
                    if lineStart < data.endIndex {
                        let tail = data[lineStart...]
                        if (try? JSONSerialization.jsonObject(with: Data(tail))) != nil {
                            parse(line: tail, into: &fc)
                            consumed = data.count
                        }
                    }
                    fc.offset += UInt64(consumed)
                }
            }
            cache[path] = fc
        }
        cache = cache.filter { liveFiles.contains($0.key) }   // 滑出 24h 窗口的文件淘汰

        // 裁掉非当天条目：长会话文件持续追加，不裁剪 entries 会把历史行无界堆在内存里。
        // 非当天条目本就不计入合计，安全删除（offset 不动，下次增量解析照常续）。
        for key in Array(cache.keys) {
            cache[key]?.entries.removeAll { $0.ts < startISO }
        }

        var seen = Set<String>()
        var total = 0
        for fc in cache.values {
            for e in fc.entries where e.ts < endISO {
                if seen.insert(e.id).inserted { total += e.tokens }
            }
        }
        return total
    }

    private func parse(line: Data.SubSequence, into fc: inout FileCache) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let id = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
        let tokens = (usage["input_tokens"] as? Int ?? 0)
            + (usage["output_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        fc.entries.append(Entry(ts: ts, id: id, tokens: tokens))
    }
}

import CoreGraphics
import Foundation

/// 一块在场显示器：持久身份 + 它在全局排列里的位置。
///
/// `bounds` 用 **CG 全局系**（左上原点、y 向下），即 `CGDisplayBounds` 的原值——
/// 与 AX 的 `kAXPosition` 同系，所以这一层不做任何坐标翻转。
/// （`NSScreen.frame` 是 Cocoa 系，同一块屏的 y 完全不同，别混进来。）
public struct ScreenBox: Equatable, Sendable {
    public let uuid: String
    public let bounds: CGRect
    public init(uuid: String, bounds: CGRect) {
        self.uuid = uuid
        self.bounds = bounds
    }
}

/// 一个窗口的存档位置：**哪块屏 + 屏内偏移**，而不是全局坐标。
///
/// 非如此不可：同一块外接屏的全局原点会随显示器组合变化而漂移
/// （实测同一台屏三屏时在 (783,-1080)、单接时在 (1728,0)）。
/// 存全局坐标既存不住「在哪块屏」，重连后还会算出一个完全错误的位置。
public struct WindowLayout: Equatable, Sendable, Codable {
    public let screen: String      // displayUUID
    public let offset: CGPoint     // 相对该屏左上角
    public let size: CGSize
    public init(screen: String, offset: CGPoint, size: CGSize) {
        self.screen = screen
        self.offset = offset
        self.size = size
    }
}

/// 窗口布局档案：按**显示器组合**分桶存放各窗口的位置。
///
/// 分桶是整个方案能自动捕获的前提：拔掉外接屏后指纹变了，系统把窗口搬到内置屏所触发的
/// 捕获会写进「单屏」那个桶，「三屏」那桶的好布局分毫不动。没有分桶的话，自动捕获会在
/// 拔线后的几秒里把自己要恢复的东西覆盖掉。
///
/// 白捡的好处：公司双屏、家里单屏、纯笔记本各记各的，互不干扰。
public struct WindowLayoutStore {
    /// v3：条目多了「最后一次见到」的时间戳（见 seen）。存档结构变了，旧档解不出来
    /// 即丢弃 —— 真窗口在下一次捕获(挂观察者时即刻发生)就重新记上。
    public static let archiveKey = "layout.archive.v3"

    private var buckets: [String: [String: WindowLayout]] = [:]
    /// 每个窗口最后一次被看见的时刻。**按窗口记而不是按配置记**：窗口一旦关掉，
    /// 就该从所有显示器配置的档案里一起消失。
    private var seen: [String: Date] = [:]

    private struct Archive: Codable {
        var buckets: [String: [String: WindowLayout]]
        var seen: [String: Date]
    }

    public init() {}

    /// 从存档载入。**非有不可**：用户的真实流程是下班拔线、第二天才插回，
    /// 中间十几个小时里没有任何「重新学习」的机会——cc-hud 若在这期间重启过
    /// （手动装更新、崩溃、注销），内存档案一清，第二天就是静默失效。
    /// 坏档案一律退回空：这功能再有用也不能让 app 起不来。
    public init(loadingFrom defaults: UserDefaults, now: Date = Date()) {
        guard let data = defaults.data(forKey: Self.archiveKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else { return }
        buckets = archive.buckets
        seen = archive.seen
        // 缺时间戳的条目按「刚见过」补戳：缺失是未知，不是陈旧。误删一条的代价是
        // 第二天那个窗口不归位，比多留几条死条目贵得多。
        for wins in buckets.values {
            for key in wins.keys where seen[key] == nil { seen[key] = now }
        }
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Archive(buckets: buckets, seen: seen))
        else { return }
        defaults.set(data, forKey: Self.archiveKey)
    }

    /// 清掉 cutoff 之前就没再见过的窗口。关掉的窗口否则会永远赖在档案里：
    /// record 只增不删，用户开开关关几天就能攒出十几条死条目。
    ///
    /// **只能按时间，不能按「当前不在场」**：锁屏时 kAXWindows 返回空列表（实测），
    /// 按在场与否清理会在每天早上把整个档案清光 —— 那正是最需要它的时刻。
    public mutating func prune(notSeenSince cutoff: Date) {
        let dead = Set(seen.filter { $0.value < cutoff }.map(\.key))
        guard !dead.isEmpty else { return }
        for key in dead { seen[key] = nil }
        buckets = buckets.compactMapValues { wins in
            let kept = wins.filter { !dead.contains($0.key) }
            return kept.isEmpty ? nil : kept
        }
    }

    /// 显示器组合的指纹 = 在场 UUID 排序后拼接。
    ///
    /// **排序**：两块屏的上电顺序每次都可能不同（实测），枚举顺序不能影响分桶。
    /// **不含分辨率**：内置屏会随外接屏的有无自己切缩放档（实测 1496×967 ↔ 1728×1117），
    /// 分辨率进指纹会把同一组显示器拆成两个桶。
    public static func fingerprint(of screens: [ScreenBox]) -> String {
        screens.map(\.uuid).sorted().joined(separator: "|")
    }

    /// 全局 frame → 存档。归属屏 = 与窗口**覆盖面积最大**的那块（一条规则同时处理跨屏与摆位空隙）。
    /// 不落在任何屏上 → nil，不入档：存了也还原不回来。
    public static func capture(frame: CGRect, on screens: [ScreenBox]) -> WindowLayout? {
        var host: ScreenBox?
        var bestArea: CGFloat = 0
        for s in screens {
            let hit = s.bounds.intersection(frame)
            guard !hit.isNull else { continue }
            let area = hit.width * hit.height
            if area > bestArea {
                bestArea = area
                host = s
            }
        }
        guard let host else { return nil }
        return WindowLayout(screen: host.uuid,
                            offset: CGPoint(x: frame.minX - host.bounds.minX,
                                            y: frame.minY - host.bounds.minY),
                            size: frame.size)
    }

    /// 存档 → 全局 frame。存档屏不在场 → nil，调用方据此跳过：
    /// 宁可不动这个窗口，也不能把它瞎塞到别的屏上。
    public static func frame(for layout: WindowLayout, on screens: [ScreenBox]) -> CGRect? {
        guard let s = screens.first(where: { $0.uuid == layout.screen }) else { return nil }
        return CGRect(x: s.bounds.minX + layout.offset.x,
                      y: s.bounds.minY + layout.offset.y,
                      width: layout.size.width, height: layout.size.height)
    }

    public mutating func record(_ layout: WindowLayout, forWindow key: String,
                                fingerprint: String, at now: Date = Date()) {
        buckets[fingerprint, default: [:]][key] = layout
        seen[key] = now
    }

    /// 一轮捕获落档：先记下这轮看见的窗口，再清掉保质期内一次都没见过的。
    ///
    /// **先记再清**：长假回来头一回看见某个窗口时，它的时间戳早已过期 —— 先清的话，
    /// 它在别的显示器组合里的记录会被当成陈旧一起删掉，当晚拔线就无档可用。
    ///
    /// **这轮一个都没看见就不清理**：锁屏、刚唤醒时 AX 答不上来，kAXWindows 要么返回空、
    /// 要么返回的窗口全被过滤掉（实测两种都有）。这时的「0 个」是看不见，不是都关了。
    /// 照常清理的话，隔了保质期以上回来的那个早上（国庆实测隔了 7 天 16 小时），
    /// 锁屏时补做的这一轮会把整个档案删光，解锁后的恢复无档可用。
    public mutating func recordCapture(_ windows: [String: WindowLayout], fingerprint: String,
                                       ttl: TimeInterval, at now: Date = Date()) {
        for (key, layout) in windows {
            record(layout, forWindow: key, fingerprint: fingerprint, at: now)
        }
        guard !windows.isEmpty else { return }
        prune(notSeenSince: now.addingTimeInterval(-ttl))
    }

    public func layout(forWindow key: String, fingerprint: String) -> WindowLayout? {
        buckets[fingerprint]?[key]
    }

    /// 整桶。恢复要遍历档案里的全部窗口，而不是只看这轮收到过通知的那些。
    public func all(fingerprint: String) -> [String: WindowLayout] {
        buckets[fingerprint] ?? [:]
    }
}

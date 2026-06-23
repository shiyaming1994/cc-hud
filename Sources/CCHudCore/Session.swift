import Foundation

public enum SessionStatus: String, Sendable, CaseIterable {
    case permission, working, idle, dead

    /// 紧急度，越小越靠前
    public var urgency: Int {
        switch self {
        case .permission: return 0
        case .working: return 1
        case .idle: return 2
        case .dead: return 3
        }
    }
}

public struct Session: Identifiable, Sendable {
    public let id: String              // session_id
    public var cwd: String
    public var transcriptPath: String?
    public var claudePid: Int32?
    public var tty: String?
    public var termProgram: String?
    public var itermSessionId: String?
    public var status: SessionStatus
    public var activity: String
    public var pendingCommand: String?    // 最近一次 PreToolUse 的格式化命令
    public var permissionCommand: String? // 等待权限时展示的命令
    public var roundStart: Date           // 本轮起点（UserPromptSubmit / 转 dead 时刻）
    public var lastEventAt: Date
    public var createdAt: Date
    public var ctxPct: Double?
    public var model: String?
    public var justDoneUntil: Date?
    public var deadSince: Date?
    public var compactStartedAt: Date? = nil   // 手动 /compact 起点（PreCompact manual）
    public var questionPendingAt: Date? = nil  // AskUserQuestion 等待选择起点（去重 + 提示生命周期）

    public var projectName: String { (cwd as NSString).lastPathComponent }

    public init(id: String, cwd: String, transcriptPath: String? = nil,
                claudePid: Int32? = nil, tty: String? = nil, termProgram: String? = nil,
                itermSessionId: String? = nil, status: SessionStatus = .idle, activity: String = "",
                pendingCommand: String? = nil, permissionCommand: String? = nil,
                roundStart: Date = Date(), lastEventAt: Date = Date(), createdAt: Date = Date(),
                ctxPct: Double? = nil, model: String? = nil, justDoneUntil: Date? = nil,
                deadSince: Date? = nil, compactStartedAt: Date? = nil, questionPendingAt: Date? = nil) {
        self.id = id
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.claudePid = claudePid
        self.tty = tty
        self.termProgram = termProgram
        self.itermSessionId = itermSessionId
        self.status = status
        self.activity = activity
        self.pendingCommand = pendingCommand
        self.permissionCommand = permissionCommand
        self.roundStart = roundStart
        self.lastEventAt = lastEventAt
        self.createdAt = createdAt
        self.ctxPct = ctxPct
        self.model = model
        self.justDoneUntil = justDoneUntil
        self.deadSince = deadSince
        self.compactStartedAt = compactStartedAt
        self.questionPendingAt = questionPendingAt
    }
}

public struct AccountUsage: Sendable, Equatable {
    public var fiveHourUsedPct: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayUsedPct: Double?
    public var sevenDayResetsAt: Date?
    public init() {}

    public static let fiveHourPeriod: TimeInterval = 5 * 3600
    public static let sevenDayPeriod: TimeInterval = 7 * 24 * 3600

    /// 按当前时间把"过期窗口"本地校正：resets_at 一旦过去，该窗口必然已重置——
    /// 用量归零、重置点按固定周期滚到当前所在窗口。额度/倒计时是事件驱动的，
    /// 归零后没人干活就收不到新快照，会卡在旧值；休眠唤醒后时间跳变同理。
    /// 这个投影只在"过期 + 无新事件"时生效，那一刻真实用量本就接近 0；
    /// 一有真实快照，absorbWindow 立刻用真实值覆盖。
    public static func project(usedPct: Double?, resetsAt: Date?, period: TimeInterval, now: Date)
        -> (usedPct: Double?, resetsAt: Date?) {
        guard let resetsAt, now >= resetsAt, period > 0 else { return (usedPct, resetsAt) }
        var next = resetsAt
        while next <= now { next += period }
        return (0, next)
    }

    /// 剩余低于此即告警（整条高亮 + 最小胶囊冒出提醒）
    public static let lowQuotaRemainPct: Double = 20

    /// 投影到 now 后，剩余 < lowQuotaRemainPct 的最紧张窗口（两个都不低 → nil）。
    /// 给最小胶囊用：平时不显示额度，只在某个窗口快见底时把它顶出来。
    public func alertWindow(now: Date) -> (label: String, remainPct: Double, resetsAt: Date?)? {
        var cands: [(label: String, remainPct: Double, resetsAt: Date?)] = []
        let h5 = Self.project(usedPct: fiveHourUsedPct, resetsAt: fiveHourResetsAt,
                              period: Self.fiveHourPeriod, now: now)
        if let u = h5.usedPct { cands.append(("5h", 100 - u, h5.resetsAt)) }
        let d7 = Self.project(usedPct: sevenDayUsedPct, resetsAt: sevenDayResetsAt,
                              period: Self.sevenDayPeriod, now: now)
        if let u = d7.usedPct { cands.append(("7d", 100 - u, d7.resetsAt)) }
        return cands.filter { $0.remainPct < Self.lowQuotaRemainPct }.min { $0.remainPct < $1.remainPct }
    }

    /// 5h 燃尽预测：按"已用 ÷ 已过时间"的速率外推，会不会在重置前提前把额度烧光。
    /// 返回（断档分钟数 = 比重置提前多久耗尽，窗口重置时刻 = 去重标识）。
    /// 数据不足 / 预热期内（窗口刚开头速率噪声大）/ 不会提前耗尽 / 断档 < 阈值 → nil。
    public func burnoutForecast(now: Date,
                                warmupFraction: Double = 0.1,
                                minDropMinutes: Double = 30)
        -> (dropMinutes: Double, windowResetsAt: Date, remainingPct: Double)? {
        let period = Self.fiveHourPeriod
        let p = Self.project(usedPct: fiveHourUsedPct, resetsAt: fiveHourResetsAt, period: period, now: now)
        guard let used = p.usedPct, let resetsAt = p.resetsAt else { return nil }
        let timeLeft = resetsAt.timeIntervalSince(now)
        guard timeLeft > 0 else { return nil }
        let elapsed = period - timeLeft
        guard elapsed >= period * warmupFraction, used > 0 else { return nil }   // 预热期内不判断
        let remain = 100 - used
        guard remain > 0 else { return nil }                  // 已耗尽，不属"预测"范畴
        let burnRate = used / elapsed                          // %/秒
        let timeToExhaust = remain / burnRate                  // 按此速率还能撑多久（秒）
        let dropSeconds = timeLeft - timeToExhaust             // 提前耗尽量 = 断档时长
        guard dropSeconds >= minDropMinutes * 60 else { return nil }
        return (dropMinutes: dropSeconds / 60, windowResetsAt: resetsAt, remainingPct: remain)
    }

    /// 断档分钟数 → 预警档位（0=不警，1=30min+，2=1h+，3=2h+）。只在升档时弹，平稳不烦。
    public static func burnoutTier(dropMinutes: Double) -> Int {
        if dropMinutes >= 120 { return 3 }
        if dropMinutes >= 60 { return 2 }
        if dropMinutes >= 30 { return 1 }
        return 0
    }
}

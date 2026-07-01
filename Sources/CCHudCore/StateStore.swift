import Foundation
import Observation

@MainActor
@Observable
public final class StateStore {
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var account = AccountUsage()
    public var todayTokens: Int?
    /// 事件链路健康：最近一条事件到达时间 / 解码失败计数（菜单诊断用）
    public private(set) var lastEventReceivedAt: Date?
    public private(set) var decodeFailures = 0

    public func noteDecodeFailure() { decodeFailures += 1 }

    /// 会话从 working/permission 转 idle（真正"完成一轮"）时回调：(完成时的会话, 本轮耗时秒)。
    @ObservationIgnored public var onCompletion: (@MainActor (Session, TimeInterval) -> Void)?
    /// 手动 /compact 完成时回调：(会话, 压缩耗时秒)。
    /// 链路：PreCompact(trigger=manual) 记起点 → 压缩完毕 claude 在同一会话发 SessionStart(source=compact)。
    @ObservationIgnored public var onCompactDone: (@MainActor (Session, TimeInterval) -> Void)?
    /// 会话进入「等待选择」（AskUserQuestion 提问）回调：(会话, 解析出的问题)。
    /// PreToolUse 与紧随的 PermissionRequest 都带该工具名，以 questionPendingAt 去重只发一次。
    @ObservationIgnored public var onQuestion: (@MainActor (Session, [QuestionItem]) -> Void)?
    /// 提问结束（答完 / 用户另起输入 / 会话停止或结束 / 进程死亡）回调：session_id。
    @ObservationIgnored public var onQuestionResolved: (@MainActor (String) -> Void)?
    /// 5h 额度按当前速率预计会在重置前提前耗尽、且断档升档时回调：(剩余%, 断档分钟数, 距重置秒数)。
    /// 频率由升档去重控制——同一窗口只在跨入更高断档档位时回调，平稳不反复。
    @ObservationIgnored public var onBurnoutWarning: (@MainActor (_ remainingPct: Double, _ dropMinutes: Double, _ timeLeft: TimeInterval) -> Void)?
    @ObservationIgnored private var burnoutWindow: Date?    // 已预警的 5h 窗口（投影后 resetsAt）
    @ObservationIgnored private var burnoutAlertedTier = 0  // 该窗口已弹到的最高断档档位

    /// 手动压缩标记的有效期：超过视为已中断（esc 取消的 /compact 不该让之后的压缩冒领动画）
    public static let compactExpiry: TimeInterval = 600
    /// 兜底信号阈值：标记存续期间 ctx% 骤降 ≥ 这么多百分点视为压缩完成。
    /// 正常对话 ctx% 只涨不跌，跌只来自压缩；SessionStart(compact) 对 resume 的旧会话
    /// 不送达（实测 2.1.173），statusline 流对所有已开会话都在动，所以骤降是更可靠的完成信号。
    public static let compactCtxDropPoints: Double = 15

    public init() {}

    public func apply(_ env: Envelope, at now: Date = Date()) {
        lastEventReceivedAt = now
        guard let sid = env.payload.sessionId else { return }
        // 无 tty 的后台 claude（更新器、IDE 后台、管道 claude -p）不建行；
        // 但 status 事件携带的账户配额照常吸收。已存在的会话、以及 PID 命中
        // 已知交互进程（占位行）的事件不受影响。
        if sessions[sid] == nil && env.tty == nil {
            let knownPid = env.claudePid.map { pid in
                sessions.values.contains { $0.claudePid == pid }
            } ?? false
            if !knownPid {
                if env.kind == "status" { absorbAccount(env, at: now) }
                return
            }
        }
        if env.kind == "status" {
            applyStatus(env, sid: sid, at: now)
            return
        }
        guard let event = env.payload.hookEventName else { return }

        var s = sessions[sid] ?? makeSession(sid: sid, env: env, at: now)
        updateIdentity(&s, env: env)
        s.lastEventAt = now

        switch event {
        case "SessionStart":
            if s.status == .dead { s.status = .idle; s.deadSince = nil }
            if env.payload.source == "compact" {
                if let t0 = s.compactStartedAt, now.timeIntervalSince(t0) < Self.compactExpiry {
                    onCompactDone?(s, now.timeIntervalSince(t0))
                }
                s.compactStartedAt = nil
            }
        case "PreCompact":
            // 只记手动触发；auto 压缩也会先发 PreCompact——顺手清掉残留的手动标记，
            // 紧随的 SessionStart(compact) 就不会冒领一次被中断的手动压缩
            s.compactStartedAt = env.payload.trigger == "manual" ? now : nil
        case "UserPromptSubmit":
            resolveQuestion(&s)
            s.status = .working
            s.activity = "思考中"
            s.roundStart = now
            s.mruAt = now              // 你发消息 = 用了它 → MRU 置顶（规则①）
            s.pendingCommand = nil
            s.permissionCommand = nil
            s.justDoneUntil = nil
            s.deadSince = nil
        case "PreToolUse":
            s.status = .working
            s.permissionCommand = nil
            if let tool = env.payload.toolName {
                s.activity = ToolSummary.activity(toolName: tool, input: env.payload.toolInput)
                s.pendingCommand = ToolSummary.command(toolName: tool, input: env.payload.toolInput)
            }
            if env.payload.toolName == QuestionParser.toolName {
                beginQuestion(&s, env: env, at: now)
            } else {
                resolveQuestion(&s)   // 不变量加固：新工具开跑说明提问早已结束
            }
        case "PermissionRequest":
            // 实测：AskUserQuestion 的选项 UI 走的就是权限请求机制（PreToolUse 后紧跟
            // 一条同工具名的 PermissionRequest）——按提问处理，不标成"等待权限"也不重复触发
            if env.payload.toolName == QuestionParser.toolName {
                beginQuestion(&s, env: env, at: now)
            } else {
                s.status = .permission
                s.activity = "等待权限"
                if let tool = env.payload.toolName {
                    s.permissionCommand = ToolSummary.command(toolName: tool, input: env.payload.toolInput)
                } else {
                    s.permissionCommand = s.pendingCommand
                }
            }
        case "PostToolUse":
            resolveQuestion(&s)
            s.status = .working
            s.activity = "思考中"
            s.permissionCommand = nil
        case "Stop":
            resolveQuestion(&s)
            let wasActive = s.status.isActive
            s.status = .idle
            s.activity = "空闲"
            s.permissionCommand = nil
            if wasActive {
                s.justDoneUntil = now.addingTimeInterval(2)
                s.mruAt = now          // 跑完一轮 → MRU 置顶（规则③，含后台完成也冒上来）
                onCompletion?(s, now.timeIntervalSince(s.roundStart))
                // SwiftUI 只在状态变化时重渲染——必须在到期时主动清除，否则
                // 风平浪静的话绿条会一直挂到下一个无关事件才消失
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.1))
                    guard let self, var cur = self.sessions[sid],
                          let until = cur.justDoneUntil, until <= Date() else { return }
                    cur.justDoneUntil = nil
                    self.sessions[sid] = cur
                }
            }
        case "SessionEnd":
            resolveQuestion(&s)
            sessions[sid] = nil
            return
        default:
            break
        }
        sessions[sid] = s
    }

    /// 进入等待选择：状态置 .permission（紧急度/琥珀色与权限等待一致），
    /// 行文案「等待选择」，副标题放第一题题面。只在标记从无到有时回调一次。
    private func beginQuestion(_ s: inout Session, env: Envelope, at now: Date) {
        let items = QuestionParser.parse(env.payload.toolInput)
        s.status = .permission
        s.activity = "等待选择"
        if let first = items.first { s.permissionCommand = first.text }
        if s.questionPendingAt == nil {
            s.questionPendingAt = now
            if !items.isEmpty { onQuestion?(s, items) }
        }
    }

    private func resolveQuestion(_ s: inout Session) {
        guard s.questionPendingAt != nil else { return }
        s.questionPendingAt = nil
        onQuestionResolved?(s.id)
    }

    /// 新会话创建：同 PID 的旧会话（占位行 / resume 前任）被收养——移除旧行，
    /// 继承 createdAt（排序稳定）与旧行已知的终端信息。
    private func makeSession(sid: String, env: Envelope, at now: Date) -> Session {
        var adopted: Session? = nil
        if let pid = env.claudePid,
           let entry = sessions.first(where: { $0.value.claudePid == pid }) {
            adopted = entry.value
            sessions[entry.key] = nil
        }
        return Session(id: sid, cwd: env.payload.cwd ?? adopted?.cwd ?? "?",
                       transcriptPath: env.payload.transcriptPath,
                       claudePid: env.claudePid ?? adopted?.claudePid,
                       tty: env.tty ?? adopted?.tty,
                       termProgram: env.termProgram ?? adopted?.termProgram,
                       itermSessionId: env.itermSessionId ?? adopted?.itermSessionId,
                       status: .idle, activity: "空闲",
                       pendingCommand: nil, permissionCommand: nil, roundStart: now,
                       lastEventAt: now, createdAt: adopted?.createdAt ?? now,
                       ctxPct: adopted?.ctxPct, model: adopted?.model,
                       justDoneUntil: nil, deadSince: nil,
                       // 不继承 compactStartedAt：领养的新会话若带上旧会话的压缩标记，其首个 status
                       // 的 ctx 骤降会误报一次"压缩完成"。同会话的正常压缩检测不走领养(sid 已存在)，不受影响。
                       compactStartedAt: nil)
    }

    private func updateIdentity(_ s: inout Session, env: Envelope) {
        if let cwd = env.payload.cwd { s.cwd = cwd }
        if let tp = env.payload.transcriptPath { s.transcriptPath = tp }
        if let pid = env.claudePid { s.claudePid = pid }
        if let tty = env.tty { s.tty = tty }
        if let term = env.termProgram { s.termProgram = term }
        if let iterm = env.itermSessionId { s.itermSessionId = iterm }
    }

    public static let deadRetention: TimeInterval = 600
    public static let placeholderPrefix = "proc-"

    /// 与系统实际运行的 claude 进程对账（地面真相）：
    /// - 进程消失：真实会话转 dead（保留 deadRetention 后移除），占位行立即移除
    /// - 未被任何会话认领的进程：创建空闲占位行（接入前就开着的会话也能立刻显示）
    public func syncProcesses(_ procs: [DiscoveredProcess], at now: Date = Date()) {
        let alive = Set(procs.map(\.pid))
        for (sid, var s) in sessions {
            if let dead = s.deadSince {
                if now.timeIntervalSince(dead) > Self.deadRetention { sessions[sid] = nil }
                continue
            }
            guard let pid = s.claudePid, !alive.contains(pid) else { continue }
            if sid.hasPrefix(Self.placeholderPrefix) {
                sessions[sid] = nil
            } else {
                resolveQuestion(&s)   // 进程没了，挂着的提问提示一并撤掉
                s.status = .dead
                s.activity = "无响应"
                s.permissionCommand = nil
                s.roundStart = now
                s.deadSince = now
                sessions[sid] = s
            }
        }
        let claimed = Set(sessions.values.compactMap(\.claudePid))
        for p in procs where !claimed.contains(p.pid) {
            let sid = Self.placeholderPrefix + String(p.pid)
            sessions[sid] = Session(
                id: sid, cwd: p.cwd ?? "?", transcriptPath: nil,
                claudePid: p.pid, tty: p.tty, termProgram: p.termProgram,
                itermSessionId: nil, status: .idle, activity: "空闲",
                pendingCommand: nil, permissionCommand: nil, roundStart: now,
                lastEventAt: now, createdAt: now, ctxPct: nil, model: nil,
                justDoneUntil: nil, deadSince: nil)
        }
    }

    /// 显示顺序：权限恒在最前 → 其余按 mruAt 降序（MRU）→ 无响应(dead)最末；并给同名项目编号。
    /// mruAt 只在「你发消息(UserPromptSubmit)」或「跑完一轮(Stop)」时刷新，中间跑工具/思考中一概不动
    /// —— 故忙碌的后台 agent 不乱飘、你正看的那个也不抖；从没交互过(mruAt=nil)的垫底。
    /// 手动拖拽换序也只是改这把同一的尺子（见 reorder：把拖后顺序写进各行 mruAt），故与 MRU 不冲突：
    /// 拖动即时生效，之后发消息/完成某行仍按 MRU 把它推上去。见 Session.mruAt。
    public func displaySessions() -> [DisplaySession] {
        let all = Array(sessions.values)
        let byAuto: (Session, Session) -> Bool = { a, b in
            let aDead = a.status == .dead, bDead = b.status == .dead
            if aDead != bDead { return !aDead }          // 非 dead 恒在 dead 之前
            if !aDead {                                   // 都活着：按 mruAt 降序，nil（从没交互过）垫底
                switch (a.mruAt, b.mruAt) {
                case let (x?, y?): if x != y { return x > y }
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            }
            // 都 dead：近的在前
            if a.roundStart != b.roundStart { return a.roundStart > b.roundStart }
            return a.id < b.id
        }
        // 权限组内：等得最久的（roundStart 最早）在前
        let byWaiting: (Session, Session) -> Bool = {
            $0.roundStart != $1.roundStart ? $0.roundStart < $1.roundStart : $0.id < $1.id
        }
        // 权限恒在最前；其余（含拖拽后写入的 mruAt）按 MRU 排
        let permission = all.filter { $0.status == .permission }.sorted(by: byWaiting)
        let rest = all.filter { $0.status != .permission }.sorted(by: byAuto)
        let ordered = permission + rest

        // 同名项目按 createdAt 升序编号（唯一者不编号）
        var nameCounts: [String: Int] = [:]
        for s in all { nameCounts[s.projectName, default: 0] += 1 }
        var dupMap: [String: Int] = [:]
        var counters: [String: Int] = [:]
        for s in all.sorted(by: { $0.createdAt < $1.createdAt }) where nameCounts[s.projectName]! > 1 {
            counters[s.projectName, default: 0] += 1
            dupMap[s.id] = counters[s.projectName]
        }
        return ordered.map { DisplaySession(session: $0, dup: dupMap[$0.id]) }
    }

    /// 手动拖拽换序（纯数据改变）：把拖后顺序写进各行 mruAt（严格递减），使 MRU 排序即呈现该顺序。
    /// 不是「钉住」——此后任意发消息/完成仍会把对应行 mruAt 刷成 now、按 MRU 重新上顶，与拖拽共用一把尺子。
    /// 不持久化（会话本就随进程重建），故不会有跨重启的陈旧顺序残留。
    public func reorder(_ ids: [String], at now: Date = Date()) {
        for (i, id) in ids.enumerated() {
            sessions[id]?.mruAt = now.addingTimeInterval(-Double(i))
        }
    }

    private func applyStatus(_ env: Envelope, sid: String, at now: Date) {
        var s = sessions[sid] ?? makeSession(sid: sid, env: env, at: now)
        updateIdentity(&s, env: env)
        if let pct = env.payload.contextWindow?.usedPercentage {
            if let t0 = s.compactStartedAt, let old = s.ctxPct,
               pct <= old - Self.compactCtxDropPoints {
                if now.timeIntervalSince(t0) < Self.compactExpiry {
                    onCompactDone?(s, now.timeIntervalSince(t0))
                }
                s.compactStartedAt = nil
            }
            s.ctxPct = pct
        }
        if let m = env.payload.model?.displayName { s.model = m }
        sessions[sid] = s
        absorbAccount(env, at: now)
    }

    private func absorbAccount(_ env: Envelope, at now: Date) {
        guard let rl = env.payload.rateLimits else { return }
        var acc = account   // @Observable 计算属性不能多个 inout 子属性同传
        Self.absorbWindow(rl.fiveHour, pct: &acc.fiveHourUsedPct, resetAt: &acc.fiveHourResetsAt)
        Self.absorbWindow(rl.sevenDay, pct: &acc.sevenDayUsedPct, resetAt: &acc.sevenDayResetsAt)
        account = acc
        checkBurnout(now)
    }

    /// 5h 燃尽预警：升档才回调（断档恶化到更高档位才弹），进新窗口后档位清零。
    private func checkBurnout(_ now: Date) {
        guard let f = account.burnoutForecast(now: now) else { return }
        if burnoutWindow != f.windowResetsAt {     // 进了新窗口（重置/滚动）→ 清零重来
            burnoutWindow = f.windowResetsAt
            burnoutAlertedTier = 0
        }
        let tier = AccountUsage.burnoutTier(dropMinutes: f.dropMinutes)
        guard tier > burnoutAlertedTier else { return }   // 只在升档时弹
        burnoutAlertedTier = tier
        onBurnoutWarning?(f.remainingPct, f.dropMinutes, f.windowResetsAt.timeIntervalSince(now))
    }

    /// 同窗判定容差：不同会话快照的 resets_at 可能有秒级抖动，±60s 内视为同一窗口
    static let windowJitter: TimeInterval = 60

    /// 吸收一个限额窗口的快照。多会话各自上报，闲置会话报的是它上次 API 调用时的
    /// 旧数字——直接覆盖会让显示在新旧值之间来回跳。同一窗口内用量只增不减，
    /// 取 max 即"最新鲜的那份"；重置时间明显前移（>jitter）才是窗口滚动、接受回落；
    /// 明显早于当前窗口（<-jitter）的迟到快照整条忽略。
    private static func absorbWindow(_ win: RateWindow?, pct: inout Double?, resetAt: inout Date?) {
        guard let win else { return }
        if let r = win.resetsAt {
            let incoming = Date(timeIntervalSince1970: r)
            if let cur = resetAt {
                let delta = incoming.timeIntervalSince(cur)
                if delta < -Self.windowJitter { return }
                if delta > Self.windowJitter {
                    resetAt = incoming
                    if let p = win.usedPercentage { pct = p }
                    return
                }
            } else {
                resetAt = incoming
            }
        }
        if let p = win.usedPercentage { pct = max(pct ?? 0, p) }
    }
}

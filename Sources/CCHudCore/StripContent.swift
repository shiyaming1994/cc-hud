import CoreGraphics
import Foundation

/// 菜单栏额度条的详略档位，由富到简。真 NSStatusItem 只有一个全局宽度、所有屏一样，
/// 所以详略不能按屏自适应，只能由用户在菜单里显式选 —— 档位就是这个选择。
/// 五档沿用旧独立窗口方案里那个降级阶梯的五档，语义不变，只是从"按预算自动选"改成"用户选"。
public enum StripLevel: Int, CaseIterable, Sendable {
    /// `5H 68% 14:50　7D 96%　59M`
    case full = 0
    /// `5H 68% 14:50　7D 96%`
    case noToken = 1
    /// `5H 68%　7D 96%`
    case noFiveTime = 2
    /// `5H 68% 14:50` —— 只留最紧的那一段，带时间
    case tightestWithTime = 3
    /// `5H 68%` —— 只留最紧的那一段，去时间
    case tightest = 4
}

/// 额度条的开关与档位。存 UserDefaults，跨重启保活。
/// 注入 UserDefaults 便于单测隔离（与 StateStore 同一套做法）。
/// 不标 Sendable —— UserDefaults 在 Swift 6 里不是 Sendable，而这个类型只在主线程用。
public struct StripSettings {
    public static let enabledKey = "hud.menuBarStrip.enabled"
    public static let levelKey = "hud.menuBarStrip.level"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// 越界一律夹取到 .full —— 将来减少档位数时旧存档不能让状态项白屏。
    public var level: StripLevel {
        get { StripLevel(rawValue: defaults.integer(forKey: Self.levelKey)) ?? .full }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.levelKey) }
    }
}

// MARK: - 语义化的渲染指令
//
// 只表达"是什么"，不含任何磁量与色值 —— 字号 / 字重 / 字距 / 间距 / 颜色 / 光晕的具体数值
// 全部由 StripStyle 一处持有（见 StripTitle.swift）。这样 CCHudCore 这层可以纯逻辑单测，
// 而改样式永远只改一个文件。

/// 字重档：标签 500 / 5H 数值 600 / 7D 数值 400 / 常规 400 / 告警 700
public enum StripWeight: Sendable, Equatable { case label, five, seven, regular, alert }

/// 明度与告警色档
public enum StripInk: Sendable, Equatable { case l1, l2, l3, caution, alert }

/// 字距档
public enum StripTracking: Sendable, Equatable { case none, label, time, token }

/// 段间距档
public enum StripGap: Sendable, Equatable {
    case labelToValue, valueToPercent, percentToTime, groupGap
}

public enum StripRun: Sendable, Equatable {
    case text(String, weight: StripWeight, ink: StripInk, tracking: StripTracking, glow: Bool)
    case gap(StripGap)
}

// MARK: - 显示什么

public enum StripContent {
    /// 按档位产出这一行要显示的内容。纯函数：同样的入参永远给同样的结果，便于单测。
    /// 空数组 = 没东西可显示（两个额度窗口都无数据）→ 状态项退回纯图标。
    public static func runs(account: AccountUsage, todayTokens: Int,
                            level: StripLevel, now: Date) -> [StripRun] {
        let five = projected(account.fiveHourUsedPct, account.fiveHourResetsAt,
                             AccountUsage.fiveHourPeriod, now)
        let seven = projected(account.sevenDayUsedPct, account.sevenDayResetsAt,
                              AccountUsage.sevenDayPeriod, now)
        // 7D 倒计时只在剩余 <20% 或距重置 <24h 时出现 —— 这是相关性规则，与档位无关
        let sevenUrgent = seven.map {
            AccountUsage.showsSevenDayReset(remainPct: $0.remain, resetsAt: $0.resetsAt, now: now)
        } ?? false

        func fiveGroup(time: Bool) -> [StripRun] {
            guard let five else { return [] }
            return group(label: "5H", remain: five.remain, base: .five, ink: .l1, glow: true,
                         tail: time ? five.resetsAt.map { Format.resetTimeShort($0, now: now) }
                                    : nil)
        }
        func sevenGroup(time: Bool) -> [StripRun] {
            guard let seven else { return [] }
            let tail = (time && sevenUrgent)
                ? seven.resetsAt.map { Format.countdownDH(to: $0, from: now) } : nil
            return group(label: "7D", remain: seven.remain, base: .seven, ink: .l2, glow: false,
                         tail: tail)
        }
        // token 不能单独成条：它没有标签，孤零零一个数字看不懂。
        // 旧的 SwiftUI 版没这道闸门 —— 启动后额度还没到、而 token 已扫出来时，
        // 菜单栏上会只剩一个光秃秃的 "59M"。
        let hasWindow = five != nil || seven != nil
        let token: [StripRun] = (todayTokens > 0 && hasWindow)
            ? [.text(Format.tokens(todayTokens), weight: .regular, ink: .l3,
                     tracking: .token, glow: false)]
            : []
        // 只留一段时保留"当前最紧的那一段"：宽松时是 5H，7D 更低时换成 7D
        let sevenIsTighter = (seven?.remain ?? .infinity) < (five?.remain ?? .infinity)
        func tightest(time: Bool) -> [StripRun] {
            sevenIsTighter ? sevenGroup(time: time) : fiveGroup(time: time)
        }

        switch level {
        case .full:             return join([fiveGroup(time: true), sevenGroup(time: true), token])
        case .noToken:          return join([fiveGroup(time: true), sevenGroup(time: true)])
        case .noFiveTime:       return join([fiveGroup(time: false), sevenGroup(time: true)])
        case .tightestWithTime: return tightest(time: true)
        case .tightest:         return tightest(time: false)
        }
    }

    /// 一组 = 标签 ⟨4⟩ 数值 ⟨1.5⟩ 百分号 ⟨5⟩ 时刻。
    /// 剩余 20–50 / <20 时数值与百分号一起换 Bold 700 + 档位色（字号不变）；
    /// 百分号平时用 L3、告警时跟着换成档位色。
    private static func group(label: String, remain: Double, base: StripWeight,
                              ink: StripInk, glow: Bool, tail: String?) -> [StripRun] {
        let tone = tone(remain: remain)
        let weight: StripWeight = tone == nil ? base : .alert
        var runs: [StripRun] = [
            .text(label, weight: .label, ink: .l3, tracking: .label, glow: false),
            .gap(.labelToValue),
            .text("\(Int(remain))", weight: weight, ink: tone ?? ink,
                  tracking: .none, glow: glow),
            .gap(.valueToPercent),
            .text("%", weight: weight, ink: tone ?? .l3, tracking: .none, glow: false),
        ]
        if let tail {
            runs.append(.gap(.percentToTime))
            runs.append(.text(tail, weight: .regular, ink: .l2, tracking: .time, glow: false))
        }
        return runs
    }

    /// 20–50 注意 / <20 告警 / >50 无彩色
    private static func tone(remain: Double) -> StripInk? {
        if remain < AccountUsage.lowQuotaRemainPct { return .alert }
        if remain <= 50 { return .caution }
        return nil
    }

    private static func join(_ groups: [[StripRun]]) -> [StripRun] {
        let live = groups.filter { !$0.isEmpty }
        guard let first = live.first else { return [] }
        return live.dropFirst().reduce(first) { $0 + [.gap(.groupGap)] + $1 }
    }

    /// 过期窗口的本地校正：resets_at 一旦过去，该窗口必然已重置（见 AccountUsage.project）
    private static func projected(_ used: Double?, _ resetsAt: Date?,
                                  _ period: TimeInterval, _ now: Date)
        -> (remain: Double, resetsAt: Date?)? {
        let p = AccountUsage.project(usedPct: used, resetsAt: resetsAt, period: period, now: now)
        guard let u = p.usedPct else { return nil }
        return (max(0, min(100, 100 - u)), p.resetsAt)
    }
}

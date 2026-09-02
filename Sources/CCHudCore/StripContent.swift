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

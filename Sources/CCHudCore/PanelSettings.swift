import Foundation

/// 会话浮窗的显隐存档。
///
/// **默认隐藏，但记住用户那一次点击** —— 这两件事不冲突：key 未设时 `defaults.bool`
/// 返回 false，新装用户看到的与 1.4.0 定下的「浮窗默认隐藏」一模一样；存档只多做一件事，
/// 就是把用户手动叫出来的那次记下来。
///
/// 为什么非记不可：这个 app 是 `LSUIElement`（无 Dock 图标），把浮窗叫回来的唯一入口是
/// 菜单栏那一格；而进程重启不全是用户发起的 —— 「登录时启动」会自己拉起，自动更新装完还会
/// `scheduleRelaunch()` 自己重启。不记的话，用户开着的窗会被这些动作悄悄关掉，
/// 而且每次开机都得再点一遍。
///
/// 注入 UserDefaults 便于单测隔离（与 StripSettings 同一套做法）。
/// 不标 Sendable —— UserDefaults 在 Swift 6 里不是 Sendable，而这个类型只在主线程用。
public struct PanelSettings {
    public static let visibleKey = "hud.panelVisible"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var visible: Bool {
        get { defaults.bool(forKey: Self.visibleKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.visibleKey) }
    }
}

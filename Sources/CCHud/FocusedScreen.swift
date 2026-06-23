import AppKit

/// 用户"正在工作"的屏幕：前台 app 最前的普通窗口所在屏 → 鼠标所在屏 → 焦点屏/首屏。
/// 完成动画要出现在用户视线所在的屏，而不是 HUD 挂着的屏（HUD 常驻副屏时尤其）。
@MainActor
enum FocusedScreen {
    static func current() -> NSScreen? {
        frontmostWindowScreen() ?? screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// CGWindowList 自带 z 序（前→后），取前台 app 第一个 layer-0 普通窗口的中心点定屏。
    /// 只读 bounds/pid/layer，无需录屏权限；CC HUD 自己的面板不在 layer 0，不会自指。
    private static func frontmostWindowScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict)
            else { continue }
            // CG 全局坐标顶左原点、y 向下 → 以首屏高度翻转成 Cocoa 底左原点坐标
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            let center = CGPoint(x: rect.midX, y: primaryMaxY - rect.midY)
            return NSScreen.screens.first { $0.frame.contains(center) }
        }
        return nil
    }

    private static func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) }
    }
}

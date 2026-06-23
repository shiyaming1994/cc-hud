import AppKit
import SwiftUI

/// 非激活浮窗：点击不抢终端焦点，所有 Space + 全屏可见。
/// 位置以"用户拖放的右上角锚点"为唯一真相，按【所在屏 UUID + 屏内偏移】持久化——
/// 多屏拔插/睡眠时全局坐标会漂移（排列原点变了），系统还会把窗口搬去幸存屏，
/// 绝对坐标既存不住"在哪块屏"，还会被系统搬窗覆写。
/// 只有按着鼠标拖出来的移动才写存档；存档屏不在场时临时落主屏，屏一回来立即归位。
final class HUDPanel: NSPanel {
    private static let anchorKey = "hud.anchor.v2"             // {screen: 显示器 UUID, dx/dy: 相对屏 origin 的右上锚点}
    private static let legacyAnchorKey = "hud.anchorTopRight"  // v1 全局绝对坐标，读到即迁移
    private var programmaticMove = false
    private var settleTask: Task<Void, Never>?

    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false  // 移窗只在指定区域（WindowDragGesture），行区留给拖拽排序
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = NSHostingView(rootView: rootView)

        applyAnchor(savedAnchor() ?? defaultAnchor())

        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
        // 显示器拔插 / 睡眠醒来：每次变化都重新落位。外接屏上电慢（插线后几秒才注册），
        // 注册那一刻系统会再发一次本通知，所以无论多慢，屏到场即归位，无需重启。
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // 等重排尘埃落定再落位；2.5s 后再校一次，防系统迟到的搬窗又把面板挪走
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.settle()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// 存档屏在场 → 拉回存档锚点（被系统搬走也拉回）；
    /// 不在场 → 整窗已不可见才临时去主屏右上，存档不动，屏回来即恢复。
    private func settle() {
        if let anchor = savedAnchor() {
            applyAnchor(anchor)
        } else if !NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            applyAnchor(defaultAnchor())
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// SwiftUI 内容尺寸变化 → 以持久化锚点（右上角）重排 frame，向左/向下生长。
    func applyContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let anchor = savedAnchor() ?? CGPoint(x: frame.maxX, y: frame.maxY)
        let newFrame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height,
                              width: size.width, height: size.height)
        guard newFrame != frame else { return }
        programmaticMove = true
        setFrame(newFrame, display: true)
        programmaticMove = false
    }

    /// 用户拖动 → 记录锚点（屏 UUID + 屏内偏移）。程序性 setFrame 与系统搬窗都不算：
    /// 拔屏/睡眠重排时 window server 搬窗没有按着鼠标，v1 把它当用户拖动存了档，
    /// 拔一次屏锚点就被主屏坐标覆写——这正是"重插不回原位"的根因。
    @objc private func didMove() {
        guard !programmaticMove, NSEvent.pressedMouseButtons != 0 else { return }
        guard let s = screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let uuid = s.displayUUID else { return }
        UserDefaults.standard.set(
            ["screen": uuid, "dx": frame.maxX - s.frame.minX, "dy": frame.maxY - s.frame.minY],
            forKey: Self.anchorKey)
    }

    /// 解析存档：所在屏在场才返回全局锚点（超界偏移夹回屏内），不在场返回 nil（调用方临时落主屏）。
    private func savedAnchor() -> CGPoint? {
        if let d = UserDefaults.standard.dictionary(forKey: Self.anchorKey),
           let uuid = d["screen"] as? String,
           let dx = d["dx"] as? Double, let dy = d["dy"] as? Double {
            guard let s = NSScreen.screens.first(where: { $0.displayUUID == uuid }) else { return nil }
            let f = s.frame
            // 锚点是右上角、面板向左/向下生长：下限留 40pt 保证可见，上限贴屏边
            return CGPoint(x: min(max(f.minX + dx, f.minX + 40), f.maxX),
                           y: min(max(f.minY + dy, f.minY + 40), f.maxY))
        }
        // v1 绝对坐标存档：能定位到所在屏就迁移成 v2（找不到屏说明那块屏不在场，留待回场或用户重拖）
        if let arr = UserDefaults.standard.array(forKey: Self.legacyAnchorKey) as? [Double], arr.count == 2 {
            let p = CGPoint(x: arr[0], y: arr[1])
            if let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(p) }),
               let uuid = s.displayUUID {
                UserDefaults.standard.set(
                    ["screen": uuid, "dx": p.x - s.frame.minX, "dy": p.y - s.frame.minY],
                    forKey: Self.anchorKey)
                UserDefaults.standard.removeObject(forKey: Self.legacyAnchorKey)
                return p
            }
        }
        return nil
    }

    private func defaultAnchor() -> CGPoint {
        guard let primary = NSScreen.screens.first else { return CGPoint(x: 800, y: 600) }
        let v = primary.visibleFrame
        return CGPoint(x: v.maxX - 18, y: v.maxY - 8)
    }

    private func applyAnchor(_ anchor: CGPoint) {
        programmaticMove = true
        setFrame(NSRect(x: anchor.x - frame.width, y: anchor.y - frame.height,
                        width: frame.width, height: frame.height), display: false)
        programmaticMove = false
    }
}

private extension NSScreen {
    /// 物理显示器 UUID（EDID 派生）：同一台显示器拔插、睡眠、换口都稳定；
    /// NSScreenNumber(displayID) 每次插拔可能变，不能当持久身份。
    var displayUUID: String? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
}

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
    /// 悬停态由 AppDelegate 的鼠标监视器经此写入（用可见玻璃 frame 命中判定，不依赖会被内容缩放扰动的 tracking area）。
    weak var hoverState: HoverState?
    private var isHovering = false
    /// 可见玻璃当前高度（静息 < 窗口高；展开 = 窗口高）。窗口恒为展开尺寸、下方留透明预留区，
    /// 所以：悬停命中区按此高度（不含预留，避免在空白处误触发）、预留区 hitTest 穿透点击、系统阴影按此贴合。
    /// 默认 = 启动窗口高，首帧测量后即校正。
    var visibleHeight: CGFloat = 120
    /// 收起判定的外扩量：贴边小幅移动落在此余量内不收起（空间迟滞，避免边缘横跳）
    private let hoverMargin: CGFloat = 24

    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true   // 系统窗口投影：沿圆角玻璃描一圈柔和投影，常驻、干净
        isMovableByWindowBackground = false  // 移窗只在指定区域（WindowDragGesture），行区留给拖拽排序
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true   // app 处于 active 时，本地鼠标监视器靠它收到 mouseMoved（非 active 走全局监视器）
        // PassThroughHostingView：窗口恒为展开尺寸，静息时玻璃只占顶部、下方是透明预留区；
        // 该子类让预留区的点击穿透到下方窗口（否则会挡住终端）。
        let host = PassThroughHostingView(rootView: rootView)
        host.layerContentsRedrawPolicy = .duringViewResize
        contentView = host

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

    /// 悬停判定入口（AppDelegate 的鼠标监视器在每次鼠标移动时调用，传入屏幕坐标）。
    /// 命中区 = 顶右锚点向下 `可见玻璃高度` 的矩形（**不含**下方透明预留区，故在空白处不会误触发）；
    /// 已悬停时四周外扩 margin 形成迟滞死区，贴边小幅移动不横跳。展开时玻璃填满窗口 → 命中区即整窗。
    func updateHover(at point: NSPoint) {
        // 行悬停（每次移动都判定）：屏幕鼠标 → 窗口内容坐标（左上原点、y 向下），命中哪行矩形就高亮哪行。
        // 单一真相 = 恰好一行（或无），免疫 NSTrackingArea 漏 enter/exit 与探针重复导致的"乱亮/多行同亮"。
        if let hoverState {
            let g = frame.windowContentPoint(fromScreen: point)
            let row = hoverState.rowRects.first { $0.value.contains(g) }?.key
            if hoverState.hoveredRow != row { hoverState.hoveredRow = row }
        }
        // 页脚展开悬停（迟滞判定，仅在跨越可见玻璃边界时翻转）
        let anchor = savedAnchor() ?? CGPoint(x: frame.maxX, y: frame.maxY)
        let h = max(visibleHeight, 1)
        let m = isHovering ? hoverMargin : 0
        let inside = NSRect(x: anchor.x - frame.width - m, y: anchor.y - h - m,
                            width: frame.width + 2 * m, height: h + 2 * m).contains(point)
        guard inside != isHovering else { return }
        isHovering = inside
        hoverState?.footerExpanded = inside   // 只翻转内容展开态；窗口尺寸不变，内容在窗口内平滑伸缩
    }

    /// SwiftUI 内容尺寸（= 展开态尺寸，由隐藏探针恒定给出）变化 → 重排 frame 向左/向下生长（瞬时）。
    /// 固定**当前**右上角（不回存档锚点，避免夹取误差导致上下跳）；整数像素防亚像素漂移；重算阴影。
    /// 悬停不改变此尺寸（探针恒展开），故此函数在悬停时空跑；只在行数增减 / 换档时真正重排。
    func applyContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let maxX = frame.maxX.rounded(), maxY = frame.maxY.rounded()
        let w = size.width.rounded(), h = size.height.rounded()
        let newFrame = NSRect(x: maxX - w, y: maxY - h, width: w, height: h)
        guard newFrame != frame else { return }
        programmaticMove = true
        setFrame(newFrame, display: true)
        invalidateShadow()
        programmaticMove = false
    }

    /// 可见玻璃高度变化（含悬停动画每帧）→ 更新命中区基准、预留区穿透阈值（PassThroughHostingView 读 visibleHeight）、
    /// 并重算系统阴影使其随玻璃高度伸缩（窗口不缩放，阴影只能靠 invalidate 跟上玻璃 alpha）。
    func setVisibleHeight(_ h: CGFloat) {
        guard h > 1, abs(h - visibleHeight) > 0.5 else { return }
        visibleHeight = h
        invalidateShadow()
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

extension NSRect {
    /// 屏幕坐标(左下原点)的点 → 以本 rect 为窗口时的内容坐标(左上原点、y 向下)，
    /// 用于和 SwiftUI `.frame(in: .global)` 上报的矩形做命中判定。HUD 与预警卡共用。
    func windowContentPoint(fromScreen p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - minX, y: maxY - p.y)
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

/// 宿主视图：窗口恒为展开尺寸，静息时可见玻璃只占顶部、其下是透明预留区。
/// 让预留区的点击**穿透**到下方窗口（不然会挡住终端）；玻璃区（顶部 visibleHeight 内）正常命中 SwiftUI 子视图。
final class PassThroughHostingView<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 玻璃顶对齐，占顶部 visibleHeight；其下透明预留区 → 返回 nil 穿透
        let opaque = (window as? HUDPanel)?.visibleHeight ?? .greatestFiniteMagnitude
        let local = convert(point, from: superview)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        if fromTop > opaque + 0.5 { return nil }
        return super.hitTest(point)
    }
}

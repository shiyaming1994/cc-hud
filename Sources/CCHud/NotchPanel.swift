import AppKit
import SwiftUI
import CCHudCore

/// 刘海岛面板：吸附屏幕顶端、包住刘海、不可拖。
/// 位置的唯一真相是屏幕参数（刘海在哪岛就在哪），所以不做 HUDPanel 那套"用户拖动锚点 + 屏 UUID 存档"——
/// 那套规则与"跟刘海走"互斥，混在一起会把已经打磨稳的多屏归位逻辑搅浑。
@MainActor
final class NotchPanel: NSPanel, VisibleContentProviding {
    /// 可见岛体在窗口内容坐标（左上原点）的矩形；其外是透明预留区，点击穿透。
    private(set) var visibleContentRect: CGRect = .zero
    /// 窗口尺寸 = 展开态尺寸（由隐藏探针恒定给出），静息时只画中间一小块。
    private var contentSize = CGSize(width: 360, height: 110)
    private var settleTask: Task<Void, Never>?
    /// 岛的刘海几何,与窗口落位同源刷新(见 reposition)
    let metrics: NotchMetrics

    init(rootView: some View, metrics: NotchMetrics) {
        self.metrics = metrics
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar          // 实测 25 > 菜单栏 24，能盖住菜单栏；菜单展开时 popUpMenu(101) 盖住岛，顺序正确
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false           // 岛与刘海融为一体，系统投影会在刘海周围描出一圈灰边、露馅
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        let host = PassThroughHostingView(rootView: rootView)
        host.layerContentsRedrawPolicy = .duringViewResize
        contentView = host
        reposition()
        // 外接屏拔插 / 睡眠唤醒后重新落位（外接屏上电慢，故 600ms + 2s 两次校准，同 HUDPanel）
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 岛所在屏：优先有刘海的屏；都没有（合盖只剩外接屏）→ 主屏，渲染无刘海的胶囊版。
    static func hostScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    static func notch(of screen: NSScreen) -> CGRect? {
        NotchGeometry.notchRect(screenFrame: screen.frame,
                                safeAreaTop: screen.safeAreaInsets.top,
                                auxLeft: screen.auxiliaryTopLeftArea,
                                auxRight: screen.auxiliaryTopRightArea)
    }

    /// 静息岛的高度基准 = 刘海高；无刘海屏用菜单栏高度兜底，保证胶囊版也不突兀。
    static func notchHeight(of screen: NSScreen) -> CGFloat {
        let top = screen.safeAreaInsets.top
        return top > 0 ? top : max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
    }

    /// SwiftUI 内容尺寸（= 展开态，恒定）变化 → 重新落位。
    func applyContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        contentSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
        reposition()
    }

    func setVisibleContentRect(_ r: CGRect) { visibleContentRect = r }

    private func reposition() {
        guard let screen = Self.hostScreen() else { return }
        let notch = Self.notch(of: screen)
        // 视图内部布局与窗口位置同源:换屏后刘海变了/没了,占位宽度必须一起跟进
        metrics.notchWidth = notch?.width ?? 0
        metrics.notchHeight = Self.notchHeight(of: screen)
        let f = NotchGeometry.islandFrame(screenFrame: screen.frame,
                                          notch: notch,
                                          contentSize: contentSize)
        guard f != frame else { return }
        setFrame(f, display: true)
    }

    @objc private func screensChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.reposition()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.reposition()
        }
    }
}

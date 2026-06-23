import AppKit
import SwiftUI
import CCHudCore

/// 完成动画调度：排队 + 合并（动画播放期间到达的完成累积，播完合并成一条），绝不叠加。
/// 动画窗口按需创建、播完即毁——无动画时零常驻成本。
@MainActor
final class CompletionAnimator {
    static let styleKey = "completion.style"   // off | a | b | c（默认 a）

    private var queue: [CompletionItem] = []
    private var busy = false
    private var panel: NSPanel?
    private var model: PlaybackModel?
    private var playTask: Task<Void, Never>?
    /// 动画播放在哪块屏：show() 那一刻采样，跟随用户焦点屏（FocusedScreen.current）
    var screenProvider: () -> NSScreen? = { nil }

    var style: String {
        get { UserDefaults.standard.string(forKey: Self.styleKey) ?? "a" }
        set { UserDefaults.standard.set(newValue, forKey: Self.styleKey) }
    }

    func trigger(_ item: CompletionItem) {
        guard style != "off" else { return }
        queue.append(item)
        pump()
    }

    /// 切换预览等场景：中断当前播放 + 清空队列，立即回到无动画态（防快速重触发时叠加）
    func reset() {
        playTask?.cancel()
        playTask = nil
        queue.removeAll()
        teardown()
        busy = false
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        let style = self.style
        guard style != "off" else { queue.removeAll(); return }
        busy = true
        let items = queue
        queue.removeAll()

        let dur = Self.duration(style: style, items: items)
        let leave = Self.leaveSeconds(style: style)
        show(style: style, items: items)

        playTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((dur - leave) * 1000)))
            self?.model?.leaving = true
            try? await Task.sleep(for: .milliseconds(Int(leave * 1000) + 60))
            self?.teardown()
            self?.busy = false
            self?.pump()
        }
    }

    private func show(style: String, items: [CompletionItem]) {
        let model = PlaybackModel()
        self.model = model
        let root = Group {
            switch style {
            case "b": AnyView(VarBView(items: items, model: model))
            case "c": AnyView(VarCView(items: items, model: model))
            default: AnyView(VarAView(items: items, model: model))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let screen = screenProvider() ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true        // 点击穿透：对正常操作零影响
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    // ---- 时长（移植自原型 durationFor / LEAVE_MS）----
    static func duration(style: String, items: [CompletionItem]) -> Double {
        let n = items.count
        switch style {
        case "b":
            let charMs = n > 1 ? 0.016 : 0.026
            let chars = items.reduce(0) { $0 + "✓ \($1.name) · \($1.verb) · \($1.time)".count }
            return min(2.5, 0.48 + Double(chars) * charMs + 0.75 + 0.7)
        case "c":
            return 2.0
        default:
            return n > 1 ? 2.4 : 2.1
        }
    }
    static func leaveSeconds(style: String) -> Double {
        switch style {
        case "b": return 0.78
        case "c": return 0.42
        default: return 0.38
        }
    }
}

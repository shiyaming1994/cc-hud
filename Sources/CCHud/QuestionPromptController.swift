import AppKit
import SwiftUI
import CCHudCore

/// 提问提示调度：同会话去重、跨会话排队（当前退场完成后下一个进场，绝不叠加）、
/// 5s 超时缓退 / 答完快撤 / 点击跳转退场。面板按需创建、播完即毁，平时零常驻。
@MainActor
final class QuestionPromptController {
    static let stayMs = 5000
    static let enterMs = 480, lightEnterMs = 150
    static let exitSlowMs = 850, exitFastMs = 300, exitGoMs = 260
    /// 上张卡关闭后多少秒内同会话再提问 → 轻进场。
    /// 真实信号里逐题作答无事件、跨调用间隔数秒，「原地换题」永远赶不上——
    /// 设计稿的 swap 动画在原生侧降级为这个接续式轻进场。
    static let lightEnterWindow: TimeInterval = 8

    /// 与完成动画配对（用户要求成对不分开），completion.style 是唯一真相：
    /// off→off，a 光环→rings 光环呼吸，b 打字机→typewriter 逐字打出，c 呼吸灯→edges 边缘光呼吸
    var style: String {
        switch UserDefaults.standard.string(forKey: CompletionAnimator.styleKey) ?? "a" {
        case "off": return "off"
        case "b": return "typewriter"
        case "c": return "edges"
        default: return "rings"
        }
    }
    var onJump: @MainActor (String) -> Void = { _ in }

    private enum Phase { case idle, showing, leaving }
    private var phase: Phase = .idle
    private var panel: NSPanel?
    private var hosting: PassthroughHostingView<QuestionOverlayView>?
    private var model: QuestionPlayback?
    private var currentSid: String?
    private var queue: [QuestionPromptItem] = []
    private var stageTask: Task<Void, Never>?
    private var lastClose: (sid: String, at: Date)?

    func present(_ item: QuestionPromptItem) {
        guard style != "off", !item.questions.isEmpty else { return }
        guard phase == .idle else {
            if currentSid == item.sid { return }      // store 已按会话去重，双保险
            queue.removeAll { $0.sid == item.sid }
            queue.append(item)
            return
        }
        show(item)
    }

    /// 该会话的提问结束（答完 / 打断 / 会话没了）：撤当前卡 + 清排队
    func resolve(sid: String) {
        queue.removeAll { $0.sid == sid }
        if phase == .showing, currentSid == sid { dismiss(.leaveFast) }
    }

    /// 菜单「测试播放」：两题示意（验证徽章与选项排版）；sid 不存在 → 点击跳转自然 no-op
    func preview(project: String) {
        present(QuestionPromptItem(sid: "preview", project: project, questions: [
            QuestionItem(text: "检测到 3 处合并冲突，如何处理？", header: "合并冲突",
                         optionLabels: ["全部覆盖", "逐个确认", "放弃合并"], multiSelect: false),
            QuestionItem(text: "测试第二题", header: nil, optionLabels: ["继续", "停止"], multiSelect: false),
        ]))
    }

    private func show(_ item: QuestionPromptItem) {
        let light = lastClose.map {
            $0.sid == item.sid && Date().timeIntervalSince($0.at) < Self.lightEnterWindow
        } ?? false
        let enter = light ? Self.lightEnterMs : Self.enterMs
        let model = QuestionPlayback(lightEnter: light,
                                     timelineSeconds: Double(Self.stayMs - enter) / 1000)
        let root = QuestionOverlayView(
            item: item, model: model, decor: style,
            onJump: { [weak self] in self?.jump(item.sid) },
            onIgnore: { [weak self] in self?.dismiss(.leaveFast) },
            onCardFrame: { [weak self] r in self?.hosting?.hitRect = r })

        // 出现在用户焦点屏（前台窗口所在屏），与完成动画同策略
        let screen = FocusedScreen.current()
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hosting = PassthroughHostingView(rootView: root)
        let panel = OverlayPanel(contentRect: frame)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = hosting
        self.model = model
        currentSid = item.sid
        phase = .showing

        stageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))   // 隐藏初值先上屏一帧
            guard let self, self.phase == .showing, let m = self.model else { return }
            withAnimation(light ? .easeOut(duration: 0.15)
                                : .timingCurve(0.2, 1, 0.3, 1, duration: 0.48)) {
                m.stage = .idle
            }
            try? await Task.sleep(for: .milliseconds(Self.stayMs - 30))
            guard !Task.isCancelled else { return }
            self.dismiss(.leaveSlow)   // 超时：缓慢淡出 + 轻微下沉
        }
    }

    private func jump(_ sid: String) {
        onJump(sid)
        dismiss(.leaveGo)
    }

    private func dismiss(_ st: QuestionPlayback.Stage) {
        guard phase == .showing, let model else { return }
        phase = .leaving
        stageTask?.cancel()
        let dur: Int
        switch st {
        case .leaveSlow:
            dur = Self.exitSlowMs
            withAnimation(.easeOut(duration: 0.85)) { model.stage = .leaveSlow }
        case .leaveGo:
            // 设计稿 askOutGo：35% 处先弹到 1.03 再淡出（确认感）
            dur = Self.exitGoMs
            withAnimation(.easeOut(duration: 0.09)) { model.stage = .goBump }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard let self, let m = self.model, m.stage == .goBump else { return }
                withAnimation(.easeIn(duration: 0.17)) { m.stage = .leaveGo }
            }
        default:
            dur = Self.exitFastMs
            withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.3)) { model.stage = .leaveFast }
        }
        let sid = currentSid
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(dur + 80))
            guard let self, self.phase == .leaving else { return }
            self.teardown()
            if let sid { self.lastClose = (sid, Date()) }
            self.pump()
        }
    }

    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        model = nil
        currentSid = nil
        phase = .idle
    }

    private func pump() {
        guard phase == .idle, !queue.isEmpty else { return }
        show(queue.removeFirst())
    }
}

/// 全屏透明叠加面板：非激活、不抢焦点、所有 Space 可见。
private final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 命中区裁定：卡片 frame 之外的点击一律穿透（返回 nil，事件落到下层 App）。
/// 完成动画那种纯展示面板用 ignoresMouseEvents 全穿透即可；这里要"只有卡片可点"。
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var hitRect: CGRect = .zero   // 卡片 frame（SwiftUI .global ＝ 本视图坐标，hosting view 是 flipped）

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard hitRect.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        return super.hitTest(point)
    }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @MainActor @preconcurrency dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

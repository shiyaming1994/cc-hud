import SwiftUI
import CCHudCore

/// 提问提示的数据。questions 取自 PreToolUse(AskUserQuestion) 的 tool_input。
struct QuestionPromptItem: Sendable {
    let sid: String
    let project: String
    let questions: [QuestionItem]
}

/// 播放状态机（设计稿 .enter → .idle → .leave-slow/.leave-fast/.leave-go）。
/// 曲线全部由控制器的 withAnimation 驱动，视图只做 stage → 数值映射。
@MainActor @Observable
final class QuestionPlayback {
    enum Stage { case enter, idle, goBump, leaveSlow, leaveFast, leaveGo }
    var stage: Stage = .enter
    let lightEnter: Bool          // 同会话短间隔连发 → 150ms 轻进场（代替整套大进场）
    let timelineSeconds: Double   // 剩余时间细线时长 = 停留 − 进场

    init(lightEnter: Bool, timelineSeconds: Double) {
        self.lightEnter = lightEnter
        self.timelineSeconds = timelineSeconds
    }
}

// 设计稿 :root（琥珀与 HUD 权限等待黄同源 #FFB02E）
private enum QTheme {
    static let amber = Theme.permission
    static let amberHi = Color(red: 1, green: 200/255, blue: 104/255)
    /// 卡片底：纯色，不用 NSVisualEffectView——毛玻璃跟随系统外观（浅色=白底），
    /// 退场 opacity 淡出时模糊合成失效会闪白；纯色深底淡出全程干净。
    /// 设计稿 0.86+blur(30)，去掉模糊后提到 0.94 保持杂乱背景上的可读性。
    static let cardSolid = Color(red: 24/255, green: 24/255, blue: 28/255).opacity(0.94)
    static let hairline = Color.white.opacity(0.11)
    static let txPrimary = Color.white.opacity(0.94)
    static let txTertiary = Color.white.opacity(0.35)
}

/// 全屏叠加层：装饰光效（光环 / 边缘光）+ 居中卡片。背景透明，命中区由控制器按卡片 frame 裁定。
struct QuestionOverlayView: View {
    let item: QuestionPromptItem
    let model: QuestionPlayback
    let decor: String                       // rings | edges
    let onJump: () -> Void
    let onIgnore: () -> Void
    let onCardFrame: (CGRect) -> Void

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// stagebox 的 stage → (opacity, scale, y)
    private var fx: (o: Double, s: Double, y: Double) {
        switch model.stage {
        case .enter: return model.lightEnter ? (0, 1, 5) : (0, 0.94, 14)
        case .idle: return (1, 1, 0)
        case .goBump: return (1, 1.03, 0)
        case .leaveSlow: return (0, 0.985, 16)
        case .leaveFast: return (0, 0.94, 0)
        case .leaveGo: return (0, 1.05, 0)
        }
    }
    private var leaving: Bool {
        switch model.stage {
        case .leaveSlow, .leaveFast, .leaveGo: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            if decor == "edges" {
                EdgeGlow(breathing: !reduceMotion)
                    .opacity(model.stage == .enter || leaving ? 0 : 1)
            }
            ZStack {
                if decor == "rings" {
                    BreathingRing(width: 700, height: 440, stroke: 0.40, delay: 0,
                                  breathing: !reduceMotion)
                    BreathingRing(width: 860, height: 560, stroke: 0.18, delay: 0.3,
                                  breathing: !reduceMotion)
                }
                if decor == "typewriter" {
                    // 打字机配中心辉光（设计稿背景光效 3：光标辉光意象）
                    BreathingGlow(breathing: !reduceMotion)
                }
                QuestionCardView(item: item, model: model, decor: decor,
                                 onJump: onJump, onIgnore: onIgnore, onCardFrame: onCardFrame)
            }
            .opacity(fx.o)
            .scaleEffect(fx.s)
            .offset(y: fx.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 玻璃卡片（唯一可点击区域）：整卡点击 = 跳转终端；右上 ✕ = 忽略。
private struct QuestionCardView: View {
    let item: QuestionPromptItem
    let model: QuestionPlayback
    let decor: String
    let onJump: () -> Void
    let onIgnore: () -> Void
    let onCardFrame: (CGRect) -> Void

    @State private var hovering = false
    @State private var timelineScale: CGFloat = 1
    @State private var typedDone = false   // 打字机：问题打完后选项/提示语才浮现
    private static let letters = ["A", "B", "C", "D"]

    private var first: QuestionItem? { item.questions.first }

    var body: some View {
        let rr = RoundedRectangle(cornerRadius: 16)
        VStack(alignment: .leading, spacing: 0) {
            // 眉行：✳ 项目 · 等你选择（· 可多选）＋ N 题徽章（数量而非进度——逐题作答没有信号）
            HStack(spacing: 8) {
                Text("✳").font(.system(size: 13)).foregroundStyle(QTheme.amber)
                Text(eyebrow)
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(QTheme.amber.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if item.questions.count > 1 {
                    Text("\(item.questions.count) 题")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(QTheme.amber)
                        .padding(.vertical, 3).padding(.horizontal, 9)
                        .background(QTheme.amber.opacity(0.14), in: Capsule())
                        .overlay(Capsule().stroke(QTheme.amber.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(.trailing, 30)   // 给右上 ✕ 留位

            // 主标题 = 问题本身（打字机方案逐字打出，其余直出）
            Group {
                if decor == "typewriter" {
                    TypewriterText(text: first?.text ?? "",
                                   active: model.stage == .idle) {
                        withAnimation(.easeOut(duration: 0.3)) { typedDone = true }
                    }
                } else {
                    Text(first?.text ?? "")
                }
            }
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(QTheme.txPrimary)
            .lineSpacing(4)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.top, 12)

            // 选项：每项一行灰字，超长截尾（只列 label；description 放不下也不该放）
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((first?.optionLabels.prefix(4) ?? []).enumerated()), id: \.offset) { i, label in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(Self.letters[i])
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(QTheme.amber.opacity(0.6))
                        Text(label)
                            .font(.system(size: 13.5))
                            .foregroundStyle(QTheme.txTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.top, 10)
            .opacity(typedDone ? 1 : 0)

            HStack(spacing: 6) {
                Text("点击前往终端")
                Text("→").offset(x: hovering ? 3 : 0)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hovering ? QTheme.amberHi : QTheme.amber.opacity(0.75))
            .padding(.top, 16)
            .opacity(typedDone ? 1 : 0)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 24, trailing: 26))
        .frame(width: 540, alignment: .leading)
        .background(QTheme.cardSolid)
        .clipShape(rr)
        .overlay(rr.stroke(hovering ? QTheme.amber.opacity(0.45) : QTheme.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            IgnoreButton(action: onIgnore).padding(8)
        }
        .overlay(alignment: .bottom) {
            // 剩余时间细线：进场结束后 scaleX 1→0 linear
            Rectangle()
                .fill(QTheme.amber.opacity(0.35))
                .frame(height: 2)
                .scaleEffect(x: timelineScale, anchor: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
        }
        .shadow(color: .black.opacity(0.7), radius: 45, y: 22)
        .shadow(color: QTheme.amber.opacity(hovering ? 0.14 : 0.07), radius: hovering ? 32 : 25)
        .offset(y: hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(rr)
        .onTapGesture(perform: onJump)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCardFrame($0) }
        .onChange(of: model.stage) { _, st in
            if st == .idle {
                withAnimation(.linear(duration: model.timelineSeconds)) { timelineScale = 0 }
            }
        }
        .onAppear { typedDone = decor != "typewriter" }
    }

    private var eyebrow: String {
        var t = "\(item.project) · 等你选择"
        if item.questions.count == 1, first?.multiSelect == true { t += " · 可多选" }
        return t
    }
}

/// 打字机方案的问题文字：进场结束后逐字打出 + 琥珀光标呼吸闪烁
/// （与完成动画「打字机」配对，但不带终端框——终端框样式已被否决）。
/// 隐藏的全文占位保证卡片高度恒定，打字过程不抖动。
private struct TypewriterText: View {
    let text: String
    let active: Bool
    let onFinished: () -> Void
    @State private var count = 0

    /// 速度对齐完成动画 B（单条 26ms/字），长问题封顶 1.8s
    private static func duration(_ text: String) -> Double {
        min(1.8, Double(max(text.count, 1)) * 0.022)
    }

    /// 拼接段必须逐段显式着色——未着色段不继承环境前景色（实测渲染成隐形）
    private func typed(blinkOn: Bool) -> Text {
        Text(String(text.prefix(count)))
            .foregroundStyle(QTheme.txPrimary)
        + Text("▍")
            .foregroundStyle(QTheme.amber.opacity(blinkOn ? 0.9 : 0.25))
    }

    var body: some View {
        // 光标闪烁用 TimelineView 离散翻转，绝不能用 repeatForever withAnimation——
        // 持续动画事务会把拼接 Text 里"跨渲染变化的字形"（打出的前缀）渲染成隐形，
        // 只有跨渲染稳定的字面量能上屏（实测取证：状态/重渲染全对，唯独变化字符不可见）
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let blinkOn = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
            ZStack(alignment: .topLeading) {
                Text(text).opacity(0)   // 占位：高度恒定，打字不抖
                typed(blinkOn: blinkOn)
            }
        }
        .task(id: active) {
            guard active, count == 0 else { return }
            let total = max(text.count, 1)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                count = total
                onFinished()
                return
            }
            // 按墙钟推进而非逐字 sleep——22ms 级短睡眠会被定时器合并拖慢约 10 倍
            let t0 = Date()
            let dur = Self.duration(text)
            while count < total {
                try? await Task.sleep(for: .milliseconds(16), tolerance: .zero)
                if Task.isCancelled { return }
                count = min(total, Int(Double(total) * Date().timeIntervalSince(t0) / dur))
            }
            onFinished()
        }
    }
}

/// 右上角忽略按钮：安静（低透明度，hover 才亮），点击 = 纯关闭不跳转。
/// 26×26 命中区；Button 自吞事件，不会冒泡到整卡的跳转 tap。
private struct IgnoreButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("✕")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(hover ? 0.85 : 0.30))
                .frame(width: 26, height: 26)
                .background(hover ? Color.white.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 卡片背后的琥珀呼吸环：2.4s 循环，透明度 0.55↔1 + 极轻缩放（5s 停留约走完两轮）
private struct BreathingRing: View {
    let width: CGFloat
    let height: CGFloat
    let stroke: Double
    let delay: Double
    let breathing: Bool
    @State private var on = false

    var body: some View {
        Ellipse()
            .stroke(QTheme.amber.opacity(stroke), lineWidth: 1.5)
            .frame(width: width, height: height)
            .shadow(color: QTheme.amber.opacity(0.12), radius: 20)
            .opacity(on ? 1 : 0.55)
            .scaleEffect(on ? 1.02 : 1)
            .onAppear {
                guard breathing else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(delay)) {
                    on = true
                }
            }
    }
}

/// 打字机方案的背景「中心辉光」（设计稿光效 3，光标辉光意象）：
/// 卡片背后 880×560 椭圆琥珀光晕，径向 0.22 → 0.07@55% → 透明@75%，
/// 待机 2.4s 呼吸（透明度 0.55↔1 + 缩放 1↔1.04）；进退场跟随卡片 stagebox。
private struct BreathingGlow: View {
    let breathing: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: QTheme.amber.opacity(0.22), location: 0),
                    .init(color: QTheme.amber.opacity(0.07), location: 0.55),
                    .init(color: .clear, location: 0.75),
                ],
                center: .center, startRadius: 0, endRadius: 280))
            .frame(width: 560, height: 560)
            .scaleEffect(x: 880.0 / 560.0, y: 1)   // 拉成 880×560 椭圆（CSS closest-side 等效）
            .opacity(on ? 1 : 0.55)
            .scaleEffect(on ? 1.04 : 1)
            .onAppear {
                guard breathing else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(0.1)) {
                    on = true
                }
            }
    }
}

/// 变体「边缘光」：屏幕四边琥珀辉光呼吸（上 → 左右 +0.12s → 下 +0.24s 错峰）
private struct EdgeGlow: View {
    let breathing: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * 0.13
            let w = geo.size.width * 0.09
            ZStack {
                EdgeBand(delay: 0, breathing: breathing) {
                    LinearGradient(colors: [QTheme.amber.opacity(0.30), .clear],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(height: h).frame(maxHeight: .infinity, alignment: .top)
                EdgeBand(delay: 0.24, breathing: breathing) {
                    LinearGradient(colors: [QTheme.amber.opacity(0.30), .clear],
                                   startPoint: .bottom, endPoint: .top)
                }
                .frame(height: h).frame(maxHeight: .infinity, alignment: .bottom)
                EdgeBand(delay: 0.12, breathing: breathing) {
                    LinearGradient(colors: [QTheme.amber.opacity(0.28), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: w).frame(maxWidth: .infinity, alignment: .leading)
                EdgeBand(delay: 0.12, breathing: breathing) {
                    LinearGradient(colors: [QTheme.amber.opacity(0.28), .clear],
                                   startPoint: .trailing, endPoint: .leading)
                }
                .frame(width: w).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct EdgeBand<G: View>: View {
    let delay: Double
    let breathing: Bool
    @ViewBuilder let gradient: () -> G
    @State private var on = false

    var body: some View {
        gradient()
            .opacity(on ? 0.85 : 0.32)
            .onAppear {
                guard breathing else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(delay)) {
                    on = true
                }
            }
    }
}

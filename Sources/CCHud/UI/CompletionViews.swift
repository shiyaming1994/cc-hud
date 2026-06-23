import SwiftUI

/// 完成动画的数据与播放状态。
struct CompletionItem: Sendable {
    let name: String      // 项目名
    let time: String      // 本轮用时 "4:32"
    let task: String      // 任务标题
    let verb: String      // 完成语："完成" / "上下文已压缩"

    init(name: String, time: String, task: String, verb: String = "完成") {
        self.name = name
        self.time = time
        self.task = task
        self.verb = verb
    }
}

@MainActor @Observable
final class PlaybackModel {
    var leaving = false
}

// 原型 :root 配色
private enum CTheme {
    static let green = Color(red: 70/255, green: 192/255, blue: 138/255)
    static let greenHi = Color(red: 111/255, green: 224/255, blue: 172/255)
    static let txPrimary = Color.white.opacity(0.94)
    static let txSecondary = Color.white.opacity(0.55)
    static let txTertiary = Color.white.opacity(0.34)
    static let glassSolid = Color(red: 26/255, green: 26/255, blue: 30/255).opacity(0.88)
    static let hairline = Color.white.opacity(0.10)
}

/// 入场 fade-up 工具：opacity 0→1，y +10→0
private struct FadeUp: ViewModifier {
    let delay: Double
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 10)
            .onAppear { withAnimation(.easeOut(duration: 0.5).delay(delay)) { on = true } }
    }
}
private extension View {
    func fadeUp(delay: Double) -> some View { modifier(FadeUp(delay: delay)) }
}

// ============================================================
// 方案 A — 光环冲击波
// ============================================================
struct VarAView: View {
    let items: [CompletionItem]
    let model: PlaybackModel

    private struct Particle: Identifiable {
        let id: Int
        let p0: CGSize, p1: CGSize
        let duration: Double, delay: Double
    }
    @State private var particles: [Particle] = (0..<14).map { i in
        let ang = Double(i) / 14 * .pi * 2 + Double.random(in: 0..<0.5)
        let r0 = Double.random(in: 60..<130)
        let r1 = r0 + Double.random(in: 90..<220)
        let drift = Double.random(in: -30..<30)
        return Particle(
            id: i,
            p0: CGSize(width: cos(ang) * r0, height: sin(ang) * r0 * 0.7),
            p1: CGSize(width: cos(ang) * r1 + drift,
                       height: sin(ang) * r1 * 0.7 - Double.random(in: 70..<130)),
            duration: Double.random(in: 1.1..<1.8),
            delay: Double.random(in: 0.1..<0.55))
    }
    @State private var nameOn = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.18)
            ForEach(particles) { p in ParticleDot(p0: p.p0, p1: p.p1, duration: p.duration, delay: p.delay) }
            VStack(spacing: 14) {
                Text(items.count > 1 ? "\(items.count) 个任务完成" : items[0].name)
                    .font(.system(size: 68, weight: .bold))
                    .foregroundStyle(CTheme.txPrimary)
                    .shadow(color: CTheme.green.opacity(0.35), radius: 18)
                    .shadow(color: .black.opacity(0.5), radius: 9, y: 2)
                    .scaleEffect(nameOn ? 1 : 0.78)
                    .opacity(nameOn ? 1 : 0)
                    .onAppear {
                        withAnimation(.spring(duration: 0.6, bounce: 0.35).delay(0.05)) { nameOn = true }
                    }
                if items.count > 1 {
                    VStack(spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                            HStack(spacing: 10) {
                                Text("✓").font(.system(size: 15)).foregroundStyle(CTheme.greenHi)
                                Text(t.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(CTheme.txPrimary)
                                Text(t.time).font(.system(size: 15, design: .monospaced)).foregroundStyle(CTheme.txTertiary)
                            }
                        }
                    }
                    .fadeUp(delay: 0.5)
                } else {
                    HStack(spacing: 14) {
                        HStack(spacing: 7) {
                            Text("✓").font(.system(size: 17, weight: .bold))
                            Text(items[0].verb).font(.system(size: 19, weight: .bold))
                        }
                        .foregroundStyle(CTheme.greenHi)
                        Text(items[0].time)
                            .font(.system(size: 19, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(CTheme.txSecondary)
                    }
                    .fadeUp(delay: 0.42)
                    Text(items[0].task)
                        .font(.system(size: 15)).foregroundStyle(CTheme.txTertiary)
                        .lineLimit(1).frame(maxWidth: 520)
                        .fadeUp(delay: 0.55)
                }
            }
        }
        .opacity(model.leaving ? 0 : 1)
        .offset(y: model.leaving ? -10 : 0)
        .scaleEffect(model.leaving ? 0.985 : 1)
        .animation(.easeOut(duration: 0.38), value: model.leaving)
    }

    private func ring(delay: Double) -> some View {
        RingPulse(delay: delay)
    }
}

private struct RingPulse: View {
    let delay: Double
    @State private var go = false
    var body: some View {
        ZStack {
            // 内侧柔光（CSS inset 近似，调淡）
            Circle()
                .fill(RadialGradient(
                    colors: [CTheme.green.opacity(0), CTheme.green.opacity(0.015), CTheme.green.opacity(0.12)],
                    center: .center, startRadius: 60, endRadius: 120))
            // 光晕层：粗描边 + 高斯模糊（调淡）
            Circle()
                .stroke(CTheme.green.opacity(0.34), lineWidth: 8)
                .blur(radius: 12)
            // 主线
            Circle()
                .stroke(CTheme.green.opacity(0.85), lineWidth: 1.5)
                .shadow(color: CTheme.green.opacity(0.4), radius: 12)
        }
        .frame(width: 240, height: 240)
        .scaleEffect(go ? 5.2 : 0.22)
        .animation(.timingCurve(0.16, 0.7, 0.3, 1, duration: 1.55).delay(delay), value: go)
        // 透明度按原型 keyframe：12% 处到峰值 0.9，之后立刻进入 ease-out 衰减
        //（前段掉得快、长尾拖到结束）——bezier(0.16,0.7,0.3,1) 逐点采样
        .keyframeAnimator(initialValue: 0.0, trigger: go) { view, a in
            view.opacity(a)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                LinearKeyframe(0.0, duration: max(delay, 0.001))
                LinearKeyframe(0.9, duration: 0.19)
                LinearKeyframe(0.53, duration: 0.20)
                LinearKeyframe(0.33, duration: 0.20)
                LinearKeyframe(0.17, duration: 0.27)
                LinearKeyframe(0.06, duration: 0.34)
                LinearKeyframe(0.0, duration: 0.35)
            }
        }
        .onAppear { go = true }
    }
}

private struct ParticleDot: View {
    let p0: CGSize, p1: CGSize
    let duration: Double, delay: Double
    @State private var go = false
    var body: some View {
        Circle()
            .fill(CTheme.greenHi)
            .frame(width: 4, height: 4)
            .shadow(color: CTheme.green.opacity(0.8), radius: 4.5)
            .offset(go ? p1 : p0)
            .scaleEffect(go ? 1.05 : 0.5)
            .opacity(go ? 0 : 0.95)
            .animation(.easeOut(duration: duration).delay(delay), value: go)
            .onAppear { go = true }
    }
}

// ============================================================
// 方案 B — 终端胜利帧（逐字打出）
// ============================================================
struct VarBView: View {
    let items: [CompletionItem]
    let model: PlaybackModel

    private var charMs: Double { items.count > 1 ? 0.016 : 0.026 }
    private var lines: [[(String, Color)]] {
        items.map { t in
            [("✓ ", CTheme.greenHi), (t.name, CTheme.txPrimary),
             (" · \(t.verb) · ", CTheme.txSecondary), (t.time, CTheme.green)]
        }
    }
    private var totalChars: Int { lines.reduce(0) { $0 + $1.reduce(0) { $0 + $1.0.count } } }

    @State private var typed = 0
    @State private var entered = false
    private let tick = Timer.publish(every: 0.026, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.13)).frame(width: 11, height: 11)
                }
                Text("claude code")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CTheme.txTertiary)
                    .padding(.leading, 8)
                Spacer()
            }
            .frame(height: 36)
            .padding(.horizontal, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }

            VStack(alignment: .leading, spacing: 4) {
                let done = typed >= totalChars
                ForEach(visibleLines().indices, id: \.self) { i in
                    let segs = visibleLines()[i]
                    HStack(spacing: 0) {
                        // 原型：打字过程纯白，整行打完的瞬间才上色（终端高亮的"啪"感）
                        segs.reduce(Text("")) { acc, seg in
                            acc + Text(seg.0).foregroundColor(done ? seg.1 : CTheme.txPrimary)
                        }
                        .font(.system(size: 26, design: .monospaced))
                        if i == visibleLines().count - 1 {
                            CursorBlock(blinking: done)
                        }
                    }
                    .frame(minHeight: 43)
                }
                if items.count == 1 {
                    Text(items[0].task)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(CTheme.txTertiary)
                        .padding(.top, 6)
                        .opacity(typed >= totalChars ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(0.4), value: typed >= totalChars)
                }
            }
            .padding(EdgeInsets(top: 26, leading: 30, bottom: 30, trailing: 30))
        }
        .frame(width: 680, alignment: .leading)
        .background(CTheme.glassSolid)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CTheme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.75), radius: 45, y: 30)
        .shadow(color: CTheme.green.opacity(0.10), radius: 30)
        .scaleEffect(entered ? (model.leaving ? 0.99 : 1) : 0.955)
        .offset(y: entered ? (model.leaving ? -22 : 0) : 8)
        .opacity(entered ? (model.leaving ? 0 : 1) : 0)
        .animation(.timingCurve(0.2, 1, 0.3, 1, duration: 0.42), value: entered)
        .animation(.easeOut(duration: 0.75), value: model.leaving)
        .onAppear { entered = true }
        .onReceive(tick) { _ in
            if typed < totalChars { typed += items.count > 1 ? 2 : 1 }
        }
    }

    /// 按全局已打字数切分出可见行（含部分行）
    private func visibleLines() -> [[(String, Color)]] {
        var remain = typed
        var out: [[(String, Color)]] = []
        for line in lines {
            if remain <= 0 { break }
            var vis: [(String, Color)] = []
            for (text, color) in line {
                if remain <= 0 { break }
                let take = min(remain, text.count)
                vis.append((String(text.prefix(take)), color))
                remain -= take
            }
            out.append(vis)
        }
        return out.isEmpty ? [[]] : out
    }
}

private struct CursorBlock: View {
    let blinking: Bool
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(CTheme.greenHi)
            .frame(width: 13, height: 28)
            .shadow(color: CTheme.green.opacity(0.7), radius: 6)
            .padding(.leading, 3)
            .opacity(visible ? 1 : 0)
            .onChange(of: blinking) { _, on in
                guard on else { return }
                Task { @MainActor in
                    for _ in 0..<2 {
                        try? await Task.sleep(for: .milliseconds(360))
                        visible = false
                        try? await Task.sleep(for: .milliseconds(360))
                        visible = true
                    }
                }
            }
    }
}

// ============================================================
// 方案 C — 屏幕边缘呼吸
// ============================================================
struct VarCView: View {
    let items: [CompletionItem]
    let model: PlaybackModel
    @State private var nameOn = false

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    BreathingEdge(from: .top, to: .bottom, delay: 0,
                                  start: CGSize(width: 0, height: -h * 0.16 * 0.4))
                        .frame(height: h * 0.16)
                        .frame(maxHeight: .infinity, alignment: .top)
                    BreathingEdge(from: .bottom, to: .top, delay: 0.20,
                                  start: CGSize(width: 0, height: h * 0.16 * 0.4))
                        .frame(height: h * 0.16)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    BreathingEdge(from: .leading, to: .trailing, delay: 0.10,
                                  start: CGSize(width: -w * 0.12 * 0.4, height: 0))
                        .frame(width: w * 0.12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BreathingEdge(from: .trailing, to: .leading, delay: 0.10,
                                  start: CGSize(width: w * 0.12 * 0.4, height: 0))
                        .frame(width: w * 0.12)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Text(items.count > 1 ? "\(items.count) 个任务完成" : items[0].name)
                    Text("✓").foregroundStyle(CTheme.greenHi)
                        .shadow(color: CTheme.green.opacity(0.6), radius: 12)
                }
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(CTheme.txPrimary)
                .shadow(color: .black.opacity(0.55), radius: 11, y: 2)
                .scaleEffect(nameOn ? 1 : 0.96)
                .offset(y: nameOn ? 0 : 8)
                .opacity(nameOn ? 1 : 0)
                .onAppear {
                    withAnimation(.timingCurve(0.2, 1, 0.3, 1, duration: 0.55).delay(0.12)) { nameOn = true }
                }
                Group {
                    if items.count > 1 {
                        HStack(spacing: 16) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                                HStack(spacing: 5) {
                                    Text(t.name)
                                    Text(t.time).font(.system(size: 16, design: .monospaced))
                                        .foregroundStyle(CTheme.txTertiary)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Text(items[0].verb)
                            Text(items[0].time).font(.system(size: 16, design: .monospaced)).monospacedDigit()
                            Text(items[0].task)
                                .font(.system(size: 14)).foregroundStyle(CTheme.txTertiary)
                                .lineLimit(1).frame(maxWidth: 420)
                        }
                    }
                }
                .font(.system(size: 16))
                .foregroundStyle(CTheme.txSecondary)
                .fadeUp(delay: 0.4)
            }
        }
        .opacity(model.leaving ? 0 : 1)
        .scaleEffect(model.leaving ? 0.99 : 1)
        .animation(.easeOut(duration: 0.42), value: model.leaving)
    }
}

/// 边缘辉光：渐变本体（边缘 0.42 绿 → 透明），opacity 0→1(28%)→0.55(55%)→0，1.9s 错峰
private struct BreathingEdge: View {
    let from: UnitPoint
    let to: UnitPoint
    let delay: Double
    let start: CGSize
    @State private var phase = 0
    var body: some View {
        LinearGradient(colors: [CTheme.green.opacity(0.42), CTheme.green.opacity(0)],
                       startPoint: from, endPoint: to)
            .opacity(phase == 1 ? 1 : (phase == 2 ? 0.55 : 0))
            .offset(phase == 0 ? start : .zero)
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                    withAnimation(.timingCurve(0.3, 0, 0.3, 1, duration: 0.53)) { phase = 1 }
                    try? await Task.sleep(for: .milliseconds(530))
                    withAnimation(.linear(duration: 0.51)) { phase = 2 }
                    try? await Task.sleep(for: .milliseconds(510))
                    withAnimation(.easeOut(duration: 0.86)) { phase = 3 }
                }
            }
            .allowsHitTesting(false)
    }
}

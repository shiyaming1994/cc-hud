import SwiftUI
import CCHudCore

struct StatusDotView: View {
    let status: SessionStatus
    @State private var pulse = false

    // 实心半盘 ◐ 的 conic 渐变（半亮/半淡）。常量：每帧只变旋转角，渐变本身不重建。
    private static let workingGradient = AngularGradient(
        gradient: Gradient(stops: [
            .init(color: Theme.working, location: 0),
            .init(color: Theme.working, location: 0.5),
            .init(color: Theme.working.opacity(0.16), location: 0.5),
            .init(color: Theme.working.opacity(0.16), location: 1),
        ]),
        center: .center)

    var body: some View {
        ZStack {
            if status == .working {
                // 原型实心半盘 ◐（conic 半亮/半淡）。用 TimelineView 连续驱动旋转，而不是
                // .rotationEffect + repeatForever——repeatForever 在这套布局里会让图标随时间横移、飘出胶囊
                // （本项目 QuestionViews 也特意规避 repeatForever，用 TimelineView 离散驱动）。
                TimelineView(.animation) { tl in
                    let angle = tl.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.3) / 1.3 * 360.0
                    Circle()
                        .fill(Self.workingGradient)
                        .frame(width: 9, height: 9)
                        .rotationEffect(.degrees(angle))
                }
            } else {
                Circle()
                    .fill(Theme.statusColor(status))
                    .frame(width: 8, height: 8)   // 原型 .dot i 基础点 8px；working 圆环 9px
                    .opacity(status == .dead ? 0.55 : 1)
                    .overlay {
                        if status == .permission {
                            Circle()
                                .stroke(Theme.permission.opacity(0.55), lineWidth: 2)
                                .scaleEffect(pulse ? 2.1 : 1.0)
                                .opacity(pulse ? 0 : 0.8)
                                .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                        }
                    }
            }
        }
        .frame(width: 9, height: 9)
        .onAppear { pulse = (status == .permission) }
        .onChange(of: status) { _, new in pulse = (new == .permission) }
    }
}

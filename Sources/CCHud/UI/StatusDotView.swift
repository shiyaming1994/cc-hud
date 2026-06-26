import SwiftUI
import CCHudCore

struct StatusDotView: View {
    let status: SessionStatus

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
            switch status {
            case .working:
                // 实心半盘 ◐（conic 半亮/半淡）：TimelineView 连续驱动旋转，而不是
                // .rotationEffect + repeatForever——后者在这套布局里会让图标随时间横移、飘出胶囊。
                TimelineView(.animation) { tl in
                    let angle = tl.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.3) / 1.3 * 360.0
                    Circle()
                        .fill(Self.workingGradient)
                        .frame(width: 9, height: 9)
                        .rotationEffect(.degrees(angle))
                }
            case .permission:
                // 权限脉冲：扩散圈。同样用 TimelineView 离散驱动（与 working 一致地规避 repeatForever，
                // 后者作用在常驻视图上会持续重绘、且与本布局的隐式动画相互干扰）。
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    let eased = t * (2 - t)   // easeOut：快扩散、慢收尾
                    ZStack {
                        Circle().fill(Theme.permission).frame(width: 8, height: 8)
                        Circle()
                            .stroke(Theme.permission.opacity(0.55), lineWidth: 2)
                            .scaleEffect(1.0 + eased * 1.1)
                            .opacity(0.8 * (1 - eased))
                            .frame(width: 8, height: 8)
                    }
                }
            default:
                Circle()
                    .fill(Theme.statusColor(status))
                    .frame(width: 8, height: 8)   // 原型 .dot i 基础点 8px
                    .opacity(status == .dead ? 0.55 : 1)
            }
        }
        .frame(width: 9, height: 9)
    }
}

import SwiftUI

/// 岛的刘海几何（宽/高），由 NotchPanel 在每次落位时按当前屏幕刷新。
/// 不能做成视图的构造期常量——合盖/拔插换屏后刘海会变甚至消失，
/// 窗口位置由 reposition() 跟进了，视图内部的占位宽度也必须跟进。
@MainActor
final class NotchMetrics: ObservableObject {
    /// 刘海宽度；无刘海屏为 0，此时中间不留占位、渲染成一条完整胶囊。
    @Published var notchWidth: CGFloat = 0
    /// 静息岛高度基准 = 刘海高；无刘海屏用菜单栏高度兜底。
    @Published var notchHeight: CGFloat = 28
}

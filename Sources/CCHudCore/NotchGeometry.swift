import CoreGraphics

/// 刘海几何：屏幕参数 → 刘海矩形。菜单栏额度条用它做避让（见 MenuBarStrip.frame）。
/// 纯函数、不碰 AppKit（选屏留给 app 层），只吃 CGRect —— 与 Format 同样的可测性考量：
/// 多屏 / 无刘海 / 合盖的分支不单测必出事。
public enum NotchGeometry {
    /// 由屏幕参数解析刘海矩形（屏幕坐标系，左下原点）；无刘海屏返回 nil。
    /// aux 区缺失、或左右辅助区贴合无间隙，一律当无刘海——调用方据此渲染胶囊版。
    public static func notchRect(screenFrame: CGRect, safeAreaTop: CGFloat,
                                 auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard safeAreaTop > 0, let auxLeft, let auxRight else { return nil }
        let minX = auxLeft.maxX, maxX = auxRight.minX
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: screenFrame.maxY - safeAreaTop,
                      width: maxX - minX, height: safeAreaTop)
    }
}

import CoreGraphics

/// 面板外形：右边贴屏幕边缘，上下沿在贴边处外翻成弧，顺滑接进屏幕边缘（设计文档第 5 节、10.1、10.2）。
/// 坐标系：视图本地坐标，左上原点、y 向下，和 SwiftUI、窗口内容坐标一致；x = 宽 那条竖线就是屏幕边缘。
/// 同一条路径同时给 SwiftUI 裁切和描边、毛玻璃遮罩、点击判定用，三处不会对不上。
public enum EdgeShape {
    public enum Kind: Sendable, Equatable {
        /// 标签：圆心在右边缘上的半圆，上下用外翻弧和半圆相切
        case tab
        /// 方框（列表、展开）：左侧两个圆角，右侧上下各一道外翻弧
        case box
    }

    /// 外翻弧半径 f
    public static let ear: CGFloat = 6
    /// 标签半圆半径 R（= 标签宽）
    public static let tabRadius: CGFloat = 20
    /// 方框左侧圆角 r
    public static let boxCorner: CGFloat = 11

    /// 标签外形的精确高度：2·√((R+f)² − f²)，R 20、f 6 时约 50.6
    public static var tabShapeHeight: CGFloat {
        2 * ((tabRadius + ear) * (tabRadius + ear) - ear * ear).squareRoot()
    }

    /// 标签窗口尺寸：宽 R，高向上取整，外形在里面垂直居中
    public static var tabSize: CGSize {
        CGSize(width: tabRadius, height: tabShapeHeight.rounded(.up))
    }

    /// 方框九宫格遮罩图的尺寸：四个角 + 中间各留 1pt 可拉伸
    public static var boxMaskSize: CGSize {
        CGSize(width: boxCorner + 1 + ear, height: 2 * (ear + boxCorner) + 1)
    }

    /// 方框九宫格遮罩的 capInsets：上下 = f + r，左 = r，右 = f
    public static var boxMaskInsets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        (ear + boxCorner, boxCorner, ear + boxCorner, ear)
    }

    /// 闭合外形：填充、遮罩、点击判定用。最后一段沿屏幕边缘闭合。
    public static func path(_ kind: Kind, in size: CGSize) -> CGPath {
        let p = CGMutablePath()
        trace(kind, in: size, into: p)
        p.closeSubpath()
        return p
    }

    /// 开放外形：和 path 同一条线，只是不沿屏幕边缘闭合——描边用，贴边那一侧不描。
    public static func outline(_ kind: Kind, in size: CGSize) -> CGPath {
        let p = CGMutablePath()
        trace(kind, in: size, into: p)
        return p
    }

    /// 从右上角（屏幕边缘上）出发，绕外侧走到右下角。
    /// 弧的方向按路径自己的数值坐标判断：角度变大 clockwise = false，变小 = true，和显示时 y 轴朝哪无关。
    private static func trace(_ kind: Kind, in size: CGSize, into p: CGMutablePath) {
        let w = size.width, h = size.height, f = ear
        switch kind {
        case .tab:
            let r = w                                            // 半圆半径 = 宽
            let half = ((r + f) * (r + f) - f * f).squareRoot()  // 半圆圆心到外形顶边的高
            let top = (h - 2 * half) / 2                         // 外形在窗口里垂直居中
            let theta = atan2(half, f)                           // 外翻弧从 0 转到 theta，正好和半圆相切
            p.move(to: CGPoint(x: w, y: top))
            p.addArc(center: CGPoint(x: w - f, y: top), radius: f,
                     startAngle: 0, endAngle: theta, clockwise: false)
            p.addArc(center: CGPoint(x: w, y: top + half), radius: r,
                     startAngle: theta - .pi, endAngle: .pi - theta, clockwise: true)
            p.addArc(center: CGPoint(x: w - f, y: top + 2 * half), radius: f,
                     startAngle: -theta, endAngle: 0, clockwise: false)
        case .box:
            let r = min(boxCorner, max(0, (h - 2 * f) / 2))      // 太矮时圆角让位（正常用不到）
            p.move(to: CGPoint(x: w, y: 0))
            p.addArc(center: CGPoint(x: w - f, y: 0), radius: f,
                     startAngle: 0, endAngle: .pi / 2, clockwise: false)
            p.addLine(to: CGPoint(x: r, y: f))
            p.addArc(center: CGPoint(x: r, y: f + r), radius: r,
                     startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
            p.addLine(to: CGPoint(x: 0, y: h - f - r))
            p.addArc(center: CGPoint(x: r, y: h - f - r), radius: r,
                     startAngle: .pi, endAngle: .pi / 2, clockwise: true)
            p.addLine(to: CGPoint(x: w - f, y: h - f))
            p.addArc(center: CGPoint(x: w - f, y: h), radius: f,
                     startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        }
    }
}

import SwiftUI
import CCHudCore

/// EdgeShape 的 SwiftUI 包装。closed = true：闭合外形，填充、裁切、点击区域用；
/// closed = false：开放外形，描边用——贴屏幕边缘那一段不画（设计文档第 5 节）。
struct EdgeTabShape: Shape {
    let kind: EdgeShape.Kind
    var closed = true

    func path(in rect: CGRect) -> Path {
        let p = closed ? EdgeShape.path(kind, in: rect.size) : EdgeShape.outline(kind, in: rect.size)
        return Path(p).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

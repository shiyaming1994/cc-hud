import AppKit

extension NSScreen {
    /// 物理显示器 UUID（EDID 派生）：同一台显示器拔插、睡眠、换口都稳定；
    /// NSScreenNumber(displayID) 每次插拔可能变，不能当持久身份。
    /// 浮窗的拖放锚点存档与菜单栏额度条的常驻屏存档共用这一套身份。
    var displayUUID: String? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
}

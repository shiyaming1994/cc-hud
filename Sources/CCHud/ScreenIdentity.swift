import AppKit

extension NSScreen {
    /// 物理显示器 UUID（EDID 派生）：同一台显示器拔插、睡眠、换口都稳定；
    /// NSScreenNumber(displayID) 每次插拔可能变，不能当持久身份。
    /// 目前唯一使用者是 HUDPanel 的拖放锚点存档（hud.anchor.v2）。
    var displayUUID: String? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
}

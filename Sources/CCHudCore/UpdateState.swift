import Foundation

/// 更新流程状态。spec 中的 failed/upToDate 折叠进 idle:
/// 两者都是"弹窗提示后回落",菜单表现与 idle 无差别。
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(ReleaseInfo)
    case downloading(Double)   // 0...1
    case installing
}

/// 菜单该长什么样——纯映射放 core,UI 层只负责摆进 NSMenu
public struct UpdateMenuPresentation: Equatable, Sendable {
    public let bannerTitle: String?    // 状态行下方的横幅;nil = 不显示
    public let bannerEnabled: Bool     // 可点(→ 弹更新确认窗)
    public let checkItemTitle: String  // 「检查更新…」项标题
    public let checkItemEnabled: Bool
}

public extension UpdateState {
    var menuPresentation: UpdateMenuPresentation {
        switch self {
        case .idle:
            return .init(bannerTitle: nil, bannerEnabled: false,
                         checkItemTitle: "检查更新…", checkItemEnabled: true)
        case .checking:
            return .init(bannerTitle: nil, bannerEnabled: false,
                         checkItemTitle: "正在检查…", checkItemEnabled: false)
        case .available(let r):
            return .init(bannerTitle: "⬆ 有新版本 \(r.tagName),点击更新", bannerEnabled: true,
                         checkItemTitle: "检查更新…", checkItemEnabled: true)
        case .downloading(let p):
            return .init(bannerTitle: "正在下载更新… \(Int((p * 100).rounded()))%", bannerEnabled: false,
                         checkItemTitle: "检查更新…", checkItemEnabled: false)
        case .installing:
            return .init(bannerTitle: "正在安装更新…", bannerEnabled: false,
                         checkItemTitle: "检查更新…", checkItemEnabled: false)
        }
    }
}

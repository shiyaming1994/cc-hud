import Foundation

/// 语义化版本(major.minor.patch),接受 release tag 的 v 前缀。
/// 数值比较——"1.10.0" 必须大于 "1.9.9",字符串比较会出错。
public struct SemVer: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        var s = Substring(string)
        if s.hasPrefix("v") || s.hasPrefix("V") { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]),
              a >= 0, b >= 0, c >= 0 else { return nil }
        self.init(major: a, minor: b, patch: c)
    }

    public static func < (l: SemVer, r: SemVer) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

/// 一次可用更新的全部信息(展示 + 下载 + 校验所需)
public struct ReleaseInfo: Equatable, Sendable {
    public let tagName: String
    public let version: SemVer
    public let body: String
    public let dmgURL: URL
    public let dmgSize: Int
}

/// 查询 GitHub releases/latest 并判断是否比当前版本新。
/// 网络层可注入(fetch 闭包),测试不走真网络。
public struct UpdateChecker: Sendable {
    /// GitHub API:latest 天然不含 prerelease/draft,无需过滤
    public static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/shiyaming1994/cc-hud/releases/latest")!
    static let assetName = "CC-HUD.dmg"

    private struct GHRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [GHAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", body, assets
        }
    }
    private struct GHAsset: Decodable {
        let name: String
        let size: Int
        let downloadURL: String
        enum CodingKeys: String, CodingKey {
            case name, size, downloadURL = "browser_download_url"
        }
    }

    /// 解析失败(限流 HTML、tag 非法、缺资产)一律 nil——按无更新处理,不打扰用户
    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let r = try? JSONDecoder().decode(GHRelease.self, from: data),
              let version = SemVer(r.tagName),
              let asset = r.assets.first(where: { $0.name == assetName }),
              let url = URL(string: asset.downloadURL) else { return nil }
        return ReleaseInfo(tagName: r.tagName, version: version,
                           body: r.body ?? "", dmgURL: url, dmgSize: asset.size)
    }
}

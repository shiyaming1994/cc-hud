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

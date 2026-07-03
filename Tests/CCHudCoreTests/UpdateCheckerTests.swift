import XCTest
@testable import CCHudCore

final class UpdateCheckerTests: XCTestCase {
    // MARK: SemVer

    func testSemVerParsesPlainAndPrefixed() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemVer("v1.2.3"), SemVer(major: 1, minor: 2, patch: 3), "接受 v 前缀(release tag 形态)")
    }

    func testSemVerRejectsMalformed() {
        XCTAssertNil(SemVer("1.2"), "缺 patch 段")
        XCTAssertNil(SemVer("1.2.3.4"), "多余段")
        XCTAssertNil(SemVer("1.2.x"), "非数字")
        XCTAssertNil(SemVer(""), "空串")
        XCTAssertNil(SemVer("abc"))
    }

    func testSemVerNumericCompare() {
        XCTAssertTrue(SemVer("1.10.0")! > SemVer("1.9.9")!, "数值比较,不是字符串比较")
        XCTAssertTrue(SemVer("2.0.0")! > SemVer("1.99.99")!)
        XCTAssertTrue(SemVer("1.2.10")! > SemVer("1.2.9")!)
        XCTAssertFalse(SemVer("1.2.1")! > SemVer("1.2.1")!, "相等不算新")
    }

    // MARK: Release JSON 解析

    static let fixtureJSON = """
    {
      "tag_name": "v1.3.0",
      "prerelease": false,
      "body": "## 本次更新\\n\\n- 支持应用内自动更新",
      "assets": [
        {"name": "irrelevant.zip", "size": 1, "browser_download_url": "https://example.com/x.zip"},
        {"name": "CC-HUD.dmg", "size": 2855311,
         "browser_download_url": "https://github.com/shiyaming1994/cc-hud/releases/download/v1.3.0/CC-HUD.dmg"}
      ]
    }
    """

    func testParseReleasePicksDmgAsset() throws {
        let info = try XCTUnwrap(UpdateChecker.parseRelease(Data(Self.fixtureJSON.utf8)))
        XCTAssertEqual(info.tagName, "v1.3.0")
        XCTAssertEqual(info.version, SemVer("1.3.0"))
        XCTAssertEqual(info.dmgSize, 2855311)
        XCTAssertEqual(info.dmgURL.lastPathComponent, "CC-HUD.dmg")
        XCTAssertTrue(info.body.contains("自动更新"))
    }

    func testParseReleaseNilWhenNoDmgAsset() {
        let json = #"{"tag_name": "v1.3.0", "body": "", "assets": [{"name": "a.zip", "size": 1, "browser_download_url": "https://e.com/a.zip"}]}"#
        XCTAssertNil(UpdateChecker.parseRelease(Data(json.utf8)), "没有 CC-HUD.dmg 资产按无更新处理")
    }

    func testParseReleaseNilWhenTagMalformed() {
        let json = #"{"tag_name": "nightly", "body": "", "assets": [{"name": "CC-HUD.dmg", "size": 1, "browser_download_url": "https://e.com/d.dmg"}]}"#
        XCTAssertNil(UpdateChecker.parseRelease(Data(json.utf8)), "tag 不是 vX.Y.Z 按无更新处理,不弹错")
    }

    func testParseReleaseNilWhenNotJSON() {
        XCTAssertNil(UpdateChecker.parseRelease(Data("<html>rate limited</html>".utf8)))
    }

    func testParseReleaseToleratesNullBody() throws {
        let json = #"{"tag_name": "v9.9.9", "body": null, "assets": [{"name": "CC-HUD.dmg", "size": 5, "browser_download_url": "https://e.com/d.dmg"}]}"#
        let info = try XCTUnwrap(UpdateChecker.parseRelease(Data(json.utf8)))
        XCTAssertEqual(info.body, "", "body 为 null 时给空串,弹窗仍可用")
    }
}

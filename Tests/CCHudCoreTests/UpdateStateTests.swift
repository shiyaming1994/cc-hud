import XCTest
@testable import CCHudCore

final class UpdateStateTests: XCTestCase {
    private var release: ReleaseInfo {
        ReleaseInfo(tagName: "v1.3.0", version: SemVer("1.3.0")!, body: "",
                    dmgURL: URL(string: "https://e.com/CC-HUD.dmg")!, dmgSize: 1)
    }

    func testIdleHasNoBanner() {
        let p = UpdateState.idle.menuPresentation
        XCTAssertNil(p.bannerTitle)
        XCTAssertEqual(p.checkItemTitle, "检查更新…")
        XCTAssertTrue(p.checkItemEnabled)
    }

    func testCheckingDisablesCheckItem() {
        let p = UpdateState.checking.menuPresentation
        XCTAssertNil(p.bannerTitle)
        XCTAssertEqual(p.checkItemTitle, "正在检查…")
        XCTAssertFalse(p.checkItemEnabled)
    }

    func testAvailableShowsClickableBannerWithTag() {
        let p = UpdateState.available(release).menuPresentation
        XCTAssertEqual(p.bannerTitle, "⬆ 有新版本 v1.3.0,点击更新")
        XCTAssertTrue(p.bannerEnabled)
        XCTAssertTrue(p.checkItemEnabled, "有新版时仍可手动重查")
    }

    func testDownloadingShowsPercentBanner() {
        let p = UpdateState.downloading(0.45).menuPresentation
        XCTAssertEqual(p.bannerTitle, "正在下载更新… 45%")
        XCTAssertFalse(p.bannerEnabled)
        XCTAssertFalse(p.checkItemEnabled, "下载中不允许再触发检查")
    }

    func testInstallingBanner() {
        let p = UpdateState.installing.menuPresentation
        XCTAssertEqual(p.bannerTitle, "正在安装更新…")
        XCTAssertFalse(p.bannerEnabled)
        XCTAssertFalse(p.checkItemEnabled)
    }
}

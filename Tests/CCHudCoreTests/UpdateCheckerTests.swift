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
}

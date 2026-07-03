import XCTest
@testable import CCHudCore

final class UpdateInstallerTests: XCTestCase {
    var base: URL!          // 临时根
    var appsDir: URL!       // 模拟 /Applications
    var newApp: URL!        // 模拟 dmg 里的新版 app

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-\(UUID().uuidString)")
        appsDir = base.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        newApp = base.appendingPathComponent("CC HUD.app")
        try FileManager.default.createDirectory(at: newApp, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newApp.appendingPathComponent("marker.txt"))
    }
    override func tearDownWithError() throws {
        // 失败路径测试可能把目录改成只读,先恢复再删
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appsDir.path)
        try? FileManager.default.removeItem(at: base)
    }

    private func installOld() throws -> URL {
        let old = appsDir.appendingPathComponent("CC HUD.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("marker.txt"))
        return old
    }
    private var installer: UpdateInstaller {
        UpdateInstaller(applicationsDir: appsDir, appName: "CC HUD.app")
    }

    // MARK: replaceApp

    func testReplaceSwapsAppAtomically() throws {
        let dst = try installOld()
        try installer.replaceApp(with: newApp)
        let marker = try String(contentsOf: dst.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: appsDir.path)
            .filter { $0.hasPrefix(".CC HUD.app") }
        XCTAssertTrue(leftovers.isEmpty, "临时 .new/.old 必须清理干净")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newApp.path), "源(挂载卷)不动")
    }

    func testReplaceWorksWhenNoExistingApp() throws {
        try installer.replaceApp(with: newApp)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appsDir.appendingPathComponent("CC HUD.app/marker.txt").path))
    }

    func testReplaceCleansStaleTemps() throws {
        _ = try installOld()
        // 模拟上次更新中断留下的残留
        for stale in [".CC HUD.app.new", ".CC HUD.app.old"] {
            try FileManager.default.createDirectory(
                at: appsDir.appendingPathComponent(stale), withIntermediateDirectories: true)
        }
        try installer.replaceApp(with: newApp)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: appsDir.path)
            .filter { $0.hasPrefix(".CC HUD.app") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testReplaceThrowsAndKeepsOldWhenDirUnwritable() throws {
        let dst = try installOld()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appsDir.path)
        XCTAssertThrowsError(try installer.replaceApp(with: newApp)) { err in
            guard case UpdateError.replaceFailed = err else {
                return XCTFail("应为 replaceFailed,得到 \(err)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appsDir.path)
        let marker = try String(contentsOf: dst.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "old", "失败后旧版必须原样保留")
    }

    // MARK: hdiutil plist 解析

    func testMountPointParsedFromHdiutilPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>system-entities</key><array>
            <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
            <dict>
              <key>content-hint</key><string>Apple_HFS</string>
              <key>mount-point</key><string>/Volumes/CC HUD</string>
            </dict>
          </array>
        </dict></plist>
        """
        XCTAssertEqual(UpdateInstaller.mountPoint(fromHdiutilPlist: Data(plist.utf8)),
                       "/Volumes/CC HUD", "取第一个带 mount-point 的分区")
    }

    func testMountPointNilOnGarbage() {
        XCTAssertNil(UpdateInstaller.mountPoint(fromHdiutilPlist: Data("not a plist".utf8)))
        XCTAssertNil(UpdateInstaller.mountPoint(fromHdiutilPlist: Data()))
    }

    // MARK: 签名校验负路径

    func testTeamIdentifierNilForUnsignedDirectory() {
        XCTAssertNil(UpdateInstaller.teamIdentifier(of: newApp), "裸目录无签名 → nil,绝不能当有效")
    }

    func testTeamIdentifierNilForMissingPath() {
        XCTAssertNil(UpdateInstaller.teamIdentifier(
            of: base.appendingPathComponent("nonexistent.app")))
    }
}

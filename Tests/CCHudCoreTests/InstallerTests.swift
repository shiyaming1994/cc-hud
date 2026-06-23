import XCTest
@testable import CCHudCore

final class InstallerTests: XCTestCase {
    var claudeDir: URL!
    var emitSource: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-\(UUID().uuidString)")
        claudeDir = base.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        emitSource = base.appendingPathComponent("emit-src")
        try Data("#!/bin/true\n".utf8).write(to: emitSource)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: claudeDir.deletingLastPathComponent())
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testFreshInstall() throws {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "~/.claude/statusline.sh"]]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: claudeDir.appendingPathComponent("settings.json"))

        let installer = Installer(claudeDir: claudeDir, emitSourceURL: emitSource)
        let report = try installer.install()

        XCTAssertEqual(report.originalStatusLine, "~/.claude/statusline.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: claudeDir.appendingPathComponent("cc-hud/emit").path))
        let s = try readSettings()
        XCTAssertNotNil((s["hooks"] as! [String: Any])["PermissionRequest"])
        // 备份存在
        let backups = try FileManager.default.contentsOfDirectory(atPath: claudeDir.path)
            .filter { $0.hasPrefix("settings.json.cc-hud-backup-") }
        XCTAssertEqual(backups.count, 1)
        // config.json 记录 original
        let cfg = try JSONSerialization.jsonObject(
            with: Data(contentsOf: claudeDir.appendingPathComponent("cc-hud/config.json"))) as! [String: Any]
        XCTAssertEqual(cfg["originalStatusLine"] as? String, "~/.claude/statusline.sh")
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallWithoutSettingsFile() throws {
        let installer = Installer(claudeDir: claudeDir, emitSourceURL: emitSource)
        _ = try installer.install()
        let s = try readSettings()
        XCTAssertNotNil(s["hooks"])
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallIdempotentKeepsOriginalStatusLine() throws {
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "orig.sh"]]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: claudeDir.appendingPathComponent("settings.json"))
        let installer = Installer(claudeDir: claudeDir, emitSourceURL: emitSource)
        _ = try installer.install()
        _ = try installer.install()   // 第二次
        let cfg = try JSONSerialization.jsonObject(
            with: Data(contentsOf: claudeDir.appendingPathComponent("cc-hud/config.json"))) as! [String: Any]
        XCTAssertEqual(cfg["originalStatusLine"] as? String, "orig.sh", "二次安装不覆盖 original")
        let hooks = (try readSettings()["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(hooks.count, 1, "不重复追加")
    }

    func testBackupRotationKeepsFive() throws {
        try JSONSerialization.data(withJSONObject: ["model": "opus"])
            .write(to: claudeDir.appendingPathComponent("settings.json"))
        // 预置 7 份旧备份
        for i in 1...7 {
            try Data("old".utf8).write(to: claudeDir.appendingPathComponent(
                "settings.json.cc-hud-backup-2026010\(i)-000000"))
        }
        let installer = Installer(claudeDir: claudeDir, emitSourceURL: emitSource)
        _ = try installer.install()
        let backups = try FileManager.default.contentsOfDirectory(atPath: claudeDir.path)
            .filter { $0.hasPrefix("settings.json.cc-hud-backup-") }
        XCTAssertEqual(backups.count, 5, "7 旧 + 1 新 → 轮换只留 5")
        XCTAssertFalse(backups.contains("settings.json.cc-hud-backup-20260101-000000"),
                       "最旧的被清掉")
    }

    func testInvalidSettingsRefused() throws {
        try Data("{ not json".utf8).write(to: claudeDir.appendingPathComponent("settings.json"))
        let installer = Installer(claudeDir: claudeDir, emitSourceURL: emitSource)
        XCTAssertThrowsError(try installer.install())
        // 原文件未被改动
        let raw = try String(contentsOf: claudeDir.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertEqual(raw, "{ not json")
    }

    func testUninstallRestores() throws {
        let settings: [String: Any] = [
            "statusLine": ["type": "command", "command": "orig.sh"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay /x.wav"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: claudeDir.appendingPathComponent("settings.json"))
        let installer = Installer(claudeDir: claudeDir, emitSourceURL: emitSource)
        _ = try installer.install()
        try installer.uninstall()
        let s = try readSettings()
        XCTAssertEqual((s["statusLine"] as! [String: Any])["command"] as! String, "orig.sh")
        let stop = (s["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 1)
        XCTAssertFalse(installer.isInstalled())
    }
}

import Foundation

public struct InstallReport: Sendable {
    public let originalStatusLine: String?
}

public enum InstallError: Error, LocalizedError {
    case invalidSettings
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: return "~/.claude/settings.json 不是合法 JSON，已拒绝写入"
        }
    }
}

/// 接入安装器。所有路径注入，便于测试。
public struct Installer: Sendable {
    public let claudeDir: URL
    public let emitSourceURL: URL

    public var hudDir: URL { claudeDir.appendingPathComponent("cc-hud") }
    public var emitDest: URL { hudDir.appendingPathComponent("emit") }
    public var configURL: URL { hudDir.appendingPathComponent("config.json") }
    public var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    public var socketPath: String { hudDir.appendingPathComponent("hud.sock").path }

    // settings.json 里写的命令用 $HOME（hook 经 sh 执行会展开），与真实安装路径解耦
    public static let emitCommand = "\"$HOME/.claude/cc-hud/emit\" hook"
    public static let statusCommand = "\"$HOME/.claude/cc-hud/emit\" status"

    public init(claudeDir: URL, emitSourceURL: URL) {
        self.claudeDir = claudeDir
        self.emitSourceURL = emitSourceURL
    }

    @discardableResult
    public func install() throws -> InstallReport {
        let fm = FileManager.default
        try fm.createDirectory(at: hudDir, withIntermediateDirectories: true)

        // 1. emit 二进制（覆盖式更新）。
        // 必须剥离 quarantine：下载的 dmg/zip 里所有文件都带隔离标记，右键打开只豁免
        // app 本体的启动——拷出去的 emit 若带着标记，claude 一执行就被 Gatekeeper 拦截。
        if fm.fileExists(atPath: emitDest.path) { try fm.removeItem(at: emitDest) }
        try fm.copyItem(at: emitSourceURL, to: emitDest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: emitDest.path)
        removexattr(emitDest.path, "com.apple.quarantine", 0)

        // 2. 读 settings（缺失 = 空对象；非法 = 拒绝）
        var settings: [String: Any] = [:]
        let exists = fm.fileExists(atPath: settingsURL.path)
        if exists {
            let data = try Data(contentsOf: settingsURL)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.invalidSettings
            }
            settings = parsed
        }

        // 4'. merge 先行，无实际变化则不动文件（避免每次启动重排用户的 settings.json）
        let (merged, original) = SettingsMerger.merge(
            settings: settings, emitCommand: Self.emitCommand, statusCommand: Self.statusCommand)
        let outData = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let normalizedExisting = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let changed = outData != normalizedExisting

        // 3. 备份（仅在真要改动时；轮换：只保留最近 5 份）
        if exists && changed {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let backup = claudeDir.appendingPathComponent(
                "settings.json.cc-hud-backup-\(df.string(from: Date()))")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
            let backups = ((try? fm.contentsOfDirectory(atPath: claudeDir.path)) ?? [])
                .filter { $0.hasPrefix("settings.json.cc-hud-backup-") }
                .sorted()   // 时间戳命名，字典序即时间序
            for old in backups.dropLast(5) {
                try? fm.removeItem(at: claudeDir.appendingPathComponent(old))
            }
        }

        // 4. 写回（有变化才写）
        if changed {
            try outData.write(to: settingsURL, options: .atomic)
        }

        // 5. config.json：只在首次记录 original（幂等）
        var config: [String: Any] = [:]
        if let d = try? Data(contentsOf: configURL),
           let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            config = c
        }
        // merge 发现了非我们的 statusline = 用户当前真实配置，刷新记录
        //（重装场景：用户接入后又换过自己的 statusline，以最新为准）
        if let original {
            config["originalStatusLine"] = original
        }
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
            .write(to: configURL, options: .atomic)

        return InstallReport(originalStatusLine: config["originalStatusLine"] as? String)
    }

    public func uninstall() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var original: String? = nil
        if let d = try? Data(contentsOf: configURL),
           let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            original = c["originalStatusLine"] as? String
        }
        let restored = SettingsMerger.restore(
            settings: settings, emitCommand: Self.emitCommand,
            statusCommand: Self.statusCommand, originalStatusLine: original)
        try JSONSerialization.data(withJSONObject: restored,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: settingsURL, options: .atomic)
    }

    public func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: emitDest.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        let hasHook = SettingsMerger.hookEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == Self.emitCommand }
            }
        }
        let slOK = ((settings["statusLine"] as? [String: Any])?["command"] as? String) == Self.statusCommand
        return hasHook && slOK
    }
}

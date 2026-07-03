import Foundation
import Security

public enum UpdateError: LocalizedError, Equatable {
    case downloadFailed(String)
    case sizeMismatch(expected: Int, got: Int)
    case mountFailed
    case appNotFoundInDmg
    case teamMismatch(expected: String, got: String?)
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let why): return "下载失败:\(why)"
        case .sizeMismatch(let e, let g): return "下载不完整(期望 \(e) 字节,实际 \(g))"
        case .mountFailed: return "更新包无法挂载"
        case .appNotFoundInDmg: return "更新包内没有找到 CC HUD.app"
        case .teamMismatch(let e, let g):
            return "更新包签名校验失败(期望 \(e),实际 \(g ?? "无签名")),已取消安装"
        case .replaceFailed(let why): return "替换应用失败:\(why)"
        }
    }
}

/// 下载 → 挂载 → 校验 → 原子替换 → 重启调度。
/// 目录可注入:测试在临时目录里演练完整替换序列。
public struct UpdateInstaller: Sendable {
    public let applicationsDir: URL
    public let appName: String

    public init(applicationsDir: URL = URL(fileURLWithPath: "/Applications"),
                appName: String = "CC HUD.app") {
        self.applicationsDir = applicationsDir
        self.appName = appName
    }

    /// 原子替换:全程同目录 rename(同卷保证原子),任何一步失败回滚到旧版。
    /// 运行中的进程不受影响——二进制已映射内存,旧 bundle 被 rename 走也能继续跑到退出。
    public func replaceApp(with newAppDir: URL) throws {
        let fm = FileManager.default
        let dst = applicationsDir.appendingPathComponent(appName)
        let staged = applicationsDir.appendingPathComponent(".\(appName).new")
        let old = applicationsDir.appendingPathComponent(".\(appName).old")
        // 上次更新中断的残留先清掉
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)

        do {
            // 先整体落到目标同目录(同卷),后续 rename 才是原子的
            try fm.copyItem(at: newAppDir, to: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError.replaceFailed("拷贝新版本失败:\(error.localizedDescription)")
        }
        let hadOld = fm.fileExists(atPath: dst.path)
        if hadOld {
            do { try fm.moveItem(at: dst, to: old) } catch {
                try? fm.removeItem(at: staged)
                throw UpdateError.replaceFailed("移开旧版本失败:\(error.localizedDescription)")
            }
        }
        do { try fm.moveItem(at: staged, to: dst) } catch {
            if hadOld { try? fm.moveItem(at: old, to: dst) }   // 回滚
            try? fm.removeItem(at: staged)
            throw UpdateError.replaceFailed("放置新版本失败:\(error.localizedDescription)")
        }
        if hadOld { try? fm.removeItem(at: old) }
    }

    // MARK: - 挂载

    /// hdiutil attach -plist 输出 → 挂载点。多分区 dmg 取第一个有 mount-point 的
    static func mountPoint(fromHdiutilPlist data: Data) -> String? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    // MARK: - 签名校验

    /// 签名有效时返回 TeamIdentifier;无签名/签名破损/路径不存在一律 nil。
    /// 防篡改关卡:新包 Team 必须与当前运行 app 一致才允许安装。
    public static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - 下载 + 安装组装

    /// 完整更新链:下载(报进度)→ 尺寸校验 → 挂载 → 签名校验 → 原子替换。
    /// nonisolated async:hdiutil 的秒级同步等待不在主线程上。
    public func downloadAndInstall(_ release: ReleaseInfo, expectedTeam: String,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("cc-hud-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }
        let dmgFile = tmpDir.appendingPathComponent("CC-HUD.dmg")

        // 1. 下载:逐块累积,每 64KB 报一次进度(资产仅 ~3MB,粒度足够)
        var req = URLRequest(url: release.dmgURL)
        req.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var data = Data()
        data.reserveCapacity(release.dmgSize)
        var lastReported = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count - lastReported >= 65536 {
                lastReported = data.count
                progress(min(1, Double(data.count) / Double(release.dmgSize)))
            }
        }
        guard data.count == release.dmgSize else {
            throw UpdateError.sizeMismatch(expected: release.dmgSize, got: data.count)
        }
        try data.write(to: dmgFile)
        progress(1)

        // 2. 挂载
        guard let mnt = runHdiutil(["attach", "-nobrowse", "-readonly", "-plist", dmgFile.path])
            .flatMap({ Self.mountPoint(fromHdiutilPlist: $0) }) else {
            throw UpdateError.mountFailed
        }
        defer { _ = runHdiutil(["detach", mnt, "-quiet"]) }

        // 3. 定位 + 签名校验 + 替换
        let newApp = URL(fileURLWithPath: mnt).appendingPathComponent(appName)
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.appNotFoundInDmg }
        let got = Self.teamIdentifier(of: newApp)
        guard got == expectedTeam else {
            throw UpdateError.teamMismatch(expected: expectedTeam, got: got)
        }
        try replaceApp(with: newApp)
    }

    /// 成功时返回 stdout,非零退出返回 nil
    private func runHdiutil(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    // MARK: - 重启

    /// 游离 shell:等本进程退出后 open 新版。不 wait——本进程马上 terminate
    public func scheduleRelaunch(afterSeconds seconds: Double = 1) {
        let appPath = applicationsDir.appendingPathComponent(appName).path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep \(seconds); /usr/bin/open \"\(appPath)\""]
        try? p.run()
    }
}

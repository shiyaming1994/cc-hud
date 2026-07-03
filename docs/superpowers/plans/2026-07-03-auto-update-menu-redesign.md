# CC HUD 自动更新 + 菜单重组 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 应用内检查 GitHub Releases 新版本,一键下载、校验签名、原子替换、自动重启;同时把菜单栏菜单从 13 项重组为 9 项(排障项收进子菜单)。

**Architecture:** 纯逻辑(版本比较、API 解析、文件替换)放 `CCHudCore` 用 XCTest 覆盖;UI 编排(状态机调度、弹窗、菜单)放 `CCHud`。更新源为 GitHub `releases/latest` API,防篡改靠 codesign TeamIdentifier 校验(新包必须与当前运行 app 同 Team)。

**Tech Stack:** Swift 6(SPM,无新依赖)、URLSession、Security framework(SecStaticCode)、hdiutil(Process 调用)、AppKit(NSMenu/NSAlert)。

**Spec:** `docs/superpowers/specs/2026-07-03-auto-update-menu-redesign-design.md`(已批准,行为以 spec 为准)

## Global Constraints

- macOS 15+,Swift 6 语言模式(swift-tools 6.0 默认),不修改 `Package.swift`(无新依赖、无 resources)。
- `CCHudCore` 禁止 `import AppKit`(可以 `import Security`)。
- 版本号唯一来源 `AppInfo.version`(`Sources/CCHud/AppInfo.swift`),当前 `1.2.1`。
- 所有用户可见文案为中文;代码注释风格与现有代码一致(中文,解释"为什么")。
- 测试框架 XCTest,`@testable import CCHudCore`,临时目录模式参照 `Tests/CCHudCoreTests/InstallerTests.swift`。
- 更新资产:仓库 `shiyaming1994/cc-hud`,tag `vX.Y.Z`,资产名固定 `CC-HUD.dmg`。
- commit 用 conventional commits + 中文描述(如 `feat(update): ...`),每个任务至少一次 commit。
- spec 中 UpdateState 的 `failed`/`upToDate` 两态在实现中折叠进 `idle`(行为不变:弹窗提示后回落;两态无菜单差异、无持久语义)。

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/CCHudCore/UpdateChecker.swift` | 新建 | `SemVer` + `ReleaseInfo` + `UpdateChecker`(API 解析、版本比较、网络注入) |
| `Sources/CCHudCore/UpdateInstaller.swift` | 新建 | `UpdateError` + `UpdateInstaller`(下载、挂载、签名校验、原子替换、重启调度) |
| `Sources/CCHudCore/UpdateState.swift` | 新建 | `UpdateState` + 菜单表现映射(纯映射,可单测) |
| `Sources/CCHud/UpdateController.swift` | 新建 | 状态机持有 + 定时调度 + 弹窗交互 |
| `Sources/CCHud/StatusItemController.swift` | 重写 rebuildMenu | 菜单重组 + `InstallState` 结构化状态行 |
| `Sources/CCHud/AppDelegate.swift` | 修改 | 接线 UpdateController、状态行、事件文案 |
| `Tests/CCHudCoreTests/UpdateCheckerTests.swift` | 新建 | SemVer / 解析 / checkLatest |
| `Tests/CCHudCoreTests/UpdateInstallerTests.swift` | 新建 | 替换序列成功/失败/残留清理、hdiutil plist 解析、签名校验负路径 |
| `Tests/CCHudCoreTests/UpdateStateTests.swift` | 新建 | 各状态的菜单表现 |
| `README.zh-CN.md` / `README.md` | 修改 | 发版约定小节 |

---

### Task 1: SemVer 版本解析与比较

**Files:**
- Create: `Sources/CCHudCore/UpdateChecker.swift`
- Test: `Tests/CCHudCoreTests/UpdateCheckerTests.swift`

**Interfaces:**
- Produces: `public struct SemVer: Comparable, Equatable, Sendable`,`init?(_ string: String)`(接受 `"1.2.3"` 与 `"v1.2.3"`),`<` 按 major.minor.patch 数值字典序。

- [ ] **Step 1: 写失败测试**

创建 `Tests/CCHudCoreTests/UpdateCheckerTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -5`
Expected: 编译失败,`cannot find 'SemVer' in scope`

- [ ] **Step 3: 最小实现**

创建 `Sources/CCHudCore/UpdateChecker.swift`:

```swift
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
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -3`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHudCore/UpdateChecker.swift Tests/CCHudCoreTests/UpdateCheckerTests.swift
git commit -m "feat(update): SemVer 版本解析与数值比较"
```

---

### Task 2: GitHub Release 响应解析

**Files:**
- Modify: `Sources/CCHudCore/UpdateChecker.swift`(追加)
- Test: `Tests/CCHudCoreTests/UpdateCheckerTests.swift`(追加)

**Interfaces:**
- Consumes: `SemVer`(Task 1)。
- Produces: `public struct ReleaseInfo: Equatable, Sendable { tagName: String, version: SemVer, body: String, dmgURL: URL, dmgSize: Int }`;`UpdateChecker.parseRelease(_ data: Data) -> ReleaseInfo?`(internal,供测试与 Task 3)。

- [ ] **Step 1: 写失败测试**

在 `UpdateCheckerTests.swift` 追加(fixture 为真实 GitHub API 响应形状):

```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -5`
Expected: 编译失败,`cannot find 'UpdateChecker' in scope`

- [ ] **Step 3: 实现解析**

在 `Sources/CCHudCore/UpdateChecker.swift` 追加:

```swift
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
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -3`
Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHudCore/UpdateChecker.swift Tests/CCHudCoreTests/UpdateCheckerTests.swift
git commit -m "feat(update): GitHub release 响应解析(资产定位/容错)"
```

---

### Task 3: UpdateChecker.checkLatest(网络注入)

**Files:**
- Modify: `Sources/CCHudCore/UpdateChecker.swift`(追加)
- Test: `Tests/CCHudCoreTests/UpdateCheckerTests.swift`(追加)

**Interfaces:**
- Produces:
  - `UpdateChecker.init?(currentVersionString: String, fetch: @escaping @Sendable (URL) async throws -> Data)`(fetch 有默认值 `Self.defaultFetch`;版本串非法返回 nil)
  - `func checkLatest() async throws -> ReleaseInfo?`(nil = 已最新或解析失败;throws = 网络错误)

- [ ] **Step 1: 写失败测试**

在 `UpdateCheckerTests.swift` 追加:

```swift
    // MARK: checkLatest

    func testCheckLatestReturnsNewerRelease() async throws {
        let checker = try XCTUnwrap(UpdateChecker(currentVersionString: "1.2.1",
                                                  fetch: { _ in Data(Self.fixtureJSON.utf8) }))
        let info = try await checker.checkLatest()
        XCTAssertEqual(info?.tagName, "v1.3.0")
    }

    func testCheckLatestNilWhenUpToDate() async throws {
        let checker = try XCTUnwrap(UpdateChecker(currentVersionString: "1.3.0",
                                                  fetch: { _ in Data(Self.fixtureJSON.utf8) }))
        let info = try await checker.checkLatest()
        XCTAssertNil(info, "相同版本不算新")
    }

    func testCheckLatestNilWhenCurrentNewer() async throws {
        let checker = try XCTUnwrap(UpdateChecker(currentVersionString: "9.0.0",
                                                  fetch: { _ in Data(Self.fixtureJSON.utf8) }))
        let info = try await checker.checkLatest()
        XCTAssertNil(info, "本地比 release 新(开发中)不提示")
    }

    func testCheckLatestPropagatesNetworkError() async {
        struct Boom: Error {}
        let checker = UpdateChecker(currentVersionString: "1.2.1", fetch: { _ in throw Boom() })!
        do {
            _ = try await checker.checkLatest()
            XCTFail("网络错误应该抛出(调用方区分静默/弹窗)")
        } catch {}
    }

    func testCheckerInitNilOnBadCurrentVersion() {
        XCTAssertNil(UpdateChecker(currentVersionString: "dev", fetch: { _ in Data() }))
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -5`
Expected: 编译失败,`UpdateChecker` 无该 init / `checkLatest` 未定义

- [ ] **Step 3: 实现**

在 `UpdateChecker` struct 内追加:

```swift
    private let currentVersion: SemVer
    private let fetch: @Sendable (URL) async throws -> Data

    /// currentVersionString 传 AppInfo.version;非法版本串返回 nil(调用方降级为"不支持更新")
    public init?(currentVersionString: String,
                 fetch: @escaping @Sendable (URL) async throws -> Data = UpdateChecker.defaultFetch) {
        guard let v = SemVer(currentVersionString) else { return nil }
        self.currentVersion = v
        self.fetch = fetch
    }

    public static let defaultFetch: @Sendable (URL) async throws -> Data = { url in
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// nil = 已最新(或响应解析失败,按无更新处理);throws = 网络层错误
    public func checkLatest() async throws -> ReleaseInfo? {
        let data = try await fetch(Self.latestReleaseURL)
        guard let info = Self.parseRelease(data) else {
            DebugLog.log("update: release 响应解析失败(\(data.count)B)")
            return nil
        }
        return info.version > currentVersion ? info : nil
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -3`
Expected: `Executed 13 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHudCore/UpdateChecker.swift Tests/CCHudCoreTests/UpdateCheckerTests.swift
git commit -m "feat(update): checkLatest 组装(网络注入,新版判定)"
```

---

### Task 4: 原子替换 replaceApp

**Files:**
- Create: `Sources/CCHudCore/UpdateInstaller.swift`
- Test: `Tests/CCHudCoreTests/UpdateInstallerTests.swift`

**Interfaces:**
- Produces:
  - `public enum UpdateError: LocalizedError, Equatable`(cases: `downloadFailed(String)`, `sizeMismatch(expected: Int, got: Int)`, `mountFailed`, `appNotFoundInDmg`, `teamMismatch(expected: String, got: String?)`, `replaceFailed(String)`;`errorDescription` 全中文)
  - `public struct UpdateInstaller: Sendable { init(applicationsDir: URL, appName: String) }`(默认 `/Applications`、`"CC HUD.app"`)
  - `func replaceApp(with newAppDir: URL) throws`

- [ ] **Step 1: 写失败测试**

创建 `Tests/CCHudCoreTests/UpdateInstallerTests.swift`:

```swift
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
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter UpdateInstallerTests 2>&1 | tail -5`
Expected: 编译失败,`cannot find 'UpdateInstaller' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/CCHudCore/UpdateInstaller.swift`:

```swift
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
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter UpdateInstallerTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHudCore/UpdateInstaller.swift Tests/CCHudCoreTests/UpdateInstallerTests.swift
git commit -m "feat(update): 原子替换(同目录 rename,失败回滚)"
```

---

### Task 5: 下载、挂载、签名校验与安装组装

**Files:**
- Modify: `Sources/CCHudCore/UpdateInstaller.swift`(追加)
- Test: `Tests/CCHudCoreTests/UpdateInstallerTests.swift`(追加)

**Interfaces:**
- Consumes: `ReleaseInfo`(Task 2)、`replaceApp`(Task 4)。
- Produces:
  - `static func mountPoint(fromHdiutilPlist: Data) -> String?`(internal,可测)
  - `public static func teamIdentifier(of url: URL) -> String?`(签名无效/无签名返回 nil)
  - `public func downloadAndInstall(_ release: ReleaseInfo, expectedTeam: String, progress: @escaping @Sendable (Double) -> Void) async throws`
  - `public func scheduleRelaunch(afterSeconds: Double)`(默认 1 秒)

单测只覆盖纯解析与负路径(plist 解析、无签名路径);下载/hdiutil/真实签名在 Task 10 端到端验证——mock 这三者的成本高于收益。

- [ ] **Step 1: 写失败测试**

在 `UpdateInstallerTests.swift` 追加:

```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter UpdateInstallerTests 2>&1 | tail -5`
Expected: 编译失败,`mountPoint`/`teamIdentifier` 未定义

- [ ] **Step 3: 实现**

在 `UpdateInstaller` struct 内追加:

```swift
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
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter UpdateInstallerTests 2>&1 | tail -3`
Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: 全量测试(确认没破坏现有)**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通过,`0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/CCHudCore/UpdateInstaller.swift Tests/CCHudCoreTests/UpdateInstallerTests.swift
git commit -m "feat(update): 下载/挂载/签名校验/安装组装 + 重启调度"
```

---

### Task 6: UpdateState 与菜单表现映射

**Files:**
- Create: `Sources/CCHudCore/UpdateState.swift`
- Test: `Tests/CCHudCoreTests/UpdateStateTests.swift`

**Interfaces:**
- Consumes: `ReleaseInfo`(Task 2)。
- Produces:
  - `public enum UpdateState: Equatable, Sendable { case idle, checking, available(ReleaseInfo), downloading(Double), installing }`
  - `public struct UpdateMenuPresentation: Equatable, Sendable { bannerTitle: String?, bannerEnabled: Bool, checkItemTitle: String, checkItemEnabled: Bool }`
  - `public extension UpdateState { var menuPresentation: UpdateMenuPresentation }`

- [ ] **Step 1: 写失败测试**

创建 `Tests/CCHudCoreTests/UpdateStateTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter UpdateStateTests 2>&1 | tail -5`
Expected: 编译失败,`cannot find 'UpdateState' in scope`

- [ ] **Step 3: 实现**

创建 `Sources/CCHudCore/UpdateState.swift`:

```swift
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
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter UpdateStateTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/CCHudCore/UpdateState.swift Tests/CCHudCoreTests/UpdateStateTests.swift
git commit -m "feat(update): UpdateState 与菜单表现映射"
```

---

### Task 7: UpdateController(调度 + 弹窗 + 下载驱动)

**Files:**
- Create: `Sources/CCHud/UpdateController.swift`

**Interfaces:**
- Consumes: `UpdateChecker`、`UpdateInstaller`、`UpdateState`、`ReleaseInfo`(Task 1-6),`AppInfo.version`。
- Produces(供 Task 8/9):
  - `@MainActor final class UpdateController`
  - `private(set) var state: UpdateState`、`var onStateChange: (() -> Void)?`
  - `func startAutomaticChecks()`(启动 ~10s 首查 + 每 24h)
  - `func checkNow()`(手动检查,有弹窗反馈)
  - `func presentUpdateAlert()`(available 态弹更新确认窗;菜单横幅点击入口)

CCHud 是 executable target,无法被测试目标 import——本任务以构建通过 + Task 10 端到端验证兜底。

- [ ] **Step 1: 实现**

创建 `Sources/CCHud/UpdateController.swift`:

```swift
import AppKit
import CCHudCore

/// 更新编排:定时调度、状态持有、弹窗交互。
/// 检查/下载/替换的可测逻辑都在 CCHudCore(UpdateChecker / UpdateInstaller),这里只做 UI 编排。
@MainActor
final class UpdateController {
    private(set) var state: UpdateState = .idle {
        didSet { onStateChange?() }
    }
    /// 状态变化 → 菜单重建(StatusItemController 注册)
    var onStateChange: (() -> Void)?

    private let checker: UpdateChecker?
    private let installer = UpdateInstaller()
    private var periodicTimer: Timer?
    private var firstCheckTask: Task<Void, Never>?

    init() {
        checker = UpdateChecker(currentVersionString: AppInfo.version)
    }

    /// 启动后 ~10s 首查(避开启动高峰),之后每 24h 一次;自动检查静默,只亮菜单不弹窗
    func startAutomaticChecks() {
        firstCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.check(userInitiated: false)
        }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.check(userInitiated: false) }
        }
    }

    /// 菜单「检查更新…」入口:有弹窗反馈(已最新/失败都提示)
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard let checker else {
            if userInitiated { info("检查更新失败", "当前版本号无法解析(\(AppInfo.version))。") }
            return
        }
        switch state {
        case .downloading, .installing, .checking: return   // 更新流程进行中不重入
        case .idle, .available: break
        }
        state = .checking
        do {
            if let release = try await checker.checkLatest() {
                state = .available(release)
                if userInitiated { presentUpdateAlert() }
            } else {
                state = .idle
                if userInitiated { info("已是最新版本", "当前 v\(AppInfo.version) 即最新发布版本。") }
            }
        } catch {
            state = .idle
            DebugLog.log("update: 检查失败 \(error.localizedDescription)")
            if userInitiated { info("检查更新失败", "请稍后重试:\(error.localizedDescription)") }
        }
    }

    /// 更新确认窗:changelog(markdown 简单渲染,失败退回纯文本)+ [立即更新][稍后]
    func presentUpdateAlert() {
        guard case .available(let release) = state else { return }
        let alert = NSAlert()
        alert.messageText = "CC HUD \(release.tagName)"
        alert.informativeText = "发现新版本(当前 v\(AppInfo.version)),更新日志:"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        text.isEditable = false
        text.drawsBackground = false
        if let md = try? AttributedString(
            markdown: release.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            var styled = md
            styled.foregroundColor = NSColor.labelColor
            text.textStorage?.setAttributedString(NSAttributedString(styled))
        } else {
            text.string = release.body
            text.textColor = .labelColor
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        alert.accessoryView = scroll

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            startDownload(release)
        }
    }

    private func startDownload(_ release: ReleaseInfo) {
        // 期望 Team 取自当前运行 app(证书轮换同 Team 仍通过);
        // ad-hoc 开发构建无 Team → 拒绝自动更新,避免开发时误替换 /Applications
        guard let team = UpdateInstaller.teamIdentifier(of: Bundle.main.bundleURL) else {
            info("无法自动更新", "当前为开发构建(无稳定签名身份),请用 build-app.sh 部署或手动更新。")
            return
        }
        state = .downloading(0)
        let installer = self.installer
        Task {
            do {
                try await installer.downloadAndInstall(release, expectedTeam: team) { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.state { self?.state = .downloading(p) }
                    }
                }
                state = .installing
                installer.scheduleRelaunch()
                NSApp.terminate(nil)
            } catch {
                state = .idle
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "更新失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "前往 Releases 页面")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "https://github.com/shiyaming1994/cc-hud/releases")!)
        }
    }

    private func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
```

- [ ] **Step 2: 构建验证**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`(无 warning 视为通过;Swift 6 并发报错必须修复而不是加 `@unchecked`)

- [ ] **Step 3: Commit**

```bash
git add Sources/CCHud/UpdateController.swift
git commit -m "feat(update): UpdateController 调度/弹窗/下载驱动"
```

---

### Task 8: 菜单重组(StatusItemController)

**Files:**
- Modify: `Sources/CCHud/StatusItemController.swift`(重写状态行与 rebuildMenu,init 增参)

**Interfaces:**
- Consumes: `UpdateController`(Task 7)、`UpdateState.menuPresentation`(Task 6)。
- Produces(供 Task 9):
  - `enum InstallState { case ok, failed(String), uninstalled, serverError(String) }`(定义在 StatusItemController.swift 顶部,CCHud 层)
  - `init` 第一个参数变为 `updateController: UpdateController`,其余参数不变
  - `func setInstallState(_ state: InstallState)` 替代 `setInstallStatus(_ text: String)`;`installStatusText` 属性删除

菜单目标结构(spec):状态行(+横幅)| sep | 显示/隐藏 HUD | sep | 动画▸ 焦点 燃尽 登录 | sep | 权限与排障▸ 检查更新… 退出。

- [ ] **Step 1: 修改**

对 `Sources/CCHud/StatusItemController.swift` 做以下修改。

文件顶部(import 之后、class 之前)加:

```swift
/// 接入状态的结构化表达——菜单状态行按 case 渲染:正常灰色一行,异常显眼可点
enum InstallState {
    case ok
    case failed(String)
    case uninstalled
    case serverError(String)
}
```

class 内属性区:删除 `private(set) var installStatusText = "未安装"`,替换为:

```swift
    private let updateController: UpdateController
    private var installState: InstallState = .failed("未安装")
```

init 签名与实现(整体替换现有 init):

```swift
    init(updateController: UpdateController,
         togglePanel: @escaping () -> Void, reinstall: @escaping () -> Void,
         uninstall: @escaping () -> Void, eventStatus: @escaping () -> String,
         previewAnimation: @escaping (String) -> Void,
         previewBurnout: @escaping () -> Void) {
        self.updateController = updateController
        self.togglePanel = togglePanel
        self.reinstall = reinstall
        self.uninstallAction = uninstall
        self.eventStatus = eventStatus
        self.previewAnimation = previewAnimation
        self.previewBurnout = previewBurnout
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack.fill",
                                     accessibilityDescription: "CC HUD")
        menu.delegate = self
        item.menu = menu
        // 更新状态变化(发现新版/下载进度)→ 即时重建,菜单开着也能看到进度跳动
        updateController.onStateChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
    }
```

`setInstallStatus` 替换为:

```swift
    func setInstallState(_ state: InstallState) {
        installState = state
        rebuildMenu()
    }
```

`rebuildMenu()` 整体替换为:

```swift
    private func rebuildMenu() {
        menu.removeAllItems()
        // ── 状态行:版本+接入状态合并一行;正常零噪音,异常显眼可点
        switch installState {
        case .ok:
            let s = NSMenuItem(title: "CC HUD v\(AppInfo.version) · 运行正常",
                               action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
        case .failed(let why):
            let s = makeItem("⚠ 接入失败 · 点击重新安装", #selector(reinstallAction))
            s.toolTip = why
            menu.addItem(s)
        case .uninstalled:
            menu.addItem(makeItem("已卸载接入 · 点击恢复", #selector(reinstallAction)))
        case .serverError(let why):
            let s = NSMenuItem(title: "⚠ 事件服务启动失败", action: nil, keyEquivalent: "")
            s.isEnabled = false
            s.toolTip = why   // 端口占用等,重装修不了——只展示原因
            menu.addItem(s)
        }
        // ── 更新横幅(有新版 / 下载中 / 安装中才出现)
        let pres = updateController.state.menuPresentation
        if let banner = pres.bannerTitle {
            if pres.bannerEnabled {
                let b = makeItem(banner, #selector(updateBannerAction))
                b.attributedTitle = NSAttributedString(string: banner, attributes: [
                    .foregroundColor: NSColor.controlAccentColor,
                ])
                menu.addItem(b)
            } else {
                let b = NSMenuItem(title: banner, action: nil, keyEquivalent: "")
                b.isEnabled = false
                menu.addItem(b)
            }
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("显示 / 隐藏 HUD", #selector(togglePanelAction)))
        menu.addItem(.separator())
        // ── 设置(高频开关留顶层,随手可切)
        let animMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: CompletionAnimator.styleKey) ?? "a"
        let styles: [(String, String)] = [
            ("off", "关闭"), ("a", "光环"), ("b", "打字机"), ("c", "呼吸灯"),
        ]
        for (key, name) in styles {
            let mi = NSMenuItem(title: name, action: #selector(pickAnimStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            mi.state = current == key ? .on : .off
            animMenu.addItem(mi)
        }
        let animRoot = NSMenuItem(title: "提示动画(完成 / 提问)", action: nil, keyEquivalent: "")
        animRoot.submenu = animMenu
        menu.addItem(animRoot)
        let focusItem = makeItem("焦点会话不提示", #selector(toggleFocusSuppress))
        focusItem.state = TerminalFocus.suppressEnabled ? .on : .off
        menu.addItem(focusItem)
        let burnoutItem = makeItem("额度燃尽预警", #selector(toggleBurnout))
        burnoutItem.state = BurnoutAlertController.enabled ? .on : .off
        menu.addItem(burnoutItem)
        let launch = makeItem("登录时启动", #selector(toggleLaunchAtLogin))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())
        // ── 权限与排障(低频,收进子菜单;事件心跳明细在这里)
        let diag = NSMenu()
        let ev = NSMenuItem(title: eventStatus(), action: nil, keyEquivalent: "")
        ev.isEnabled = false
        diag.addItem(ev)
        let axOK = AXIsProcessTrusted()
        diag.addItem(makeItem(axOK ? "辅助功能:已授权 ✓" : "授权辅助功能(Ghostty 跳转)…",
                              #selector(openAccessibilitySettings)))
        diag.addItem(makeItem("自动化授权设置(iTerm2/终端跳转)…", #selector(openAutomationSettings)))
        diag.addItem(.separator())
        diag.addItem(makeItem("重新安装接入", #selector(reinstallAction)))
        diag.addItem(makeItem("卸载接入(还原 settings.json)", #selector(uninstallMenuAction)))
        let diagRoot = NSMenuItem(title: "权限与排障", action: nil, keyEquivalent: "")
        diagRoot.submenu = diag
        menu.addItem(diagRoot)
        // ── 检查更新 + 退出
        if pres.checkItemEnabled {
            menu.addItem(makeItem(pres.checkItemTitle, #selector(checkUpdateAction)))
        } else {
            let c = NSMenuItem(title: pres.checkItemTitle, action: nil, keyEquivalent: "")
            c.isEnabled = false
            menu.addItem(c)
        }
        menu.addItem(makeItem("退出", #selector(quit)))
    }
```

action 区追加两个 selector:

```swift
    @objc private func updateBannerAction() { updateController.presentUpdateAlert() }
    @objc private func checkUpdateAction() { updateController.checkNow() }
```

注意:菜单标题里的括号沿用现有代码的全角括号风格(如「提示动画(完成 / 提问)」原样保留,上面代码块中的半角括号仅是文档转写,实现时对照原文件保持全角)。

- [ ] **Step 2: 构建验证(此时 AppDelegate 还在调旧接口,预期编译失败)**

Run: `swift build 2>&1 | grep -c "setInstallStatus\|extra argument"`
Expected: 非 0(AppDelegate 报错——Task 9 修复;这一步确认改动面与预期一致)

- [ ] **Step 3: 不 commit,直接进 Task 9**(两个文件必须一起编译通过才是一个可提交单元)

---

### Task 9: AppDelegate 接线

**Files:**
- Modify: `Sources/CCHud/AppDelegate.swift`

**Interfaces:**
- Consumes: `UpdateController`(Task 7)、`InstallState` / `setInstallState` / 新 init(Task 8)。

- [ ] **Step 1: 修改 AppDelegate**

属性区(`var statusItem: StatusItemController?` 之后)加:

```swift
    var updateController: UpdateController?
```

`applicationDidFinishLaunching` 中「// 4. 菜单栏」段,statusItem 创建前先建 UpdateController,并传入 init(原 init 调用整体替换):

```swift
        // 4. 菜单栏(更新控制器先建——菜单要渲染更新状态)
        let updateController = UpdateController()
        self.updateController = updateController
        statusItem = StatusItemController(
            updateController: updateController,
            togglePanel: { [weak self] in
                guard let p = self?.panel else { return }
                p.isVisible ? p.orderOut(nil) : p.orderFrontRegardless()
            },
            reinstall: { [weak self] in self?.runInstall(force: true) },
            uninstall: { [weak self] in
                guard let self else { return }
                try? self.installer.uninstall()
                UserDefaults.standard.set(true, forKey: Self.uninstalledKey)
                self.statusItem?.setInstallState(.uninstalled)
            },
            eventStatus: { [weak self] in
                guard let self else { return "" }
                let fails = self.store.decodeFailures
                let failNote = fails > 0 ? "(解析失败 \(fails))" : ""
                guard let last = self.store.lastEventReceivedAt else {
                    return "最近收到事件:尚未收到\(failNote)"
                }
                let s = Int(Date().timeIntervalSince(last))
                let age = s < 60 ? "\(s) 秒前" : (s < 3600 ? "\(s / 60) 分钟前" : "\(s / 3600) 小时前")
                return "最近收到事件:\(age)\(failNote)"
            },
            previewAnimation: { ... 原样保留 ... },
            previewBurnout: { ... 原样保留 ... })
```

(`previewAnimation` / `previewBurnout` 两个闭包内容不动,只是位置顺延;`eventStatus` 闭包的改动就是上面的「最近收到事件:」前缀,其余逻辑不变——括号沿用原文件的全角风格。)

statusItem 创建之后的状态设置段(原 `if let serverError {...}` 三分支)替换为:

```swift
        if let serverError {
            statusItem?.setInstallState(.serverError(serverError))
        } else if UserDefaults.standard.bool(forKey: Self.uninstalledKey) {
            statusItem?.setInstallState(.uninstalled)
        } else {
            statusItem?.setInstallState(installer.isInstalled() ? .ok : .failed("hooks 未接入"))
        }
        updateController.startAutomaticChecks()
```

`runInstall(force:)` 内两处替换:

```swift
        do {
            _ = try installer.install()
            statusItem?.setInstallState(.ok)
        } catch {
            statusItem?.setInstallState(.failed(error.localizedDescription))
        }
```

- [ ] **Step 2: 构建 + 全量测试**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!` 且 `0 failures`

- [ ] **Step 3: 冒烟运行(开发构建)**

Run: `swift run CCHud &` 然后手动点开菜单栏图标检查:
- 状态行一行合并(开发构建下接入状态取决于本机)
- 菜单顺序:状态行 | HUD | 动画/焦点/燃尽/登录 | 权限与排障▸/检查更新…/退出
- 「权限与排障」子菜单里有「最近收到事件:…」
- 点「检查更新…」→ 本机 1.2.1 == latest 1.2.1 → 弹「已是最新版本」
验证后 `pkill -f CCHud`。

- [ ] **Step 4: Commit(Task 8+9 一起)**

```bash
git add Sources/CCHud/StatusItemController.swift Sources/CCHud/AppDelegate.swift
git commit -m "feat(menu): 菜单重组——状态行合并/权限与排障子菜单/更新入口"
```

---

### Task 10: README 发版约定 + 端到端验证

**Files:**
- Modify: `README.zh-CN.md`(「从源码构建」章节末尾)
- Modify: `README.md`(「Build from source」章节末尾)

- [ ] **Step 1: README.zh-CN.md 追加(「从源码构建」小节末尾、「原理」之前)**

```markdown
### 发版约定(应用内自动更新依赖)

应用内更新器直接消费 GitHub Releases,发版必须遵守:

- tag 用 `vX.Y.Z`(如 `v1.3.0`),与 `Sources/CCHud/AppInfo.swift` 的版本一致(改版本只改那一行)。
- dmg 资产名固定为 `CC-HUD.dmg`,用 `./scripts/make-dmg.sh` 生成。
- release 正文写中文更新日志——它会原样展示在用户的更新确认窗里。
- 用同一台机器的 Apple Development 证书签名构建;换签名身份会让老用户更新后辅助功能授权失效一次,需在更新日志中提醒。
```

- [ ] **Step 2: README.md 追加对应英文(「Build from source」末尾)**

```markdown
### Release conventions (required by in-app auto-update)

The in-app updater consumes GitHub Releases directly:

- Tag as `vX.Y.Z` (e.g. `v1.3.0`), matching the version in `Sources/CCHud/AppInfo.swift`.
- The dmg asset must be named exactly `CC-HUD.dmg` (built via `./scripts/make-dmg.sh`).
- The release body is shown verbatim in the update dialog — write it for end users.
- Sign with the same Apple Development certificate; changing signing identity invalidates users' Accessibility grant once after update (mention it in the changelog).
```

- [ ] **Step 3: 全量验证**

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | tail -2 && ./scripts/build-app.sh 2>&1 | tail -2`
Expected: 构建、测试、打包全通过

- [ ] **Step 4: Commit**

```bash
git add README.zh-CN.md README.md
git commit -m "docs(readme): 发版约定(自动更新依赖)"
```

- [ ] **Step 5: 端到端手动验证(真实更新链路)**

前提:本机已有 Apple Development 证书(build-app.sh 自动使用)。流程会真实替换 `/Applications/CC HUD.app`,最后一步恢复。

1. 临时把 `Sources/CCHud/AppInfo.swift` 的 version 改为 `"1.2.0"`(仅验证用)
2. `INSTALL=1 ./scripts/build-app.sh` 部署"旧版"
3. 等 ~10 秒,点开菜单:应出现蓝色「⬆ 有新版本 v1.2.1,点击更新」
4. 点击 → 确认弹窗显示 v1.2.1 的中文 changelog → 点「立即更新」
5. 观察:菜单显示下载进度 → app 自动退出重启
6. 验证(部署验证三件套):
   - `plutil -p "/Applications/CC HUD.app/Contents/Info.plist" | grep ShortVersion` → `1.2.1`
   - 菜单状态行显示 `CC HUD v1.2.1 · 运行正常`
   - 「权限与排障」→ 辅助功能仍「已授权 ✓」(同证书替换,TCC 不失效)
7. **恢复**:把 `AppInfo.version` 改回当前开发版本,`INSTALL=1 ./scripts/build-app.sh` 重新部署本地构建
8. 注意:此验证装上的 v1.2.1 是**不含更新器的老代码**,恢复步骤(7)不可省略

---

## Self-Review 记录

- **Spec 覆盖**:更新体验(Task 7)、组件三分(Task 1-7)、版本比较规则(Task 1)、下载校验安装(Task 4/5)、错误处理表(Task 5/7 的 UpdateError + presentFailure/静默分支)、菜单常态结构与异常态(Task 8)、更新状态菜单形态(Task 6/8)、事件文案自解释(Task 9)、测试策略(Task 1-6 单测 + Task 10 e2e)、发版约定(Task 10)、风险边界(teamIdentifier 运行时取自身→证书轮换同 Team 仍通过;非 admin → replaceFailed 路径 + 前往 Releases 按钮)。spec 的 failed/upToDate 状态折叠已在 Global Constraints 声明。
- **占位符**:previewAnimation/previewBurnout 在 Task 9 标注「原样保留」属于明确指令(内容在原文件 169-188 行),非占位符。
- **类型一致性**:`ReleaseInfo` 字段(tagName/version/body/dmgURL/dmgSize)在 Task 2/6/7 一致;`setInstallState`/`InstallState` 在 Task 8/9 一致;`menuPresentation` 字段在 Task 6/8 一致;`checkNow()` 无参(Task 7 定义、Task 8 调用)一致。

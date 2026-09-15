import XCTest
import CoreGraphics
@testable import CCHudCore

/// 多显示器窗口位置恢复的纯数据层。
///
/// 坐标一律是 **CG 全局系**（左上原点、y 向下）——`kAXPosition` 与 `CGDisplayBounds` 同系，
/// 故此层不做任何翻转。（`NSScreen.frame` 是 Cocoa 系，同一块屏坐标不同，别混用。）
final class WindowLayoutStoreTests: XCTestCase {
    // 实测排列：两块 27 寸并排挂在笔记本上方
    let builtin = ScreenBox(uuid: "BUILTIN", bounds: CGRect(x: 0, y: 0, width: 1496, height: 967))
    let left = ScreenBox(uuid: "LEFT", bounds: CGRect(x: -1137, y: -1080, width: 1920, height: 1080))
    let right = ScreenBox(uuid: "RIGHT", bounds: CGRect(x: 783, y: -1080, width: 1920, height: 1080))
    /// 拔掉外接后内置屏自己换缩放档（实测 1496×967 → 1728×1117）
    let builtinAlone = ScreenBox(uuid: "BUILTIN", bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))

    // ── 指纹：决定档案分到哪个桶 ────────────────────────────────

    func testFingerprintIgnoresEnumerationOrder() {
        XCTAssertEqual(WindowLayoutStore.fingerprint(of: [builtin, left, right]),
                       WindowLayoutStore.fingerprint(of: [right, builtin, left]),
                       "同一组显示器，枚举顺序不同也必须落同一个桶——实测上电顺序会变")
    }

    func testFingerprintIgnoresResolution() {
        let scaled = ScreenBox(uuid: "BUILTIN", bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertEqual(WindowLayoutStore.fingerprint(of: [builtin, left, right]),
                       WindowLayoutStore.fingerprint(of: [scaled, left, right]),
                       "内置屏会自己切缩放档，分辨率进指纹会把同一组拆成两个桶")
    }

    func testFingerprintDistinguishesDisplaySets() {
        XCTAssertNotEqual(WindowLayoutStore.fingerprint(of: [builtin, left, right]),
                          WindowLayoutStore.fingerprint(of: [builtinAlone]),
                          "拔掉外接屏必须换桶——否则拔线后的坏布局会覆盖好布局")
    }

    // ── 捕获：全局 frame → 屏内相对偏移 ──────────────────────────

    func testCaptureStoresOffsetRelativeToItsScreen() {
        // 实测窗口：右屏上，距屏左边 0、距屏顶 30（菜单栏高度）
        let frame = CGRect(x: 783, y: -1050, width: 960, height: 1050)
        let got = WindowLayoutStore.capture(frame: frame, on: [builtin, left, right])
        XCTAssertEqual(got, WindowLayout(screen: "RIGHT",
                                         offset: CGPoint(x: 0, y: 30),
                                         size: CGSize(width: 960, height: 1050)))
    }

    func testCaptureAssignsWindowToScreenWithLargestOverlap() {
        // 骑在两块 27 寸的接缝上（左屏右边界 = 右屏左边界 = x783）：左边占 100 宽、右边占 300 宽
        let frame = CGRect(x: 683, y: -500, width: 400, height: 400)
        let got = WindowLayoutStore.capture(frame: frame, on: [builtin, left, right])
        XCTAssertEqual(got?.screen, "RIGHT", "跨屏时归给覆盖面积最大的那块")
    }

    func testCaptureReturnsNilWhenWindowOffAllScreens() {
        let frame = CGRect(x: 9000, y: 9000, width: 400, height: 300)
        XCTAssertNil(WindowLayoutStore.capture(frame: frame, on: [builtin, left, right]),
                     "不在任何屏上的窗口不入档，免得存进去一个还原不回来的位置")
    }

    // ── 恢复：屏内相对偏移 → 全局 frame ──────────────────────────

    func testRestoreRebuildsGlobalFrameOnSameScreen() {
        let layout = WindowLayout(screen: "RIGHT", offset: CGPoint(x: 0, y: 30),
                                  size: CGSize(width: 960, height: 1050))
        XCTAssertEqual(WindowLayoutStore.frame(for: layout, on: [builtin, left, right]),
                       CGRect(x: 783, y: -1050, width: 960, height: 1050))
    }

    func testRestoreSurvivesArrangementOriginShift() {
        // 同一块屏，单独接时全局原点挪到 (1728,0)（实测：三屏 (783,-1080) → 单接 (1728,0)）
        let moved = ScreenBox(uuid: "RIGHT", bounds: CGRect(x: 1728, y: 0, width: 1920, height: 1080))
        let layout = WindowLayout(screen: "RIGHT", offset: CGPoint(x: 0, y: 30),
                                  size: CGSize(width: 960, height: 1050))
        XCTAssertEqual(WindowLayoutStore.frame(for: layout, on: [builtinAlone, moved]),
                       CGRect(x: 1728, y: 30, width: 960, height: 1050),
                       "存绝对坐标必错——排列原点会随配置漂移，只有屏内偏移稳")
    }

    func testRestoreReturnsNilWhenScreenAbsent() {
        let layout = WindowLayout(screen: "RIGHT", offset: CGPoint(x: 0, y: 30),
                                  size: CGSize(width: 960, height: 1050))
        XCTAssertNil(WindowLayoutStore.frame(for: layout, on: [builtinAlone]),
                     "存档屏不在场就别摆——宁可不动，也不能瞎塞到别的屏上")
    }

    func testCaptureRestoreRoundTrips() {
        let frame = CGRect(x: -1000, y: -900, width: 800, height: 600)
        let screens = [builtin, left, right]
        let layout = WindowLayoutStore.capture(frame: frame, on: screens)
        XCTAssertEqual(layout.flatMap { WindowLayoutStore.frame(for: $0, on: screens) }, frame)
    }

    // ── 分桶隔离：自动捕获能安全运行的全部理由 ────────────────────

    func testBucketsAreIsolatedByFingerprint() {
        var store = WindowLayoutStore()
        let good = WindowLayoutStore.fingerprint(of: [builtin, left, right])
        let degraded = WindowLayoutStore.fingerprint(of: [builtinAlone])
        let onRight = WindowLayout(screen: "RIGHT", offset: CGPoint(x: 0, y: 30),
                                   size: CGSize(width: 960, height: 1050))
        let dumped = WindowLayout(screen: "BUILTIN", offset: CGPoint(x: 12, y: 40),
                                  size: CGSize(width: 960, height: 900))
        store.record(onRight, forWindow: "w1", fingerprint: good)
        // 拔线后系统把窗口搬到内置屏，捕获写进「单屏」那桶
        store.record(dumped, forWindow: "w1", fingerprint: degraded)

        XCTAssertEqual(store.layout(forWindow: "w1", fingerprint: good), onRight,
                       "三屏那桶的好布局不能被拔线后的坏位置覆盖")
        XCTAssertEqual(store.layout(forWindow: "w1", fingerprint: degraded), dumped)
    }

    /// 恢复时要遍历整桶——按窗口逐个查会漏掉「档案里有、但这次没被通知到」的窗口
    func testAllReturnsEveryWindowInTheBucket() {
        var store = WindowLayoutStore()
        let fp = WindowLayoutStore.fingerprint(of: [builtin, left, right])
        let a = WindowLayout(screen: "RIGHT", offset: .zero, size: CGSize(width: 960, height: 1050))
        let b = WindowLayout(screen: "LEFT", offset: CGPoint(x: 10, y: 20),
                             size: CGSize(width: 800, height: 600))
        store.record(a, forWindow: "w1", fingerprint: fp)
        store.record(b, forWindow: "w2", fingerprint: fp)
        store.record(a, forWindow: "w3", fingerprint: WindowLayoutStore.fingerprint(of: [builtinAlone]))
        XCTAssertEqual(store.all(fingerprint: fp), ["w1": a, "w2": b], "只返回本桶的，别串桶")
    }

    // ── 持久化：12 小时的隔夜流程里，cc-hud 一旦重启，内存档案就没了 ──────

    func testArchiveSurvivesRoundTripThroughDefaults() {
        var store = WindowLayoutStore()
        let fp = WindowLayoutStore.fingerprint(of: [builtin, left, right])
        let layout = WindowLayout(screen: "RIGHT", offset: CGPoint(x: 0, y: 30),
                                  size: CGSize(width: 960, height: 1050))
        store.record(layout, forWindow: "w1", fingerprint: fp)

        let defaults = UserDefaults(suiteName: "layout-roundtrip")!
        defaults.removePersistentDomain(forName: "layout-roundtrip")
        store.save(to: defaults)
        let loaded = WindowLayoutStore(loadingFrom: defaults)

        XCTAssertEqual(loaded.layout(forWindow: "w1", fingerprint: fp), layout,
                       "隔夜重启后档案必须还在——用户不会在拔线和插回之间去拖窗口，没有重新学习的机会")
    }

    func testLoadingFromEmptyDefaultsYieldsEmptyStore() {
        let defaults = UserDefaults(suiteName: "layout-empty")!
        defaults.removePersistentDomain(forName: "layout-empty")
        let store = WindowLayoutStore(loadingFrom: defaults)
        XCTAssertTrue(store.all(fingerprint: "whatever").isEmpty, "首次运行不该炸")
    }

    func testCorruptArchiveIsIgnoredRatherThanCrashing() {
        let defaults = UserDefaults(suiteName: "layout-corrupt")!
        defaults.removePersistentDomain(forName: "layout-corrupt")
        defaults.set("这不是归档数据", forKey: WindowLayoutStore.archiveKey)
        let store = WindowLayoutStore(loadingFrom: defaults)
        XCTAssertTrue(store.all(fingerprint: "whatever").isEmpty, "坏档案退回空，不能让 app 起不来")
    }

    func testUnknownWindowHasNoLayout() {
        let store = WindowLayoutStore()
        XCTAssertNil(store.layout(forWindow: "never-seen",
                                  fingerprint: WindowLayoutStore.fingerprint(of: [builtin])))
    }
}

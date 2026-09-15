import AppKit
import ApplicationServices
import ColorSync
import CCHudCore

/// AXObserver 的回调是 C 函数指针，不能捕获上下文 —— 实例经 refcon 传进来。
///
/// **回调里绝不读任何 AX 属性**：实测拖动窗口时通知峰值 37 次/秒、相邻最小间隔 1ms，
/// 每条都做一次同步跨进程 AX 读的话，主线程会被终端进程的响应速度拖住。
/// 这里只打一下节流器，真正读 frame 在防抖之后做一次。
private let layoutKeeperCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let keeper = Unmanaged<LayoutKeeper>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { keeper.windowChanged() }
}

/// 多显示器窗口位置恢复：记住每个终端窗口在「这套显示器组合」下待在哪，
/// 拔插重连后把被系统搬走的窗口摆回去。
///
/// 全程事件驱动，空闲零开销：捕获由 AX 的窗口移动/缩放通知触发，恢复由显示器配置变化触发，
/// 两个入口都是系统推过来的，没有任何定时轮询。
///
/// 时序参数全部来自实测（见各常量注释），不是估的。
@MainActor
final class LayoutKeeper {
    static let enabledKey = "layout.restore"
    /// 默认开启 —— 这功能的价值就在于不用想着它（与「焦点会话不提示」同款默认）
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    /// 拖动防抖：静默这么久才算「拖完了」。实测拖动中相邻通知中位 18ms、最密 1ms。
    private static let dragSettle = Duration.milliseconds(500)
    /// 显示器变化防抖，**每次变化都重置**。实测外接屏注册后 0.9s 会掉线、1.7s 才回来，
    /// 窗口短的话恢复会正好落在抖动窗口里，按「目标屏不在场」把窗口跳过。
    private static let screenSettle = Duration.seconds(2)
    /// 补刀：系统迟到的搬窗会把刚摆好的窗口又挪走（HUDPanel 同款双段 settle）
    private static let confirmDelay = Duration.milliseconds(2500)
    /// 恢复后闸门续关：实测我们自己写位置也会触发通知，延迟 +146~193ms。
    /// 不续关的话，恢复动作会立刻触发一次捕获。
    private static let gateReopen = Duration.milliseconds(500)

    /// 当前承载 Claude 会话的终端 App（由 AppDelegate 从 store 算出来）
    var hostApps: () -> [NSRunningApplication] = { [] }

    /// 上次恢复的结果，给菜单显示 —— 这功能失败是静默的（窗口没回去，和没装一模一样），
    /// 没有这行字，用户第二天早上无从判断它到底跑没跑。
    private(set) static var lastRestore: (at: Date, moved: Int, matched: Int)?

    private var store = WindowLayoutStore(loadingFrom: .standard)
    /// 见过的终端宿主。**不能只看在场会话**：夜里最后一个 claude 退出后，
    /// 按会话倒推会得到空集合、观察者被摘掉、窗口从此失联，而 Ghostty 窗口明明还开着。
    /// 只要进程还活着就继续盯，进程没了才忘掉。
    private var knownHosts: [pid_t: NSRunningApplication] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    /// 闸门关着时一律不写档案 —— 拔插那几秒系统正在搬窗，记下来的全是坏位置
    private var gateOpen = true
    private var captureTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    /// 在场宿主 = 当前会话倒推出来的 ∪ 以前见过且进程还活着的
    private func liveHosts() -> [NSRunningApplication] {
        for app in hostApps() { knownHosts[app.processIdentifier] = app }
        knownHosts = knownHosts.filter { !$0.value.isTerminated }
        return Array(knownHosts.values)
    }

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refreshObservers()   // 首次捕获由它负责（见下）
    }

    /// 由 AppDelegate 的 5s 存活检查搭车调用（不新增定时器）：
    /// 终端 App 重启、新开会话用了别的终端，都在这里补挂观察者。
    func refreshObservers() {
        guard Self.enabled, AXIsProcessTrusted() else { return }
        let want = Set(liveHosts().map(\.processIdentifier))
        for pid in observers.keys where !want.contains(pid) {
            if let obs = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                      AXObserverGetRunLoopSource(obs), .defaultMode)
            }
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        var added = false
        for pid in want where observers[pid] == nil {
            var obs: AXObserver?
            guard AXObserverCreate(pid, layoutKeeperCallback, &obs) == .success,
                  let obs else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            // 只订阅移动/缩放。探针实测 Created/Destroyed 绝大多数来自转瞬即逝的临时元素
            // （日志里 32 个元素 id、真窗口只有 2 个），订了也只是噪音——
            // 捕获与恢复本就每次重新枚举窗口，不靠这两个通知维护列表。
            for n in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverAddNotification(obs, axApp, n as CFString, me)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = obs
            added = true
            DebugLog.log("layout: 挂上观察者 pid=\(pid)")
        }
        // 刚认识这个终端 App = 头一回看见它的窗口，立刻记一次当前布局。
        // 不能只在 start() 里捕获：启动时会话表由后台扫描异步填充，start() 那一刻
        // hostApps() 还是空的，捕获必然是 0 个窗口（实测）。
        if added, gateOpen { capture() }
    }

    // ── 捕获侧 ────────────────────────────────────────────────

    /// AX 回调入口（已在主线程）。只做节流，不读属性。
    func windowChanged() {
        guard Self.enabled, gateOpen else { return }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dragSettle)
            guard !Task.isCancelled else { return }
            self?.capture()
        }
    }

    private func capture() {
        guard Self.enabled, AXIsProcessTrusted() else { return }
        let screens = Self.onlineScreens()
        guard !screens.isEmpty else { return }
        let fp = WindowLayoutStore.fingerprint(of: screens)
        var n = 0
        for (key, el) in trackedWindows() {
            guard let frame = Self.frame(of: el),
                  let layout = WindowLayoutStore.capture(frame: frame, on: screens) else { continue }
            store.record(layout, forWindow: key, fingerprint: fp)
            n += 1
        }
        store.save(to: .standard)   // 隔夜要活过 cc-hud 重启
        DebugLog.log("layout: 捕获 \(n) 个窗口 @ \(fp)")
    }

    // ── 恢复侧 ────────────────────────────────────────────────

    @objc private func screensChanged() {
        guard Self.enabled else { return }
        gateOpen = false            // 立刻关闸：系统这会儿正在搬窗，捕获到的全是坏位置
        captureTask?.cancel()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.screenSettle)
            guard !Task.isCancelled, let self else { return }
            self.refreshObservers()   // 期间终端 App 可能重启过
            self.restore()
            try? await Task.sleep(for: Self.confirmDelay)
            guard !Task.isCancelled else { return }
            self.restore()
            try? await Task.sleep(for: Self.gateReopen)
            guard !Task.isCancelled else { return }
            self.gateOpen = true
        }
    }

    private func restore() {
        guard Self.enabled, AXIsProcessTrusted() else { return }
        let screens = Self.onlineScreens()
        let fp = WindowLayoutStore.fingerprint(of: screens)
        let archive = store.all(fingerprint: fp)
        guard !archive.isEmpty else {
            DebugLog.log("layout: \(fp) 没有存档，不恢复")
            return
        }
        let live = trackedWindows()
        var matched = 0, moved = 0
        for (key, el) in live {
            guard let layout = archive[key] else { continue }
            matched += 1
            guard let target = WindowLayoutStore.frame(for: layout, on: screens),
                  let now = Self.frame(of: el), now != target else { continue }
            // 先定位再定尺寸：窗口还在旧屏上时，目标尺寸可能超出旧屏可用区而被钳制
            // （实测写超界的高度会被截回原值）
            Self.setPoint(el, kAXPositionAttribute, target.origin)
            Self.setSize(el, kAXSizeAttribute, target.size)
            moved += 1
        }
        Self.lastRestore = (Date(), moved, matched)
        // 分母用「在场窗口数」，不用档案条数 —— 档案会累积已关闭窗口的陈旧条目，
        // 拿它当分母读起来像是失败了（实测出现过「恢复 1/4」其实一切正常）。
        DebugLog.log("layout: 恢复 在场\(live.count) 命中\(matched) 搬动\(moved) @ \(fp)")
    }

    // ── 窗口枚举 ──────────────────────────────────────────────

    /// 可参与恢复的窗口。**必须过滤**：探针实测 AX 通知里混着大量非窗口的临时元素
    /// （一次会话里出现过 32 个元素 id，真窗口只有 2 个）。这里只认 kAXWindows 列表里、
    /// 角色确为窗口、且没全屏没最小化的——全屏窗口 AX 也搬不动。
    ///
    /// 键 = pid + 元素哈希。引用跨拔插存活（实测），所以同一个窗口在拔插前后键一致。
    private func trackedWindows() -> [(String, AXUIElement)] {
        var out: [(String, AXUIElement)] = []
        for app in liveHosts() {
            let pid = app.processIdentifier
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                kAXWindowsAttribute as CFString, &v) == .success,
                  let wins = v as? [AXUIElement] else { continue }
            for w in wins {
                guard Self.string(w, kAXRoleAttribute) == kAXWindowRole,
                      Self.bool(w, "AXFullScreen") != true,
                      Self.bool(w, kAXMinimizedAttribute) != true else { continue }
                out.append(("\(pid):\(CFHash(w))", w))
            }
        }
        return out
    }

    /// 在场显示器。走 `CGDisplayBounds` 而**不是** `NSScreen.frame`：
    /// 前者与 AX 的 kAXPosition 同为 CG 系（左上原点、y 向下），全程零坐标转换；
    /// NSScreen 是 Cocoa 系（左下原点），混用必错。
    private static func onlineScreens() -> [ScreenBox] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        var out: [ScreenBox] = []
        for id in ids {
            guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            out.append(ScreenBox(uuid: CFUUIDCreateString(nil, u) as String,
                                 bounds: CGDisplayBounds(id)))
        }
        return out
    }

    // ── AX 读写 ──────────────────────────────────────────────

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: p, size: s)
    }
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? Bool
    }
    private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(val, to: AXValue.self), .cgPoint, &p) else { return nil }
        return p
    }
    private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(val, to: AXValue.self), .cgSize, &s) else { return nil }
        return s
    }
    @discardableResult
    private static func setPoint(_ el: AXUIElement, _ attr: String, _ p: CGPoint) -> Bool {
        var pt = p
        guard let v = AXValueCreate(.cgPoint, &pt) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, v) == .success
    }
    @discardableResult
    private static func setSize(_ el: AXUIElement, _ attr: String, _ s: CGSize) -> Bool {
        var sz = s
        guard let v = AXValueCreate(.cgSize, &sz) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, v) == .success
    }
}

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

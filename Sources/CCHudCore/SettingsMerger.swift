import Foundation

/// settings.json 的纯函数 merge/restore。输入输出 [String: Any]（JSONSerialization 形态），不碰文件。
public enum SettingsMerger {
    public static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SessionEnd", "PreCompact",
    ]

    public static func merge(settings: [String: Any], emitCommand: String,
                             statusCommand: String) -> (settings: [String: Any], originalStatusLine: String?) {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let exists = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == emitCommand }
            }
            if !exists {
                groups.append(["hooks": [["type": "command", "command": emitCommand]]])
            }
            hooks[event] = groups
        }
        out["hooks"] = hooks

        var original: String? = nil
        if let sl = out["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String, cmd != statusCommand {
            original = cmd
        }
        out["statusLine"] = ["type": "command", "command": statusCommand]
        return (out, original)
    }

    public static func restore(settings: [String: Any], emitCommand: String,
                               statusCommand: String, originalStatusLine: String?) -> [String: Any] {
        var out = settings
        if var hooks = out["hooks"] as? [String: Any] {
            for event in hookEvents {
                guard var groups = hooks[event] as? [[String: Any]] else { continue }
                groups = groups.compactMap { group in
                    var inner = group["hooks"] as? [[String: Any]] ?? []
                    inner.removeAll { ($0["command"] as? String) == emitCommand }
                    if inner.isEmpty { return nil }
                    var g = group
                    g["hooks"] = inner
                    return g
                }
                if groups.isEmpty { hooks[event] = nil } else { hooks[event] = groups }
            }
            if hooks.isEmpty { out["hooks"] = nil } else { out["hooks"] = hooks }
        }
        if let sl = out["statusLine"] as? [String: Any], (sl["command"] as? String) == statusCommand {
            if let original = originalStatusLine {
                out["statusLine"] = ["type": "command", "command": original]
            } else {
                out["statusLine"] = nil
            }
        }
        return out
    }
}

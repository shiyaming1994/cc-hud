import Foundation

/// 把 tool_name + tool_input 变成 UI 文案。
/// activity = 行内活动文字；command = 权限等待时的完整命令展示 `Tool(detail)`。
public enum ToolSummary {
    public static func activity(toolName: String, input: JSONValue?) -> String {
        switch toolName {
        case "Bash":
            if let d = input?["description"]?.stringValue, !d.isEmpty { return d }
            if let c = input?["command"]?.stringValue { return "$ " + truncate(c, 40) }
            return "Bash"
        case "Edit": return "编辑 " + fileName(input)
        case "Write": return "写入 " + fileName(input)
        case "Read": return "读取 " + fileName(input)
        case "NotebookEdit": return "编辑 " + fileName(input)
        case "Task":
            if let d = input?["description"]?.stringValue, !d.isEmpty { return "Task: " + d }
            return "Task"
        default:
            return toolName
        }
    }

    public static func command(toolName: String, input: JSONValue?) -> String {
        switch toolName {
        case "Bash":
            if let c = input?["command"]?.stringValue { return "Bash(\(truncate(c, 60)))" }
            return "Bash"
        case "Edit", "Write", "Read", "NotebookEdit":
            return "\(toolName)(\(fileName(input)))"
        default:
            return toolName
        }
    }

    private static func fileName(_ input: JSONValue?) -> String {
        guard let p = input?["file_path"]?.stringValue, !p.isEmpty else { return "?" }
        return (p as NSString).lastPathComponent
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= n ? flat : String(flat.prefix(n)) + "…"
    }
}

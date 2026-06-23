import Foundation

/// AskUserQuestion 的一题。实测（claude 2.1.x，shim 抓包）：
/// PreToolUse 与 PermissionRequest 都带 tool_name="AskUserQuestion"，
/// tool_input.questions = [{question, header, options:[{label,description}], multiSelect}]；
/// 一次调用多题只有这一对信号，逐题作答之间没有任何事件；
/// PostToolUse 在全部答完时到达（tool_input 多出 answers map）。
public struct QuestionItem: Sendable, Equatable {
    public let text: String
    public let header: String?
    public let optionLabels: [String]
    public let multiSelect: Bool

    public init(text: String, header: String?, optionLabels: [String], multiSelect: Bool) {
        self.text = text
        self.header = header
        self.optionLabels = optionLabels
        self.multiSelect = multiSelect
    }
}

public enum QuestionParser {
    public static let toolName = "AskUserQuestion"

    /// 容错解析：缺 question 字段的题跳过；解析不出返回 []（调用方据此不弹提示）。
    /// 提示卡只展示选项 label——description 是整句解释，卡片放不下也不该放。
    public static func parse(_ input: JSONValue?) -> [QuestionItem] {
        guard let arr = input?["questions"]?.arrayValue else { return [] }
        return arr.compactMap { q in
            guard let text = q["question"]?.stringValue, !text.isEmpty else { return nil }
            let opts = (q["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
            return QuestionItem(text: text,
                                header: q["header"]?.stringValue,
                                optionLabels: opts,
                                multiSelect: q["multiSelect"]?.boolValue ?? false)
        }
    }
}

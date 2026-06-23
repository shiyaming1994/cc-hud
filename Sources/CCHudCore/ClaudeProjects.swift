import Foundation

public enum ClaudeProjects {
    /// cwd → ~/.claude/projects 下的目录名。
    /// Claude Code 的真实规则是把**所有非字母数字字符**替换为 "-"
    ///（实证：~/.claude/.model-tokens-tracker → -Users-x--model-tokens-tracker，
    /// 点也被替换）；只换 "/" 会让带 . _ 空格 的路径全部失配。
    public static func slug(forCwd cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}

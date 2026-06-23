import XCTest
@testable import CCHudCore

final class ToolSummaryTests: XCTestCase {
    private func obj(_ d: [String: JSONValue]) -> JSONValue { .object(d) }

    func testBashWithDescription() {
        let input = obj(["command": .string("rm -rf node_modules"), "description": .string("Remove deps")])
        XCTAssertEqual(ToolSummary.activity(toolName: "Bash", input: input), "Remove deps")
        XCTAssertEqual(ToolSummary.command(toolName: "Bash", input: input), "Bash(rm -rf node_modules)")
    }

    func testBashWithoutDescriptionTruncates() {
        let long = String(repeating: "x", count: 100)
        let input = obj(["command": .string(long)])
        let act = ToolSummary.activity(toolName: "Bash", input: input)
        XCTAssertEqual(act, "$ " + String(repeating: "x", count: 40) + "…")
        let cmd = ToolSummary.command(toolName: "Bash", input: input)
        XCTAssertEqual(cmd, "Bash(" + String(repeating: "x", count: 60) + "…)")
    }

    func testFileTools() {
        let input = obj(["file_path": .string("/Users/x/proj/src/App.tsx")])
        XCTAssertEqual(ToolSummary.activity(toolName: "Edit", input: input), "编辑 App.tsx")
        XCTAssertEqual(ToolSummary.activity(toolName: "Write", input: input), "写入 App.tsx")
        XCTAssertEqual(ToolSummary.activity(toolName: "Read", input: input), "读取 App.tsx")
        XCTAssertEqual(ToolSummary.command(toolName: "Write", input: input), "Write(App.tsx)")
    }

    func testTaskUsesDescription() {
        let input = obj(["description": .string("查证文档"), "prompt": .string("...")])
        XCTAssertEqual(ToolSummary.activity(toolName: "Task", input: input), "Task: 查证文档")
    }

    func testFallbackToolName() {
        XCTAssertEqual(ToolSummary.activity(toolName: "WebSearch", input: nil), "WebSearch")
        XCTAssertEqual(ToolSummary.command(toolName: "WebSearch", input: nil), "WebSearch")
    }
}

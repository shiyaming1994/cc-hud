#!/bin/bash
# 向运行中的 CC HUD 发送一组假事件，遍历四种状态 + 账户配额，肉眼验收 UI。
SOCK="$HOME/.claude/cc-hud/hud.sock"
send() { printf '%s' "$1" | python3 -c "
import socket, sys
data = sys.stdin.buffer.read()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCK')
s.sendall(data)
s.close()
"; }

NOW=$(date +%s)
send "{\"kind\":\"hook\",\"claudePid\":$$,\"tty\":\"ttys099\",\"termProgram\":\"ghostty\",\"payload\":{\"hook_event_name\":\"SessionStart\",\"session_id\":\"fake-1\",\"cwd\":\"/Users/x/pigeon\"}}"
send "{\"kind\":\"hook\",\"claudePid\":$$,\"payload\":{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"fake-1\",\"cwd\":\"/Users/x/pigeon\"}}"
send "{\"kind\":\"status\",\"claudePid\":$$,\"payload\":{\"session_id\":\"fake-1\",\"cwd\":\"/Users/x/pigeon\",\"model\":{\"display_name\":\"Fable\"},\"context_window\":{\"used_percentage\":84},\"rate_limits\":{\"five_hour\":{\"used_percentage\":38,\"resets_at\":$((NOW+8040))},\"seven_day\":{\"used_percentage\":22,\"resets_at\":$((NOW+266400))}}}}"
sleep 1
send "{\"kind\":\"hook\",\"payload\":{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"fake-1\",\"cwd\":\"/Users/x/pigeon\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf node_modules\",\"description\":\"清理依赖\"}}}"
sleep 1
send "{\"kind\":\"hook\",\"payload\":{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"fake-1\",\"cwd\":\"/Users/x/pigeon\"}}"
# 第二个会话：working
send "{\"kind\":\"hook\",\"payload\":{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"fake-2\",\"cwd\":\"/Users/x/extension\"}}"
send "{\"kind\":\"status\",\"payload\":{\"session_id\":\"fake-2\",\"cwd\":\"/Users/x/extension\",\"context_window\":{\"used_percentage\":45}}}"
echo "已注入：fake-1 等待权限 / fake-2 工作中。10 秒后 fake-2 完成……"
sleep 10
send "{\"kind\":\"hook\",\"payload\":{\"hook_event_name\":\"Stop\",\"session_id\":\"fake-2\",\"cwd\":\"/Users/x/extension\"}}"
echo "fake-2 → idle（应有 2s 绿色脉冲）。30 秒后两会话 SessionEnd 清理。"
sleep 30
send "{\"kind\":\"hook\",\"payload\":{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"fake-1\",\"cwd\":\"/Users/x/pigeon\"}}"
send "{\"kind\":\"hook\",\"payload\":{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"fake-2\",\"cwd\":\"/Users/x/extension\"}}"
echo "done"

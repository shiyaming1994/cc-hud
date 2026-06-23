#!/bin/bash
# 注入/清除一批模拟会话，供手动体验滚动、拖拽、状态样式。
# 用法：./scripts/demo-sessions.sh add | clear
# 假会话不带 claudePid（存活检查跳过），会一直留到 clear 或 app 重启。
SOCK="$HOME/.claude/cc-hud/hud.sock"
send() { printf '%s' "$1" | python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCK'); s.sendall(sys.stdin.buffer.read()); s.close()" 2>/dev/null; }

NAMES=(relay beacon harbor lumen needle orbit quartz sable)

case "${1:-add}" in
add)
  # 1) 等待权限：橙色 + 待批命令子行
  send '{"kind":"hook","tty":"ttysd01","payload":{"hook_event_name":"UserPromptSubmit","session_id":"demo-1","cwd":"/demo/relay"}}'
  send '{"kind":"hook","tty":"ttysd01","payload":{"hook_event_name":"PreToolUse","session_id":"demo-1","cwd":"/demo/relay","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules && npm i","description":"重装依赖"}}}'
  send '{"kind":"hook","tty":"ttysd01","payload":{"hook_event_name":"PermissionRequest","session_id":"demo-1","cwd":"/demo/relay"}}'
  send '{"kind":"status","tty":"ttysd01","payload":{"session_id":"demo-1","cwd":"/demo/relay","context_window":{"used_percentage":88}}}'
  # 2) 工作中：蓝色 + 活动 + 计时
  send '{"kind":"hook","tty":"ttysd02","payload":{"hook_event_name":"UserPromptSubmit","session_id":"demo-2","cwd":"/demo/beacon"}}'
  send '{"kind":"hook","tty":"ttysd02","payload":{"hook_event_name":"PreToolUse","session_id":"demo-2","cwd":"/demo/beacon","tool_name":"Edit","tool_input":{"file_path":"/demo/beacon/src/App.tsx"}}}'
  send '{"kind":"status","tty":"ttysd02","payload":{"session_id":"demo-2","cwd":"/demo/beacon","context_window":{"used_percentage":45}}}'
  # 3) 工作中：思考中
  send '{"kind":"hook","tty":"ttysd03","payload":{"hook_event_name":"UserPromptSubmit","session_id":"demo-3","cwd":"/demo/harbor"}}'
  send '{"kind":"status","tty":"ttysd03","payload":{"session_id":"demo-3","cwd":"/demo/harbor","context_window":{"used_percentage":72}}}'
  # 4-8) 空闲：不同 ctx
  i=4
  for name in lumen needle orbit quartz sable; do
    send "{\"kind\":\"hook\",\"tty\":\"ttysd0$i\",\"payload\":{\"hook_event_name\":\"SessionStart\",\"session_id\":\"demo-$i\",\"cwd\":\"/demo/$name\"}}"
    if [ $((i % 2)) = 0 ]; then
      send "{\"kind\":\"status\",\"tty\":\"ttysd0$i\",\"payload\":{\"session_id\":\"demo-$i\",\"cwd\":\"/demo/$name\",\"context_window\":{\"used_percentage\":$((i * 9))}}}"
    fi
    i=$((i + 1))
  done
  echo "已注入 8 个模拟会话（demo-1 等待权限 / demo-2,3 工作中 / demo-4~8 空闲）"
  echo "清除：$0 clear"
  ;;
clear)
  for i in 1 2 3 4 5 6 7 8; do
    send "{\"kind\":\"hook\",\"tty\":\"ttysd0$i\",\"payload\":{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"demo-$i\",\"cwd\":\"/demo/x\"}}"
  done
  echo "已清除"
  ;;
esac

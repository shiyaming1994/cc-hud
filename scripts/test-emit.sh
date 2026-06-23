#!/bin/bash
# emit 集成测试：起一个临时 socket server，喂 hook JSON，验证信封字段与 exit code。
set -e
cd "$(dirname "$0")/.."
swift build > /dev/null

# 隔离的临时 socket，绝不碰生产路径（否则会顶掉运行中 HUD 的监听）
SOCK="$(mktemp -d)/hud-test.sock"
export CC_HUD_SOCK="$SOCK"
OUT=$(mktemp)

python3 - "$SOCK" "$OUT" << 'EOF' &
import socket, sys, os
path, out = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(1); s.settimeout(5)
conn, _ = s.accept()
data = b""
while True:
    chunk = conn.recv(65536)
    if not chunk: break
    data += chunk
open(out, "wb").write(data)
EOF
SERVER_PID=$!
sleep 0.3

echo '{"hook_event_name":"Stop","session_id":"itest","cwd":"/tmp/x"}' | .build/debug/cc-hud-emit hook
RC=$?
wait $SERVER_PID

echo "--- emit exit code: $RC"
[ "$RC" = "0" ] || { echo "FAIL: exit code"; exit 1; }
python3 - "$OUT" << 'EOF'
import json, sys
env = json.load(open(sys.argv[1]))
assert env["kind"] == "hook", env
assert env["payload"]["session_id"] == "itest", env
print("envelope OK:", {k: env[k] for k in env if k != "payload"})
EOF

# 无 server 时必须 100ms 级快速退出且 exit 0
rm -f "$SOCK"
START=$(python3 -c 'import time; print(time.time())')
echo '{"hook_event_name":"Stop","session_id":"x"}' | .build/debug/cc-hud-emit hook
RC=$?
END=$(python3 -c 'import time; print(time.time())')
ELAPSED=$(python3 -c "print($END - $START)")
echo "--- no-server: rc=$RC elapsed=${ELAPSED}s"
[ "$RC" = "0" ] || { echo "FAIL: no-server exit code"; exit 1; }
python3 -c "exit(0 if $ELAPSED < 0.5 else 1)" || { echo "FAIL: too slow without server"; exit 1; }
echo "ALL PASS"

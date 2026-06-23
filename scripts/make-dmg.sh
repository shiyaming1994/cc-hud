#!/bin/bash
# 把 dist/CC HUD.app 打成标准 dmg 安装包（含 Applications 拖放快捷方式）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/CC HUD.app"
[ -d "$APP" ] || { echo "先构建：./scripts/build-app.sh"; exit 1; }

STAGE="$(mktemp -d)/CC HUD"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CC HUD.app"
ln -s /Applications "$STAGE/Applications"

rm -f dist/CC-HUD.dmg
hdiutil create -volname "CC HUD" -srcfolder "$STAGE" -ov -format UDZO -quiet dist/CC-HUD.dmg
echo "Built: dist/CC-HUD.dmg"

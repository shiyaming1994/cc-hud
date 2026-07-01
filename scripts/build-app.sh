#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release"
[ -d "$BIN" ] || BIN=".build/release"
APP="dist/CC HUD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/CCHud" "$APP/Contents/MacOS/CCHud"
cp "$BIN/cc-hud-emit" "$APP/Contents/Resources/cc-hud-emit"

# 图标：assets/icon-1024.png → AppIcon.icns
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
  d=$((s * 2))
  sips -z "$d" "$d" assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CC HUD</string>
    <key>CFBundleDisplayName</key><string>CC HUD</string>
    <key>CFBundleIdentifier</key><string>io.github.shiyaming.cc-hud</string>
    <key>CFBundleExecutable</key><string>CCHud</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>CFBundleVersion</key><string>14</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>CC HUD 需要控制 iTerm2 / 终端，以便点击会话行时跳转到对应窗口。</string>
</dict>
</plist>
PLIST

# 签名：优先用本机 Apple Development 证书（身份稳定 → 自动化/辅助功能授权跨重打包持久）；
# 没有则退回 ad-hoc（每次重打包授权会失效，需重新允许）。
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "warn: 未找到 Apple Development 证书，使用 ad-hoc 签名（TCC 授权不跨构建持久）"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/cc-hud-emit"
codesign --force --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"
echo "Built: $APP"

# INSTALL=1 ./scripts/build-app.sh → 安装到 /Applications 并重启
if [ "${INSTALL:-0}" = "1" ]; then
  pkill -f "CC HUD.app" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/CC HUD.app"
  ditto "$APP" "/Applications/CC HUD.app"
  open "/Applications/CC HUD.app"
  echo "Installed: /Applications/CC HUD.app"
else
  echo "运行: open \"$APP\"   （或 INSTALL=1 $0 安装到 /Applications）"
fi

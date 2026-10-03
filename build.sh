#!/usr/bin/env bash
# Build Pomodoro.app from Sources/ with the system Swift toolchain.
# Everything is written under ./build so the build never touches anything else.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/.dev/Pomodoro.app"
BIN="$APP/Contents/MacOS/Pomodoro"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.0"

echo "==> 清理旧产物"
# The bundle deliberately lives under a dot-directory: Spotlight and
# LaunchServices both ignore hidden directories, so the dev build never shows up
# as a second "Pomodoro" app next to the installed one in ~/Applications.
# build/Pomodoro.app is the legacy location and is removed if it is still around.
rm -rf "$APP" build/Pomodoro.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/cache
touch build/.metadata_never_index

echo "==> 编译（swiftc ${TARGET}）"
swiftc \
  -O \
  -swift-version 5 \
  -target "$TARGET" \
  -module-cache-path build/cache \
  -framework AppKit \
  -framework UserNotifications \
  -framework ServiceManagement \
  -o "$BIN" \
  Sources/*.swift

echo "==> 组装 bundle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 临时签名"
codesign --force --sign - --identifier local.pomodoro "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP" >/dev/null

echo "==> 校验"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
file "$BIN" | sed 's/^/    /'

echo ""
echo "构建完成：$APP"
echo "自检：    $BIN --selftest"
echo "安装：    ./install.sh"

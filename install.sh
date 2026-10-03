#!/usr/bin/env bash
# Install Pomodoro.app into ~/Applications (override with POMODORO_INSTALL_DIR).
set -euo pipefail

cd "$(dirname "$0")"

SRC="build/.dev/Pomodoro.app"
DEST_DIR="${POMODORO_INSTALL_DIR:-$HOME/Applications}"
DEST="${DEST_DIR}/Pomodoro.app"

if [ ! -d "$SRC" ]; then
  echo "找不到 ${SRC}，请先运行 ./build.sh" >&2
  exit 1
fi

echo "==> 退出正在运行的实例"
osascript -e 'quit app id "local.pomodoro"' >/dev/null 2>&1 || true
pkill -f "Pomodoro.app/Contents/MacOS/Pomodoro" >/dev/null 2>&1 || true

# Wait until it is really gone: the app refuses to start while another instance
# still holds the pid file, so launching too early would leave nothing running.
for _ in $(seq 1 40); do
  if ! pgrep -f "Pomodoro.app/Contents/MacOS/Pomodoro" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if pgrep -f "Pomodoro.app/Contents/MacOS/Pomodoro" >/dev/null 2>&1; then
  echo "警告：旧实例仍在运行，强制结束" >&2
  pkill -9 -f "Pomodoro.app/Contents/MacOS/Pomodoro" >/dev/null 2>&1 || true
  sleep 1
fi

echo "==> 安装到 ${DEST}"
mkdir -p "${DEST_DIR}"
rm -rf "${DEST}"
cp -R "$SRC" "${DEST}"

echo "==> 重新签名"
codesign --force --sign - --identifier local.pomodoro "${DEST}" >/dev/null 2>&1 \
  || codesign --force --sign - "${DEST}" >/dev/null
codesign --verify --verbose=1 "${DEST}" 2>&1 | sed 's/^/    /'

echo "==> 启动"
open "${DEST}"

echo ""
echo "已安装并启动，菜单栏应出现 🍅 倒计时。"
echo "  · 开机自启：点菜单里的「开机自启」"
echo "  · 状态查询：\"${DEST}/Contents/MacOS/Pomodoro\" --status"
echo "  · 卸载：    ./uninstall.sh"

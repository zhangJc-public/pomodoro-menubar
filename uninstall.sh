#!/usr/bin/env bash
# Remove Pomodoro.app and its login item. Statistics survive unless --purge is given.
set -euo pipefail

cd "$(dirname "$0")"

DEST_DIR="${POMODORO_INSTALL_DIR:-$HOME/Applications}"
DEST="${DEST_DIR}/Pomodoro.app"
DATA="${HOME}/Library/Application Support/Pomodoro"
AGENT="${HOME}/Library/LaunchAgents/local.pomodoro.plist"

PURGE=0
if [ "${1:-}" = "--purge" ]; then
  PURGE=1
fi

echo "==> 退出应用"
osascript -e 'quit app id "local.pomodoro"' >/dev/null 2>&1 || true
pkill -f "Pomodoro.app/Contents/MacOS/Pomodoro" >/dev/null 2>&1 || true
sleep 1

echo "==> 移除登录项"
# Ask the app to unregister first: an SMAppService.mainApp registration cannot be undone
# from a shell, and deleting the bundle would leave a stale entry in System Settings.
if [ -x "${DEST}/Contents/MacOS/Pomodoro" ]; then
  "${DEST}/Contents/MacOS/Pomodoro" --login-item off >/dev/null 2>&1 || true
fi
launchctl bootout "gui/$(id -u)/local.pomodoro" >/dev/null 2>&1 || true
rm -f "${AGENT}"

echo "==> 删除应用：${DEST}"
if [ -d "${DEST}" ]; then
  rm -rf "${DEST}"
else
  echo "    （未安装，跳过）"
fi

if [ "${PURGE}" = "1" ]; then
  echo "==> 删除数据：${DATA}"
  rm -rf "${DATA}"
else
  echo "==> 数据保留：${DATA}"
  echo "    （如需一并删除，运行 ./uninstall.sh --purge）"
fi

echo "完成。"

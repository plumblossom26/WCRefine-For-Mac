#!/bin/bash
set -euo pipefail
APP="${1:-${HOME}/Applications/WCRefine-WeChat.app}"
[[ -d "$APP" ]] || { echo "找不到副本: $APP" >&2; exit 1; }

TARGET_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo com.tencent.xinWeChat)"

# 主副本与原版共用同一沙盒数据目录，必须先退出所有微信；
# 多开副本（CFBundleIdentifier 不同）拥有独立数据目录，可与原版/主副本同时运行。
if [[ "$TARGET_BUNDLE_ID" == "com.tencent.xinWeChat" ]]; then
    for RUNNING_APP in \
        "/Applications/微信.app/Contents/MacOS/WeChat" \
        "/Applications/WeChat.app/Contents/MacOS/WeChat" \
        "${HOME}/Applications/WCRefine-WeChat.app/Contents/MacOS/WeChat"; do
        if pgrep -f "$RUNNING_APP" >/dev/null 2>&1; then
            echo "请先完全退出已运行的微信，再启动主副本（多开副本不受此限制）。" >&2
            exit 2
        fi
    done
fi
open -n "$APP"

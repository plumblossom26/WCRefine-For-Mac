#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 270115（微信.app）构建出的副本 exec 即被 SIGKILL，必须优先用 WeChat.app（270135）。
if [[ -d "/Applications/WeChat.app" ]]; then
    SOURCE_APP="/Applications/WeChat.app"
elif [[ -d "/Applications/微信.app" ]]; then
    SOURCE_APP="/Applications/微信.app"
else
    SOURCE_APP="/Applications/WeChat.app"
fi
DEST_APP="${HOME}/Applications/WCRefine-WeChat.app"
DEST_EXPLICIT=0
MULTI=0
REPLACE=0

usage() {
    cat <<USAGE
Usage: Installer/install.sh [options]

Options:
  --app PATH      Source WeChat.app (default: /Applications/WeChat.app if present)
  --dest PATH     Destination copy (default: ~/Applications/WCRefine-WeChat.app).
                  With --multi, this path is used as given instead of the
                  default WCRefine-WeChat-<N>.app location.
  --multi N       Install a multi-instance copy (多开副本) as
                  ~/Applications/WCRefine-WeChat-<N>.app with an isolated
                  bundle id; it can run alongside the original WeChat (N >= 2)
  --replace       Replace an existing destination copy without accumulating backups
  -h, --help      Show this help
USAGE
}

die() {
    echo "错误: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || die "--app 缺少路径"
            SOURCE_APP="$2"
            shift 2
            ;;
        --dest)
            [[ $# -ge 2 ]] || die "--dest 缺少路径"
            DEST_APP="$2"
            DEST_EXPLICIT=1
            shift 2
            ;;
        --multi)
            [[ $# -ge 2 ]] || die "--multi 缺少编号"
            [[ "$2" =~ ^[0-9]+$ ]] || die "--multi 需要数字编号"
            [[ "$2" -ge 2 ]] || die "--multi 编号需 >= 2"
            MULTI="$2"
            shift 2
            ;;
        --replace)
            REPLACE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数: $1"
            ;;
    esac
done

[[ "$(uname -m)" == "arm64" ]] || die "当前仅支持 Apple Silicon（arm64）"
[[ -d "$SOURCE_APP" ]] || die "找不到微信: $SOURCE_APP"

echo "构建管理 App 与插件…"
make -C "$ROOT_DIR" all

APP_BINARY="$ROOT_DIR/build/WCRefine-for-Mac.app/Contents/MacOS/WCRefine-for-Mac"
DYLIB="$ROOT_DIR/build/WCRefineMac.dylib"
[[ -x "$APP_BINARY" ]] || die "管理 App 构建失败"
[[ -f "$DYLIB" ]] || die "插件构建失败"

if [[ "$MULTI" -ge 2 && "$DEST_EXPLICIT" -eq 0 ]]; then
    DEST_APP="${HOME}/Applications/WCRefine-WeChat-${MULTI}.app"
fi

ARGS=(--install --source "$SOURCE_APP" --output "$DEST_APP" --dylib "$DYLIB")
if [[ "$MULTI" -ge 2 ]]; then
    ARGS+=(--bundle-id "com.tencent.xinWeChat.WCRefineMulti${MULTI}" \
           --display-name "WCRefine 微信 多开${MULTI}")
fi
if [[ "$REPLACE" -eq 1 ]]; then
    ARGS+=(--replace)
fi

"$APP_BINARY" "${ARGS[@]}"

if [[ "$MULTI" -ge 2 ]]; then
    cat <<DONE

多开副本已生成: $DEST_APP

它拥有独立数据目录，可与原版微信/主副本同时运行，无需先退出原版:
  open "$DEST_APP"

首次启动需扫码登录另一个微信账号。
DONE
else
    cat <<DONE

安装完成: $DEST_APP

请先完全退出原版微信，然后运行:
  open -n "$DEST_APP"

安装只修改副本，不会改写 ${SOURCE_APP}。
同一时间只运行一份同 bundle id 的微信（主副本与原版），避免争用数据目录；
需要多开请改用 --multi N 生成独立数据目录的多开副本。
DONE
fi

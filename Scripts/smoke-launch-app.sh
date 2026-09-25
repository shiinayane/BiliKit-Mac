#!/bin/sh

# CI 在较旧 macOS 上启动发布工具链构建的 App：确认能加载并持续运行，不运行测试。
# 用法：smoke-launch-app.sh <BiliKit.app 的 tar>

set -eu

umask 077

archive=${1:?用法：$0 <BiliKit.app 的 tar>}
settle_seconds=15

work_root=$(mktemp -d "${TMPDIR:-/tmp}/BiliKit-smoke.XXXXXX")
app_pid=
cleanup() {
    status=$?
    if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work_root"
    exit "$status"
}
trap cleanup EXIT

tar -xf "$archive" -C "$work_root"
executable="$work_root/BiliKit.app/Contents/MacOS/BiliKit"
[ -x "$executable" ] || {
    echo "[Smoke] 找不到可执行文件：$executable" >&2
    exit 1
}

marker="$work_root/started"
: >"$marker"
"$executable" >"$work_root/app.log" 2>&1 &
app_pid=$!

elapsed=0
while [ "$elapsed" -lt "$settle_seconds" ]; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
        wait "$app_pid" && status=0 || status=$?
        echo "[Smoke] App 在 ${elapsed} 秒内退出（status $status）" >&2
        cat "$work_root/app.log" >&2
        find "$HOME/Library/Logs/DiagnosticReports" -name 'BiliKit*' -newer "$marker" \
            -exec head -n 60 {} \; 2>/dev/null >&2 || true
        app_pid=
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

echo "[Smoke] App 已持续运行 ${settle_seconds} 秒"

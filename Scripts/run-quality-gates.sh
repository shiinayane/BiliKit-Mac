#!/bin/sh

set -eu

fail() {
    echo "质量 Gate 失败：$1" >&2
    exit 1
}

mode="${1:-package}"
case "$mode" in
    static|package|app) ;;
    *) fail "模式必须是 static、package 或 app" ;;
esac

compact_logs="${BILIKIT_COMPACT_LOGS:-0}"
case "$compact_logs" in
    0|1) ;;
    *) fail "BILIKIT_COMPACT_LOGS 必须是 0 或 1" ;;
esac

gate_log_dir=""
if [ "$compact_logs" = "1" ]; then
    gate_log_dir=$(mktemp -d "${TMPDIR:-/tmp}/BiliKit-gates.XXXXXX")
    echo "[Gate] 精简日志已启用；完整日志：$gate_log_dir"
fi

run_with_optional_compact_log() {
    stage="$1"
    shift

    if [ "$compact_logs" = "0" ]; then
        "$@"
        return
    fi

    log_path="$gate_log_dir/$stage.log"
    if "$@" >"$log_path" 2>&1; then
        echo "[Gate] $stage 通过；完整日志：$log_path"
        return
    else
        status=$?
    fi

    echo "[Gate] $stage 失败；完整日志：$log_path" >&2
    tail -n 40 "$log_path" | cut -c 1-360 >&2
    return "$status"
}

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repository_root"

run_static_contracts() {
    sh Scripts/check-architecture.sh || return $?
    sh Scripts/check-secrets.sh || return $?
    sh Scripts/check-project-contract.sh || return $?
    git diff --check || return $?
    git diff --cached --check || return $?
}

echo "[Gate] 静态契约"
run_with_optional_compact_log static-contracts run_static_contracts

if [ "$mode" = "static" ]; then
    echo "[Gate] static 通过"
    exit 0
fi

echo "[Gate] Swift Package"
run_with_optional_compact_log \
    swift-package \
    xcrun swift test --package-path Packages/BiliKitCore

if [ "$mode" = "package" ]; then
    echo "[Gate] package 通过"
    exit 0
fi

xcodebuild -version >/dev/null 2>&1 \
    || fail "app 模式需要完整 Xcode；请先切换 xcode-select 或显式设置 DEVELOPER_DIR"

derived_data_path="${BILIKIT_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/BiliKitMac-derived}"

echo "[Gate] App build-for-testing"
run_with_optional_compact_log \
    app-build-for-testing \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing

echo "[Gate] App unit tests"
run_with_optional_compact_log \
    app-unit-tests \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    test-without-building \
    -only-testing:BiliKitMacTests

echo "[Gate] app 通过"

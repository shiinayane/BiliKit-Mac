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

github_actions="${GITHUB_ACTIONS:-false}"
github_summary="${GITHUB_STEP_SUMMARY:-}"
if [ "$github_actions" = "true" ] && [ -n "$github_summary" ]; then
    {
        echo "### BiliKit quality gate"
        echo
        echo "| Stage | Result |"
        echo "| --- | --- |"
    } >>"$github_summary"
fi

record_stage_result() {
    stage="$1"
    result="$2"
    if [ "$github_actions" = "true" ] && [ -n "$github_summary" ]; then
        echo "| \`$stage\` | $result |" >>"$github_summary"
    fi
}

run_with_optional_compact_log() {
    stage="$1"
    shift

    if [ "$github_actions" = "true" ]; then
        echo "::group::$stage"
    fi

    if [ "$compact_logs" = "0" ]; then
        if "$@"; then
            status=0
        else
            status=$?
        fi
    else
        log_path="$gate_log_dir/$stage.log"
        if "$@" >"$log_path" 2>&1; then
            echo "[Gate] $stage 通过；完整日志：$log_path"
            status=0
        else
            status=$?
            echo "[Gate] $stage 失败；完整日志：$log_path" >&2
            tail -n 40 "$log_path" | LC_ALL=C cut -c 1-360 >&2
        fi
    fi

    if [ "$github_actions" = "true" ]; then
        echo "::endgroup::"
    fi

    if [ "$status" -eq 0 ]; then
        record_stage_result "$stage" "passed"
    else
        record_stage_result "$stage" "failed"
    fi
    return "$status"
}

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repository_root"

run_static_contracts() {
    sh Scripts/check-architecture.sh || return $?
    sh Scripts/check-secrets.sh || return $?
    sh Scripts/check-project-contract.sh || return $?
    sh Scripts/check-swift-format.sh || return $?
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

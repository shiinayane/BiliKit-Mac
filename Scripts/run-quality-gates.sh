#!/bin/sh

set -eu

umask 077

fail() {
    echo "质量 Gate 失败：$1" >&2
    exit 1
}

mode="${1:-package}"
case "$mode" in
    static|package|app) ;;
    *) fail "模式必须是 static、package 或 app" ;;
esac

fresh_artifacts="${BILIKIT_GATE_FRESH:-0}"
retain_artifacts="${BILIKIT_GATE_RETAIN_ARTIFACTS:-0}"
print_paths_only="${BILIKIT_GATE_PRINT_PATHS_ONLY:-0}"
case "$fresh_artifacts" in
    0|1) ;;
    *) fail "BILIKIT_GATE_FRESH 必须是 0 或 1" ;;
esac
case "$retain_artifacts" in
    0|1) ;;
    *) fail "BILIKIT_GATE_RETAIN_ARTIFACTS 必须是 0 或 1" ;;
esac
case "$print_paths_only" in
    0|1) ;;
    *) fail "BILIKIT_GATE_PRINT_PATHS_ONLY 必须是 0 或 1" ;;
esac
[ "$retain_artifacts" = "0" ] || [ "$fresh_artifacts" = "1" ] \
    || fail "BILIKIT_GATE_RETAIN_ARTIFACTS=1 只能与 BILIKIT_GATE_FRESH=1 一起使用"

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
checkout_key=$(printf '%s' "$repository_root" | shasum -a 256 | awk '{ print substr($1, 1, 16) }')
[ -n "$checkout_key" ] || fail "无法从 canonical worktree path 计算缓存 key"
cd "$repository_root"

fresh_root=""
gate_log_dir=""
cleanup_status=0

safe_remove_fresh_root() {
    [ -n "$fresh_root" ] || return 0
    case "$fresh_root" in
        "$temporary_base"/BiliKit-quality-gate.*) ;;
        *)
            echo "[Gate] 拒绝清理未验证的 fresh 路径：$fresh_root" >&2
            return 1
            ;;
    esac
    [ -f "$fresh_root/.bilikit-quality-gate-fresh-root" ] \
        || {
            echo "[Gate] 拒绝清理缺少 marker 的 fresh 路径：$fresh_root" >&2
            return 1
        }
    [ "$(cat "$fresh_root/.bilikit-quality-gate-fresh-root")" = "$repository_root" ] \
        || {
            echo "[Gate] 拒绝清理 checkout marker 不匹配的 fresh 路径：$fresh_root" >&2
            return 1
        }
    rm -rf -- "$fresh_root"
    [ ! -e "$fresh_root" ] || return 1
}

safe_remove_gate_logs() {
    [ -n "$gate_log_dir" ] || return 0
    [ "$fresh_artifacts" = "0" ] || return 0
    case "$gate_log_dir" in
        "$artifact_root"/logs.*) ;;
        *)
            echo "[Gate] 拒绝清理未验证的日志路径：$gate_log_dir" >&2
            return 1
            ;;
    esac
    [ -f "$gate_log_dir/.bilikit-quality-gate-log-root" ] \
        || {
            echo "[Gate] 拒绝清理缺少 marker 的日志路径：$gate_log_dir" >&2
            return 1
        }
    rm -rf -- "$gate_log_dir"
    [ ! -e "$gate_log_dir" ] || return 1
}

finalize_artifacts() {
    status=$?
    trap - EXIT HUP INT TERM

    if ! safe_remove_gate_logs; then
        echo "[Gate] 临时日志清理失败" >&2
        cleanup_status=1
    fi

    if [ "$fresh_artifacts" = "1" ] && [ -n "$fresh_root" ]; then
        if [ "$retain_artifacts" = "1" ]; then
            echo "[Gate] fresh 诊断产物已保留：$fresh_root"
        elif safe_remove_fresh_root; then
            echo "[Gate] fresh 产物已清理：$fresh_root"
        else
            echo "[Gate] fresh 产物清理失败：$fresh_root" >&2
            cleanup_status=1
        fi
    fi

    if [ "$status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        status=$cleanup_status
    fi
    exit "$status"
}

trap finalize_artifacts EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$fresh_artifacts" = "1" ]; then
    [ -z "${BILIKIT_DERIVED_DATA_PATH:-}" ] \
        || fail "fresh 模式不接受 BILIKIT_DERIVED_DATA_PATH；所有产物必须位于唯一临时根"
    temporary_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
    fresh_root=$(mktemp -d "$temporary_base/BiliKit-quality-gate.XXXXXX")
    chmod 700 "$fresh_root"
    printf '%s\n' "$repository_root" >"$fresh_root/.bilikit-quality-gate-fresh-root"
    artifact_root=$fresh_root
    artifact_mode="fresh"
else
    artifact_root="$repository_root/.build/bilikit-quality-gates/$checkout_key"
    mkdir -p "$artifact_root"
    artifact_root=$(CDPATH= cd -- "$artifact_root" && pwd -P)
    artifact_mode="iteration"
fi

swiftpm_scratch_path="$artifact_root/swiftpm-scratch"
swiftpm_cache_path="$artifact_root/swiftpm-cache"
swiftpm_config_path="$artifact_root/swiftpm-config"
swiftpm_security_path="$artifact_root/swiftpm-security"
xcode_package_path="$artifact_root/xcode-packages"
xcode_package_cache_path="$artifact_root/xcode-package-cache"
clang_module_cache_path="$artifact_root/module-cache/clang"
swift_module_cache_path="$artifact_root/module-cache/swift"

if [ -n "${BILIKIT_DERIVED_DATA_PATH:-}" ]; then
    derived_data_path=$BILIKIT_DERIVED_DATA_PATH
else
    derived_data_path="$artifact_root/xcode-derived"
fi

for path in \
    "$swiftpm_scratch_path" \
    "$swiftpm_cache_path" \
    "$swiftpm_config_path" \
    "$swiftpm_security_path" \
    "$xcode_package_path" \
    "$xcode_package_cache_path" \
    "$clang_module_cache_path" \
    "$swift_module_cache_path" \
    "$derived_data_path"
do
    mkdir -p "$path"
done
derived_data_path=$(CDPATH= cd -- "$derived_data_path" && pwd -P)

case "$derived_data_path" in
    /|"${HOME:-/nonexistent}"|"$repository_root")
        fail "BILIKIT_DERIVED_DATA_PATH 不能解析为根目录、HOME 或仓库根目录"
        ;;
esac

export CLANG_MODULE_CACHE_PATH="$clang_module_cache_path"
export SWIFT_MODULE_CACHE_PATH="$swift_module_cache_path"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_module_cache_path"

echo "[Gate] 产物模式：${artifact_mode}（checkout key: ${checkout_key}）"
echo "[Gate] SwiftPM scratch：$swiftpm_scratch_path"
echo "[Gate] Xcode DerivedData：$derived_data_path"
echo "[Gate] Clang module cache：$clang_module_cache_path"
echo "[Gate] Swift module cache：$swift_module_cache_path"

if [ "$print_paths_only" = "1" ]; then
    echo "[Gate] 仅输出产物路径；未运行检查"
    exit 0
fi

compact_logs="${BILIKIT_COMPACT_LOGS:-0}"
case "$compact_logs" in
    0|1) ;;
    *) fail "BILIKIT_COMPACT_LOGS 必须是 0 或 1" ;;
esac

if [ "$compact_logs" = "1" ]; then
    gate_log_dir=$(mktemp -d "$artifact_root/logs.XXXXXX")
    printf '%s\n' "$repository_root" >"$gate_log_dir/.bilikit-quality-gate-log-root"
    echo "[Gate] 精简日志已启用；日志在退出时清理"
    if [ "$fresh_artifacts" = "1" ] && [ "$retain_artifacts" = "1" ]; then
        echo "[Gate] fresh retain 已启用；完整日志将随诊断产物保留：$gate_log_dir"
    fi
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
            echo "[Gate] $stage 通过"
            if [ "$fresh_artifacts" = "1" ] && [ "$retain_artifacts" = "1" ]; then
                echo "[Gate] $stage 完整日志：$log_path"
            fi
            status=0
        else
            status=$?
            echo "[Gate] $stage 失败；临时日志末尾如下" >&2
            tail -n 40 "$log_path" | LC_ALL=C cut -c 1-360 >&2
            if [ "$fresh_artifacts" = "1" ] && [ "$retain_artifacts" = "1" ]; then
                echo "[Gate] $stage 完整日志：$log_path" >&2
            fi
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
    xcrun swift test \
    --package-path Packages/BiliKitCore \
    --scratch-path "$swiftpm_scratch_path" \
    --cache-path "$swiftpm_cache_path" \
    --config-path "$swiftpm_config_path" \
    --security-path "$swiftpm_security_path" \
    --manifest-cache local

if [ "$mode" = "package" ]; then
    echo "[Gate] package 通过"
    exit 0
fi

xcodebuild -version >/dev/null 2>&1 \
    || fail "app 模式需要完整 Xcode；请先切换 xcode-select 或显式设置 DEVELOPER_DIR"

echo "[Gate] App build-for-testing"
run_with_optional_compact_log \
    app-build-for-testing \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    -clonedSourcePackagesDirPath "$xcode_package_path" \
    -packageCachePath "$xcode_package_cache_path" \
    CLANG_MODULE_CACHE_PATH="$clang_module_cache_path" \
    SWIFT_MODULE_CACHE_PATH="$swift_module_cache_path" \
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
    -clonedSourcePackagesDirPath "$xcode_package_path" \
    -packageCachePath "$xcode_package_cache_path" \
    CLANG_MODULE_CACHE_PATH="$clang_module_cache_path" \
    SWIFT_MODULE_CACHE_PATH="$swift_module_cache_path" \
    CODE_SIGNING_ALLOWED=NO \
    test-without-building \
    -only-testing:BiliKitMacTests

echo "[Gate] app 通过"

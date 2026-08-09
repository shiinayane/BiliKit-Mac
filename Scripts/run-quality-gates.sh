#!/bin/sh

set -eu

umask 077

cache_schema="bilikit-quality-gates-v2"

fail_classification() {
    classification="$1"
    shift
    echo "[Gate] classification=$classification" >&2
    echo "质量 Gate 失败：$*" >&2
    exit 1
}

marker_has_line() {
    marker_file="$1"
    expected_line="$2"
    grep -F -x "$expected_line" "$marker_file" >/dev/null 2>&1
}

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
checkout_key=$(printf '%s' "$repository_root" | shasum -a 256 | awk '{ print substr($1, 1, 16) }')
[ -n "$checkout_key" ] || fail_classification configuration "无法从 canonical worktree path 计算缓存 key"
cd "$repository_root"

temporary_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P) \
    || fail_classification sandbox "无法解析任务临时目录"
gate_checkout_root="$repository_root/.build/bilikit-quality-gates/$checkout_key"

validate_iteration_root() {
    candidate="$1"
    [ -d "$candidate" ] || return 1
    [ ! -L "$candidate" ] || return 1
    canonical_candidate=$(CDPATH= cd -- "$candidate" && pwd -P) || return 1
    [ "$canonical_candidate" = "$gate_checkout_root" ] || return 1
    marker="$candidate/.bilikit-quality-gate-iteration-root"
    [ -f "$marker" ] || return 1
    marker_has_line "$marker" "schema=$cache_schema" || return 1
    marker_has_line "$marker" "repository_root=$repository_root" || return 1
    marker_has_line "$marker" "checkout_key=$checkout_key" || return 1
}

validate_fresh_root() {
    candidate="$1"
    expected_run_identity="${2:-}"
    [ -n "$candidate" ] || return 1
    case "$candidate" in
        /|"${HOME:-/nonexistent}"|"$repository_root") return 1 ;;
        "$temporary_base"/BiliKit-quality-gate.*) ;;
        *) return 1 ;;
    esac
    [ -d "$candidate" ] || return 1
    [ ! -L "$candidate" ] || return 1
    canonical_candidate=$(CDPATH= cd -- "$candidate" && pwd -P) || return 1
    [ "$canonical_candidate" = "${candidate%/}" ] || return 1
    [ "$(/usr/bin/stat -f '%u' "$candidate" 2>/dev/null)" = "$(id -u)" ] || return 1
    [ "$(/usr/bin/stat -f '%Lp' "$candidate" 2>/dev/null)" = "700" ] || return 1
    marker="$candidate/.bilikit-quality-gate-fresh-root"
    [ -f "$marker" ] || return 1
    marker_has_line "$marker" "schema=$cache_schema" || return 1
    marker_has_line "$marker" "repository_root=$repository_root" || return 1
    marker_has_line "$marker" "checkout_key=$checkout_key" || return 1
    grep -E -x 'artifact_policy=(fresh|closure)' "$marker" >/dev/null 2>&1 || return 1
    grep -E -x 'run_identity=[^[:space:]]+' "$marker" >/dev/null 2>&1 || return 1
    if [ -n "$expected_run_identity" ]; then
        marker_has_line "$marker" "run_identity=$expected_run_identity" || return 1
    fi
}

safe_remove_iteration_root() {
    [ -e "$gate_checkout_root" ] || {
        echo "[Gate] 当前 checkout 没有 iteration 产物"
        return 0
    }
    case "$gate_checkout_root" in
        "$repository_root"/.build/bilikit-quality-gates/"$checkout_key") ;;
        *) return 1 ;;
    esac
    validate_iteration_root "$gate_checkout_root" || return 1
    rm -rf -- "$gate_checkout_root"
    [ ! -e "$gate_checkout_root" ]
}

safe_remove_fresh_root() {
    candidate="$1"
    expected_run_identity="${2:-}"
    validate_fresh_root "$candidate" "$expected_run_identity" || return 1
    rm -rf -- "$candidate"
    [ ! -e "$candidate" ]
}

command_name="${1:-package}"
case "$command_name" in
    cleanup-iteration)
        [ "$#" -eq 1 ] || fail_classification configuration "cleanup-iteration 不接受路径参数"
        safe_remove_iteration_root \
            || fail_classification configuration "拒绝清理未通过 marker 与 checkout identity 验证的 iteration 路径"
        echo "[Gate] iteration 产物已清理：$gate_checkout_root"
        exit 0
        ;;
    cleanup-retained)
        [ "$#" -eq 2 ] || fail_classification configuration "cleanup-retained 需要一个脚本打印的精确路径"
        retained_root="$2"
        safe_remove_fresh_root "$retained_root" "" \
            || fail_classification configuration "拒绝清理未通过 owner、mode、marker 与 checkout identity 验证的 retained 路径"
        echo "[Gate] retained fresh 产物已清理：$retained_root"
        exit 0
        ;;
esac

mode="$command_name"
case "$mode" in
    static|package|app) ;;
    *) fail_classification configuration "模式必须是 static、package、app、cleanup-iteration 或 cleanup-retained" ;;
esac
[ "$#" -le 2 ] || fail_classification configuration "质量 Gate 最多接受 mode 与 artifact policy 两个参数"

fresh_compat="${BILIKIT_GATE_FRESH:-0}"
retain_artifacts="${BILIKIT_GATE_RETAIN_ARTIFACTS:-0}"
print_paths_only="${BILIKIT_GATE_PRINT_PATHS_ONLY:-0}"
term_is_timeout="${BILIKIT_GATE_TERM_IS_TIMEOUT:-0}"
case "$fresh_compat" in 0|1) ;; *) fail_classification configuration "BILIKIT_GATE_FRESH 必须是 0 或 1" ;; esac
case "$retain_artifacts" in 0|1) ;; *) fail_classification configuration "BILIKIT_GATE_RETAIN_ARTIFACTS 必须是 0 或 1" ;; esac
case "$print_paths_only" in 0|1) ;; *) fail_classification configuration "BILIKIT_GATE_PRINT_PATHS_ONLY 必须是 0 或 1" ;; esac
case "$term_is_timeout" in 0|1) ;; *) fail_classification configuration "BILIKIT_GATE_TERM_IS_TIMEOUT 必须是 0 或 1" ;; esac

if [ "$#" -eq 2 ]; then
    artifact_policy="$2"
    if [ "$fresh_compat" = "1" ] && [ "$artifact_policy" = "iteration" ]; then
        fail_classification configuration "显式 iteration 与 BILIKIT_GATE_FRESH=1 冲突"
    fi
else
    if [ "$fresh_compat" = "1" ]; then
        artifact_policy="fresh"
    else
        artifact_policy="iteration"
    fi
fi
case "$artifact_policy" in
    iteration|fresh|closure) ;;
    *) fail_classification configuration "artifact policy 必须是 iteration、fresh 或 closure" ;;
esac
if [ "$retain_artifacts" = "1" ] && [ "$artifact_policy" = "iteration" ]; then
    fail_classification configuration "BILIKIT_GATE_RETAIN_ARTIFACTS=1 只能用于 fresh 或 closure"
fi
case "$artifact_policy" in fresh|closure) fresh_artifacts=1 ;; iteration) fresh_artifacts=0 ;; esac

developer_dir_input="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$developer_dir_input" ] \
    || fail_classification toolchain "完整 Xcode Developer 目录不存在：$developer_dir_input"
developer_dir=$(CDPATH= cd -- "$developer_dir_input" && pwd -P) \
    || fail_classification toolchain "无法解析完整 Xcode Developer 目录"
export DEVELOPER_DIR="$developer_dir"

if ! xcode_version=$(xcodebuild -version 2>&1); then
    fail_classification toolchain "DEVELOPER_DIR 没有提供可用的完整 Xcode"
fi
if ! swift_version=$(xcrun swift --version 2>&1); then
    fail_classification toolchain "所选 Xcode 没有提供可用的 Swift 工具链"
fi

identity_files="
Packages/BiliKitCore/Package.swift
Packages/BiliKitCore/Package.resolved
BiliKitMac.xcodeproj/project.pbxproj
BiliKitMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
"
for identity_file in $identity_files; do
    [ -f "$identity_file" ] || fail_classification configuration "缺少构建身份输入：$identity_file"
done

generation_key=$(
    {
        printf 'schema=%s\n' "$cache_schema"
        printf 'repository_root=%s\n' "$repository_root"
        printf 'developer_dir=%s\n' "$developer_dir"
        printf 'architecture=%s\n' "$(uname -m)"
        printf '%s\n' "$xcode_version"
        printf '%s\n' "$swift_version"
        for identity_file in $identity_files; do
            shasum -a 256 "$identity_file"
        done
        find BiliKitMac.xcodeproj -type f \
            \( -name '*.xcscheme' -o -name '*.xcconfig' -o -name '*.xctestplan' \) \
            -print | LC_ALL=C sort | while IFS= read -r identity_file; do
                shasum -a 256 "$identity_file"
            done
    } | shasum -a 256 | awk '{ print substr($1, 1, 16) }'
)
[ -n "$generation_key" ] || fail_classification configuration "无法计算 iteration generation"

fresh_root=""
fresh_run_identity=""
gate_log_dir=""
artifact_root=""
cleanup_status=0
force_cleanup_fresh=0

report_artifact_capacity() {
    [ -n "$artifact_root" ] || return 0
    [ -d "$artifact_root" ] || return 0
    total_kib=$(/usr/bin/du -sk "$artifact_root" 2>/dev/null | awk '{ print $1 }') || total_kib="unknown"
    echo "[Gate] repository-artifacts total-kib=$total_kib policy=$artifact_policy generation=$generation_key"
    accounted_kib=0
    capacity_known=1
    for component in swiftpm-scratch swiftpm-cache swiftpm-config swiftpm-security swiftpm-home xcode-derived xcode-packages xcode-package-cache xcode-user-home module-cache; do
        if [ -e "$artifact_root/$component" ]; then
            component_kib=$(/usr/bin/du -sk "$artifact_root/$component" 2>/dev/null | awk '{ print $1 }') || component_kib="unknown"
            echo "[Gate] repository-artifacts component=$component kib=$component_kib"
            case "$component_kib" in
                *[!0-9]*|"") capacity_known=0 ;;
                *) accounted_kib=$((accounted_kib + component_kib)) ;;
            esac
        fi
    done
    logs_kib=$(find "$artifact_root" -mindepth 1 -maxdepth 1 -type d -name 'logs.*' -exec /usr/bin/du -sk {} + 2>/dev/null | awk '{ total += $1 } END { print total + 0 }') \
        || logs_kib="unknown"
    echo "[Gate] repository-artifacts component=logs kib=$logs_kib"
    case "$logs_kib" in
        *[!0-9]*|"") capacity_known=0 ;;
        *) accounted_kib=$((accounted_kib + logs_kib)) ;;
    esac
    case "$total_kib" in *[!0-9]*|"") capacity_known=0 ;; esac
    if [ "$capacity_known" -eq 1 ] && [ "$total_kib" -ge "$accounted_kib" ]; then
        other_kib=$((total_kib - accounted_kib))
    else
        other_kib="unknown"
    fi
    echo "[Gate] repository-artifacts component=other kib=$other_kib"
    if [ "$artifact_policy" = "iteration" ]; then
        generation_count=$(find "$gate_checkout_root/generations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | awk 'END { print NR + 0 }')
        echo "[Gate] repository-artifacts generation-count=$generation_count"
        if [ "$generation_count" -gt 1 ]; then
            echo "[Gate] 存在旧 generation；确认无并行 Gate 后可运行：sh Scripts/run-quality-gates.sh cleanup-iteration"
        fi
    fi
}

safe_remove_gate_logs() {
    [ -n "$gate_log_dir" ] || return 0
    [ "$fresh_artifacts" = "0" ] || return 0
    case "$gate_log_dir" in "$artifact_root"/logs.*) ;; *) return 1 ;; esac
    marker="$gate_log_dir/.bilikit-quality-gate-log-root"
    [ -f "$marker" ] || return 1
    marker_has_line "$marker" "schema=$cache_schema" || return 1
    marker_has_line "$marker" "repository_root=$repository_root" || return 1
    marker_has_line "$marker" "checkout_key=$checkout_key" || return 1
    marker_has_line "$marker" "generation_key=$generation_key" || return 1
    rm -rf -- "$gate_log_dir"
    [ ! -e "$gate_log_dir" ]
}

finalize_artifacts() {
    status=$?
    trap - EXIT
    trap '' HUP INT TERM
    report_artifact_capacity || true

    if ! safe_remove_gate_logs; then
        echo "[Gate] 临时日志清理失败" >&2
        cleanup_status=1
    fi

    if [ "$fresh_artifacts" = "1" ] && [ -n "$fresh_root" ]; then
        if [ "$retain_artifacts" = "1" ] && [ "$force_cleanup_fresh" = "0" ]; then
            echo "[Gate] fresh 诊断产物已保留：$fresh_root"
            echo "[Gate] 安全清理命令：sh Scripts/run-quality-gates.sh cleanup-retained '$fresh_root'"
        elif safe_remove_fresh_root "$fresh_root" "$fresh_run_identity"; then
            echo "[Gate] fresh 产物已清理：$fresh_root"
        else
            echo "[Gate] fresh 产物清理失败：$fresh_root" >&2
            cleanup_status=1
        fi
    fi
    trap - HUP INT TERM

    if [ "$status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
        status=$cleanup_status
    fi
    exit "$status"
}

handle_signal() {
    signal_name="$1"
    signal_status="$2"
    if [ "$signal_name" = "TERM" ] && [ "$term_is_timeout" = "1" ]; then
        echo "[Gate] classification=timeout.inconclusive signal=TERM" >&2
    else
        echo "[Gate] classification=unknown signal=$signal_name" >&2
    fi
    exit "$signal_status"
}

trap finalize_artifacts EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

if [ "$fresh_artifacts" = "1" ]; then
    [ -z "${BILIKIT_DERIVED_DATA_PATH:-}" ] \
        || fail_classification configuration "fresh/closure 不接受 BILIKIT_DERIVED_DATA_PATH"
    fresh_root=$(mktemp -d "$temporary_base/BiliKit-quality-gate.XXXXXX") \
        || fail_classification sandbox "无法创建 fresh 私有根"
    chmod 700 "$fresh_root" || fail_classification sandbox "无法设置 fresh 私有根权限"
    fresh_run_identity="$(basename "$fresh_root").$$"
    {
        printf 'schema=%s\n' "$cache_schema"
        printf 'repository_root=%s\n' "$repository_root"
        printf 'checkout_key=%s\n' "$checkout_key"
        printf 'artifact_policy=%s\n' "$artifact_policy"
        printf 'run_identity=%s\n' "$fresh_run_identity"
    } >"$fresh_root/.bilikit-quality-gate-fresh-root"
    artifact_root="$fresh_root"
else
    build_root="$repository_root/.build"
    if [ -e "$build_root" ]; then
        [ -d "$build_root" ] && [ ! -L "$build_root" ] \
            || fail_classification configuration "checkout-local .build 不是普通目录"
    else
        mkdir "$build_root" || fail_classification sandbox "无法创建 checkout-local .build"
    fi
    canonical_build_root=$(CDPATH= cd -- "$build_root" && pwd -P) \
        || fail_classification sandbox "无法解析 checkout-local .build"
    [ "$canonical_build_root" = "$build_root" ] \
        || fail_classification configuration "checkout-local .build 不能通过 symlink 逃逸仓库"
    gate_base="$build_root/bilikit-quality-gates"
    if [ -e "$gate_base" ]; then
        [ -d "$gate_base" ] && [ ! -L "$gate_base" ] \
            || fail_classification configuration "checkout-local Gate 容器不是普通目录"
    else
        mkdir "$gate_base" || fail_classification sandbox "无法创建 checkout-local Gate 根"
    fi
    canonical_gate_base=$(CDPATH= cd -- "$gate_base" && pwd -P) \
        || fail_classification sandbox "无法解析 checkout-local Gate 根"
    [ "$canonical_gate_base" = "$gate_base" ] \
        || fail_classification configuration "checkout-local Gate 根不能通过 symlink 逃逸仓库"
    if [ -e "$gate_checkout_root" ]; then
        validate_iteration_root "$gate_checkout_root" \
            || fail_classification configuration "iteration 根缺少有效 marker 或 checkout identity 不匹配"
    else
        mkdir "$gate_checkout_root" || fail_classification sandbox "无法创建 iteration 根"
        {
            printf 'schema=%s\n' "$cache_schema"
            printf 'repository_root=%s\n' "$repository_root"
            printf 'checkout_key=%s\n' "$checkout_key"
        } >"$gate_checkout_root/.bilikit-quality-gate-iteration-root"
    fi
    generation_parent="$gate_checkout_root/generations"
    if [ -e "$generation_parent" ]; then
        [ -d "$generation_parent" ] && [ ! -L "$generation_parent" ] \
            || fail_classification configuration "generation 容器不是受控目录"
    else
        mkdir "$generation_parent" || fail_classification sandbox "无法创建 generation 容器"
    fi
    canonical_generation_parent=$(CDPATH= cd -- "$generation_parent" && pwd -P) \
        || fail_classification sandbox "无法解析 generation 容器"
    [ "$canonical_generation_parent" = "$generation_parent" ] \
        || fail_classification configuration "generation 容器不能通过 symlink 逃逸 iteration 根"
    artifact_root="$generation_parent/$generation_key"
    generation_marker="$artifact_root/.bilikit-quality-gate-generation-root"
    if [ -e "$artifact_root" ]; then
        [ -d "$artifact_root" ] && [ ! -L "$artifact_root" ] \
            || fail_classification configuration "generation 路径不是受控目录"
        [ -f "$generation_marker" ] \
            || fail_classification configuration "generation 根缺少 marker"
        marker_has_line "$generation_marker" "schema=$cache_schema" \
            && marker_has_line "$generation_marker" "repository_root=$repository_root" \
            && marker_has_line "$generation_marker" "checkout_key=$checkout_key" \
            && marker_has_line "$generation_marker" "generation_key=$generation_key" \
            || fail_classification configuration "generation marker identity 不匹配"
    else
        mkdir "$artifact_root" || fail_classification sandbox "无法创建 generation 根"
        {
            printf 'schema=%s\n' "$cache_schema"
            printf 'repository_root=%s\n' "$repository_root"
            printf 'checkout_key=%s\n' "$checkout_key"
            printf 'generation_key=%s\n' "$generation_key"
        } >"$generation_marker"
    fi
fi

canonical_artifact_root=$(CDPATH= cd -- "$artifact_root" && pwd -P) \
    || fail_classification sandbox "无法解析 Gate 产物根"
[ "$canonical_artifact_root" = "$artifact_root" ] \
    || fail_classification configuration "Gate 产物根不能通过 symlink 逃逸受控路径"

ensure_artifact_directory() {
    candidate="$1"
    case "$candidate" in
        "$artifact_root"/*) ;;
        *) fail_classification configuration "受控缓存路径必须位于当前 Gate 产物根内" ;;
    esac
    parent=${candidate%/*}
    [ -d "$parent" ] && [ ! -L "$parent" ] \
        || fail_classification configuration "受控缓存父目录缺失或为 symlink"
    canonical_parent=$(CDPATH= cd -- "$parent" && pwd -P) \
        || fail_classification sandbox "无法解析受控缓存父目录"
    case "$canonical_parent" in
        "$artifact_root"|"$artifact_root"/*) ;;
        *) fail_classification configuration "受控缓存父目录通过 symlink 逃逸 Gate 产物根" ;;
    esac
    if [ -e "$candidate" ]; then
        [ -d "$candidate" ] && [ ! -L "$candidate" ] \
            || fail_classification configuration "受控缓存路径不是普通目录"
    else
        mkdir "$candidate" || fail_classification sandbox "无法创建受控缓存路径"
    fi
    canonical_candidate=$(CDPATH= cd -- "$candidate" && pwd -P) \
        || fail_classification sandbox "无法解析受控缓存路径"
    case "$canonical_candidate" in
        "$artifact_root"/*) ;;
        *) fail_classification configuration "受控缓存路径通过 symlink 逃逸 Gate 产物根" ;;
    esac
}

swiftpm_scratch_path="$artifact_root/swiftpm-scratch"
swiftpm_cache_path="$artifact_root/swiftpm-cache"
swiftpm_config_path="$artifact_root/swiftpm-config"
swiftpm_security_path="$artifact_root/swiftpm-security"
swiftpm_home_path="$artifact_root/swiftpm-home"
xcode_package_path="$artifact_root/xcode-packages"
xcode_package_cache_path="$artifact_root/xcode-package-cache"
xcode_user_home_path="$artifact_root/xcode-user-home"
clang_module_cache_path="$artifact_root/module-cache/clang"
swift_module_cache_path="$artifact_root/module-cache/swift"

if [ -n "${BILIKIT_DERIVED_DATA_PATH:-}" ]; then
    [ "$artifact_policy" = "iteration" ] \
        || fail_classification configuration "只有 iteration 可使用受控 DerivedData 覆盖"
    derived_data_path="$BILIKIT_DERIVED_DATA_PATH"
    case "$derived_data_path" in
        "$artifact_root"/*)
            derived_data_leaf=${derived_data_path#"$artifact_root"/}
            case "$derived_data_leaf" in
                ""|.|..|*/*) fail_classification configuration "BILIKIT_DERIVED_DATA_PATH 只能是当前 generation 的直接子目录" ;;
            esac
            ;;
        *) fail_classification configuration "BILIKIT_DERIVED_DATA_PATH 必须位于当前受控 generation 根内" ;;
    esac
else
    derived_data_path="$artifact_root/xcode-derived"
fi

for path in \
    "$swiftpm_scratch_path" \
    "$swiftpm_cache_path" \
    "$swiftpm_config_path" \
    "$swiftpm_security_path" \
    "$swiftpm_home_path" \
    "$xcode_package_path" \
    "$xcode_package_cache_path" \
    "$xcode_user_home_path" \
    "$artifact_root/module-cache" \
    "$derived_data_path"
do
    ensure_artifact_directory "$path"
done
for path in \
    "$swiftpm_home_path/.cache" \
    "$xcode_user_home_path/.cache" \
    "$clang_module_cache_path" \
    "$swift_module_cache_path"
do
    ensure_artifact_directory "$path"
done

export CLANG_MODULE_CACHE_PATH="$clang_module_cache_path"
export SWIFT_MODULE_CACHE_PATH="$swift_module_cache_path"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_module_cache_path"

echo "[Gate] artifact-policy=$artifact_policy mode=$mode"
echo "[Gate] checkout-key=$checkout_key generation=$generation_key"
echo "[Gate] DEVELOPER_DIR=$developer_dir"
echo "[Gate] SwiftPM scratch：$swiftpm_scratch_path"
echo "[Gate] Xcode DerivedData：$derived_data_path"
echo "[Gate] Clang module cache：$clang_module_cache_path"
echo "[Gate] Swift module cache：$swift_module_cache_path"

if [ "$print_paths_only" = "1" ]; then
    echo "[Gate] 仅输出产物路径；未运行检查"
    exit 0
fi

compact_logs="${BILIKIT_COMPACT_LOGS:-1}"
case "$compact_logs" in 0|1) ;; *) fail_classification configuration "BILIKIT_COMPACT_LOGS 必须是 0 或 1" ;; esac

sanitize_gate_log_file() {
    source_log="$1"
    sanitized_log="$source_log.sanitized"
    awk \
        -v repository="$repository_root" \
        -v artifact="$artifact_root" \
        -v user_home="${HOME:-}" '
        function replace_literal(text, old, replacement, position) {
            if (old == "") return text
            while ((position = index(text, old)) > 0) {
                text = substr(text, 1, position - 1) replacement substr(text, position + length(old))
            }
            return text
        }
        function redact_credential_fields(text, lower, rest, consumed, quote_end, key_start, key_length) {
            lower = tolower(text)
            while (match(lower, /"?(token|refresh_token|qrcode_key)"?[[:space:]]*[=:][[:space:]]*/)) {
                key_start = RSTART
                key_length = RLENGTH
                rest = substr(text, key_start + key_length)
                if (substr(rest, 1, 1) == "\"") {
                    quote_end = index(substr(rest, 2), "\"")
                    consumed = quote_end > 0 ? quote_end + 1 : length(rest)
                } else if (match(rest, /[[:space:],}]/)) {
                    consumed = RSTART - 1
                } else {
                    consumed = length(rest)
                }
                text = substr(text, 1, key_start - 1) "credential=<redacted>" substr(rest, consumed + 1)
                lower = tolower(text)
            }
            return text
        }
        {
            line = replace_literal($0, artifact, "<gate-artifact-root>")
            line = replace_literal(line, repository, "<checkout-root>")
            line = replace_literal(line, user_home, "<user-home>")
            gsub(/\/(private\/)?var\/folders\/[^[:space:]]*\/BiliKit-quality-gate\.[^\/[:space:]]+/, "<gate-artifact-root>", line)
            gsub(/on '\''[^'\'']*'\''/, "on '\''<redacted-test-destination>'\''", line)
            gsub(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/, "<redacted-identifier>", line)
            gsub(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}/, "<redacted-identifier>", line)
            gsub(/https?:\/\/[^[:space:]"'\''<>]+/, "<redacted-url>", line)
            lower = tolower(line)
            if (match(lower, /(cookie|authorization)[[:space:]]*[=:]/)) {
                line = substr(line, 1, RSTART - 1) "credential-header=<redacted>"
            }
            line = redact_credential_fields(line)
            print line
        }
    ' "$source_log" >"$sanitized_log" || return 1
    mv "$sanitized_log" "$source_log"
}

gate_log_dir=$(mktemp -d "$artifact_root/logs.XXXXXX") \
    || fail_classification sandbox "无法创建 Gate 日志根"
{
    printf 'schema=%s\n' "$cache_schema"
    printf 'repository_root=%s\n' "$repository_root"
    printf 'checkout_key=%s\n' "$checkout_key"
    printf 'generation_key=%s\n' "$generation_key"
} >"$gate_log_dir/.bilikit-quality-gate-log-root"
echo "[Gate] 日志捕获与脱敏已启用；普通日志在退出时清理"
if [ "$compact_logs" = "1" ]; then
    echo "[Gate] compact 输出已启用；成功阶段不回显完整日志"
fi
if [ "$fresh_artifacts" = "1" ] && [ "$retain_artifacts" = "1" ]; then
    echo "[Gate] fresh retain 已启用；只有脱敏成功的完整日志才会保留"
fi

github_actions="${GITHUB_ACTIONS:-false}"
github_summary="${GITHUB_STEP_SUMMARY:-}"
if [ "$github_actions" = "true" ] && [ -n "$github_summary" ]; then
    {
        echo "### BiliKit quality gate"
        echo
        echo "- Artifact policy: \`$artifact_policy\`"
        echo "- Generation: \`$generation_key\`"
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

classify_stage_failure() {
    stage="$1"
    log_path="${2:-}"
    stage_status="${3:-1}"
    if [ "$stage_status" -eq 143 ] && [ "$term_is_timeout" = "1" ]; then
        echo timeout.inconclusive
        return
    fi
    if [ -n "$log_path" ] && grep -E \
        'Executed [0-9]+ tests?, with [1-9][0-9]* failures?|Test run with [1-9][0-9]* failures?|Failing tests:|Test case .* failed|✘ Test' \
        "$log_path" >/dev/null 2>&1; then
        echo test.assertion
        return
    fi
    if [ -n "$log_path" ] && grep -E -i \
        'sandbox-exec:.*(Operation not permitted|Permission denied)|sandbox_apply:.*Operation not permitted|(<gate-artifact-root>|DerivedData|ModuleCache|SourcePackages|swiftpm|\.build/).*(Operation not permitted|Permission denied|Read-only file system)|(Operation not permitted|Permission denied|Read-only file system).*(<gate-artifact-root>|DerivedData|ModuleCache|SourcePackages|swiftpm|\.build/)' \
        "$log_path" >/dev/null 2>&1; then
        echo sandbox
        return
    fi
    if [ -n "$log_path" ] && grep -E -i \
        "no such module ['\"]Testing|xcrun: error|requires.*Xcode|SDK.*(not found|unavailable)" \
        "$log_path" >/dev/null 2>&1; then
        echo toolchain
        return
    fi
    if [ -n "$log_path" ] && grep -E -i \
        'CodeSign|provisioning profile|signing certificate|Developer Mode' \
        "$log_path" >/dev/null 2>&1; then
        echo signing
        return
    fi
    if [ -n "$log_path" ] && grep -E -i \
        'Failed to launch.*test|test runner.*failed|test session.*failed|lost connection.*test' \
        "$log_path" >/dev/null 2>&1; then
        echo test.infrastructure
        return
    fi
    if [ "$stage" = "app-build-for-testing" ]; then
        echo build
    elif [ "$stage" = "static-contracts" ]; then
        echo configuration
    elif [ -n "$log_path" ] && grep -E -i \
        'emit-module command failed|compile command failed|linker command failed|SwiftCompile.*failed' \
        "$log_path" >/dev/null 2>&1; then
        echo build
    else
        echo unknown
    fi
}

run_with_optional_compact_log() {
    stage="$1"
    shift
    if [ "$github_actions" = "true" ]; then echo "::group::$stage"; fi

    log_path="$gate_log_dir/$stage.log"
    if "$@" >"$log_path" 2>&1; then status=0; else status=$?; fi
    if ! sanitize_gate_log_file "$log_path"; then
        rm -f -- "$log_path" "$log_path.sanitized" 2>/dev/null || true
        force_cleanup_fresh=1
        fail_classification unknown "无法脱敏 Gate 日志；已禁止 retain 并安排精确清理"
    fi
    if [ "$compact_logs" = "0" ]; then
        echo "[Gate] $stage 脱敏完整日志如下"
        LC_ALL=C cut -c 1-360 "$log_path"
    elif [ "$status" -eq 0 ]; then
        echo "[Gate] $stage 通过"
    else
        echo "[Gate] $stage 失败；脱敏日志末尾如下" >&2
        tail -n 40 "$log_path" | LC_ALL=C cut -c 1-360 >&2
    fi
    if [ "$fresh_artifacts" = "1" ] && [ "$retain_artifacts" = "1" ]; then
        echo "[Gate] $stage 脱敏完整日志：$log_path"
    fi

    if [ "$github_actions" = "true" ]; then echo "::endgroup::"; fi
    if [ "$status" -eq 0 ]; then
        record_stage_result "$stage" passed
    else
        classification=$(classify_stage_failure "$stage" "$log_path" "$status")
        echo "[Gate] classification=$classification stage=$stage exit=$status" >&2
        record_stage_result "$stage" "failed ($classification)"
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
    echo "[Gate] static 通过（artifact-policy=${artifact_policy}）"
    exit 0
fi

echo "[Gate] Swift Package"
run_with_optional_compact_log \
    swift-package \
    env \
    HOME="$swiftpm_home_path" \
    CFFIXED_USER_HOME="$swiftpm_home_path" \
    XDG_CACHE_HOME="$swiftpm_home_path/.cache" \
    xcrun swift test \
    --package-path Packages/BiliKitCore \
    --scratch-path "$swiftpm_scratch_path" \
    --cache-path "$swiftpm_cache_path" \
    --config-path "$swiftpm_config_path" \
    --security-path "$swiftpm_security_path" \
    --manifest-cache local

if [ "$mode" = "package" ]; then
    echo "[Gate] package 通过（artifact-policy=${artifact_policy}）"
    exit 0
fi

echo "[Gate] App build-for-testing"
run_with_optional_compact_log \
    app-build-for-testing \
    env \
    HOME="$xcode_user_home_path" \
    CFFIXED_USER_HOME="$xcode_user_home_path" \
    XDG_CACHE_HOME="$xcode_user_home_path/.cache" \
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
    env \
    HOME="$xcode_user_home_path" \
    CFFIXED_USER_HOME="$xcode_user_home_path" \
    XDG_CACHE_HOME="$xcode_user_home_path/.cache" \
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

echo "[Gate] app 通过（artifact-policy=${artifact_policy}）"

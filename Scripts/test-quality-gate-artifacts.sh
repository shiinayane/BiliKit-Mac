#!/bin/sh

set -eu

fail() {
    echo "质量 Gate 产物契约测试失败：$1" >&2
    exit 1
}

assert_contains() {
    haystack="$1"
    needle="$2"
    description="$3"
    printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null \
        || fail "$description"
}

assert_not_contains() {
    haystack="$1"
    needle="$2"
    description="$3"
    if printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null; then
        fail "$description"
    fi
}

expect_failure() {
    description="$1"
    shift
    set +e
    last_output=$(run_gate "$@" 2>&1)
    last_status=$?
    set -e
    [ "$last_status" -ne 0 ] || fail "$description"
}

generation_from_output() {
    printf '%s\n' "$1" |
        sed -n 's/^\[Gate\] checkout-key=[^ ]* generation=\([0-9a-f]*\)$/\1/p' |
        head -n 1
}

artifact_root_from_output() {
    printf '%s\n' "$1" |
        sed -n 's/^\[Gate\] SwiftPM scratch：\(.*\)\/swiftpm-scratch$/\1/p' |
        head -n 1
}

retained_root_from_output() {
    printf '%s\n' "$1" |
        sed -n 's/^\[Gate\] fresh 诊断产物已保留：\(.*\)$/\1/p' |
        head -n 1
}

test_base=$(mktemp -d "${TMPDIR:-/tmp}/BiliKit gate contract.XXXXXX")
trap 'rm -rf -- "$test_base"' EXIT HUP INT TERM
test_base=$(CDPATH= cd -- "$test_base" && pwd -P)

fixture_root="$test_base/repository with spaces"
fixture_home="$test_base/user home"
fixture_tmp="$test_base/private tmp"
fixture_bin="$test_base/fake bin"
fixture_developer="$test_base/Xcode Contract.app/Contents/Developer"
mkdir -p \
    "$fixture_root/Scripts" \
    "$fixture_root/Packages/BiliKitCore/Sources/Contract" \
    "$fixture_root/BiliKitMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" \
    "$fixture_root/BiliKitMac.xcodeproj/xcshareddata/xcschemes" \
    "$fixture_home/.cache/clang" \
    "$fixture_tmp" \
    "$fixture_bin" \
    "$fixture_developer"

cp Scripts/run-quality-gates.sh "$fixture_root/Scripts/run-quality-gates.sh"
cp Packages/BiliKitCore/Package.swift "$fixture_root/Packages/BiliKitCore/Package.swift"
cp Packages/BiliKitCore/Package.resolved "$fixture_root/Packages/BiliKitCore/Package.resolved"
cp BiliKitMac.xcodeproj/project.pbxproj "$fixture_root/BiliKitMac.xcodeproj/project.pbxproj"
cp \
    BiliKitMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    "$fixture_root/BiliKitMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cp \
    BiliKitMac.xcodeproj/xcshareddata/xcschemes/BiliKitMac.xcscheme \
    "$fixture_root/BiliKitMac.xcodeproj/xcshareddata/xcschemes/BiliKitMac.xcscheme"

printf 'user-cache-sentinel\n' >"$fixture_home/.cache/clang/sentinel"

for contract_script in check-secrets.sh check-project-contract.sh check-swift-format.sh; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture_root/Scripts/$contract_script"
done

cat >"$fixture_root/Scripts/check-architecture.sh" <<'EOF'
#!/bin/sh
if [ "${FAKE_BLOCK_STAGE:-0}" = "1" ]; then
    printf '%s\n' "$$" >"$FAKE_READY_FILE"
    while kill -0 "$PPID" 2>/dev/null; do
        sleep 0.01
    done
    exit 0
fi
if [ -n "${FAKE_SIGNAL:-}" ]; then
    kill -s "$FAKE_SIGNAL" "$PPID"
    exit 0
fi
if [ "${FAKE_STATIC_FAILURE:-0}" = "1" ]; then
    printf '%s\n' "${FAKE_STATIC_TEXT:-static contract failed}" >&2
    exit "${FAKE_STATIC_STATUS:-1}"
fi
exit 0
EOF

cat >"$fixture_bin/git" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$fixture_bin/xcodebuild" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-version" ]; then
    printf '%s\n' "${FAKE_XCODE_VERSION:-Xcode Contract 1.0}" 'Build version CONTRACT1'
    exit 0
fi
case "${DEVELOPER_DIR:-}" in */Xcode\ Contract.app/Contents/Developer) ;; *) exit 91 ;; esac
case "${HOME:-}" in */xcode-user-home) artifact_root=${HOME%/xcode-user-home} ;; *) exit 92 ;; esac
[ "${CFFIXED_USER_HOME:-}" = "$HOME" ] || exit 93
[ "${XDG_CACHE_HOME:-}" = "$HOME/.cache" ] || exit 94
[ "${CLANG_MODULE_CACHE_PATH:-}" = "$artifact_root/module-cache/clang" ] || exit 95
[ "${SWIFT_MODULE_CACHE_PATH:-}" = "$artifact_root/module-cache/swift" ] || exit 96
argument_value() {
    expected_name="$1"
    shift
    while [ "$#" -gt 1 ]; do
        if [ "$1" = "$expected_name" ]; then
            printf '%s\n' "$2"
            return 0
        fi
        shift
    done
    return 1
}
derived_data=$(argument_value -derivedDataPath "$@") || exit 97
package_path=$(argument_value -clonedSourcePackagesDirPath "$@") || exit 98
package_cache=$(argument_value -packageCachePath "$@") || exit 99
[ "$derived_data" = "$artifact_root/xcode-derived" ] || exit 100
[ "$package_path" = "$artifact_root/xcode-packages" ] || exit 101
[ "$package_cache" = "$artifact_root/xcode-package-cache" ] || exit 102
case " $* " in
    *' build-for-testing '*)
        [ "${FAKE_APP_BUILD_STATUS:-0}" -eq 0 ] || {
            printf '%s\n' "${FAKE_APP_BUILD_TEXT:-compile command failed}" >&2
            exit "$FAKE_APP_BUILD_STATUS"
        }
        ;;
    *' test-without-building '*)
        [ "${FAKE_APP_TEST_STATUS:-0}" -eq 0 ] || {
            printf '%s\n' "${FAKE_APP_TEST_TEXT:-test runner failed}" >&2
            exit "$FAKE_APP_TEST_STATUS"
        }
        ;;
esac
exit 0
EOF

cat >"$fixture_bin/xcrun" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "swift" ] && [ "${2:-}" = "--version" ]; then
    printf '%s\n' "${FAKE_SWIFT_VERSION:-Apple Swift Contract 1.0}"
    exit 0
fi
if [ "${1:-}" = "swift" ] && [ "${2:-}" = "test" ]; then
    case "${DEVELOPER_DIR:-}" in */Xcode\ Contract.app/Contents/Developer) ;; *) exit 91 ;; esac
    case "${HOME:-}" in */swiftpm-home) artifact_root=${HOME%/swiftpm-home} ;; *) exit 92 ;; esac
    [ "${CFFIXED_USER_HOME:-}" = "$HOME" ] || exit 93
    [ "${XDG_CACHE_HOME:-}" = "$HOME/.cache" ] || exit 94
    [ "${CLANG_MODULE_CACHE_PATH:-}" = "$artifact_root/module-cache/clang" ] || exit 95
    [ "${SWIFT_MODULE_CACHE_PATH:-}" = "$artifact_root/module-cache/swift" ] || exit 96
    [ "${SWIFTPM_MODULECACHE_OVERRIDE:-}" = "$artifact_root/module-cache/swift" ] || exit 97
    argument_value() {
        expected_name="$1"
        shift
        while [ "$#" -gt 1 ]; do
            if [ "$1" = "$expected_name" ]; then
                printf '%s\n' "$2"
                return 0
            fi
            shift
        done
        return 1
    }
    scratch_path=$(argument_value --scratch-path "$@") || exit 98
    cache_path=$(argument_value --cache-path "$@") || exit 99
    config_path=$(argument_value --config-path "$@") || exit 100
    security_path=$(argument_value --security-path "$@") || exit 101
    [ "$scratch_path" = "$artifact_root/swiftpm-scratch" ] || exit 102
    [ "$cache_path" = "$artifact_root/swiftpm-cache" ] || exit 103
    [ "$config_path" = "$artifact_root/swiftpm-config" ] || exit 104
    [ "$security_path" = "$artifact_root/swiftpm-security" ] || exit 105
    if [ "${FAKE_SANITIZER_FAILURE:-0}" = "1" ]; then
        for log_dir in "$artifact_root"/logs.*; do
            [ -d "$log_dir" ] || continue
            mkdir "$log_dir/swift-package.log.sanitized"
        done
    fi
    [ "${FAKE_PACKAGE_STATUS:-0}" -eq 0 ] || {
        printf '%s\n' "${FAKE_PACKAGE_TEXT:-package command failed}" >&2
        exit "$FAKE_PACKAGE_STATUS"
    }
    exit 0
fi
exit 0
EOF

cat >"$fixture_bin/xcode-select" <<'EOF'
#!/bin/sh
printf 'called\n' >"$FAKE_XCODE_SELECT_SENTINEL"
exit 99
EOF

chmod +x \
    "$fixture_root"/Scripts/*.sh \
    "$fixture_bin/xcodebuild" \
    "$fixture_bin/xcrun" \
    "$fixture_bin/git" \
    "$fixture_bin/xcode-select"

run_gate() {
    (
        cd "$fixture_root"
        env \
            PATH="$fixture_bin:$PATH" \
            HOME="$fixture_home" \
            TMPDIR="$fixture_tmp" \
            DEVELOPER_DIR="$fixture_developer" \
            FAKE_XCODE_SELECT_SENTINEL="$test_base/xcode-select-called" \
            FAKE_XCODE_VERSION="${FAKE_XCODE_VERSION:-Xcode Contract 1.0}" \
            FAKE_SWIFT_VERSION="${FAKE_SWIFT_VERSION:-Apple Swift Contract 1.0}" \
            FAKE_STATIC_FAILURE="${FAKE_STATIC_FAILURE:-0}" \
            FAKE_STATIC_TEXT="${FAKE_STATIC_TEXT:-}" \
            FAKE_STATIC_STATUS="${FAKE_STATIC_STATUS:-1}" \
            FAKE_SIGNAL="${FAKE_SIGNAL:-}" \
            FAKE_BLOCK_STAGE=0 \
            FAKE_READY_FILE="$test_base/unused-ready" \
            FAKE_PACKAGE_STATUS="${FAKE_PACKAGE_STATUS:-0}" \
            FAKE_PACKAGE_TEXT="${FAKE_PACKAGE_TEXT:-}" \
            FAKE_SANITIZER_FAILURE="${FAKE_SANITIZER_FAILURE:-0}" \
            FAKE_APP_BUILD_STATUS="${FAKE_APP_BUILD_STATUS:-0}" \
            FAKE_APP_BUILD_TEXT="${FAKE_APP_BUILD_TEXT:-}" \
            FAKE_APP_TEST_STATUS="${FAKE_APP_TEST_STATUS:-0}" \
            FAKE_APP_TEST_TEXT="${FAKE_APP_TEST_TEXT:-}" \
            BILIKIT_GATE_PRINT_PATHS_ONLY="${BILIKIT_GATE_PRINT_PATHS_ONLY:-0}" \
            BILIKIT_GATE_RETAIN_ARTIFACTS="${BILIKIT_GATE_RETAIN_ARTIFACTS:-0}" \
            BILIKIT_GATE_TERM_IS_TIMEOUT="${BILIKIT_GATE_TERM_IS_TIMEOUT:-0}" \
            BILIKIT_COMPACT_LOGS="${BILIKIT_COMPACT_LOGS:-1}" \
            BILIKIT_DERIVED_DATA_PATH="${BILIKIT_DERIVED_DATA_PATH:-}" \
            sh Scripts/run-quality-gates.sh "$@"
    )
}

run_gate_process() {
    cd "$fixture_root"
    exec env \
        PATH="$fixture_bin:$PATH" \
        HOME="$fixture_home" \
        TMPDIR="$fixture_tmp" \
        DEVELOPER_DIR="$fixture_developer" \
        FAKE_XCODE_SELECT_SENTINEL="$test_base/xcode-select-called" \
        FAKE_XCODE_VERSION='Xcode Contract 1.0' \
        FAKE_SWIFT_VERSION='Apple Swift Contract 1.0' \
        FAKE_STATIC_FAILURE=0 \
        FAKE_STATIC_TEXT= \
        FAKE_STATIC_STATUS=1 \
        FAKE_SIGNAL= \
        FAKE_BLOCK_STAGE=1 \
        FAKE_READY_FILE="$test_base/signal-ready" \
        FAKE_PACKAGE_STATUS=0 \
        FAKE_PACKAGE_TEXT= \
        FAKE_SANITIZER_FAILURE=0 \
        FAKE_APP_BUILD_STATUS=0 \
        FAKE_APP_BUILD_TEXT= \
        FAKE_APP_TEST_STATUS=0 \
        FAKE_APP_TEST_TEXT= \
        BILIKIT_GATE_PRINT_PATHS_ONLY=0 \
        BILIKIT_GATE_RETAIN_ARTIFACTS=0 \
        BILIKIT_GATE_TERM_IS_TIMEOUT="${BILIKIT_GATE_TERM_IS_TIMEOUT:-0}" \
        BILIKIT_COMPACT_LOGS=1 \
        BILIKIT_DERIVED_DATA_PATH= \
        sh Scripts/run-quality-gates.sh "$@"
}

run_signal_case() {
    signal_name="$1"
    timeout_flag="$2"
    signal_output_file="$test_base/signal-$signal_name-$timeout_flag.log"
    rm -f "$test_base/signal-ready"
    BILIKIT_GATE_TERM_IS_TIMEOUT="$timeout_flag" \
        run_gate_process static closure >"$signal_output_file" 2>&1 &
    gate_pid=$!
    observed_setup=0
    poll_count=0
    while [ "$poll_count" -lt 500 ]; do
        if [ -f "$test_base/signal-ready" ]; then
            observed_setup=1
            break
        fi
        kill -0 "$gate_pid" 2>/dev/null || break
        poll_count=$((poll_count + 1))
        sleep 0.01
    done
    [ "$observed_setup" -eq 1 ] || fail "$signal_name 测试没有观察到 Gate setup 事件"
    stage_pid=$(cat "$test_base/signal-ready")
    kill -s "$signal_name" "$gate_pid"
    kill -s "$signal_name" "$stage_pid" 2>/dev/null || true
    set +e
    wait "$gate_pid"
    signal_status=$?
    set -e
    signal_output=$(cat "$signal_output_file")
    [ "$signal_status" -ne 0 ] || fail "$signal_name 没有中断 Gate"
}

# Stable generation identity and paths containing spaces.
baseline_output=$(BILIKIT_GATE_PRINT_PATHS_ONLY=1 run_gate static iteration)
baseline_generation=$(generation_from_output "$baseline_output")
[ -n "$baseline_generation" ] || fail "没有输出 baseline generation"
assert_contains "$baseline_output" "$fixture_root/.build/" "路径含空格时没有使用 checkout-local 根"

reuse_output=$(BILIKIT_GATE_PRINT_PATHS_ONLY=1 run_gate static iteration)
[ "$(generation_from_output "$reuse_output")" = "$baseline_generation" ] \
    || fail "相同输入没有复用 iteration generation"

static_success_output=$(run_gate static iteration)
assert_contains "$static_success_output" 'static 通过（artifact-policy=iteration）' "完整 static 成功路径没有正确结束"

printf 'let sourceOnlyChange = true\n' >"$fixture_root/Packages/BiliKitCore/Sources/Contract/Source.swift"
source_output=$(BILIKIT_GATE_PRINT_PATHS_ONLY=1 run_gate static iteration)
[ "$(generation_from_output "$source_output")" = "$baseline_generation" ] \
    || fail "普通源码变化不应切换 generation"

printf '\n// package identity change\n' >>"$fixture_root/Packages/BiliKitCore/Package.swift"
package_output=$(BILIKIT_GATE_PRINT_PATHS_ONLY=1 run_gate static iteration)
package_generation=$(generation_from_output "$package_output")
[ "$package_generation" != "$baseline_generation" ] || fail "Package.swift 变化没有切换 generation"

toolchain_output=$(
    FAKE_XCODE_VERSION='Xcode Contract 2.0' \
    BILIKIT_GATE_PRINT_PATHS_ONLY=1 \
    run_gate static iteration
)
toolchain_generation=$(generation_from_output "$toolchain_output")
[ "$toolchain_generation" != "$package_generation" ] || fail "Xcode 变化没有切换 generation"

printf '\n// project identity change\n' >>"$fixture_root/BiliKitMac.xcodeproj/project.pbxproj"
project_output=$(
    FAKE_XCODE_VERSION='Xcode Contract 2.0' \
    BILIKIT_GATE_PRINT_PATHS_ONLY=1 \
    run_gate static iteration
)
[ "$(generation_from_output "$project_output")" != "$toolchain_generation" ] \
    || fail "Xcode 工程变化没有切换 generation"

# Arbitrary DerivedData and global toolchain changes are rejected or untouched.
external_derived="$test_base/external-derived"
set +e
last_output=$(
    BILIKIT_DERIVED_DATA_PATH="$external_derived" \
    BILIKIT_GATE_PRINT_PATHS_ONLY=1 \
    run_gate static iteration 2>&1
)
last_status=$?
set -e
[ "$last_status" -ne 0 ] || fail "外部 DerivedData 被接受"
assert_contains "$last_output" 'classification=configuration' "外部 DerivedData 没有归类 configuration"
[ ! -e "$external_derived" ] || fail "拒绝外部 DerivedData 前已经创建了该路径"
[ ! -e "$test_base/xcode-select-called" ] || fail "Gate 调用了全局 xcode-select"

# Fresh uniqueness, mode, retain, success cleanup and exact retained cleanup.
fresh_one_output=$(
    BILIKIT_GATE_PRINT_PATHS_ONLY=1 \
    BILIKIT_GATE_RETAIN_ARTIFACTS=1 \
    run_gate static closure
)
fresh_one=$(retained_root_from_output "$fresh_one_output")
[ -d "$fresh_one" ] || fail "closure retain 没有保留 fresh root"
[ "$(/usr/bin/stat -f '%Lp' "$fresh_one")" = "700" ] || fail "fresh root 不是 mode 0700"
assert_contains "$fresh_one_output" 'artifact-policy=closure' "closure 输出没有独立 policy"

fresh_two_output=$(
    BILIKIT_GATE_PRINT_PATHS_ONLY=1 \
    BILIKIT_GATE_RETAIN_ARTIFACTS=1 \
    run_gate static closure
)
fresh_two=$(retained_root_from_output "$fresh_two_output")
[ "$fresh_one" != "$fresh_two" ] || fail "两次 fresh root 不唯一"

run_gate cleanup-retained "$fresh_one" >/dev/null
[ ! -e "$fresh_one" ] || fail "cleanup-retained 没有删除精确 fresh root"
run_gate cleanup-retained "$fresh_two" >/dev/null
[ ! -e "$fresh_two" ] || fail "cleanup-retained 没有删除第二个 fresh root"

fresh_success_output=$(BILIKIT_GATE_PRINT_PATHS_ONLY=1 run_gate static closure)
fresh_success_root=$(artifact_root_from_output "$fresh_success_output")
[ -n "$fresh_success_root" ] || fail "无法取得成功 closure root"
[ ! -e "$fresh_success_root" ] || fail "成功 closure 后没有清理 fresh root"

# Failure, INT, TERM and timeout-attributed TERM all clean their exact fresh root.
set +e
fresh_failure_output=$(FAKE_STATIC_FAILURE=1 run_gate static fresh 2>&1)
fresh_failure_status=$?
set -e
[ "$fresh_failure_status" -ne 0 ] || fail "注入的 fresh failure 没有失败"
fresh_failure_root=$(artifact_root_from_output "$fresh_failure_output")
[ ! -e "$fresh_failure_root" ] || fail "失败后没有清理 fresh root"
assert_contains "$fresh_failure_output" 'classification=configuration' "静态失败没有归类 configuration"

set +e
int_output=$(FAKE_SIGNAL=INT run_gate static closure 2>&1)
int_status=$?
set -e
[ "$int_status" -ne 0 ] || fail "INT 没有中断 Gate"
int_root=$(artifact_root_from_output "$int_output")
[ ! -e "$int_root" ] || fail "INT 后没有清理 fresh root"

run_signal_case TERM 0
term_output="$signal_output"
term_root=$(artifact_root_from_output "$term_output")
[ ! -e "$term_root" ] || fail "TERM 后没有清理 fresh root"

set +e
timeout_output=$(
    FAKE_STATIC_FAILURE=1 \
    FAKE_STATIC_STATUS=143 \
    BILIKIT_GATE_TERM_IS_TIMEOUT=1 \
    run_gate static closure 2>&1
)
timeout_status=$?
set -e
[ "$timeout_status" -ne 0 ] || fail "timeout fixture 没有失败"
timeout_root=$(artifact_root_from_output "$timeout_output")
[ ! -e "$timeout_root" ] || fail "timeout TERM 后没有清理 fresh root"
assert_contains "$timeout_output" 'classification=timeout.inconclusive' "timeout 分类不透明"

# Evidence-based stage classification.
set +e
sandbox_output=$(
    FAKE_STATIC_FAILURE=1 \
    FAKE_STATIC_TEXT='sandbox-exec: Operation not permitted' \
    run_gate static fresh 2>&1
)
sandbox_status=$?
set -e
[ "$sandbox_status" -ne 0 ] || fail "sandbox fixture 没有失败"
assert_contains "$sandbox_output" 'classification=sandbox' "sandbox 证据没有正确分类"

set +e
toolchain_failure_output=$(
    FAKE_STATIC_FAILURE=1 \
    FAKE_STATIC_TEXT="no such module 'Testing'" \
    run_gate static fresh 2>&1
)
toolchain_failure_status=$?
set -e
[ "$toolchain_failure_status" -ne 0 ] || fail "toolchain fixture 没有失败"
assert_contains "$toolchain_failure_output" 'classification=toolchain' "Testing 缺失没有正确分类"

set +e
assertion_output=$(
    FAKE_PACKAGE_STATUS=1 \
    FAKE_PACKAGE_TEXT="Failing tests: Test case 'ContractTests/example()' failed" \
    run_gate package fresh 2>&1
)
assertion_status=$?
set -e
[ "$assertion_status" -ne 0 ] || fail "assertion fixture 没有失败"
assert_contains "$assertion_output" 'classification=test.assertion' "实际 assertion 没有正确分类"

set +e
assertion_permission_output=$(
    FAKE_PACKAGE_STATUS=1 \
    FAKE_PACKAGE_TEXT="Failing tests: Test case 'ContractTests/permissionText()' failed: Operation not permitted" \
    run_gate package fresh 2>&1
)
assertion_permission_status=$?
set -e
[ "$assertion_permission_status" -ne 0 ] || fail "含权限文本的 assertion fixture 没有失败"
assert_contains "$assertion_permission_output" 'classification=test.assertion' "断言被宽泛权限文本误归类为 sandbox"

set +e
build_output=$(
    FAKE_APP_BUILD_STATUS=1 \
    FAKE_APP_BUILD_TEXT='compile command failed' \
    run_gate app fresh 2>&1
)
build_status=$?
set -e
[ "$build_status" -ne 0 ] || fail "build fixture 没有失败"
assert_contains "$build_output" 'classification=build' "build failure 没有正确分类"

set +e
infrastructure_output=$(
    FAKE_APP_TEST_STATUS=1 \
    FAKE_APP_TEST_TEXT='Failed to launch test runner' \
    run_gate app fresh 2>&1
)
infrastructure_status=$?
set -e
[ "$infrastructure_status" -ne 0 ] || fail "test infrastructure fixture 没有失败"
assert_contains "$infrastructure_output" 'classification=test.infrastructure' "测试基础设施没有正确分类"

set +e
signing_output=$(
    FAKE_APP_BUILD_STATUS=1 \
    FAKE_APP_BUILD_TEXT='CodeSign failed: signing certificate unavailable' \
    run_gate app fresh 2>&1
)
signing_status=$?
set -e
[ "$signing_status" -ne 0 ] || fail "signing fixture 没有失败"
assert_contains "$signing_output" 'classification=signing' "签名证据没有正确分类"

set +e
unknown_output=$(
    FAKE_PACKAGE_STATUS=1 \
    FAKE_PACKAGE_TEXT='unclassified package failure' \
    run_gate package fresh 2>&1
)
unknown_status=$?
set -e
[ "$unknown_status" -ne 0 ] || fail "unknown fixture 没有失败"
assert_contains "$unknown_output" 'classification=unknown' "证据不足时没有保持 unknown"

# Retained compact logs are sanitized before they are exposed.
secret_text="$fixture_root $fixture_home https://example.invalid/private?token=abc token=secret-value
Authorization: Bearer header-secret
Cookie: session=cookie-secret; token=cookie-token
AUTHORIZATION: Bearer uppercase-auth-secret
COOKIE: session=uppercase-cookie-secret
{"token":"json-token-secret","refresh_token":"json-refresh-secret","qrcode_key":"json-qr-secret"}
Test case 'ContractTests/example()' passed on 'My Mac - BiliKit (123)'
/var/folders/example/T/BiliKit-quality-gate.ABC123/xcode-derived"
set +e
redacted_output=$(
    FAKE_STATIC_FAILURE=1 \
    FAKE_STATIC_TEXT="$secret_text" \
    BILIKIT_GATE_RETAIN_ARTIFACTS=1 \
    run_gate static fresh 2>&1
)
redacted_status=$?
set -e
[ "$redacted_status" -ne 0 ] || fail "脱敏 fixture 没有失败"
redacted_root=$(retained_root_from_output "$redacted_output")
[ -d "$redacted_root" ] || fail "失败 retain 没有保留诊断根"
redacted_log=$(find "$redacted_root" -path '*/logs.*/static-contracts.log' -type f -print | head -n 1)
[ -f "$redacted_log" ] || fail "没有找到 retained 脱敏日志"
redacted_contents=$(cat "$redacted_log")
assert_not_contains "$redacted_contents" "$fixture_root" "日志泄露 checkout 路径"
assert_not_contains "$redacted_contents" "$fixture_home" "日志泄露 HOME 路径"
assert_not_contains "$redacted_contents" 'https://example.invalid' "日志泄露完整 URL"
assert_not_contains "$redacted_contents" 'secret-value' "日志泄露 token"
assert_not_contains "$redacted_contents" 'header-secret' "日志泄露 Authorization header"
assert_not_contains "$redacted_contents" 'cookie-secret' "日志泄露 Cookie header"
assert_not_contains "$redacted_contents" 'uppercase-auth-secret' "日志泄露全大写 Authorization header"
assert_not_contains "$redacted_contents" 'uppercase-cookie-secret' "日志泄露全大写 Cookie header"
assert_not_contains "$redacted_contents" 'json-token-secret' "日志泄露 JSON token"
assert_not_contains "$redacted_contents" 'json-refresh-secret' "日志泄露 JSON refresh_token"
assert_not_contains "$redacted_contents" 'json-qr-secret' "日志泄露 JSON qrcode_key"
assert_not_contains "$redacted_contents" 'My Mac' "日志泄露测试 destination"
assert_not_contains "$redacted_contents" '/var/folders/example' "日志泄露 fresh root 路径别名"
assert_contains "$redacted_contents" '<redacted-url>' "日志没有留下可解释的 URL 脱敏标记"
run_gate cleanup-retained "$redacted_root" >/dev/null

# Disabling compact output still captures, sanitizes and classifies from the log.
set +e
noncompact_output=$(
    FAKE_PACKAGE_STATUS=1 \
    FAKE_PACKAGE_TEXT="$secret_text
Failing tests: Test case 'ContractTests/noncompact()' failed" \
    BILIKIT_COMPACT_LOGS=0 \
    run_gate package fresh 2>&1
)
noncompact_status=$?
set -e
[ "$noncompact_status" -ne 0 ] || fail "noncompact 脱敏 fixture 没有失败"
assert_contains "$noncompact_output" 'classification=test.assertion' "noncompact 输出没有保留日志分类"
assert_not_contains "$noncompact_output" "$fixture_root" "noncompact 输出泄露 checkout 路径"
assert_not_contains "$noncompact_output" "$fixture_home" "noncompact 输出泄露 HOME 路径"
assert_not_contains "$noncompact_output" 'secret-value' "noncompact 输出泄露 token"
assert_not_contains "$noncompact_output" 'header-secret' "noncompact 输出泄露 Authorization header"
assert_not_contains "$noncompact_output" 'cookie-secret' "noncompact 输出泄露 Cookie header"
assert_not_contains "$noncompact_output" 'uppercase-auth-secret' "noncompact 输出泄露全大写 Authorization header"
assert_not_contains "$noncompact_output" 'uppercase-cookie-secret' "noncompact 输出泄露全大写 Cookie header"
assert_not_contains "$noncompact_output" 'json-token-secret' "noncompact 输出泄露 JSON token"

# Sanitizer failure overrides retain and removes the exact fresh root.
set +e
sanitizer_failure_output=$(
    FAKE_SANITIZER_FAILURE=1 \
    BILIKIT_GATE_RETAIN_ARTIFACTS=1 \
    run_gate package fresh 2>&1
)
sanitizer_failure_status=$?
set -e
[ "$sanitizer_failure_status" -ne 0 ] || fail "注入的 sanitizer failure 没有失败"
sanitizer_failure_root=$(artifact_root_from_output "$sanitizer_failure_output")
[ -n "$sanitizer_failure_root" ] || fail "无法取得 sanitizer failure 的 fresh root"
[ ! -e "$sanitizer_failure_root" ] || fail "sanitizer failure 后仍保留 fresh root"
assert_not_contains "$sanitizer_failure_output" 'fresh 诊断产物已保留' "sanitizer failure 没有覆盖 retain"

# Cleanup never accepts broad paths and never touches the user cache sentinel.
expect_failure "cleanup-retained 接受了 HOME" cleanup-retained "$fixture_home"
assert_contains "$last_output" 'classification=configuration' "拒绝 HOME cleanup 没有归类 configuration"
[ "$(cat "$fixture_home/.cache/clang/sentinel")" = 'user-cache-sentinel' ] \
    || fail "Gate 触碰了用户级 module cache"

# Existing marker tampering and component symlink escape are rejected before writes.
tamper_baseline_output=$(BILIKIT_GATE_PRINT_PATHS_ONLY=1 run_gate static iteration)
current_artifact_root=$(artifact_root_from_output "$tamper_baseline_output")
generation_marker="$current_artifact_root/.bilikit-quality-gate-generation-root"
cp "$generation_marker" "$generation_marker.backup"
printf 'schema=tampered\n' >"$generation_marker"
expect_failure "generation marker 篡改被接受" static iteration
assert_contains "$last_output" 'classification=configuration' "generation marker 篡改没有归类 configuration"
mv "$generation_marker.backup" "$generation_marker"

external_cache="$test_base/external-component-cache"
mkdir "$external_cache"
rm -rf "$current_artifact_root/swiftpm-cache"
ln -s "$external_cache" "$current_artifact_root/swiftpm-cache"
expect_failure "组件 symlink 逃逸被接受" static iteration
assert_contains "$last_output" 'classification=configuration' "组件 symlink 逃逸没有归类 configuration"
[ -z "$(find "$external_cache" -mindepth 1 -print -quit)" ] || fail "Gate 通过 symlink 写入外部目录"

iteration_root=$(artifact_root_from_output "$baseline_output" | sed 's:/generations/[^/]*$::')
[ -d "$iteration_root" ] || fail "iteration root 不存在"
run_gate cleanup-iteration >/dev/null
[ ! -e "$iteration_root" ] || fail "cleanup-iteration 没有删除当前 checkout 精确根"

external_build_root="$test_base/external-build-root"
mkdir "$external_build_root"
rmdir "$fixture_root/.build/bilikit-quality-gates" "$fixture_root/.build"
ln -s "$external_build_root" "$fixture_root/.build"
expect_failure "checkout-local .build symlink 被接受" static iteration
assert_contains "$last_output" 'classification=configuration' ".build symlink 没有归类 configuration"
[ -z "$(find "$external_build_root" -mindepth 1 -print -quit)" ] || fail "拒绝 .build symlink 前已写入外部目录"

echo "质量 Gate 产物契约测试通过"

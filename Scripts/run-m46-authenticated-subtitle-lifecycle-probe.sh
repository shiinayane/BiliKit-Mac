#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
probe_directory=""
input_file=""
derived_data=""
test_log=""
result_bundle=""
xctestrun_file=""
environment_path=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"
maximum_build_seconds=180
maximum_test_seconds=180

read_bvid() {
    local prompt=$1
    local value
    printf '%s' "$prompt" >&2
    IFS= read -rs value
    printf '\n' >&2
    if [[ ${#value} -ne 12 || ! "$value" =~ ^BV[A-Za-z0-9]{10}$ ]]; then
        print -u2 'BVID 格式无效。'
        exit 2
    fi
    print -r -- "$value"
}

print_subtitle_failure() {
    local label=$1
    local session=$2
    local category
    category=$(rg -m 1 -o \
        "m46-subtitle-lifecycle failure=subtitle-[a-z-]+-session-${session}" \
        "$test_log")
    category=${category#*=}
    case "$category" in
        subtitle-loading-catalog-session-*)
            print -u2 "探针失败：${label}停留在字幕目录 loading。"
            ;;
        subtitle-loading-track-session-*)
            print -u2 "探针失败：${label}停留在字幕正文 loading。"
            ;;
        subtitle-unavailable-session-*)
            print -u2 "探针失败：${label}生产字幕目录为空。"
            ;;
        subtitle-authentication-required-session-*)
            print -u2 "探针失败：${label}字幕需要重新认证。"
            ;;
        subtitle-request-restricted-session-*)
            print -u2 "探针失败：${label}字幕请求被服务端限制。"
            ;;
        subtitle-invalid-response-session-*)
            print -u2 "探针失败：${label}字幕响应结构无效。"
            ;;
        subtitle-failed-unavailable-session-*)
            print -u2 "探针失败：${label}字幕链路暂时不可用。"
            ;;
        *)
            print -u2 "探针失败：${label}没有完成生产字幕准备。"
            ;;
    esac
}

probe_bvid_a=$(read_bvid '请输入第一条确定带字幕的视频 BVID：')
probe_bvid_b=$(read_bvid '请输入另一条确定带字幕的视频 BVID：')
if [[ "$probe_bvid_a" == "$probe_bvid_b" ]]; then
    print -u2 'A/B 必须是两条不同视频。'
    exit 2
fi

cleanup() {
    if [[ -n "$xctestrun_file" && -f "$xctestrun_file" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_LOCAL_PROBE_INPUT_FILE" \
            "$xctestrun_file" >/dev/null 2>&1 || true
    fi
    if [[ -n "$probe_directory"
        && "$probe_directory" == /tmp/BiliKitMac-m46-subtitle-probe.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

probe_directory=$(mktemp -d /tmp/BiliKitMac-m46-subtitle-probe.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
derived_data="$probe_directory/DerivedData"
test_log="$probe_directory/raw-test.log"
result_bundle="$probe_directory/M46SubtitleLifecycle.xcresult"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvidA -string "$probe_bvid_a" "$input_file"
/usr/bin/plutil -insert bvidB -string "$probe_bvid_b" "$input_file"
chmod 600 "$input_file"
unset probe_bvid_a probe_bvid_b

cd "$repository_root"
print '正在构建签名测试宿主……'
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl \
    -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
    "$maximum_build_seconds" \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build-for-testing > "$test_log" 2>&1; then
    print -u2 '签名测试宿主构建失败或超时；原始输出已清理。'
    exit 1
fi

xctestrun_files=("$derived_data"/Build/Products/*.xctestrun(N))
if [[ ${#xctestrun_files} -ne 1 ]]; then
    print -u2 '没有找到唯一的 xctestrun 文件，无法安全注入临时探针参数。'
    exit 1
fi
xctestrun_file=${xctestrun_files[1]}

/usr/libexec/PlistBuddy \
    -c "Add ${environment_path}:BILIKIT_LOCAL_PROBE_INPUT_FILE string $input_file" \
    "$xctestrun_file"

print '正在运行已登录 A/B 字幕生命周期探针……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl \
    -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
    "$maximum_test_seconds" \
    xcodebuild \
    -xctestrun "$xctestrun_file" \
    -destination 'platform=macOS' \
    -resultBundlePath "$result_bundle" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 150 \
    test-without-building \
    -only-testing:BiliKitMacTests/M46AuthenticatedSubtitleLifecycleProbeTests/testAuthenticatedABASubtitleLifecycleWhenExplicitlyConfigured \
    >> "$test_log" 2>&1
probe_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        /usr/bin/perl \
        -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
        20 \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'M46AuthenticatedSubtitleLifecycleProbeTests/testAuthenticatedABASubtitleLifecycleWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

if [[ $probe_status -ne 0 ]]; then
    if [[ $probe_status -eq 142 ]] \
        || rg -q 'exceeded.*time allowance|timed out' "$test_log"; then
        print -u2 '探针失败：测试宿主或外层执行达到时限。'
    elif rg -q 'm46-subtitle-lifecycle failure=video-session-1' \
        "$test_log"; then
        print -u2 '探针失败：A 的生产媒体准备未完成。'
    elif rg -q 'm46-subtitle-lifecycle failure=video-session-2' \
        "$test_log"; then
        print -u2 '探针失败：B 的生产媒体准备未完成。'
    elif rg -q 'm46-subtitle-lifecycle failure=video-session-3' \
        "$test_log"; then
        print -u2 '探针失败：返回 A 时生产媒体准备未完成。'
    elif rg -q 'm46-subtitle-lifecycle failure=subtitle-[a-z-]+-session-1' \
        "$test_log"; then
        print_subtitle_failure 'A ' 1
    elif rg -q 'm46-subtitle-lifecycle failure=subtitle-[a-z-]+-session-2' \
        "$test_log"; then
        print_subtitle_failure 'B ' 2
    elif rg -q 'm46-subtitle-lifecycle failure=subtitle-[a-z-]+-session-3' \
        "$test_log"; then
        print_subtitle_failure '返回 A 时' 3
    elif rg -q 'm46-subtitle-lifecycle failure=identity-or-generation' \
        "$test_log"; then
        print -u2 '探针失败：脱敏 identity／generation 契约不一致。'
    elif rg -q 'm46-subtitle-lifecycle failure=cleanup' "$test_log"; then
        print -u2 '探针失败：最终生产资源清理未完成。'
    else
        print -u2 '探针失败或超时，未命中允许公开的失败分类。'
    fi
    print -u2 '原始日志与测试产物已清理。'
    exit $probe_status
fi
if ! rg -q \
    'm46-subtitle-lifecycle sessions=3 context-player-timeline-subtitle=equal player-timeline-generation=advanced cleanup=complete' \
    "$test_log"; then
    print -u2 '探针未完成三次生产 identity 验证。'
    exit 1
fi

print 'm46-subtitle-lifecycle sessions=3 identity=equal player-timeline-generation=advanced cleanup=complete'
print '探针完成；原始日志与测试产物已清理。'

#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
probe_directory=""
input_file=""
xctestrun_file=""
environment_path=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"

cleanup() {
    if [[ -n "$xctestrun_file" && -f "$xctestrun_file" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_LOCAL_PROBE_INPUT_FILE" \
            "$xctestrun_file" >/dev/null 2>&1 || true
    fi
    if [[ -n "$probe_directory"
        && "$probe_directory" == /tmp/BiliKitMac-m501-danmaku-probe.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

printf '%s' '请输入一条足够长且弹幕密集的公开视频 BVID：' >&2
IFS= read -rs probe_bvid
printf '\n' >&2
if [[ ${#probe_bvid} -ne 12 || ! "$probe_bvid" =~ ^BV[A-Za-z0-9]{10}$ ]]; then
    print -u2 'BVID 格式无效。'
    exit 2
fi

probe_directory=$(mktemp -d /tmp/BiliKitMac-m501-danmaku-probe.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
derived_data="$probe_directory/DerivedData"
test_log="$probe_directory/raw-test.log"
result_bundle="$probe_directory/M501Danmaku.xcresult"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvid -string "$probe_bvid" "$input_file"
chmod 600 "$input_file"
unset probe_bvid

cd "$repository_root"
print '正在构建签名测试宿主……'
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl \
    -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
    180 \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
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

print '正在测量同一会话的真实三段弹幕工作集……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl \
    -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
    120 \
    xcodebuild \
    -xctestrun "$xctestrun_file" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 90 \
    -maximum-test-execution-time-allowance 110 \
    test-without-building \
    -only-testing:BiliKitMacTests/M501DanmakuWorkingSetProbeTests/testThreeRealSegmentsShareOneBoundedWorkingSetWhenExplicitlyConfigured \
    >> "$test_log" 2>&1
probe_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'M501DanmakuWorkingSetProbeTests/testThreeRealSegmentsShareOneBoundedWorkingSetWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

if [[ $probe_status -ne 0 ]]; then
    print -u2 '三段工作集探针失败或超时；原始输出已清理。'
    exit $probe_status
fi

summary=$(rg -m 1 -o \
    'm501-danmaku-working-set segments=3 first-segment=[0-9]+ last-segment=[0-9]+ events=[0-9]+ min-segment-events=[0-9]+ max-segment-events=[0-9]+ cache-before-reset=3 cache-after-reset=0 rss-baseline-mib=[0-9.]+ rss-peak-mib=[0-9.]+ rss-retained-mib=[0-9.]+ rss-after-reset-mib=[0-9.]+ cleanup=complete' \
    "$test_log" || true)
if [[ -z "$summary" ]]; then
    print -u2 '探针没有产生完整的脱敏结果；原始输出已清理。'
    exit 1
fi

print -r -- "$summary"
print '探针完成；BVID、CID、URL、正文、响应和原始产物均未保留。'

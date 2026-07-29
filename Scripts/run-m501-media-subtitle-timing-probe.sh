#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
probe_directory=""
input_file=""
test_log=""
xctestrun_file=""
environment_path=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"

read_bvid() {
    local value
    printf '%s' '请输入一条确定带字幕的视频 BVID：' >&2
    IFS= read -rs value
    printf '\n' >&2
    if [[ ${#value} -ne 12 || ! "$value" =~ ^BV[A-Za-z0-9]{10}$ ]]; then
        print -u2 'BVID 格式无效。'
        exit 2
    fi
    print -r -- "$value"
}

cleanup() {
    if [[ -n "$xctestrun_file" && -f "$xctestrun_file" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_LOCAL_PROBE_INPUT_FILE" \
            "$xctestrun_file" >/dev/null 2>&1 || true
    fi
    if [[ -n "$probe_directory"
        && "$probe_directory" == /tmp/BiliKitMac-m501-timing-probe.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

probe_bvid=$(read_bvid)
probe_directory=$(mktemp -d /tmp/BiliKitMac-m501-timing-probe.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
derived_data="$probe_directory/DerivedData"
test_log="$probe_directory/raw-test.log"
result_bundle="$probe_directory/M501Timing.xcresult"
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

print '正在测量真实媒体 ABR 对齐与字幕准备时序……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl \
    -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
    240 \
    xcodebuild \
    -xctestrun "$xctestrun_file" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    -maximum-test-execution-time-allowance 220 \
    test-without-building \
    -only-testing:BiliKitMacTests/M501MediaSubtitleTimingProbeTests/testRealMultivariantPlaybackWhenExplicitlyConfigured \
    -only-testing:BiliKitMacTests/M501MediaSubtitleTimingProbeTests/testABRRepresentationAlignmentWhenExplicitlyConfigured \
    -only-testing:BiliKitMacTests/M501MediaSubtitleTimingProbeTests/testSubtitleBodyAgainstMediaAssemblyWhenExplicitlyConfigured \
    >> "$test_log" 2>&1
probe_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'M501MediaSubtitleTimingProbeTests/testRealMultivariantPlaybackWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'M501MediaSubtitleTimingProbeTests/testABRRepresentationAlignmentWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'M501MediaSubtitleTimingProbeTests/testSubtitleBodyAgainstMediaAssemblyWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

if [[ $probe_status -ne 0 ]]; then
    stage_summary=$(rg -o \
        'm501-real-abr-stage stage=[a-z-]+ cleanup=complete' \
        "$test_log" \
        | tail -n 1 || true)
    if [[ -n "$stage_summary" ]]; then
        print -u2 -r -- "$stage_summary"
    fi
    print -u2 '时序探针失败或超时；原始输出已清理。'
    exit $probe_status
fi

abr_summary=$(rg -m 1 -o \
    'm501-real-abr qualities=[0-9]+( low=[0-9]+ high=[0-9]+ references=[0-9]+/[0-9]+ start=(aligned|misaligned) duration=(aligned|misaligned) boundary-delta=[a-z0-9-]+ sap=(all|partial) delta=[a-z0-9-]+| comparison=unavailable) cleanup=complete' \
    "$test_log" || true)
playback_summary=$(rg -m 1 -o \
    'm501-real-abr-playback variants=[0-9]+( initial=high downgrade=(observed|not-observed) recovery=(observed|not-observed) recovery-window=[0-9]+s metadata=recognized same-item=true| comparison=unavailable) cleanup=complete' \
    "$test_log" || true)
timing_summary=$(rg -m 1 -o \
    'm501-native-subtitle-timing relation=[a-z-]+ media=[a-z0-9-]+ subtitle=[a-z0-9-]+ lag=[a-z0-9-]+ tracks=[0-9]+ cues=[0-9]+ kind=(automatic|standard) cleanup=complete' \
    "$test_log" || true)
if [[ -z "$playback_summary" || -z "$abr_summary" || -z "$timing_summary" ]]; then
    print -u2 '探针没有产生完整的脱敏结果；原始输出已清理。'
    exit 1
fi

print -r -- "$playback_summary"
print -r -- "$abr_summary"
print -r -- "$timing_summary"
print '探针完成；BVID、字幕内容、URL、凭据和原始产物均未保留。'

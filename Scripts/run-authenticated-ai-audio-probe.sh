#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
probe_directory=""
xctestrun_file=""
environment_path=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"

cleanup() {
    if [[ -n "$xctestrun_file" && -f "$xctestrun_file" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_LOCAL_PROBE_INPUT_FILE" \
            "$xctestrun_file" >/dev/null 2>&1 || true
    fi
    if [[ -n "$probe_directory"
        && "$probe_directory" == /tmp/BiliKitMac-authenticated-ai-audio-probe.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

read_secret_value() {
    local prompt=$1
    local value
    print -n -- "$prompt" >/dev/tty
    IFS= read -r -s value </dev/tty
    print >/dev/tty
    print -r -- "$value"
}

bvid=$(read_secret_value '请输入已确认具有 AI 音轨目录的公开视频 BVID：')
cid=$(read_secret_value '请输入对应分 P 的 CID：')
if [[ "$bvid" != BV?????????? || "$cid" != <-> || "$cid" -le 0 ]]; then
    print -u2 '输入格式无效；未发起网络请求。'
    exit 1
fi

probe_directory=$(mktemp -d /tmp/BiliKitMac-authenticated-ai-audio-probe.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
derived_data="$probe_directory/DerivedData"
build_log="$probe_directory/raw-build.log"
test_log="$probe_directory/raw-test.log"
result_bundle="$probe_directory/AuthenticatedAIAudio.xcresult"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvid -string "$bvid" "$input_file"
/usr/bin/plutil -insert cid -string "$cid" "$input_file"
chmod 600 "$input_file"
unset bvid cid

cd "$repository_root"
print '正在构建签名测试宿主……'
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' 240 \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    build-for-testing > "$build_log" 2>&1; then
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

print '正在验证 AI 音轨目录、独立媒体与 Cookie 终止边界……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/perl -e '$seconds = shift @ARGV; alarm $seconds; exec @ARGV' 150 \
    xcodebuild \
    -xctestrun "$xctestrun_file" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 90 \
    test-without-building \
    -only-testing:BiliKitMacTests/AuthenticatedAIAudioProbeTests/testAuthenticatedAIAudioWhenExplicitlyConfigured \
    > "$test_log" 2>&1
probe_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'AuthenticatedAIAudioProbeTests/testAuthenticatedAIAudioWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

if rg -q \
    '(SESSDATA=[A-Za-z0-9%_-]{20,}|bili_jct=[A-Fa-f0-9]{32}|refresh_token.{0,16}[=:][^[:space:]]*[A-Za-z0-9_-]{20,})' \
    "$build_log" "$test_log"; then
    print -u2 'classification=secret-scan-failed'
    print -u2 '探针输出出现疑似秘密；已停止且原始输出将清理。'
    exit 1
fi

if rg -q '(https?://|BV[A-Za-z0-9]{10})' "$test_log"; then
    print -u2 'classification=sensitive-output-scan-failed'
    print -u2 '测试产物出现远端 URL 或内容标识；已停止且原始输出将清理。'
    exit 1
fi

summary=$(rg -m 1 -o \
    'authenticated-ai-audio catalog-count=[0-9]+ production-types=\[[0-9, -]+\] selected-current-match=true original-aac=[0-9]+ ai-aac=[0-9]+ production-ai-tracks=[0-9]+ system-audible-options=[0-9]+ system-selection-ready=true sources-differ=true media-index-ready=true media-cookie=false' \
    "$test_log" || true)
if [[ $probe_status -ne 0 || -z "$summary" ]]; then
    stage_summary=$(rg -o \
        'authenticated-ai-audio-stage stage=[a-z-]+' \
        "$test_log" | tail -n 1 || true)
    [[ -z "$stage_summary" ]] || print -u2 -r -- "$stage_summary"
    failure_summary=$(rg -m 1 -o \
        'authentication-invalid|authorization-unavailable|http-status-(403|412)|api-rejected--?[0-9]+|non-json-response|Test case.*failed' \
        "$test_log" || true)
    [[ -z "$failure_summary" ]] || print -u2 -r -- "$failure_summary"
    [[ $probe_status -ne 142 ]] || print -u2 'classification=timeout.inconclusive'
    print -u2 'AI 音轨探针失败；未重试，原始输出将清理。'
    exit 1
fi

if [[ "$summary" == *'http://'* || "$summary" == *'https://'* ]]; then
    print -u2 'classification=url-scan-failed'
    exit 1
fi

print -r -- "$summary"
print '探针完成；账号身份、BVID/CID、URL、Cookie、响应正文与原始产物均未保留。'

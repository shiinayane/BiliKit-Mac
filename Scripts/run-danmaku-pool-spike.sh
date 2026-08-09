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
        && "$probe_directory" == /tmp/BiliKitMac-danmaku-pool-spike.*
        && -d "$probe_directory" ]]; then
        rm -rf -- "$probe_directory"
    fi
}
trap cleanup EXIT INT TERM

print -n -u2 -- '请输入用于弹幕池对照的 BVID：'
if [[ -t 0 ]]; then
    stty -echo
    trap 'stty echo; cleanup' EXIT INT TERM
fi
IFS= read -r probe_bvid
if [[ -t 0 ]]; then
    stty echo
    trap cleanup EXIT INT TERM
fi
print -u2
if [[ "$probe_bvid" != BV?????????? || "$probe_bvid" == *[^A-Za-z0-9]* ]]; then
    print -u2 'BVID 格式无效。'
    exit 2
fi

probe_directory=$(mktemp -d /tmp/BiliKitMac-danmaku-pool-spike.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
derived_data="$probe_directory/DerivedData"
test_log="$probe_directory/raw-test.log"
result_bundle="$probe_directory/DanmakuPool.xcresult"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvid -string "$probe_bvid" "$input_file"
chmod 600 "$input_file"

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

print '正在对比同一生产 WBI 接口的匿名与登录态弹幕池……'
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
    -only-testing:BiliKitMacTests/DanmakuPoolProbeTests/testPoolVariantsWhenExplicitlyConfigured \
    >> "$test_log" 2>&1
probe_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'DanmakuPoolProbeTests/testPoolVariantsWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

if rg -q \
    '(SESSDATA=[A-Za-z0-9%_-]{20,}|bili_jct=[A-Fa-f0-9]{32}|refresh_token.{0,16}[=:][^[:space:]]*[A-Za-z0-9_-]{20,})' \
    "$test_log"; then
    print -u2 'classification=secret-scan-failed'
    print -u2 '探针输出出现疑似秘密；已停止且原始输出将清理。'
    exit 1
fi
if rg -F -q -- "$probe_bvid" "$test_log"; then
    print -u2 'classification=identity-scan-failed'
    print -u2 '探针输出出现输入 identity；已停止且原始输出将清理。'
    exit 1
fi
unset probe_bvid

summary=$(rg -m 1 -o \
    'danmaku-pool-spike wbi-anonymous=[A-Za-z0-9._-]+ wbi-authenticated=[A-Za-z0-9._-]+' \
    "$test_log" || true)
if [[ $probe_status -ne 0 || -z "$summary" ]]; then
    stage_summary=$(rg -o \
        'danmaku-pool-stage stage=[a-z-]+' \
        "$test_log" | tail -n 1 || true)
    [[ -z "$stage_summary" ]] || print -u2 -r -- "$stage_summary"
    [[ $probe_status -ne 142 ]] || print -u2 'classification=timeout.inconclusive'
    print -u2 '弹幕池探针失败；未重试，原始输出将清理。'
    exit 1
fi

print -r -- "$summary"
print '探针完成；BVID/CID、账号身份、URL、Cookie、弹幕正文与原始产物均未保留。'

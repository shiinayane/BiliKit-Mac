#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
derived_data=/tmp/BiliKitMac-m4-probe
test_log="$repository_root/test.log"
result_bundle="$derived_data/M4ContractProbe-$(date +%Y%m%d-%H%M%S).xcresult"
xctestrun_file=""
environment_path=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"

printf '请输入一条确定带字幕的视频 BVID：'
IFS= read -r probe_bvid
if [[ ${#probe_bvid} -ne 12 || ! "$probe_bvid" =~ ^BV[[:alnum:]]{10}$ ]]; then
    print -u2 'BVID 格式无效。'
    exit 2
fi

printf '请输入要验证的分 P CID（首分 P可直接回车）：'
IFS= read -r probe_cid
if [[ -n "$probe_cid" && ! "$probe_cid" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 'CID 必须为正整数。'
    exit 2
fi

cleanup() {
    if [[ -n "$xctestrun_file" && -f "$xctestrun_file" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_M4_PROBE_BVID" \
            "$xctestrun_file" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_M4_PROBE_CID" \
            "$xctestrun_file" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

cd "$repository_root"
print '正在构建签名测试宿主……'
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build-for-testing > "$test_log" 2>&1; then
    tail -80 "$test_log"
    exit 1
fi

xctestrun_files=("$derived_data"/Build/Products/*.xctestrun(N))
if [[ ${#xctestrun_files} -ne 1 ]]; then
    print -u2 '没有找到唯一的 xctestrun 文件，无法安全注入临时探针参数。'
    exit 1
fi
xctestrun_file=${xctestrun_files[1]}

/usr/libexec/PlistBuddy \
    -c "Add ${environment_path}:BILIKIT_M4_PROBE_BVID string $probe_bvid" \
    "$xctestrun_file"
if [[ -n "$probe_cid" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add ${environment_path}:BILIKIT_M4_PROBE_CID string $probe_cid" \
        "$xctestrun_file"
fi

print '正在运行已登录字幕契约探针……'
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild \
    -xctestrun "$xctestrun_file" \
    -destination 'platform=macOS' \
    -resultBundlePath "$result_bundle" \
    test-without-building \
    -only-testing:BiliKitMacTests/M4AuthenticatedContractProbeTests/testAuthenticatedSubtitleContractWhenExplicitlyConfigured \
    >> "$test_log" 2>&1
probe_status=$?
set -e

if [[ -d "$result_bundle" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'M4AuthenticatedContractProbeTests/testAuthenticatedSubtitleContractWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

rg 'm4-subtitle|TEST (SUCCEEDED|FAILED)|Test case.*M4Authenticated' "$test_log" || true
if [[ $probe_status -ne 0 ]]; then
    print -u2 "探针失败；完整脱敏构建日志位于 $test_log"
    exit $probe_status
fi
if ! rg -q 'm4-subtitle-production .*decoder=ready' "$test_log"; then
    print -u2 '探针未到达生产字幕 decoder；请更换存在可用字幕正文的样本。'
    print -u2 "完整脱敏构建日志位于 $test_log"
    exit 1
fi

print "探针完成；完整脱敏构建日志位于 $test_log"

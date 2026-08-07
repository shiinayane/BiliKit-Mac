#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
probe_directory=""
input_file=""
derived_data=""
test_log=""
result_bundle=""
xctestrun_file=""
environment_path=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"
maximum_build_seconds=180
maximum_test_seconds=120

read_secret_value() {
    prompt=$1
    printf '%s' "$prompt" >&2
    if [ -t 0 ]; then
        stty -echo
        trap 'stty echo' 0 1 2 15
    fi
    IFS= read -r value
    if [ -t 0 ]; then
        stty echo
        trap - 0 1 2 15
    fi
    printf '\n' >&2
    printf '%s\n' "$value"
}

probe_bvid=$(read_secret_value '请输入一条确定带字幕的视频 BVID：')
probe_cid=$(read_secret_value '请输入对应分 P 的 CID：')
case "$probe_bvid" in
    BV??????????)
        case "$probe_bvid" in
            *[!A-Za-z0-9]*)
                printf '%s\n' 'BVID 格式无效。' >&2
                exit 2
                ;;
        esac
        ;;
    *)
        printf '%s\n' 'BVID 格式无效。' >&2
        exit 2
        ;;
esac
case "$probe_cid" in
    ''|0*|*[!0-9]*)
        printf '%s\n' 'CID 必须为正整数。' >&2
        exit 2
        ;;
esac

cleanup() {
    if [ -n "$xctestrun_file" ] && [ -f "$xctestrun_file" ]; then
        /usr/libexec/PlistBuddy \
            -c "Delete ${environment_path}:BILIKIT_NATIVE_SUBTITLE_STAGE0_INPUT_FILE" \
            "$xctestrun_file" >/dev/null 2>&1 || true
    fi
    case "$probe_directory" in
        /tmp/BiliKit-native-subtitle-stage0.*)
            if [ -d "$probe_directory" ]; then
                rm -rf -- "$probe_directory"
            fi
            ;;
    esac
}
trap cleanup EXIT INT TERM

probe_directory=$(mktemp -d /tmp/BiliKit-native-subtitle-stage0.XXXXXX)
chmod 700 "$probe_directory"
input_file="$probe_directory/input.plist"
derived_data="$probe_directory/DerivedData"
test_log="$probe_directory/raw-test.log"
result_bundle="$probe_directory/NativeSubtitleStage0.xcresult"
/usr/bin/plutil -create xml1 "$input_file"
/usr/bin/plutil -insert bvid -string "$probe_bvid" "$input_file"
/usr/bin/plutil -insert cid -string "$probe_cid" "$input_file"
chmod 600 "$input_file"
unset probe_bvid probe_cid

cd "$repository_root"
printf '%s\n' '正在构建签名测试宿主……'
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
    printf '%s\n' '签名测试宿主构建失败或超时；原始输出已清理。' >&2
    exit 1
fi

set -- "$derived_data"/Build/Products/*.xctestrun
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    printf '%s\n' '没有找到唯一的 xctestrun 文件。' >&2
    exit 1
fi
xctestrun_file=$1
/usr/libexec/PlistBuddy \
    -c "Add ${environment_path}:BILIKIT_NATIVE_SUBTITLE_STAGE0_INPUT_FILE string $input_file" \
    "$xctestrun_file"

printf '%s\n' '正在运行字幕目录字段探针……'
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
    -default-test-execution-time-allowance 90 \
    -maximum-test-execution-time-allowance 110 \
    test-without-building \
    -only-testing:BiliKitMacTests/NativeSubtitleStage0ContractProbeTests/testAuthenticatedCatalogFieldCombinationsWhenExplicitlyConfigured \
    >> "$test_log" 2>&1
probe_status=$?
set -e

if [ -d "$result_bundle" ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun xcresulttool get test-results activities \
        --path "$result_bundle" \
        --test-id 'NativeSubtitleStage0ContractProbeTests/testAuthenticatedCatalogFieldCombinationsWhenExplicitlyConfigured()' \
        >> "$test_log" 2>&1 || true
fi

rg -m 1 'native-subtitle-stage0 tracks=.*combinations=' "$test_log" || true
if [ "$probe_status" -ne 0 ]; then
    rg -m 1 'native-subtitle-stage0 failure-type=[A-Za-z0-9._-]+' \
        "$test_log" || true
    printf '%s\n' '探针失败、跳过或超时；原始日志与测试产物已清理。' >&2
    exit $probe_status
fi
if ! rg -q 'native-subtitle-stage0 tracks=.*combinations=' "$test_log"; then
    printf '%s\n' '探针没有产生允许公开的字段组合摘要。' >&2
    exit 1
fi

printf '%s\n' '探针完成；输入 identity、URL、正文、凭据和原始响应均未保留。'

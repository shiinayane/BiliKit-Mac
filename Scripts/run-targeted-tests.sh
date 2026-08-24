#!/bin/sh

set -eu

umask 077

if [ "$#" -ne 3 ]; then
    echo "用法：$0 <任务临时根> <package|app> <测试筛选器>" >&2
    exit 2
fi

requested_root=$1
mode=$2
test_filter=$3

case "$requested_root" in
    /*) ;;
    *)
        echo "任务临时根必须是绝对路径" >&2
        exit 2
        ;;
esac
case "$mode" in
    package|app) ;;
    *)
        echo "测试模式必须是 package 或 app" >&2
        exit 2
        ;;
esac
[ -n "$test_filter" ] || {
    echo "测试筛选器不能为空" >&2
    exit 2
}

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ -d "$requested_root" ] || {
    echo "任务临时根必须由当前任务预先创建" >&2
    exit 2
}
artifact_root=$(CDPATH= cd -- "$requested_root" && pwd -P)
case "$artifact_root" in
    /|/tmp|/private/tmp|"$repository_root")
        echo "拒绝使用过宽的任务临时根：$artifact_root" >&2
        exit 2
        ;;
esac

owner_marker="$artifact_root/.bilikit-targeted-cache-owner"
if [ -f "$owner_marker" ]; then
    recorded_repository_root=$(sed -n '1p' "$owner_marker")
    [ "$recorded_repository_root" = "$repository_root" ] || {
        echo "任务临时根属于其他 worktree：$recorded_repository_root" >&2
        exit 2
    }
elif [ -e "$owner_marker" ]; then
    echo "任务临时根 owner marker 不是普通文件" >&2
    exit 2
elif find "$artifact_root" -mindepth 1 -print -quit | grep -q .; then
    echo "拒绝使用没有 owner marker 的非空任务临时根" >&2
    exit 2
else
    printf '%s\n' "$repository_root" > "$owner_marker"
fi

cd "$repository_root"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
    echo "需要完整 Xcode：$developer_dir" >&2
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"
task_tmp="$artifact_root/tmp"
module_cache="$artifact_root/ModuleCache.noindex"
mkdir -p "$task_tmp" "$module_cache"

if [ "$mode" = "package" ]; then
    swiftpm_home="$artifact_root/swiftpm-home"
    mkdir -p "$swiftpm_home"
    HOME="$swiftpm_home" \
    CFFIXED_USER_HOME="$swiftpm_home" \
    XDG_CACHE_HOME="$swiftpm_home/.cache" \
    TMPDIR="$task_tmp" \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    xcrun swift test \
        --package-path Packages/BiliKitCore \
        --scratch-path "$artifact_root/swiftpm" \
        --cache-path "$artifact_root/swiftpm-cache" \
        --config-path "$artifact_root/swiftpm-config" \
        --security-path "$artifact_root/swiftpm-security" \
        --filter "$test_filter"
    exit 0
fi

xcode_home="$artifact_root/xcode-home"
derived_data="$artifact_root/DerivedData"
packages="$artifact_root/SourcePackages"
mkdir -p "$xcode_home"
HOME="$xcode_home" \
CFFIXED_USER_HOME="$xcode_home" \
XDG_CACHE_HOME="$xcode_home/.cache" \
TMPDIR="$task_tmp" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
xcodebuild \
    -quiet \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$packages" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    test \
    -only-testing:"$test_filter"

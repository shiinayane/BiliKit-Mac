#!/bin/sh

set -eu

fail() {
    echo "质量 Gate 失败：$1" >&2
    exit 1
}

mode="${1:-package}"
case "$mode" in
    static|package|app) ;;
    *) fail "模式必须是 static、package 或 app" ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repository_root"

echo "[Gate] 静态契约"
sh Scripts/check-architecture.sh
sh Scripts/check-secrets.sh
sh Scripts/check-project-contract.sh
git diff --check
git diff --cached --check

if [ "$mode" = "static" ]; then
    echo "[Gate] static 通过"
    exit 0
fi

echo "[Gate] Swift Package"
xcrun swift test --package-path Packages/BiliKitCore

if [ "$mode" = "package" ]; then
    echo "[Gate] package 通过"
    exit 0
fi

xcodebuild -version >/dev/null 2>&1 \
    || fail "app 模式需要完整 Xcode；请先切换 xcode-select 或显式设置 DEVELOPER_DIR"

derived_data_path="${BILIKIT_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/BiliKitMac-derived}"

echo "[Gate] App build-for-testing"
xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing

echo "[Gate] App unit tests"
xcodebuild \
    -project BiliKitMac.xcodeproj \
    -scheme BiliKitMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    test-without-building \
    -only-testing:BiliKitMacTests

echo "[Gate] app 通过"

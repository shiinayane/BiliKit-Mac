#!/bin/sh

set -eu

umask 077

mode="${1:-app}"
case "$mode" in
    static|package|app) ;;
    *)
        echo "用法：$0 [static|package|app]" >&2
        exit 2
        ;;
esac

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
cd "$repository_root"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
    echo "需要完整 Xcode：$developer_dir" >&2
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"

artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/BiliKit-quality-gate.XXXXXX")
cleanup() {
    rm -rf -- "$artifact_root"
}
trap cleanup EXIT HUP INT TERM

echo "[Gate] static"
sh Scripts/check-architecture.sh
sh Scripts/check-secrets.sh
sh Scripts/check-project-contract.sh
sh Scripts/check-swift-format.sh
git diff --check
git diff --cached --check

if [ "$mode" = "static" ]; then
    exit 0
fi

swiftpm_home="$artifact_root/swiftpm-home"
mkdir -p "$swiftpm_home"
echo "[Gate] package"
HOME="$swiftpm_home" \
CFFIXED_USER_HOME="$swiftpm_home" \
XDG_CACHE_HOME="$swiftpm_home/.cache" \
xcrun swift test \
    --quiet \
    --package-path Packages/BiliKitCore \
    --scratch-path "$artifact_root/swiftpm" \
    --cache-path "$artifact_root/swiftpm-cache" \
    --config-path "$artifact_root/swiftpm-config" \
    --security-path "$artifact_root/swiftpm-security"

if [ "$mode" = "package" ]; then
    exit 0
fi

xcode_home="$artifact_root/xcode-home"
derived_data="$artifact_root/DerivedData"
packages="$artifact_root/SourcePackages"
mkdir -p "$xcode_home"

echo "[Gate] app build-for-testing"
# Xcode 26 misdiagnoses explicit local-package edges during build-for-testing.
HOME="$xcode_home" \
CFFIXED_USER_HOME="$xcode_home" \
XDG_CACHE_HOME="$xcode_home/.cache" \
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
    build-for-testing

echo "[Gate] app tests"
HOME="$xcode_home" \
CFFIXED_USER_HOME="$xcode_home" \
XDG_CACHE_HOME="$xcode_home/.cache" \
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
    test-without-building \
    -only-testing:BiliKitMacTests

echo "[Gate] app passed"

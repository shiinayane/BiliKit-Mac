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

artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/BiliKit-quality-gate.XXXXXX")
cleanup() {
    status=$?
    if ! rm -rf -- "$artifact_root" 2>/dev/null; then
        echo "[Gate] warning: 未能完整清理临时产物：$artifact_root" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

. Scripts/isolated-toolchain.sh

echo "[Gate] static"
sh Scripts/check-architecture.sh
sh Scripts/check-secrets.sh
sh Scripts/check-project-contract.sh
sh Scripts/check-swift-format.sh
git diff --check
git diff --cached --check

echo "[Gate] release safety contracts"
python3 -B -m unittest discover -s Scripts/release -p 'test_*.py'
(cd Updates/cloudflare && python3 -B -m unittest discover -s tests)

if [ "$mode" = "static" ]; then
    exit 0
fi

echo "[Gate] package"
package_test --quiet

if [ "$mode" = "package" ]; then
    exit 0
fi

# CI 在 macOS 26 导出同一提交的 App 测试产物，macOS 15 导入后只运行测试。
if [ -n "${BILIKIT_TEST_PRODUCTS_INPUT:-}" ]; then
    echo "[Gate] import app test products"
    mkdir -p "$derived_data/Build/Products"
    tar -xf "$BILIKIT_TEST_PRODUCTS_INPUT" -C "$derived_data/Build/Products"
else
    echo "[Gate] app build-for-testing"
    app_xcodebuild build-for-testing
fi

set -- "$derived_data"/Build/Products/*.xctestrun
[ "$#" -eq 1 ] && [ -f "$1" ] || {
    echo "需要唯一的 App 测试运行配置" >&2
    exit 1
}

echo "[Gate] app tests"
isolated xcode-home xcodebuild \
    -quiet \
    -xctestrun "$1" \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    test-without-building \
    -only-testing:BiliKitMacTests

if [ -n "${BILIKIT_TEST_PRODUCTS_OUTPUT:-}" ]; then
    tar -cf "$BILIKIT_TEST_PRODUCTS_OUTPUT" -C "$derived_data/Build/Products" .
fi

echo "[Gate] app passed"

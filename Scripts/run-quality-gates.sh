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
# 失败时把测试结果包留到 BILIKIT_FAILURE_OUTPUT（CI 上传为 artifact），其余一律清理。
save_failure_evidence() {
    [ -n "${BILIKIT_FAILURE_OUTPUT:-}" ] || return 0
    mkdir -p "$BILIKIT_FAILURE_OUTPUT"
    for bundle in "$artifact_root"/DerivedData/Logs/Test/*.xcresult; do
        [ -d "$bundle" ] && cp -R "$bundle" "$BILIKIT_FAILURE_OUTPUT/"
    done
    return 0
}

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        save_failure_evidence || echo "[Gate] warning: 未能保存失败现场" >&2
    fi
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

echo "[Gate] app build-for-testing"
app_xcodebuild build-for-testing

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

# CI 把发布工具链构建的 App 交给较旧系统做启动冒烟（Scripts/smoke-launch-app.sh）。
if [ -n "${BILIKIT_APP_OUTPUT:-}" ]; then
    tar -cf "$BILIKIT_APP_OUTPUT" -C "$derived_data/Build/Products/Debug" BiliKit.app
fi

echo "[Gate] app passed"

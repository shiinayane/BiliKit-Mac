#!/bin/sh

set -eu

fail() {
    echo "工程静态契约失败：$1" >&2
    exit 1
}

assert_occurrences() {
    expected="$1"
    text="$2"
    file="$3"
    description="$4"
    actual=$(awk -v needle="$text" 'index($0, needle) { count += 1 } END { print count + 0 }' "$file")
    [ "$actual" -eq "$expected" ] || fail "$description（期望 $expected 处，实际 $actual 处）"
}

project_file="BiliKitMac.xcodeproj/project.pbxproj"
entitlements_file="BiliKitMac/BiliKitMac.entitlements"
package_file="Packages/BiliKitCore/Package.swift"

/usr/bin/plutil -lint "$entitlements_file" >/dev/null \
    || fail "entitlements 不是有效 plist"

[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements_file")" = "true" ] \
    || fail "缺少出站网络 entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$entitlements_file")" = "true" ] \
    || fail "缺少 loopback server entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements_file")" = '$(AppIdentifierPrefix)com.shiinayane.BiliKitMac' ] \
    || fail "Keychain access group 与 App 标识不一致"
if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "$entitlements_file" >/dev/null 2>&1; then
    fail "Keychain access group 必须保持最小单项集合"
fi

top_level_key_count=$(/usr/bin/plutil -p "$entitlements_file" | awk '/^  "/ { count += 1 } END { print count + 0 }')
[ "$top_level_key_count" -eq 3 ] || fail "entitlements 出现未审计的额外能力"

assert_occurrences 2 \
    'CODE_SIGN_ENTITLEMENTS = BiliKitMac/BiliKitMac.entitlements;' \
    "$project_file" \
    "App Debug/Release 必须使用同一 entitlement 文件"
assert_occurrences 2 \
    'PRODUCT_BUNDLE_IDENTIFIER = com.shiinayane.BiliKitMac;' \
    "$project_file" \
    "App Debug/Release bundle identifier 必须统一"
assert_occurrences 2 \
    'PRODUCT_NAME = BiliKit;' \
    "$project_file" \
    "App Debug/Release 产品名必须统一"
assert_occurrences 2 \
    'ENABLE_APP_SANDBOX = YES;' \
    "$project_file" \
    "App Debug/Release 必须启用 App Sandbox"

deployment_count=$(awk '/MACOSX_DEPLOYMENT_TARGET = / { count += 1; if ($0 !~ /MACOSX_DEPLOYMENT_TARGET = 15\.0;/) bad += 1 } END { print count + 0, bad + 0 }' "$project_file")
set -- $deployment_count
[ "$1" -gt 0 ] || fail "Xcode 工程没有 deployment target"
[ "$2" -eq 0 ] || fail "Xcode target 的最低系统版本没有统一为 macOS 15"
assert_occurrences 1 '.macOS(.v15),' "$package_file" "Swift Package 最低系统版本必须为 macOS 15"

for product in BiliBrowseFeature BiliLibraryFeature BiliAuthFeature; do
    assert_occurrences 1 \
        ".library(name: \"$product\", targets: [\"$product\"])," \
        "$package_file" \
        "缺少产品领域 Feature product：$product"
done

echo "工程、entitlement 与最低系统版本静态契约检查通过"

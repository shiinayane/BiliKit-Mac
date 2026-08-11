#!/bin/sh

set -eu

fail() {
    echo "工程静态契约失败：$1" >&2
    exit 1
}

count() {
    awk -v needle="$1" 'index($0, needle) { total += 1 } END { print total + 0 }' "$2"
}

expect_count() {
    expected="$1"
    text="$2"
    file="$3"
    description="$4"
    actual=$(count "$text" "$file")
    [ "$actual" -eq "$expected" ] \
        || fail "$description（期望 $expected 处，实际 $actual 处）"
}

project="BiliKitMac.xcodeproj/project.pbxproj"
app="BiliKitMac/App/BiliKitMacApp.swift"
entitlements="BiliKitMac/BiliKitMac.entitlements"
package="Packages/BiliKitCore/Package.swift"

/usr/bin/plutil -lint "$project" >/dev/null || fail "Xcode 工程格式无效"
/usr/bin/plutil -lint "$entitlements" >/dev/null || fail "entitlements 格式无效"

[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements")" = true ] \
    || fail "缺少出站网络 entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$entitlements")" = true ] \
    || fail "缺少 loopback server entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")" = '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)' ] \
    || fail "Keychain access group 与 App 标识不一致"
if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "$entitlements" >/dev/null 2>&1; then
    fail "Keychain access group 必须保持单项"
fi
top_level_key_count=$(
    /usr/bin/plutil -p "$entitlements" \
        | awk '/^  "/ { total += 1 } END { print total + 0 }'
)
[ "$top_level_key_count" -eq 3 ] \
    || fail "entitlements 出现未审计的额外能力"

expect_count 2 'CODE_SIGN_ENTITLEMENTS = BiliKitMac/BiliKitMac.entitlements;' "$project" "App 配置必须使用同一 entitlement"
expect_count 2 'PRODUCT_BUNDLE_IDENTIFIER = com.shiinayane.BiliKitMac.dev;' "$project" "App Bundle Identifier 不一致"
expect_count 2 'PRODUCT_NAME = BiliKit;' "$project" "App 产品名不一致"
expect_count 2 'ENABLE_APP_SANDBOX = YES;' "$project" "App Sandbox 必须启用"
expect_count 1 '.typesettingLanguage(' "$app" "App 根必须设置排版语言"
expect_count 1 '.explicit(Locale.Language(identifier: "zh-Hans"))' "$app" "App 排版语言必须为简体中文"

deployment=$(awk '/MACOSX_DEPLOYMENT_TARGET = / { total += 1; if ($0 !~ /15\.0;/) bad += 1 } END { print total + 0, bad + 0 }' "$project")
set -- $deployment
[ "$1" -gt 0 ] && [ "$2" -eq 0 ] || fail "Xcode target 必须统一支持 macOS 15"
expect_count 1 '.macOS(.v15)' "$package" "Swift Package 必须支持 macOS 15"

sh -n Scripts/run-quality-gates.sh || fail "质量 Gate 脚本语法无效"

echo "工程、安全能力与最低系统版本静态契约检查通过"

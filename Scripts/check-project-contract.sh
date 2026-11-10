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
        || fail "${description}（期望 $expected 处，实际 $actual 处）"
}

project="BiliKitMac.xcodeproj/project.pbxproj"
app="BiliKitMac/App/BiliKitMacApp.swift"
entitlements="BiliKitMac/BiliKitMac.entitlements"
package="Packages/BiliKitCore/Package.swift"
ci_workflow=".github/workflows/ci.yml"

/usr/bin/plutil -lint "$project" >/dev/null || fail "Xcode 工程格式无效"
/usr/bin/plutil -lint "$entitlements" >/dev/null || fail "entitlements 格式无效"
expect_count 0 'path = Packages;' "$project" "本地 Package 不得重复注册为同步目录"

[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements")" = true ] \
    || fail "缺少出站网络 entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$entitlements")" = true ] \
    || fail "缺少 loopback server entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$entitlements")" = true ] \
    || fail "缺少评论图片保存所需的用户选择文件读写 entitlement"
[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")" = '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)' ] \
    || fail "Keychain access group 与 App 标识不一致"
if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "$entitlements" >/dev/null 2>&1; then
    fail "Keychain access group 必须保持单项"
fi
top_level_key_count=$(
    /usr/bin/plutil -p "$entitlements" \
        | awk '/^  "/ { total += 1 } END { print total + 0 }'
)
[ "$top_level_key_count" -eq 5 ] \
    || fail "entitlements 出现未审计的额外能力"

expect_count 2 'CODE_SIGN_ENTITLEMENTS = BiliKitMac/BiliKitMac.entitlements;' "$project" "App 配置必须使用同一 entitlement"
expect_count 6 'DEVELOPMENT_TEAM = 2B3LZ256AG;' "$project" "Project 与 target 必须使用正式开发团队"
# App 身份只由渠道 xcconfig 派生，默认开发渠道；正式渠道只由 release.py 在命令行选择（见 ARCHITECTURE「平台与命名」）。
channel="Configuration/BiliKit-Channel.xcconfig"
expect_count 2 'baseConfigurationReference = A1000000000000000000002D /* BiliKit-Channel.xcconfig */;' "$project" "App 两个配置都必须基于渠道 xcconfig"
expect_count 2 'PRODUCT_BUNDLE_IDENTIFIER = ' "$project" "只有测试 target 可以在工程里写 Bundle ID"
expect_count 2 'PRODUCT_BUNDLE_IDENTIFIER = com.shiinayane.BiliKitMacTests;' "$project" "测试 target 标识不一致"
for key in INFOPLIST_KEY_CFBundleDisplayName ASSETCATALOG_COMPILER_APPICON_NAME; do
    expect_count 0 "$key = " "$project" "App 身份不得在工程里绕过渠道 xcconfig（${key}）"
done
expect_count 0 'BILIKIT_' "$project" "渠道设置不得写进工程"
expect_count 1 'BILIKIT_CHANNEL = Dev' "$channel" "默认渠道必须是开发渠道"
[ "$(grep -c '^BILIKIT_CHANNEL' "$channel")" -eq 1 ] || fail "渠道 xcconfig 只能有一处默认渠道"
grep -q "'BILIKIT_CHANNEL=Production'" Scripts/release/release.py || fail "release.py 的 archive 必须选择正式渠道"
expect_count 2 'PRODUCT_NAME = BiliKit;' "$project" "App 产品名不一致"
expect_count 2 'INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.entertainment";' "$project" "App 类别元数据不一致"
expect_count 2 'INFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © 2026 shiinayane.";' "$project" "App 版权元数据不一致"
expect_count 2 'ENABLE_APP_SANDBOX = YES;' "$project" "App Sandbox 必须启用"
# 并发语义与 Package 一致（见 ARCHITECTURE「平台与命名」）：不开 NonisolatedNonsendingByDefault。
expect_count 0 'SWIFT_APPROACHABLE_CONCURRENCY = YES;' "$project" "App 与测试 target 不得开启 Approachable Concurrency"
expect_count 0 'NONISOLATED_NONSENDING' "$project" "App 与测试 target 不得开启 NonisolatedNonsendingByDefault"
expect_count 4 'SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES = YES;' "$project" "App 与测试 target 必须开启 InferIsolatedConformances"
expect_count 4 'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;' "$project" "App 与测试 target 必须开启 MemberImportVisibility"
expect_count 0 'NonisolatedNonsendingByDefault' "$package" "Package 不得开启 NonisolatedNonsendingByDefault"
expect_count 1 '.enableUpcomingFeature("InferIsolatedConformances")' "$package" "Package 必须开启 InferIsolatedConformances"
expect_count 1 '.enableUpcomingFeature("MemberImportVisibility")' "$package" "Package 必须开启 MemberImportVisibility"
/usr/bin/plutil -convert json -o - "$project" | python3 -c '
import json, sys
objects = json.load(sys.stdin)["objects"].values()
configs = [obj for obj in objects if "ARCHS" in obj.get("buildSettings", {})]
valid = (len(configs) == 1 and configs[0].get("name") == "Release"
         and configs[0]["buildSettings"]["ARCHS"] in ("arm64", ["arm64"]))
sys.exit(0 if valid else 1)
' || fail "Release 必须显式且仅指定 arm64 架构"
expect_count 1 'ONLY_ACTIVE_ARCH = NO;' "$project" "Release 不得只构建当前机器架构"
expect_count 0 '.typesettingLanguage(' "$app" "App 根不得强制内容排版语言"
expect_count 0 '.environment(\.locale' "$app" "App 根不得强制界面 locale"
if find BiliKitMac Packages/BiliKitCore/Sources -type f -name '*.swift' \
    -exec grep -En \
    '\.typesettingLanguage\(|\.environment\([[:space:]]*\\\.locale|kCTLanguageAttributeName|kCTFontDescriptorLanguageAttribute' \
    {} + >/dev/null; then
    fail "生产源码不得强制 UI、内容或字体语言"
fi

deployment=$(awk '/MACOSX_DEPLOYMENT_TARGET = / { total += 1; if ($0 !~ /15\.0;/) bad += 1 } END { print total + 0, bad + 0 }' "$project")
set -- $deployment
[ "$1" -gt 0 ] && [ "$2" -eq 0 ] || fail "Xcode target 必须统一支持 macOS 15"
expect_count 1 '.macOS(.v15)' "$package" "Swift Package 必须支持 macOS 15"
grep -Eq 'DEVELOPER_DIR: /Applications/Xcode_[0-9][0-9.]*\.app/' "$ci_workflow" \
    || fail "CI 必须显式选择带版本号的 Xcode"
# 只支持发布工具链一个版本，不保留按编译器版本分叉的代码。
if grep -rEq --include='*.swift' '#(if|elseif)[[:space:]]+!?[[:space:]]*compiler\(' \
    BiliKitMac BiliKitMacTests Packages/BiliKitCore/Sources Packages/BiliKitCore/Tests; then
    fail "源码不得按编译器版本分叉"
fi

for script in Scripts/*.sh; do
    sh -n "$script" || fail "脚本语法无效：$script"
done
# 非 UTF-8 locale（如 macOS 的 en_US，即 Latin-1）下 bash 把紧跟在变量名后的中文字节读进变量名，
# set -u 时报未定义变量（CI 即如此）；这类变量必须写成花括号形式。
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' Scripts/*.sh; then
    fail "脚本里紧跟非 ASCII 字符的变量必须加花括号"
fi

[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:0' "$entitlements")" = '$(PRODUCT_BUNDLE_IDENTIFIER)-spks' ] || fail "Sparkle status mach lookup 不一致"
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:1' "$entitlements")" = '$(PRODUCT_BUNDLE_IDENTIFIER)-spki' ] || fail "Sparkle installer mach lookup 不一致"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:2' "$entitlements" >/dev/null 2>&1; then
    fail "Sparkle mach lookup 只能授权两个精确服务"
fi

expect_count 2 'Configuration/BiliKit-Info.plist' "$project" "App 必须合并受审计的 Sparkle 配置"
expect_count 1 'version = 2.9.6;' "$project" "Sparkle 必须精确锁版"
expect_count 1 'kind = exactVersion;' "$project" "Sparkle 禁止浮动版本约束"
/usr/bin/plutil -lint Configuration/BiliKit-Info.plist >/dev/null || fail "Sparkle Info.plist 无效"

echo "工程、安全能力与最低系统版本静态契约检查通过"

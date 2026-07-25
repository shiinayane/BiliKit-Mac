#!/bin/sh

set -eu

fail() {
    echo "Swift 格式检查失败：$1" >&2
    exit 1
}

[ -f ".swift-format" ] || fail "仓库根目录缺少 .swift-format"

swift_format=$(xcrun --find swift-format 2>/dev/null) \
    || fail "当前 Xcode/Command Line Tools 不提供 swift-format"

# Protobuf 生成物由 schema 与固定 generator 负责，不把机械格式化结果作为源码契约。
"$swift_format" lint \
    --strict \
    --parallel \
    --configuration .swift-format \
    Packages/BiliKitCore/Package.swift

find BiliKitMac BiliKitMacTests BiliKitMacUITests \
    Packages/BiliKitCore/Sources Packages/BiliKitCore/Tests \
    -type f \
    -name '*.swift' \
    ! -name '*.pb.swift' \
    -exec "$swift_format" lint \
        --strict \
        --parallel \
        --configuration .swift-format \
        {} +

echo "Swift 格式检查通过"

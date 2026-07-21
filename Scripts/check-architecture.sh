#!/bin/sh

set -eu

check_forbidden_imports() {
    target_path="$1"
    forbidden_pattern="$2"
    description="$3"

    if grep -R -n -E --include='*.swift' "$forbidden_pattern" "$target_path"; then
        echo "架构边界失败：$description" >&2
        exit 1
    fi
}

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliModels" \
    '^import (Bili[A-Za-z0-9_]*|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliModels 不能依赖外层模块或界面/播放框架"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliApplication" \
    '^import (BiliAPI|BiliNetworking|BiliPlayback|BiliGuestFeature|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliApplication 只能依赖 BiliModels 与标准库"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliGuestFeature" \
    '^import (BiliAPI|BiliNetworking|BiliPlayback|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliGuestFeature 不能直接依赖 Data 或 Platform adapter"

check_forbidden_imports \
    "BiliKitMac/App" \
    '^import (BiliAPI|BiliApplication|BiliModels|BiliNetworking|BiliPlayback|AVFoundation|AVKit|AppKit|Network)$' \
    "App shell 不能直接依赖 Data、Application 或 Platform 实现"

echo "架构依赖边界检查通过"

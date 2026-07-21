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
    '^import (BiliAPI|BiliAuth|BiliAuthFeature|BiliNetworking|BiliPlayback|BiliGuestFeature|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliApplication 只能依赖 BiliModels 与标准库"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliNetworking" \
    '^import (Bili[A-Za-z0-9_]*|Security|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliNetworking 只能提供无业务语义、无秘密存储的传输边界"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliGuestFeature" \
    '^import (BiliAPI|BiliAuth|BiliAuthFeature|BiliNetworking|BiliPlayback|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliGuestFeature 不能直接依赖 Data 或 Platform adapter"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliAuthFeature" \
    '^import (BiliAPI|BiliAuth|BiliAuthFeature|BiliGuestFeature|BiliNetworking|BiliPlayback|BiliModels|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliAuthFeature 不能依赖业务 adapter、其他 Feature 或平台服务"

check_forbidden_imports \
    "BiliKitMac/App" \
    '^import (BiliAPI|BiliApplication|BiliAuth|BiliModels|BiliNetworking|BiliPlayback|AVFoundation|AVKit|AppKit|Network)$' \
    "App shell 不能直接依赖 Data、Application 或 Platform 实现"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliAuth" \
    '^import (BiliAPI|BiliPlayback|BiliGuestFeature|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliAuth 不能依赖 API、Playback 或 Presentation 实现"

echo "架构依赖边界检查通过"

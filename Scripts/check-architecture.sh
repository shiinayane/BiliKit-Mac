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
    '^import (BiliAPI|BiliAuth|BiliDanmaku|BiliNetworking|BiliPlayback|Bili[A-Za-z0-9_]*Feature|SwiftUI|CoreGraphics|CoreImage|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliApplication 只能依赖 BiliModels 与标准库"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliNetworking" \
    '^import (Bili[A-Za-z0-9_]*|Security|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliNetworking 只能提供无业务语义、无秘密存储的传输边界"

if grep -R -n -E --include='*.swift' '^import ' \
    Packages/BiliKitCore/Sources/BiliUI \
    | grep -v -E '^Packages/BiliKitCore/Sources/BiliUI/[^:]+:[0-9]+:import (Foundation|SwiftUI)$'; then
    echo "架构边界失败：BiliUI 只能依赖 Foundation 与 SwiftUI" >&2
    exit 1
fi

for feature_path in Packages/BiliKitCore/Sources/Bili*Feature; do
    check_forbidden_imports \
        "$feature_path" \
        '^import (BiliAPI|BiliAuth|BiliDanmaku|BiliNetworking|BiliPlayback|Bili[A-Za-z0-9_]*Feature|AVFoundation|AVKit|AppKit|Network)$' \
        "Feature 不能依赖业务 adapter、其他 Feature 或平台服务：$feature_path"
done

check_forbidden_imports \
    "BiliKitMac/App" \
    '^import (BiliAPI|BiliApplication|BiliAuth|BiliDanmaku|BiliModels|BiliNetworking|BiliPlayback|AVFoundation|AVKit|AppKit|Network)$' \
    "App shell 不能直接依赖 Data、Application 或 Platform 实现"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliAuth" \
    '^import (BiliAPI|BiliDanmaku|BiliPlayback|Bili[A-Za-z0-9_]*Feature|SwiftUI|AVFoundation|AVKit|AppKit|Network)$' \
    "BiliAuth 不能依赖 API、Playback 或 Presentation 实现"

check_forbidden_imports \
    "Packages/BiliKitCore/Sources/BiliDanmaku" \
    '^import (BiliAPI|BiliAuth|BiliNetworking|BiliPlayback|Bili[A-Za-z0-9_]*Feature|SwiftUI|AVFoundation|AVKit|Network)$' \
    "BiliDanmaku 只能依赖 Application/Models 与必要的系统渲染框架"

if grep -R -n -E --include='*.swift' '^import SwiftProtobuf$' \
    Packages/BiliKitCore/Sources \
    | grep -v '^Packages/BiliKitCore/Sources/BiliAPI/'; then
    echo "架构边界失败：只有 BiliAPI 可以依赖 SwiftProtobuf wire runtime" >&2
    exit 1
fi

echo "架构依赖边界检查通过"

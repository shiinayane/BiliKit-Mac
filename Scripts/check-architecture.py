"""按目录白名单检查 Swift import，固定 ARCHITECTURE「模块与依赖方向」里的边界。

在仓库根运行，由 run-quality-gates.sh 的 static 阶段调用。每个 Swift 文件按所在目录匹配
`SCOPES` 里最长的前缀，只能 import 该范围白名单里的模块；`EXTRA_ALLOWED` 给单个文件放行
额外模块，`SUBTREE_DENIED` 在范围内的子目录再收紧，`@_exported` 只允许 `EXPORTED_ALLOWED` 登记的
文件。文件清单来自 git（含尚未暂存的新文件），不在任何范围里的 Swift 文件直接失败，新增 target、
App 目录或源码根时必须先在这里写明它能依赖什么；登记的前缀或文件不存在同样失败，避免改名后
规则静默失效。注释与字符串内容先被遮蔽，不会被当成 import。

同一构建产物目录里的 module 彼此可见：没有在 Package.swift 声明依赖的 Bili 模块照样能 import，
SwiftPM 的 `--explicit-target-dependency-import-check` 在当前构建后端下也不拦截。因此 Bili 模块
之间的方向、系统框架，以及 App target 内各目录（同属一个 module，编译器不区分）都由这里检查。
"""

import os
import re
import sys

import swift_source

# 任何范围都可以使用的标准库与并发基础设施。
BASE = {"Foundation", "Synchronization", "os", "Darwin", "Dispatch"}
# Feature 经 BiliVideoCollectionUI 渲染共享的 AppKit 卡片与网格；只有 APPKIT_FEATURES 登记的 Feature
# 直接 import AppKit 等界面框架。
FEATURE_SHARED = {
    "BiliModels", "BiliApplication", "BiliUI", "BiliVideoCollectionUI", "SwiftUI", "Observation", "CoreGraphics",
}
FEATURES = {"BiliAuthFeature", "BiliBrowseFeature", "BiliLibraryFeature", "BiliVideoDetailFeature"}
# 只有渲染共享卡片网格或横排的 Feature 才依赖 BiliVideoCollectionUI。
COLLECTION_FEATURES = {"BiliBrowseFeature", "BiliLibraryFeature", "BiliVideoDetailFeature"}
# 自己拥有 AppKit 视图的 Feature 与它直接 import 的界面框架：播放页的侧栏、评论（正文排版用 CoreText）、
# 评论图片预览（动图逐帧解码用 ImageIO）、相关推荐横排与 UP 主空间列表是本 Feature 的原生集合视图。
# 播放、网络与 adapter 仍然禁止：下载、来源与响应校验、首帧解码、动图播放门槛和缓存只在 App 管线（经 port
# 注入），本 Feature 只对管线按门槛放行的动图数据逐帧解码播放。
APPKIT_FEATURES = {"BiliVideoDetailFeature": {"AppKit", "CoreText", "ImageIO"}}
ADAPTERS = {"BiliAPI", "BiliAuth", "BiliNetworking", "BiliPlayback", "BiliDanmaku"}

SOURCES = "Packages/BiliKitCore/Sources"

# 范围 -> (允许的模块, 违反时的说明)；允许的模块为 None 表示不设白名单。
# 除 EXACT_SCOPES 外，允许的模块都再加上 BASE。
SCOPES = {
    f"{SOURCES}/BiliModels": (
        set(),
        "BiliModels 只依赖标准库",
    ),
    f"{SOURCES}/BiliApplication": (
        {"BiliModels"},
        "BiliApplication 只能依赖 BiliModels 与标准库",
    ),
    f"{SOURCES}/BiliNetworking": (
        set(),
        "BiliNetworking 只提供无业务语义、无秘密存储的传输边界",
    ),
    f"{SOURCES}/BiliAPI": (
        {"BiliModels", "BiliApplication", "BiliNetworking", "CryptoKit", "SwiftProtobuf"},
        "BiliAPI 只依赖 Application/Models/Networking；SwiftProtobuf 只允许出现在这里",
    ),
    f"{SOURCES}/BiliAuth": (
        {"BiliModels", "BiliApplication", "BiliNetworking", "Security", "CoreGraphics", "CoreImage"},
        "BiliAuth 不能依赖 API、Playback 或界面框架",
    ),
    f"{SOURCES}/BiliPlayback": (
        {
            "BiliModels", "BiliApplication", "BiliNetworking",
            "AVFoundation", "Network",
        },
        "BiliPlayback 不能依赖 API、Auth 或界面框架",
    ),
    f"{SOURCES}/BiliDanmaku": (
        {"BiliModels", "BiliApplication", "AppKit", "QuartzCore", "CoreText", "CoreGraphics", "Accelerate"},
        "BiliDanmaku 只能依赖 Application/Models 与必要的系统渲染框架",
    ),
    f"{SOURCES}/BiliUI": (
        {"Foundation", "SwiftUI", "BiliApplication"},
        "BiliUI 只能依赖 Foundation、SwiftUI 与 BiliApplication，不依赖 AppKit 或 Feature",
    ),
    f"{SOURCES}/BiliVideoCollectionUI": (
        {"BiliUI", "AppKit", "QuartzCore", "CoreText", "CoreGraphics", "SwiftUI"},
        "BiliVideoCollectionUI 是共享的 AppKit 卡片与网格，只依赖 BiliUI 与界面框架；图片经 port 注入，不依赖网络或 adapter",
    ),
    **{
        f"{SOURCES}/{feature}": (
            (FEATURE_SHARED if feature in COLLECTION_FEATURES else FEATURE_SHARED - {"BiliVideoCollectionUI"})
            | APPKIT_FEATURES.get(feature, set()),
            "Feature 不能依赖 adapter、其他 Feature 或播放与网络框架；共享的 AppKit 卡片与网格只经 "
            "BiliVideoCollectionUI，且只有 COLLECTION_FEATURES 登记的 Feature 依赖它；只有 APPKIT_FEATURES "
            "登记的 Feature 直接 import AppKit 与登记的界面框架",
        )
        for feature in sorted(FEATURES)
    },
    "BiliKitMac/App": (
        FEATURES | {"SwiftUI", "Observation", "Combine"},
        "App 壳只组织 Feature 视图，不直接依赖 adapter 或平台框架；Application 只在 EXTRA_ALLOWED 登记的搜索条件或账户投影的使用点",
    ),
    "BiliKitMac/Navigation": (
        FEATURES | {"BiliModels", "BiliApplication", "Observation"},
        "Navigation 是窗口内的导航协调、来源描述、复核汇总与链接执行，只组织 Feature 模型、实体与账户投影，不依赖 adapter、界面或平台框架",
    ),
    "BiliKitMac/Composition": (
        FEATURES | ADAPTERS | {
            "BiliModels", "BiliApplication", "SwiftUI", "Observation", "AppKit", "AVFoundation", "CoreGraphics",
        },
        "Composition 是唯一组装具体 adapter 的目录",
    ),
    "BiliKitMac/Platform": (
        FEATURES | {
            "BiliModels", "BiliApplication", "BiliUI", "SwiftUI", "Combine", "AppKit", "CoreFoundation",
            "CoreGraphics", "ImageIO",
        },
        "Platform 不能依赖 BiliAPI/BiliAuth；共享集合视图支撑、播放、弹幕、网络、系统媒体与更新框架只允许在 "
        "EXTRA_ALLOWED 登记的宿主文件里",
    ),
    "BiliKitMac/Settings": (
        {"BiliApplication", "BiliAPI", "BiliPlayback", "SwiftUI", "Observation"},
        "Settings 只依赖设置所需的 Application、API 与 Playback 类型",
    ),
    "BiliKitMac/Localization": (
        set(),
        "Localization 只依赖标准库",
    ),
    # 测试与包清单可以 import 被测 target 与任意系统框架，只受 SUBTREE_DENIED 约束。
    "Packages/BiliKitCore/Tests": (None, ""),
    "Packages/BiliKitCore/Package.swift": (None, ""),
    "BiliKitMacTests": (None, ""),
}

# 单个文件额外允许的模块：每一项都是有明确理由的宿主或适配点。
EXTRA_ALLOWED = {
    # App 壳里搜索、稍后再看与收藏夹条件或账户投影（会话 scope、账户呈现状态）的使用点：搜索与稍后再看工具栏的排序与
    # 筛选、收藏夹的排序（SearchToolbarControls、WatchLaterToolbarControls、FavoritesToolbarControls；搜索与稍后再看共用的时长档标题与日期筛选错误文案在
    # SearchToolbarControls，三者共用的菜单、按钮与弹窗外壳在不依赖 Application 的 ToolbarFilterControls）、搜索提交后的回顶（AppShellView），侧栏账号行与收藏夹列表按账户范围对齐（AppSidebarViews）、资料库来源
    # 的登录门槛（AppSourceRootViews）；AppRootView、AppShellView 读取账户 scope。窗口组装 WindowComposition
    # 在 Composition/，那里本就允许 Application。
    # MemberImportVisibility 下成员只对直接 import 定义模块的文件可见，经 Feature 转出类型名不够用，
    # 在 Feature 镜像一份又违反“同一逻辑只写一处”。
    # AppShellView 持有各来源网格的滚动位置与回顶请求，并与图片管线一起构造 BiliVideoCollectionUI 的
    # `NativeVideoGridHostContext`，AppSourceRootViews 把它转交给 Feature；AppShellView 还把图片管线作为
    # `NativeVideoImageLoading` 传给播放页的相关推荐横排。网格与横排本身在 Feature 里，App 壳其余文件不接触
    # AppKit 集合视图。
    "BiliKitMac/App/AppRootView.swift": {"BiliApplication"},
    # AppShellView 还把窗口的账户写入协调者包成 BiliUI 的卡片写入口（`VideoCardAccountWriting`，经环境交给各来源的卡片
    # 菜单），并宿主 BiliUI 的写入结果胶囊（`AccountWriteStatusCapsule`）。
    "BiliKitMac/App/AppShellView.swift": {"BiliApplication", "BiliUI", "BiliVideoCollectionUI"},
    "BiliKitMac/App/AppSidebarViews.swift": {"BiliApplication"},
    "BiliKitMac/App/AppSourceRootViews.swift": {"BiliApplication", "BiliVideoCollectionUI"},
    "BiliKitMac/App/SearchToolbarControls.swift": {"BiliApplication"},
    "BiliKitMac/App/WatchLaterToolbarControls.swift": {"BiliApplication"},
    "BiliKitMac/App/FavoritesToolbarControls.swift": {"BiliApplication"},
    # 观看进度连接、播放器宿主与网格、侧栏共用同一份通知观察集合（NativeVideoNotificationObservers）；
    # 图片管线在 NativeVideoImageLoadingPorts 实现卡片取图 port（NativeVideoImageLoading）；侧栏账号头像
    # （AccountAvatarImage）的 SwiftUI 淡入与评论图片预览共用 NativeImageFadeTransition；同一文件还实现弹幕关联视频
    # 卡片的取封面 port（DanmakuCoverImageLoading）。
    "BiliKitMac/Composition/WatchProgressWindowConnection.swift": {"BiliVideoCollectionUI"},
    "BiliKitMac/Platform/AccountAvatarImage.swift": {"BiliVideoCollectionUI"},
    "BiliKitMac/Platform/AppUpdater.swift": {"Sparkle"},
    # 弹幕 overlay 按播放 item 换绑时钟，并把 renderer 的 layer 挂在时钟层下；时钟层由 item timebase 的
    # 通知在后台队列上驱动，弹幕动画随它运行。
    "BiliKitMac/Platform/DanmakuOverlayView.swift": {"AVFoundation", "BiliDanmaku"},
    "BiliKitMac/Platform/DanmakuTimebaseClock.swift": {"CoreMedia", "QuartzCore"},
    "BiliKitMac/Platform/NativeVideoImageLoadingPorts.swift": {"BiliDanmaku", "BiliVideoCollectionUI"},
    "BiliKitMac/Platform/NativeVideoImagePipeline.swift": {"BiliNetworking"},
    "BiliKitMac/Platform/PlaybackPreferencesController.swift": {"AVFoundation"},
    # 加载时按网络是否昂贵或受限决定能否加入 HDR 档（NWPathMonitor）。
    "BiliKitMac/Platform/PlaybackHDREnvironment.swift": {"Network"},
    # 播放器动作菜单的「拷贝链接」与卡片菜单共用 BiliVideoCollectionUI 的剪贴板写法（VideoLinkPasteboard）。
    "BiliKitMac/Platform/PlayerActionMenu.swift": {"BiliVideoCollectionUI"},
    "BiliKitMac/Platform/PlayerHostView.swift": {"AVKit", "BiliDanmaku", "BiliPlayback", "BiliVideoCollectionUI"},
    "BiliKitMac/Platform/PlayerKeyboardShortcutController.swift": {"BiliPlayback"},
    "BiliKitMac/Platform/PlayerOverlay.swift": {"AVFoundation", "BiliPlayback"},
    # 窗口播放器子类拦截 seek 入口，供播放器浮层判断画面是否还停在旧位置。
    "BiliKitMac/Platform/SeekTrackingPlayer.swift": {"AVFoundation"},
    "BiliKitMac/Platform/SystemNowPlayingController.swift": {"MediaPlayer"},
    # 测速结果的数字按界面语言格式化，locale 取 BiliUI 的 `InterfaceLocale`（见 ARCHITECTURE「分发」格式化 locale 一条）。
    "BiliKitMac/Settings/PlaybackSourceSettingsView.swift": {"BiliUI"},
}

# 范围内子目录再禁止的模块：纯逻辑部分不得碰播放或渲染框架。
SUBTREE_DENIED = {
    "Packages/BiliKitCore/Tests": (
        {"Sparkle"},
        "Sparkle 只属于 App target，Package 测试不链接它",
    ),
    f"{SOURCES}/BiliPlayback/Bridge": (
        {"AVFoundation"},
        "DASH→HLS bridge 与 loopback 是不可信输入与本地服务器边界，不依赖 AVFoundation",
    ),
    f"{SOURCES}/BiliPlayback/MediaIndex": (
        {"AVFoundation"},
        "媒体索引解析是纯逻辑，不依赖 AVFoundation",
    ),
    f"{SOURCES}/BiliPlayback/CDN": (
        {"AVFoundation"},
        "线路偏好与测速是纯逻辑，不依赖 AVFoundation",
    ),
    f"{SOURCES}/BiliDanmaku/Session": (
        {"AppKit", "QuartzCore", "CoreText", "Accelerate"},
        "弹幕会话是纯逻辑，渲染框架只在 Rendering/",
    ),
    f"{SOURCES}/BiliDanmaku/Layout": (
        {"AppKit", "QuartzCore", "CoreText", "Accelerate"},
        "车道布局是纯逻辑，渲染框架只在 Rendering/",
    ),
    f"{SOURCES}/BiliDanmaku/Presentation": (
        {"AppKit", "QuartzCore", "CoreText", "Accelerate"},
        "呈现与对齐是纯逻辑，渲染框架只在 Rendering/",
    ),
}

# 白名单不叠加 BASE 的范围。
EXACT_SCOPES = {f"{SOURCES}/BiliUI"}

# 允许 `@_exported import` 的文件与模块：转出的模块会出现在所有 import 该 target 的文件里，
# 绕过它们自己的白名单，所以每一处都要登记。
EXPORTED_ALLOWED: dict[str, set[str]] = {}

# 任意属性（含带括号参数的 `@_spi(X)`）、访问级别、kind import（`import class M.T`）、
# clang 子模块（`import M.Sub`）与反引号模块名都归到第一段模块名。
IMPORT = re.compile(
    r"^\s*((?:@[A-Za-z_]\w*(?:\((?:[^()]|\([^()]*\))*\))?\s*)*)"
    r"(?:(?:public|package|internal|fileprivate|private)\s+)?"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func|actor)\s+)?"
    r"`?([A-Za-z_]\w*)"
)


def scope_for(path):
    matches = [prefix for prefix in SCOPES if path == prefix or path.startswith(prefix + "/")]
    return max(matches, key=len) if matches else None


def imports(path):
    """逐个 import 语句产出 (行号, 模块, 是否 @_exported)；同一行用分号分隔的语句分别计入。"""
    masked, _ = swift_source.mask(swift_source.read(path), keep_strings=False)
    for number, line in enumerate(masked.split("\n"), start=1):
        for statement in line.split(";"):
            match = IMPORT.match(statement)
            if match is not None:
                yield number, match.group(2), "@_exported" in match.group(1)


def registration_failures():
    for prefix in list(SCOPES) + list(SUBTREE_DENIED):
        if not os.path.exists(prefix):
            yield f"{prefix}: 登记的范围不存在，改名后同步更新或删除这一项"
    for path in list(EXTRA_ALLOWED) + list(EXPORTED_ALLOWED):
        if not os.path.isfile(path):
            yield f"{path}: 登记的文件不存在，删除这一项"


def failures():
    yield from registration_failures()
    for path in swift_source.swift_files():
        scope = scope_for(path)
        if scope is None:
            yield f"{path}: 所在目录没有登记依赖白名单（Scripts/check-architecture.py 的 SCOPES）"
            continue
        allowed, reason = SCOPES[scope]
        if allowed is not None:
            base = set() if scope in EXACT_SCOPES else BASE
            allowed = base | allowed | EXTRA_ALLOWED.get(path, set())
        denied = [
            (modules, why)
            for prefix, (modules, why) in SUBTREE_DENIED.items()
            if path.startswith(prefix + "/")
        ]
        for number, module, exported in imports(path):
            if allowed is not None and module not in allowed:
                yield f"{path}:{number}: import {module} — {reason}"
            for modules, why in denied:
                if module in modules:
                    yield f"{path}:{number}: import {module} — {why}"
            if exported and module not in EXPORTED_ALLOWED.get(path, set()):
                yield f"{path}:{number}: @_exported import {module} 未在 EXPORTED_ALLOWED 登记"


def main():
    found = list(failures())
    for failure in found:
        print(f"架构边界失败：{failure}", file=sys.stderr)
    if found:
        return 1
    print("架构依赖边界检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

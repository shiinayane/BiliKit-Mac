# BiliKit macOS 客户端

BiliKit 是一个处于早期阶段、原生且非官方的 macOS B 站客户端。项目优先关注可靠播放、克制的浏览体验，以及符合 Mac 使用习惯的交互方式。

> BiliKit 是第三方项目，与哔哩哔哩不存在隶属、认可或赞助关系。哔哩哔哩相关名称与商标归其权利人所有。

## 当前状态

M1 播放可行性、M2 游客浏览播放闭环、M2.5 架构整理、M3 登录/观看历史、M4
播放器／字幕／弹幕纵向链路，以及 M4.5–M4.8 的日用两栏界面和工程收口已经完成。
当前进入 M5 日常观看核心闭环；个性推荐首页、相关推荐和可分发版本尚未实现，项目
仍不适合分发。

- 最低系统版本：macOS 15
- 开发语言：Swift 6
- 界面技术：SwiftUI，按需桥接 AppKit/AVKit
- 播放路线：AVPlayer-first，自有 clean-room DASH→HLS bridge
- 许可证：MIT

当前里程碑和验收门槛见[路线图](docs/ROADMAP.md)，产品与技术证据见[研究基线](docs/RESEARCH-native-macos-client.md)。

## 仓库结构

```text
BiliKitMac/                 App 入口、Composition Root、平台宿主与资源
Packages/BiliKitCore/       包含核心模块的本地 Swift Package
BiliKitMacTests/            App composition 集成测试
docs/                       路线图、ADR、验证记录与研究资料
references/                 完全忽略的本地参考项目，不进入 Xcode 工程
```

当前 Package 模块：

- `BiliModels`：Domain entity 与稳定的跨模块值类型。
- `BiliApplication`：游客 Use Case、Repository/Playback port、非秘密认证状态与用户意图 port。
- `BiliNetworking`：传输抽象、无业务语义的请求授权协议、重定向策略、严格 Range 校验、CDN fallback、取消传播和日志脱敏。
- `BiliAuth`：Web QR 状态机、版本化凭据、Data Protection Keychain adapter、精确请求授权器与认证专用 ephemeral transport。
- `BiliAuthFeature`：Authentication 子功能，包含账号 sheet、内存二维码展示与拥有轮询 Task/代次的认证 ViewModel。
- `BiliLibraryFeature`：Library 产品域；当前包含只读观看历史及分页、取消、旧结果隔离和内存清理。
- `BiliAPI`：游客/观看历史/字幕/弹幕 endpoint、DTO/protobuf 映射、WBI 签名与 Repository adapter；只有该模块依赖 SwiftProtobuf wire runtime。
- `BiliPlayback`：SIDX、DASH→HLS、loopback 媒体代理和播放 adapter。
- `BiliDanmaku`：只消费 Application/Models 类型和统一播放时间轴的分段预取、去重、过滤与调度内核；renderer 留给 M4.4。
- `BiliUI`：仅供 Package 内 Feature 复用的无业务视频卡片与网格布局，不公开为 library product。
- `BiliBrowseFeature`：Browse 产品域，按 BrowseScene、Feed、Search、VideoDetail 组织 SwiftUI View 与 ViewModel。

依赖方向和模型分类见 [ADR 0004](docs/adr/0004-mvvm-clean-architecture.md)，Feature target 准入与产品域命名见 [ADR 0006](docs/adr/0006-product-domain-feature-targets.md)，窄视频卡片复用边界见 [ADR 0009](docs/adr/0009-narrow-biliui-video-card-boundary.md)。CI 会运行架构、秘密与工程静态契约检查，阻止分层反向依赖，并固定 entitlement、产品命名和 macOS 15 基线。

## 构建

以下命令关闭代码签名，并将 Derived Data 放在仓库之外：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project BiliKitMac.xcodeproj \
  -scheme BiliKitMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/BiliKitMac-derived \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

单独运行 Package 测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/BiliKitCore
```

不同机器的 active developer directory 可能不同。日常开发仍建议直接在 Xcode 中打开 `BiliKitMac.xcodeproj`。

签名 Keychain smoke 需要本机可用的 Apple Development 身份和自动签名 provisioning profile。它使用独立测试 service/account，并在前后清理测试项：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project BiliKitMac.xcodeproj \
  -scheme BiliKitMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/BiliKitMac-keychain-smoke \
  test \
  -only-testing:BiliKitMacTests/SignedKeychainSmokeTests
```

没有 Team ID 的未签名或临时签名宿主会明确跳过此用例，不能把该结果当作真实 Data Protection Keychain 证据。

历史真实网络、登录、播放和弹幕观察保留在 `docs/validation/`；这些记录不是当前可执行
runner，也不能替代当前 App 的受控人工验证。

## 安全与实现边界

- Cookie 和 token 只能进入 Keychain 与内存。
- 不得将凭据写入 fixture、日志、UserDefaults、SwiftData 或崩溃报告。
- 社区 API 来自逆向分析，必须按可替换、可测试、可能失败的外部依赖处理。
- 可以研究 GPL 项目的公开行为和数据格式，但不得把其源码、注释、fixture 或资产复制进本 MIT 仓库。
- v1 明确不包含下载、直播、投稿、私信、多账号和区域限制绕过。

第三方依赖声明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

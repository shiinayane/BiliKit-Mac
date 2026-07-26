# 原生 macOS B 站客户端研究摘要

> 研究时间：2026-07-21。本文是立项期的历史研究材料，只用于解释竞品、播放机制、许可
> 和分发判断。当前产品范围、模块、导航和实施顺序分别以代码、ADR、产品文档和
> [`ROADMAP.md`](./ROADMAP.md) 为准。

## 1. 证据边界

研究优先使用 Apple 官方文档、项目许可证、工程配置和源码；README、release 与提交用于
补充项目状态；社区 API 文档和第三方实现只作为发现线索。

以下结论是 2026-07-21 的快照。仓库活跃度、API、平台支持和许可可能变化，复用前必须
重新核对。第三方项目只用于理解公开行为和机制，不是 BiliKit 的代码、fixture 或资产来源。

## 2. 项目对比

| 项目 | 平台/技术 | 研究价值 | 主要边界 |
| --- | --- | --- | --- |
| [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) | Flutter、多平台、mpv/media_kit | 功能/API 覆盖、异常与降级场景 | 不是原生 SwiftUI；GPL-3.0 |
| [wiliwili](https://github.com/xfangfang/wiliwili) | C++、mpv、macOS/Windows/Linux/主机 | 桌面播放、输入、硬解和 CDN 容错 | UI/播放器栈不同；GPL-3.0 |
| [Darock-Bili](https://github.com/Darock-Studio/Darock-Bili) | Swift，主要面向 iOS/watchOS/visionOS | Swift API 与 Apple 平台页面参考 | 不是现成 macOS 底座；GPL-3.0 |
| [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) | Swift/UIKit/tvOS、AVPlayer | DASH→HLS、SIDX、字幕与分段弹幕机制 | tvOS/UIKit；GPL-2.0 |
| [旧 Bilimac](https://github.com/typcn/bilibili-mac-client) | Objective-C/AppKit、mpv/libass | Mac-first 窗口与播放器产品历史 | 2018 年后未维护；GPL-3.0 |
| [AnimacX](https://github.com/AnimacX/AnimacX) | 原生 macOS/tvOS/iOS 播放器 | macOS 番剧产品和资料管理体验 | 不是完整开放源码底座；限制性许可 |
| [Bili.Mac.MenuBar](https://github.com/Richasy/Bili.Mac.MenuBar) | SwiftUI 菜单栏工具 | 轻量 macOS 入口与扫码形态 | 非完整播放器、停止维护；MIT |
| [Bili-Swift](https://github.com/zhihaofans/Bili-Swift) | SwiftUI | 小型 SwiftUI 客户端组织 | 已移除 macOS；未发现明确许可 |
| [cilicili](https://github.com/Rone89/cilicili) | Swift 6、SwiftUI、AVPlayer | 较新的 HLS bridge 与 Keychain 思路 | iOS-only；GPL-3.0-only |

客户端汇总项目
[oldsento/bilibili-client-software-collection](https://github.com/oldsento/bilibili-client-software-collection)
适合发现候选，但它是手工维护清单，平台标签和完整性不能替代二次核验。

## 3. 对 BiliKit 仍有价值的结论

### 原生 Mac 产品

当时活跃项目通常至少缺少一项：原生 Mac UI、现代 Swift 实现、可审计源码或持续维护。
BiliKit 的差异化应来自克制的原生窗口/导航体验、稳定可诊断的播放、清晰的资源边界和
安全登录，而不是复制移动端的功能数量。

侧栏、主内容、同窗口播放页、键盘和辅助功能应优先使用平台能力。独立播放窗口、
mini player、画中画、拖放和完整媒体键只有在核心观看闭环稳定后再评估。

### API 与认证

- 每个 endpoint 使用独立 DTO，在 adapter 边界映射为 Domain/Application 类型。
- Web API、App API 和 protobuf/gRPC 是不同认证与数据边界，不能用一个万能模型混合。
- 未公开 API 可能返回 HTML 风控页、未知状态、异常重定向和缺失字段，默认失败关闭。
- Web Cookie 与 App token 是不同凭据；不能假设一次登录覆盖全部 endpoint。
- Cookie/token 进入 Keychain，普通偏好才进入 UserDefaults；登出同时清理秘密、内存与
  相关会话。

这些原则已经由当前 ADR、安全文档和代码细化；本文不再描述 target 或 owner。

### AVPlayer 与 DASH

Apple 的 [`AVPlayer`](https://developer.apple.com/documentation/avfoundation/avplayer)
原生消费 HLS，而 B 站点播常返回音视频分离的 DASH。ATV-Bilibili-demo 提供的可研究机制
包括：

1. 从 `SegmentBase`/SIDX 字节范围构建 HLS master/media playlist；
2. 用自定义 URL scheme 和 `AVAssetResourceLoader` 把请求映射为 CDN Range；
3. 分别处理视频与音频轨，并保持时间轴一致；
4. 在 SIDX 和后续媒体分段间保持已成功 CDN 的一致性；
5. 弹幕按播放时间分段预取，seek 后重置时间游标。

这些机制必须依据 Apple 文档、自制测试媒体和本项目测试 clean-room 实现。当前生产实现
和安全边界以 ADR 0002、代码及播放验证记录为准。

### 弹幕

弹幕适合拆为 decoder、分段 scheduler、filter/dedup/lane allocator 和 renderer。渲染
使用 Core Animation 或有界 `NSView` 复用，避免让每条弹幕成为长生命周期 SwiftUI View。
必须验证暂停、倍速、前后 seek、窗口变化、旧 identity 隔离和资源上限。

## 4. 许可、品牌与分发

BiliKit 使用 MIT，但这只授权本项目自己的代码。研究过的 GPL 或限制性许可项目不能直接
复制源码、注释、fixture、图标或其他资产：

- GPL-3.0：PiliPlus、wiliwili、Darock-Bili、旧 Bilimac、cilicili。
- GPL-2.0：ATV-Bilibili-demo。
- MIT：Bili.Mac.MenuBar。
- 限制性许可：AnimacX。
- 未发现明确许可：Bili-Swift，默认不可复制。

“clean-room”是工程纪律，不是法律意见。若以后直接派生 GPL 项目，需要接受对应源码开放
和分发义务并重新评估许可证。

App 名称、图标、bundle metadata 和宣传材料必须明确“第三方、非官方”，不得使用会让
用户误认为官方客户端的资产。Apple
[App Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/)
对第三方服务内容、商标、流媒体和下载授权有额外要求，因此不能默认承诺 Mac App Store
上架。直接分发也不免除服务条款、商标和版权责任。

## 5. 原始资料索引

### 重点源码与许可证

- [PiliPlus README](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/README.md)
  与 [GPL-3.0](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/LICENSE)
- [wiliwili README](https://github.com/xfangfang/wiliwili/blob/yoga/README.md)
  与 [GPL-3.0](https://github.com/xfangfang/wiliwili/blob/yoga/LICENSE)
- [Darock-Bili 工程配置](https://github.com/Darock-Studio/Darock-Bili/blob/60d66761e34339f7ff1e6d6a2a336f88216c4689/DarockBili.xcodeproj/project.pbxproj)
- [ATV-Bilibili-demo 播放实现](https://github.com/yichengchen/ATV-Bilibili-demo/tree/86ba6f5bb9d6860cb47522a037ef02ab43a4ad55/BilibiliLive/Component/Player)
  与 [GPL-2.0](https://github.com/yichengchen/ATV-Bilibili-demo/blob/main/LICENSE.md)
- [旧 Bilimac README](https://github.com/typcn/bilibili-mac-client/blob/master/README.md)
- [AnimacX 许可](https://github.com/AnimacX/AnimacX/blob/main/LICENSE)
- [Bili.Mac.MenuBar](https://github.com/Richasy/Bili.Mac.MenuBar)
- [cilicili](https://github.com/Rone89/cilicili)

### Apple 官方资料

- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)
- [HTTP Live Streaming](https://developer.apple.com/documentation/HTTP-Live-Streaming)
- [AVAssetResourceLoader](https://developer.apple.com/documentation/avfoundation/avurlasset/resourceloader)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services/)
- [TN3154：采用 NavigationSplitView](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### 社区接口资料

- [SocialSisterYi/bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [Bilibili-Gate](https://github.com/magicdawn/Bilibili-Gate)
- [BBDown](https://github.com/nilaoda/BBDown)

社区接口资料只用于发现端点和字段，不能代替当前响应、负向处理、fixture 与真实 probe。

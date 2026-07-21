# SwiftUI 原生 macOS B 站客户端：竞品、技术路线与 AI 接手基线

> 状态：立项前研究基线，不是最终产品规格。
>
> 最近核验：2026-07-21（Asia/Tokyo）。仓库活跃度、分支、许可和平台支持会变化；继续开发前应按本文的“复核协议”重新检查动态事实。
>
> 当前载体：[shiinayane/BiliKit](https://github.com/shiinayane/BiliKit)。正式客户端应另开仓库；本文适合复制到新仓库的 `docs/research/`，作为后续 AI/开发者的入口文档。

## 0. 给下一位 AI 的一分钟摘要

### 项目目标

做一个 **SwiftUI 驱动、macOS-first、真正遵循 Mac 使用习惯** 的第三方 B 站浏览与播放客户端，而不是把移动端 Flutter 页面搬到桌面，也不是一开始追求复刻 B 站所有社交功能。

推荐的产品表述：

> 一个安静、键盘友好、播放可靠的原生 Mac B 站浏览器与播放器。

### 当前结论

1. 市场空位真实存在：活跃且功能全面的项目主要是 Flutter/C++；Swift 项目主要集中于 iOS、watchOS、tvOS。尚未发现成熟、活跃、macOS-first、以 SwiftUI 为主的完整客户端。
2. 最值得参考的项目不是一个，而是四类：
   - [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：功能/API 百科。
   - [wiliwili](https://github.com/xfangfang/wiliwili)：桌面播放器、CDN 和输入体验。
   - [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)：Apple 平台 DASH→HLS、AVPlayer、弹幕分段机制。
   - [typcn/bilibili-mac-client](https://github.com/typcn/bilibili-mac-client)：旧时代真正的 Mac 产品形态参考。
3. 技术路线建议：`SwiftUI + 必要的 AppKit/AVKit 桥接 + AVPlayer-first + 自己实现的 DASH→HLS bridge + Core Animation 弹幕层`。
4. 新仓库默认建议：repo 名 `BiliKit-Mac`，App 显示名 `BiliKit`，采用 MIT；只迁移当前 BiliKit 自己的 MIT 代码/算法。GPL 项目只研究机制，不复制代码。
5. MVP 只做：游客浏览、搜索、扫码登录、推荐/详情/分 P、可靠播放、基础弹幕/字幕、历史与稍后再看。下载、直播、投稿、私信、多账号、区域解锁暂不进入 v1。

### 不可擅自改变的边界

- 不要把新 Xcode 工程混进当前 userscript 仓库；单独开 repo。
- 不要直接复制 PiliPlus、wiliwili、Darock-Bili、ATV-Bilibili-demo、cilicili 或旧 Bilimac 的实现到 MIT 项目。
- 不要把社区逆向 API 当成稳定官方 SDK；端点、签名、字段和风控都必须可替换、可测试、可降级。
- 不要把 `SESSDATA`、`bili_jct`、`access_token`/`access_key` 放入 `UserDefaults`、SwiftData、日志或 crash report；使用 Keychain。
- 不要为了“功能完整”在 v1 加下载、投稿、直播和复杂社交写操作。
- 不要用成千上万个 SwiftUI `Text` 实例渲染滚动弹幕；播放器与弹幕都允许使用 AppKit/Core Animation。

---

## 1. 研究问题与证据规则

本轮主要回答五个问题：

1. 现有第三方 B 站客户端覆盖了哪些平台和产品形态？
2. Swift/Apple 平台项目做到什么程度，哪里仍有空位？
3. 原生 macOS 客户端最困难的技术环节是什么？
4. 哪些实现可以研究，哪些代码不能直接复用？
5. 新 repo 应如何定位、命名和拆 MVP？

本文按以下标签理解结论：

- **事实**：README、源码、工程配置、提交记录、许可证或 Apple 官方文档直接支持。
- **判断**：基于事实作出的工程/产品推断，可能需要原型验证。
- **建议**：当前推荐的实施方向，可以通过 ADR 在新仓库中修改。
- **待验证**：接口或运行行为会漂移，不能仅凭本文直接实现。

证据优先级：

1. Apple 官方文档、仓库内许可证、工程配置和源码。
2. 项目 README、release、commit。
3. 社区 API 文档和第三方实现。
4. 聚合清单、论坛帖、搜索结果只作为线索，不作为唯一证据。

---

## 2. 对客户端汇总仓库的评价

入口：[oldsento/bilibili-client-software-collection](https://github.com/oldsento/bilibili-client-software-collection)

### 它适合做什么

- 快速发现 Android、Android TV、PC、插件化播放器和历史项目。
- 观察社区当前最活跃的方向：Android/TV 客户端明显最多，跨平台客户端其次。
- 找 fork、存档项目和相互继承关系。

### 它不适合做什么

- 它是手工维护的 README 清单，不是可证明“收录全部客户端”的数据库。
- 分类明显偏 Android/TV；Apple 平台只零散列出手表或“多平台”项目。
- “多平台”“存档”“不能用”等标签粒度不统一，不能代替源码和工程配置核验。
- 不应根据清单缺失直接断言某个平台没有客户端。

截至 2026-07-21，清单仓库仍活跃，最近核到的提交是 [2026-07-09 更新 README](https://github.com/oldsento/bilibili-client-software-collection/commit/ad00ca02a1464206146c3adcac802bf9d0f10730)。因此它应作为持续发现入口，但每个候选必须二次核验。

---

## 3. 重点项目对比

| 项目 | 平台/技术 | 2026-07-21 状态快照 | 对新项目的价值 | 主要边界 |
| --- | --- | --- | --- | --- |
| [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) | Flutter/Dart，多平台；仓库含 `macos/`，播放器使用 `media_kit`/mpv 路线 | 活跃；当天仍有 [macOS 标题栏修复](https://github.com/bggRGjQaUbCoE/PiliPlus/commit/2d389424aff9a06a8df76d595e2fc362be3f4df3) | 功能/API 覆盖最完整，适合列功能表、找请求流程和异常情形 | README 的平台勾选未列 macOS，但源码和提交实际维护 Mac；Mac 仍不是原生 SwiftUI。GPL-3.0 |
| [wiliwili](https://github.com/xfangfang/wiliwili) | C++、mpv、自定义 UI；macOS/Windows/Linux/主机 | 活跃发布线，最新核到 `v1.6.0` 提交（2026-04-25） | 桌面播放、硬解、键鼠/手柄输入、CDN、跨平台容错 | UI/播放器栈与 SwiftUI 差异大。GPL-3.0 |
| [Darock-Bili / 喵哩喵哩](https://github.com/Darock-Studio/Darock-Bili) | Swift 原生，主要为 iOS/watchOS/visionOS 方向 | 活跃；最近核到 2026-06-28 提交 | Swift API 调用、Apple 平台页面与登录形态参考 | README 写“跨平台”，但 [工程配置](https://github.com/Darock-Studio/Darock-Bili/blob/60d66761e34339f7ff1e6d6a2a336f88216c4689/DarockBili.xcodeproj/project.pbxproj) 显示现有 app target 重点并非 macOS。部分登录态放在 `@AppStorage` 的做法不应继承。GPL-3.0 |
| [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) | Swift/UIKit/tvOS、AVPlayer | 活跃；2026-07-05 仍在增强 DASH/CDN 播放 | 本轮最有价值的 Apple 播放机制参考；含 DASH→HLS、SIDX、字幕、弹幕分段、CDN 失败切换 | tvOS/UIKit，不是 macOS/SwiftUI；只能 clean-room 重做机制。GPL-2.0 |
| [typcn/bilibili-mac-client](https://github.com/typcn/bilibili-mac-client) | Objective-C/AppKit、mpv/libass | 最后提交 2018-09-30，历史项目 | 真正 Mac-first 的窗口、标签页、本地播放器、硬解、低 CPU 弹幕等产品历史 | API 和依赖老旧，不应作为现代代码底座。GPL-3.0 |
| [AnimacX](https://github.com/AnimacX/AnimacX) | 原生 macOS/tvOS/iOS 番剧与弹幕播放器；README 称自研 Metal 播放引擎 | 活跃；2026-07-20 更新 | macOS 14+ 原生番剧产品、播放/资料/资源管理 UX 参考 | 公共仓库主要是说明与发布信息，不是可审计的完整源码底座；自定义许可禁止未经书面同意修改、合并和二次发布 |
| [Bili.Mac.MenuBar](https://github.com/Richasy/Bili.Mac.MenuBar) | SwiftUI 菜单栏工具，TCA + Swinject | 最后提交 2022-09-15；作者明确不长期维护 | 原生 SwiftUI 菜单栏、扫码登录、动态/排行/番剧的轻量结构；MIT | 不是完整播放器，也不是持续维护底座 |
| [Bili-Swift](https://github.com/zhihaofans/Bili-Swift) | SwiftUI | 2025-12-10 最近提交标题为 [“取消macos”](https://github.com/zhihaofans/Bili-Swift/commit/e807ce7e77199fc652f196a8860ee3e1614f9328) | 可观察小型 SwiftUI 客户端组织方式 | 仓库描述仍可能提 macOS，但工程已经移除；未发现明确许可证，不应复用代码 |
| [cilicili](https://github.com/Rone89/cilicili) | Swift 6/SwiftUI、iOS 26.4+、AVPlayer HLS Bridge | 活跃；最近核到 2026-07-17 `v1.0.13` 提交 | 当前较新的 SwiftUI + Keychain + AVPlayer/HLS Bridge 思路参考 | 明确是 iOS 实验项目，不是 macOS；过高系统门槛不适合照搬。GPL-3.0-only |

### 3.1 PiliPlus：功能/API 百科，而非 UI 模板

**事实**：README 展示了推荐、动态、评论、私信、收藏、直播、离线缓存、多账号、互动视频、高级弹幕等非常大的功能面；依赖和源码中存在 `media_kit`，仓库也含 macOS 工程产物。

**最适合研究**：

- 一个“完整客户端”会碰到的功能和接口清单。
- 登录态、WBI、App API、gRPC、评论/动态等不同数据线如何并存。
- 播放设置、清晰度、编码、字幕、弹幕、SponsorBlock、CDN 等边缘场景。
- 请求失败时的产品降级逻辑。

**不建议照搬**：

- Flutter 页面布局与状态组织不是 Mac 原生体验的目标答案。
- 先复制其巨大功能面会让 MVP 失控。
- GPL-3.0 代码不能无条件并入拟采用 MIT 的新仓库。

关键原始链接：

- [README / 功能清单](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/README.md)
- [`pubspec.lock` / media_kit 证据](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/2d389424aff9a06a8df76d595e2fc362be3f4df3/pubspec.lock)
- [macOS Podfile.lock](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/2d389424aff9a06a8df76d595e2fc362be3f4df3/macos/Podfile.lock)
- [GPL-3.0 License](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/LICENSE)

### 3.2 wiliwili：桌面端可靠性与输入模型

**事实**：项目明确支持 macOS 10.11+、Windows、Linux 和多种主机；使用 mpv，强调硬件解码、键盘、鼠标、触屏和手柄。

**最适合研究**：

- 桌面窗口中播放器与列表的关系。
- 全屏、返回、快捷键、鼠标与手柄输入冲突如何处理。
- 老硬件、不同平台解码能力与清晰度降级。
- 网络诊断、CDN 选择、起播速度和失败重试的产品呈现。

**判断**：新项目不需要复制它的 C++ UI，但应把“播放失败可诊断、输入路径一致、低端设备可降级”当成同等级需求。

关键原始链接：

- [README](https://github.com/xfangfang/wiliwili/blob/yoga/README.md)
- [项目 Wiki](https://github.com/xfangfang/wiliwili/wiki)
- [GPL-3.0 License](https://github.com/xfangfang/wiliwili/blob/yoga/LICENSE)

### 3.3 Darock-Bili：Swift 原生参考，但不是现成 Mac 底座

**事实**：README 自称“跨平台的 Swift 原生 B 站客户端”，功能覆盖推荐、登录、下载、详情、评论、互动、用户页、搜索、收藏、稍后再看和动态。工程中的实际 target 支持需要以 `project.pbxproj` 为准，而不能只看 README 标签。

**最适合研究**：

- Swift 侧 API 请求和模型处理。
- iOS/watchOS 等不同 Apple 设备的功能裁剪。
- SwiftUI 页面如何承载 B 站复杂数据。

**风险**：

- 代码中可见大量弱类型 JSON 处理，新的 macOS 项目应优先使用 `Codable` 和端点级模型。
- 登录敏感字段不应通过 `@AppStorage`/UserDefaults 持久化。
- GPL-3.0。

关键原始链接：

- [README](https://github.com/Darock-Studio/Darock-Bili/blob/main/README.md)
- [Xcode 工程配置](https://github.com/Darock-Studio/Darock-Bili/blob/60d66761e34339f7ff1e6d6a2a336f88216c4689/DarockBili.xcodeproj/project.pbxproj)
- [GPL-3.0 License](https://github.com/Darock-Studio/Darock-Bili/blob/main/LICENSE)

### 3.4 ATV-Bilibili-demo：最重要的 Apple 播放机制样本

这个项目的价值不在 tvOS 界面，而在它如何让 AVPlayer 消费 B 站的 DASH 数据。

重点文件：

- [`BilibiliVideoResourceLoaderDelegate.swift`](https://github.com/yichengchen/ATV-Bilibili-demo/blob/86ba6f5bb9d6860cb47522a037ef02ab43a4ad55/BilibiliLive/Component/Player/BilibiliVideoResourceLoaderDelegate.swift)
- [`VideoDanmuProvider.swift`](https://github.com/yichengchen/ATV-Bilibili-demo/blob/86ba6f5bb9d6860cb47522a037ef02ab43a4ad55/BilibiliLive/Component/Video/VideoDanmuProvider.swift)
- [`VideoPlayerViewModel.swift`](https://github.com/yichengchen/ATV-Bilibili-demo/blob/86ba6f5bb9d6860cb47522a037ef02ab43a4ad55/BilibiliLive/Component/Video/VideoPlayerViewModel.swift)
- [`BVideoPlayPlugin.swift`](https://github.com/yichengchen/ATV-Bilibili-demo/blob/86ba6f5bb9d6860cb47522a037ef02ab43a4ad55/BilibiliLive/Component/Video/Plugins/BVideoPlayPlugin.swift)

从源码与 2026-07-05 提交可以确认的机制：

1. 从 B 站 DASH `SegmentBase`/SIDX 字节范围构建 HLS master/media playlist。
2. 用自定义 URL scheme 和 `AVAssetResourceLoaderDelegate` 把 AVPlayer 的资源请求映射回真实 CDN Range 请求。
3. 把独立视频/音频轨组合为 AVPlayer 可选择的播放清单，并处理字幕/HDR 等轨道信息。
4. SIDX 下载会尝试多个 CDN，media playlist 使用实际成功的 URL，避免只换一次 URL 后媒体分段仍指向坏线路。
5. 弹幕按时间分段加载，并在播放接近下一个分段前预取；seek 时需要重建时间游标，而不是继续沿旧游标吐弹幕。

**建议**：研究上述机制后，在新仓库依据 Apple 文档和自己的测试样本 clean-room 实现；不要复制 GPL-2.0 源码。

关键原始链接：

- [README](https://github.com/yichengchen/ATV-Bilibili-demo/blob/main/README.md)
- [2026-07-05 播放可靠性提交](https://github.com/yichengchen/ATV-Bilibili-demo/commit/86ba6f5bb9d6860cb47522a037ef02ab43a4ad55)
- [GPL-2.0 License](https://github.com/yichengchen/ATV-Bilibili-demo/blob/main/LICENSE.md)

### 3.5 旧 Bilimac：历史产品参考

旧客户端曾实现硬件解码、低 CPU 弹幕、多标签、本地播放、直播、下载、mpv 配置与 Lua 扩展。它证明“Mac 用户愿意使用独立桌面 B 站客户端”，也展示了 Mac 窗口化播放的旧范式。

它不适合作为现代底座：最后提交在 2018 年，API、Web 认证、构建依赖和系统安全模型都已变化。

关键原始链接：

- [README / 功能与历史性能数据](https://github.com/typcn/bilibili-mac-client/blob/master/README.md)
- [构建说明](https://github.com/typcn/bilibili-mac-client/blob/master/HOW_TO_BUILD.md)
- [GPL-3.0 License](https://github.com/typcn/bilibili-mac-client/blob/master/LICENSE)

### 3.6 其他 Swift/macOS 项目

- [AnimacX README](https://github.com/AnimacX/AnimacX/blob/main/README.md)：适合观察 macOS 14+ 番剧播放器如何串起本地播放、网络资源、弹幕、Bangumi 和资料管理；不应把其发布仓库误判为开放源码底座。其 [自定义许可证](https://github.com/AnimacX/AnimacX/blob/main/LICENSE) 明确限制修改、合并和二次发布。
- [Bili.Mac.MenuBar README](https://github.com/Richasy/Bili.Mac.MenuBar/blob/main/README.md)：作者明确说明是短期 SwiftUI 练手项目；其 [`AppCompose.swift`](https://github.com/Richasy/Bili.Mac.MenuBar/blob/9e2124fdb4fa110cd61e665fc077438ae5967a37/Bili.Mac.MenuBar/Compose/AppCompose.swift) 可观察 TCA/Swinject 组织。项目采用 [MIT](https://github.com/Richasy/Bili.Mac.MenuBar/blob/main/LICENSE)。
- [Bili-Swift 工程配置](https://github.com/zhihaofans/Bili-Swift/blob/e807ce7e77199fc652f196a8860ee3e1614f9328/Bili-Swift.xcodeproj/project.pbxproj)：不能因仓库简介含 macOS 就认为当前 target 仍支持 Mac；最近提交已经明确“取消macos”。未发现明确许可，默认不可复制。
- [cilicili README](https://github.com/Rone89/cilicili/blob/main/README.md)：较新的 Swift 6、SwiftUI、AVPlayer HLS Bridge、Keychain 实验，但只面向 iOS 26.4+；采用 [GPL-3.0-only](https://github.com/Rone89/cilicili/blob/main/LICENSE)。

---

## 4. 市场与产品定位判断

### 4.1 真正的机会

现有项目通常至少缺一项：

- 活跃，但不是原生 Mac UI（PiliPlus、wiliwili）。
- 原生 Swift，但主平台不是 macOS（Darock-Bili、ATV、cilicili）。
- 真正 Mac-first，但已经多年未维护（旧 Bilimac）。
- 原生且活跃，但不是完整可复用的开源 B 站客户端（AnimacX）。
- SwiftUI/macOS，但只是菜单栏小工具且不再维护（Bili.Mac.MenuBar）。

因此新项目最有差异化的不是“功能最多”，而是：

1. 原生窗口、菜单命令、快捷键和系统媒体集成。
2. 比网页更稳定、可诊断的播放与 CDN 切换。
3. 克制的内容浏览，不把移动端所有入口塞进侧栏。
4. 安全地保存登录态，并明确第三方/非官方身份。

### 4.2 推荐的信息架构

使用 `NavigationSplitView` 做三栏或两栏结构：

- Sidebar：首页、动态、收藏、稍后再看、历史。
- Content：卡片/列表，可键盘选择、多选和上下文菜单。
- Detail：视频详情、分 P、评论摘要；播放可在 detail、独立窗口和 mini player 之间迁移。

Mac 原生能力优先级：

- 菜单栏 Commands 与可发现快捷键。
- 独立播放器窗口、置顶 mini player、全屏与画中画。
- 系统媒体键、Now Playing、AirPlay（能力允许时）。
- 拖放 URL、复制 BV/AV/CID、系统分享。
- 恢复窗口位置、列表选择和播放进度。
- 完整键盘导航、VoiceOver 标签和 Reduce Motion。

Apple 的 [`NavigationSplitView` 技术说明](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view) 表明该 API 从 macOS 13 可用。综合开发成本、现代 API 与可持续运行验证，**当前决定最低 macOS 15**。原先的 macOS 14 建议已由 [ADR 0003](./adr/0003-raise-minimum-macos-to-15.md) 取代：项目没有对应实机，而 GitHub 的 macOS 14 runner 将于 2026-11-02 停止支持。

---

## 5. 推荐技术架构

```text
BiliKitMac
├── AppShell
│   ├── NavigationSplitView / WindowGroup / Settings
│   ├── Commands / Keyboard shortcuts / Deep links
│   └── Player window / Mini player / Restoration
├── BiliAPI
│   ├── HTTPClient actor
│   ├── WebAPI + WbiSigner
│   ├── AppAPI + AppSigner
│   ├── Endpoint-specific Codable models
│   └── Fixtures + contract tests
├── Auth
│   ├── WebQRCodeSession
│   ├── TVQRCodeSession (later milestone)
│   └── KeychainCredentialStore
├── Playback
│   ├── PlayerEngine protocol
│   ├── AVPlayerEngine
│   ├── DASHToHLSBridge
│   ├── ResourceLoader
│   └── CDNSelector / Diagnostics
├── Danmaku
│   ├── Protobuf decoder
│   ├── Segment scheduler
│   ├── Filter / dedup / lane allocator
│   └── Core Animation or NSView renderer
└── Persistence
    ├── SwiftData: cache, history, shown-BVID set
    ├── UserDefaults: non-sensitive preferences
    └── Keychain: cookies and tokens
```

### 5.1 UI 层

- SwiftUI 负责窗口壳、导航、列表、详情、设置和普通交互。
- `AVPlayerView` 用 `NSViewRepresentable` 桥接；Apple 官方把 macOS 的 [`AVPlayerView`](https://developer.apple.com/documentation/avfoundation/avplayer) 作为完整播放呈现方式。
- 必要时使用 `NSWindow`, `NSMenu`, `NSVisualEffectView`, `NSViewControllerRepresentable`，不把“100% SwiftUI”当教条。
- 状态使用 Swift Observation；异步边界采用 Swift 6 strict concurrency，网络和缓存放 actor。

### 5.2 API 层

接口按认证体系隔离：

- Web API：Cookie + WBI，适合网页推荐、详情、历史等。
- App API：appkey/appsec 签名 + access token，适合 App feed 或特定媒体能力。
- gRPC/protobuf：弹幕等需要二进制模型的接口。

设计规则：

- 每个 endpoint 有独立请求/响应模型，不建立一个巨大“万能 BiliJSON”。
- 原始响应 fixture 进入测试资源，模型变更能通过 contract test 发现。
- 统一识别 JSON、HTML 风控页、403、412、超时、取消和字段缺失。
- WBI key 允许刷新；签名失败不能永久缓存成“本会话不可用”。
- 日志必须脱敏 URL query、Cookie、token 和响应头。

### 5.3 认证与存储

建议顺序：

1. 游客模式先可用。
2. Web QR 登录，保存 Web cookies，覆盖大部分个性化浏览。
3. 只有 App feed/特定能力明确需要时，再实现 TV QR/access token。

凭据模型必须分开：

```swift
struct WebCredential { /* SESSDATA, bili_jct, DedeUserID, expiry */ }
struct AppCredential { /* accessToken, refreshToken, expiry, issuing app key id */ }
```

- Keychain 保存所有 cookies/tokens；Apple 文档说明 [Keychain Services](https://developer.apple.com/documentation/security/keychain-services/) 用于安全保存小块秘密数据。
- UserDefaults 只保存主题、弹幕密度、默认清晰度等偏好。
- SwiftData 保存可重建的历史、缓存、已展示 BVID 和 UI 恢复状态。
- 登出要删除对应 Keychain item、内存副本和缓存，不只清 UI。

### 5.4 播放层：AVPlayer-first，但保留后端抽象

Apple 的 [`AVPlayer`](https://developer.apple.com/documentation/avfoundation/avplayer) 原生支持文件媒体和 HLS；B 站常返回音视频分离的 DASH，因此真正难点是把 B 站媒体描述转换成 AVPlayer 能稳定消费的形式。

建议接口：

```swift
protocol PlayerEngine: AnyObject {
    func load(_ request: PlaybackRequest) async throws
    func play()
    func pause()
    func seek(to time: Duration) async
    var events: AsyncStream<PlayerEvent> { get }
}
```

v1 只实现 `AVPlayerEngine`。若实测出现大量 AVPlayer 无法覆盖的编码、格式或直播需求，再新增可选 `MPVPlayerEngine`；不要一开始把 libmpv 构建、签名、许可和分发复杂度引入主路径。

#### DASH→HLS Bridge 需要完成的工作

1. 读取 playurl 的 video/audio representations、codec、带宽和 `SegmentBase`。
2. 对候选 CDN 发 Range 请求取得 init 与 SIDX。
3. 解析 SIDX，生成 HLS master playlist 和 media playlist。
4. 通过自定义 URL scheme + `AVAssetResourceLoaderDelegate` 映射媒体分段。
5. 音视频轨分别处理并保持时间轴一致。
6. 请求失败时按 CDN 质量顺序切换，成功下载 SIDX 的线路要延续到后续媒体分段。
7. 第一版只保证 AVC + 普通 AAC；HEVC/HDR/Dolby/8K 在稳定基线后逐项增加。

CDN 选择至少识别：

- 普通 upos CDN。
- `mcdn`/PCDN、`szbdyd.com` 等可能对外部 Range 不稳定的线路。
- backup URL 与海外镜像。
- HTTP 状态、Content-Range、响应是否其实是 HTML/小错误页。

当前 BiliKit 已经有一份 TypeScript 版“镜像优先 + PCDN 降权 + Range 严格校验”的自有 MIT 实现，可作为新 Swift 代码的直接迁移依据，见第 7 节。

### 5.5 弹幕层

建议分为四个纯逻辑组件：

1. `DanmakuDecoder`：protobuf → typed event。
2. `DanmakuSegmentScheduler`：按播放时间加载/预取分段，seek 后重置游标。
3. `DanmakuFilter`：关键词、用户、颜色、类型、重复内容过滤。
4. `DanmakuRenderer`：轨道分配、碰撞预测、复用和动画。

渲染建议使用 Core Animation layer 或可复用的 `NSView` 池。SwiftUI 只负责设置面板和播放器外层状态；不要让每条弹幕成为参与 SwiftUI diff/layout 的长生命周期 View。

需要测试：

- seek 向前/向后后不重复喷射旧弹幕。
- 暂停、倍速和拖动进度时动画时间轴一致。
- 窗口 resize、全屏和 mini player 切换时轨道重排。
- 低性能设备上的最大同屏条数和降级策略。

---

## 6. MVP 与里程碑

### M0：仓库与基础设施

- 独立 Xcode repo，macOS 15+，Swift 6。
- MIT License、非官方声明、隐私说明、`THIRD_PARTY_NOTICES.md`。
- `HTTPClient` actor、fixture test、Keychain wrapper、统一错误模型。
- CI 至少运行 Debug build、unit tests 和 SwiftFormat/SwiftLint（若引入）。

验收：全新 clone 不依赖私人证书即可在 CI 编译测试 target；App target 的签名配置不进入 Git。

### M1：游客浏览

- 热门/推荐二选一先通；建议先热门或 Web 推荐，避免一开始依赖 App token。
- 搜索、视频详情、分 P。
- 基础缓存、骨架状态、重试、空状态和风控错误提示。

验收：无账号可从启动进入列表、搜索并打开一个视频详情；API 返回 HTML 或字段缺失不会卡死。

### M2：Web QR 登录

- 扫码、轮询、过期/取消/重试。
- Cookie 写入 Keychain，登录态校验与登出。
- 登录后的推荐/历史/收藏中选择一个闭环。

验收：日志、UserDefaults、SwiftData 和测试快照中不存在 token/cookie。

### M3：可靠播放

- 一条 AVC DASH 视频轨 + 一条 AAC 音频轨。
- DASH→HLS Bridge、AVPlayerView、暂停/seek/倍速/清晰度。
- CDN fallback 和最小可读诊断。

验收：用一组热门/冷门/多 P fixture 和真实样本测试；任一 CDN 403 时会自动尝试备用线路；取消播放不会留下悬挂请求。

### M4：字幕与弹幕

- 字幕轨选择。
- protobuf 弹幕分段、预取、基础过滤、轨道分配。
- 弹幕密度、字号、透明度和屏蔽词设置。

验收：至少 30 分钟视频连续播放/seek，无明显时间漂移、重复喷射或内存单调增长。

### M5：Mac 产品完成度

- Commands、快捷键、独立播放器窗口、mini player、PiP（能力允许时）。
- 窗口恢复、拖入 B 站 URL、系统分享、辅助功能。
- 历史、稍后再看和播放进度同步。

### v1 明确不做

- 下载、转码和媒体导出。
- 直播与直播弹幕。
- 投稿、发动态、私信、复杂评论写操作。
- 多账号。
- 区域解锁和绕过地区限制。
- Dolby Vision、8K、互动视频、课程等长尾格式。
- 完整复刻官方 App 首页所有 Tab。

这些功能不是“永远不做”，而是必须在核心播放和认证稳定后，通过新 ADR 重新评估。

---

## 7. 当前 BiliKit 可以迁移的自有资产

当前 [shiinayane/BiliKit](https://github.com/shiinayane/BiliKit) 采用 MIT，以下实现属于本项目自己的可迁移基线。新仓库应重写为 Swift 类型和 actor，而不是在原生 App 内嵌 JS runtime。

| 当前文件 | 已验证能力 | Swift 目标 |
| --- | --- | --- |
| [`src/feed/app-api.ts`](https://github.com/shiinayane/BiliKit/blob/main/src/feed/app-api.ts) | Web/App feed 请求、响应归一化、HTML 风控响应识别、token 日志脱敏 | `HTTPClient`, `FeedEndpoint`, typed models |
| [`src/lib/wbi.ts`](https://github.com/shiinayane/BiliKit/blob/main/src/lib/wbi.ts) | WBI key 获取、缓存、签名与失败后重试 | `WbiSigner` actor |
| [`src/lib/app-sign.ts`](https://github.com/shiinayane/BiliKit/blob/main/src/lib/app-sign.ts) | App query 签名 | `AppSigner`，与凭据模型隔离 |
| [`src/core/tv-login.ts`](https://github.com/shiinayane/BiliKit/blob/main/src/core/tv-login.ts) | TV QR 获取、轮询、防重入、过期/取消和风控处理 | `TVQRCodeSession` 状态机 |
| [`src/feed/play-url.ts`](https://github.com/shiinayane/BiliKit/blob/main/src/feed/play-url.ts) | WBI playurl、AVC 轨筛选、SegmentBase、CDN/PCDN 排序、Range 候选 | `PlayURLResolver`, `CDNSelector` |
| [`docs/RESEARCH-feed.md`](https://github.com/shiinayane/BiliKit/blob/main/docs/RESEARCH-feed.md) | Web/App feed、认证、分页和去重范围研究 | API ADR 与 feed 测试依据 |

已知 feed 结论：

- Web 推荐 `/x/web-interface/wbi/index/top/feed/rcmd` 使用 Cookie/WBI，可利用 `last_showlist`/`fresh_idx` 一类上下文。
- App 推荐 `/x/v2/feed/index` 使用 App 签名和可选 access token；缺少有效 token 时更接近匿名流。
- 无论服务端是否去重，客户端都应保留跨刷新、带容量/时效限制的 shown-BVID 集合。
- Web Cookie 和 App token 是两套凭据，不要假设一个登录态可覆盖全部端点。

这些结论来自 2026-07 的实现和实测；API 参数与风控可能变化，迁移时必须用匿名 fixture、登录 fixture 和真实请求重新核验。

---

## 8. 许可证、品牌与分发边界

### 8.1 代码许可证

推荐新仓库使用 MIT，前提是：

- 只迁移当前 BiliKit 的 MIT 代码。
- 对 GPL 项目只研究公开行为、数据格式和架构思想，并基于 Apple 文档/自己抓取的合法测试样本重新实现。
- 不复制 GPL 源码、注释、测试 fixture、图标或其他版权资产。
- 记录每个依赖的版本、许可证和 notice。

项目快照：

- GPL-3.0：PiliPlus、wiliwili、Darock-Bili、旧 Bilimac、cilicili。
- GPL-2.0：ATV-Bilibili-demo。
- MIT：Bili.Mac.MenuBar。
- 自定义强限制许可：AnimacX。
- 未发现明确许可：Bili-Swift；默认不可复制。

“clean-room”是降低混用风险的工程纪律，不等同于法律意见。若以后决定直接派生 GPL 项目，应先接受相应源码开放和分发义务，并重新选择新仓库许可证。

### 8.2 Bilibili 商标和服务条款

- App 名、图标、bundle metadata 和宣传材料必须明确“第三方、非官方”。
- 不使用官方图标、22/33 娘或让用户误认为官方客户端的视觉资产。
- 名称含 `Bili` 有可发现性，也增加商标/混淆风险；品牌中性名称更安全，但需要副标题解释用途。
- API 是社区逆向接口，不是官方 SDK。端点可下线，账号也可能受到异常调用影响。

### 8.3 分发

Apple [App Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/) 要求第三方服务内容、商标、流媒体和下载能力具备相应授权，并可能要求提供证明。对未获 B 站明确授权的第三方客户端：

- **现实的早期路线**：Developer ID 签名 + notarization + GitHub Releases/Homebrew Cask（后者以后评估）。
- **不应默认承诺**：Mac App Store 上架。
- **v1 不做下载**：既降低技术范围，也降低 App Review 5.2.3 和版权风险。

直接分发不等于免除服务条款、商标和版权责任；它只是避开 Mac App Store 的审核通道限制。

---

## 9. 新仓库命名建议

### 首选：`BiliKit-Mac`

- repo：`BiliKit-Mac`
- App 显示名：`BiliKit`
- 可选 bundle id：`com.shiinayane.BiliKitMac`
- tagline：`A native, unofficial Bilibili client for macOS.`

优点：

- 延续现有 BiliKit 的品牌和 MIT 技术资产，用户与 AI 都容易理解两仓关系。
- `Kit` 不承诺“官方完整客户端”，也允许未来加入浏览器/辅助工具联动。
- repo 名明确与当前 `BiliKit` userscript 区分。

缺点：

- App 显示名若仍叫 BiliKit，用户可能分不清 userscript 和 macOS App；README 首屏必须解释。
- 含 `Bili`，仍需处理非官方声明和品牌混淆。

建议仓库关系表述：

> BiliKit-Mac is a separate native macOS application. The original BiliKit repository remains the browser userscript suite and research source.

### 次选：`MakuDock`

- 含义：`maku`（幕/弹幕意象）+ macOS Dock。
- 优点：Mac 感强、可品牌化、避开直接把 Bilibili 写进主品牌。
- 缺点：首次看到名字不一定知道是 B 站客户端，需要副标题。
- 适合：如果未来可能扩展为通用弹幕/在线视频播放器。

### 次选：`BiliDeck`

- 含义：把推荐、动态、收藏和播放器组织成一个桌面 deck。
- 优点：桌面产品感清楚，适合多栏/卡片式 UI。
- 缺点：仍含 `Bili`；`Deck` 也可能让人联想到 Steam Deck。

### 品牌中性：`PinkShell`

- 含义：B 站粉色意象 + 原生桌面 shell。
- 优点：不直接冒用服务名，未来扩展空间最大。
- 缺点：搜索可发现性弱，名字偏开发者气质；必须配 `Unofficial Bilibili client for macOS` 副标题。

### 当前排序

1. `BiliKit-Mac`：最适合现在立项，继承性和识别度最好。
2. `MakuDock`：最适合长期独立品牌。
3. `BiliDeck`：最像完整桌面客户端名称。
4. `PinkShell`：商标最中性，但需要额外品牌建设。

截至 2026-07-21，GitHub repository search 未发现上述四个查询的直接匹配结果：

- [BiliKit-Mac 搜索](https://github.com/search?q=BiliKit-Mac&type=repositories)
- [MakuDock 搜索](https://github.com/search?q=MakuDock&type=repositories)
- [BiliDeck 搜索](https://github.com/search?q=BiliDeck&type=repositories)
- [PinkShell macOS 搜索](https://github.com/search?q=PinkShell+macOS&type=repositories)

这只代表 GitHub 仓库搜索快照，不代表商标、域名、App Store 名称或社交账号可用。定名前仍需分别检索这些渠道。

不建议：

- `Bilibili for Mac`、`Bilibili Mac`：过于官方化，混淆风险最高。
- `PiliPlus Mac`、`wiliwili Swift`：与现有项目形成派生/官方关系暗示。
- `Bili-Swift`：已有同名仓库，且辨识度过低。

---

## 10. 建议的新仓库初始结构

```text
BiliKit-Mac/
├── BiliKitMac.xcodeproj
├── App/
├── Packages/
│   ├── BiliAPI/
│   ├── BiliAuth/
│   ├── BiliPlayback/
│   └── DanmakuKit/
├── Tests/
│   ├── APIFixtures/
│   ├── PlaybackFixtures/
│   └── ContractTests/
├── docs/
│   ├── research/native-macos-client.md
│   ├── adr/
│   ├── API-SURVIVAL-GUIDE.md
│   └── THREAT-MODEL.md
├── THIRD_PARTY_NOTICES.md
├── LICENSE
└── README.md
```

建议首批 issue：

1. Bootstrap macOS 15 / Swift 6 app and CI.
2. Define credential threat model and Keychain store.
3. Implement cancellable `HTTPClient` actor and redacted logging.
4. Add WBI signer with fixtures.
5. Implement guest popular/search/detail flow.
6. Implement Web QR state machine.
7. Design `PlayerEngine` protocol and player window lifecycle.
8. Build SIDX parser from self-created fixtures.
9. Build minimal DASH→HLS bridge with AVC/AAC.
10. Add CDN fallback/diagnostic matrix.
11. Implement protobuf danmaku decoder and segment scheduler.
12. Add keyboard commands, accessibility and window restoration.

---

## 11. 后续 AI 接手协议

每次继续开发前：

1. 先读本文、当前 repo 的 `AGENTS.md`/`CLAUDE.md`（若存在）、README、license、open ADR。
2. `git status`，保留用户未提交修改；不要假设 clean worktree。
3. 对将要使用的 B 站 endpoint 做小样本复核：匿名、Web 登录、App token 至少区分清楚。
4. 对引用项目重新核对 default branch、最近提交、license 和目标平台；不要从本文的日期快照推导“目前仍然如此”。
5. 改动认证、播放后端、最低系统版本、仓库许可证、下载/直播范围前，新增或更新 ADR。
6. 使用录制 fixture 做可重复测试；真实 token 只存在本机 Keychain，不进入 fixture。
7. 对播放功能至少检查：热门视频、冷门/PCDN 视频、多 P、seek、取消、CDN 403、音视频同步。
8. 对 UI 至少检查：键盘、VoiceOver、深浅色、窗口 resize、全屏和 mini player。

下一位 AI 不应把这些“建议”误当已完成事实：

- 新 repo 尚未创建。
- repo 名、App 名、bundle id 和 license 尚未由用户最终确认。
- 最低版本已决定为 macOS 15，以匹配可持续 CI 运行验证能力。
- AVPlayer DASH→HLS bridge 尚未在 macOS 原型中验证。
- Developer ID、notarization、自动更新和分发渠道尚未建立。
- B 站对第三方客户端的授权状态未解决。

需要用户拍板的首要决定：

1. 使用 `BiliKit-Mac` 还是独立品牌 `MakuDock`。
2. 首版是否只做 GitHub Releases 直接分发。
3. 最低系统已确定为 macOS 15；若未来下探，必须先恢复对应运行环境。
4. 是否坚持 MIT + clean-room，还是愿意采用 GPL 以直接派生现有实现。

---

## 12. 原始资料索引

### 客户端与清单

- [第三方客户端汇总](https://github.com/oldsento/bilibili-client-software-collection)
- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
- [wiliwili](https://github.com/xfangfang/wiliwili)
- [Darock-Bili](https://github.com/Darock-Studio/Darock-Bili)
- [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)
- [旧 Bilimac](https://github.com/typcn/bilibili-mac-client)
- [AnimacX](https://github.com/AnimacX/AnimacX)
- [Bili.Mac.MenuBar](https://github.com/Richasy/Bili.Mac.MenuBar)
- [Bili-Swift](https://github.com/zhihaofans/Bili-Swift)
- [cilicili](https://github.com/Rone89/cilicili)

### API 与接口资料

- [SocialSisterYi/bilibili-API-collect（已归档，默认 deprecated）](https://github.com/SocialSisterYi/bilibili-API-collect)
- [pskdje/bilibili-API-collect 镜像（也已归档）](https://github.com/pskdje/bilibili-API-collect)
- [Bilibili-Gate](https://github.com/magicdawn/Bilibili-Gate)
- [BBDown](https://github.com/nilaoda/BBDown)
- [DownKyi](https://github.com/leiurayer/downkyi)

社区 API 文档已经归档，说明依赖逆向 API 本身就是项目风险。文档可用于发现端点和字段，但实现必须以当前响应、错误处理和 fixture 为准。

### Apple 官方资料

- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)
- [HTTP Live Streaming](https://developer.apple.com/documentation/HTTP-Live-Streaming)
- [AVAssetResourceLoader](https://developer.apple.com/documentation/avfoundation/avurlasset/resourceloader)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services/)
- [TN3154: Adopting SwiftUI NavigationSplitView](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### 本仓库已有研究

- [`docs/RESEARCH-feed.md`](./RESEARCH-feed.md)
- [`docs/RESEARCH-mse-preview.md`](./RESEARCH-mse-preview.md)
- [`docs/RESEARCH-extension-architecture.md`](./RESEARCH-extension-architecture.md)

---

## 13. 一句话立项建议

单独创建 `BiliKit-Mac`，先用 macOS 15 + Swift 6 做一个 **游客可浏览、Web QR 可登录、AVPlayer 能可靠播放 AVC/AAC DASH、弹幕能正确 seek** 的小而完整原型；在这条链路被真实样本验证之前，不扩展到下载、直播和完整社交功能。

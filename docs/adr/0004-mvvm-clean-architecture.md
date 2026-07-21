# ADR 0004：以 Feature MVVM 落实 Clean Architecture

- 状态：已接受
- 日期：2026-07-21
- 取代：ADR 0001 中“SwiftUI Feature 初期留在 App target”的临时安排；其余平台、命名和单 Package 决策继续有效。

## 背景

M2 已经证明游客热门、搜索、详情、分 P 与播放的纵向链路，但原型代码把 Presentation、应用编排和具体 adapter 混在一起：`GuestAppModel` 同时持有 API、播放器、界面状态和并发代次，SwiftUI View 直接导入 `BiliAPI` 与 `BiliPlayback`，而跨 endpoint 的 `GuestVideoCoordinator` 位于 API target。继续在该结构上增加认证和持久化，会让 Feature 通过具体实现彼此耦合。

## 决策

继续使用 `Packages/BiliKitCore` 这一个本地 Swift Package，以 target 作为编译边界：

```text
BiliKit App（Composition Root）
├── BiliGuestFeature ──→ BiliApplication ──→ BiliModels
├── BiliAPI ───────────→ BiliApplication / BiliModels / BiliNetworking
└── BiliPlayback ──────→ BiliApplication / BiliModels / BiliNetworking
```

- `BiliModels` 是 Domain：保存稳定实体和值对象，不包含 DTO、UI State 或框架实现。
- `BiliApplication` 保存实际在用的 Use Case 与 port。Application 只依赖 Domain，不知道 B 站 endpoint、AVFoundation 或 SwiftUI。
- `BiliAPI` 保存 endpoint DTO、解码、WBI 和远端错误，并由 `BiliGuestRepository` 把它们适配为 Application port 与应用级错误。
- `BiliPlayback` 保存播放算法和 AVFoundation 实现；`AVPlayerEngine` 实现 Application 的播放 port。
- `BiliGuestFeature` 是 Presentation：SwiftUI View 负责渲染和发送意图，`@MainActor` ViewModel 负责 UI State、界面 Task 生命周期、取消和旧结果隔离。
- App target 是 composition root，只创建具体 adapter、注入 Use Case/ViewModel，并提供无法反向抽象到 Feature 的 `AVPlayerView` 宿主。

Presentation 按 Feature 组织为 `Feed/`、`VideoDetail/`、`GuestScene/`，不建立横跨所有功能的 `Views/`、`ViewModels/` 或 `Utils/` 大目录。当前拆成 `GuestFeedViewModel` 与 `GuestVideoViewModel`，避免新的 God ViewModel。

## 模型分类

| 类别 | 落点 | 当前例子 |
| --- | --- | --- |
| Domain Entity / Value | `BiliModels` | `PopularVideo`、`VideoDetail`、`VideoPage`、`VideoPlayback`、`PlaybackManifest` |
| Application Request / Result / Error | `BiliApplication` | `GuestFeedRequest`、`GuestFeedContent`、`GuestVideoContext`、`GuestApplicationError` |
| Application Port / Use Case | `BiliApplication` | `GuestContentRepository`、`PlaybackControlling`、`GuestFeedUseCase`、`GuestVideoUseCase` |
| Remote DTO / Error | `BiliAPI` | `PopularVideoPayload`、`DASHPayload`、`BiliAPIError` |
| Presentation State | `BiliGuestFeature` | `GuestFeedState`、`GuestSelectionState`、`GuestFlowFailure` |
| Platform Request / State | `BiliPlayback` | `PlaybackRequest`、`PlayerState`、`PlayerEvent` |

媒体 URL 请求头随 `VideoPlayback` 保留在 Domain 值中，是因为它们属于成功播放该资源所需的不可分割上下文；具体 `PlaybackRequest`、CDN/Range 策略与 AVPlayer 状态仍留在 adapter。

## 并发与状态所有权

- Use Case 是无 UI 状态的单次操作，可以并行获取详情和分 P。
- ViewModel 拥有用户意图的 Task、取消和代次；只有最新意图可以写回 UI State 或加载播放器。
- Repository/adapter 负责传播取消，不能把 `CancellationError` 折叠成普通网络失败。
- View 不创建 Task 来直接调用 repository 或具体播放器；SwiftUI `.task(id:)` 只负责把界面生命周期意图送给 ViewModel。

## 不采用的方案

- 不为每个类型建立独立 framework 或 `Package.swift`。
- 不引入第三方 DI、Coordinator、Redux/TCA 或 code generation。
- 不保留新旧两套游客实现，也不建立无调用方的 Repository/Use Case。
- 不把所有网络模型机械改名为 Domain；只有跨层稳定语义进入 `BiliModels`，endpoint payload 继续留在 API adapter。

## 约束与验证

- CI 运行 `Scripts/check-architecture.sh`，阻止内层 target 反向导入外层实现。
- Domain、Application、API/Playback adapter、Feature ViewModel 和 App composition 分别测试。
- M2 用户行为与 M1 播放算法必须通过回归；架构迁移本身不增加产品功能。

## 影响

正面影响是 M3 认证可以通过新 port 接入，而无需让 ViewModel 持有 API client 或 Keychain；Feature 状态、用例和 adapter 可以分别替换与测试。代价是增加两个 target、若干窄协议和显式 composition 代码；跨 target API 的访问级别也需要更谨慎维护。

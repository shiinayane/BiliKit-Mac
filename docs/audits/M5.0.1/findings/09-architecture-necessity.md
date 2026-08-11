# 09 架构必要性

状态：第二轮真实调用图审计与独立交叉复核完成（2026-07-27）；未修改生产代码。

## ARCH-001：Application ports 有单实现，但隔离了真实 target 边界

- **finding_id**：ARCH-001
- **审计线与涉及能力**：Application protocol、Feature → port → adapter 调用图。
- **当前实现（文件、符号、调用链）**：

  | Port | 生产调用者数 | 生产实现数 | 实际隔离 |
  | --- | ---: | ---: | --- |
  | `AuthenticationServicing` | 1：`AuthenticationViewModel` | 1：`BiliAuthenticationService` | Feature 与 QR/Keychain/auth actor |
  | `AuthenticatedSessionInvalidating` | 1：`BiliAuthenticationService` | 1：`BiliAPIClient` | Auth 登出与 API transport/WBI 清理，避免 Auth import API |
  | `GuestContentRepository` | 2：`GuestFeedUseCase`、`GuestVideoUseCase` | 1：`BiliGuestRepository` | endpoint/DTO/error mapping |
  | `WatchHistoryRepository` | 1：`WatchHistoryUseCase` | 1：`BiliWatchHistoryRepository` | 不透明 cursor、登录 endpoint/error |
  | `SubtitleRepository` | 1：`SubtitleUseCase` | 1：`BiliSubtitleRepository` | 认证目录、受信正文 URL、per-identity session |
  | `DanmakuSegmentRepository` | 1：`DanmakuSegmentUseCase` | 1：`BiliDanmakuRepository` | protobuf/endpoint 与 typed segment |
  | `PlaybackTimelineProviding` | 2：`SubtitleViewModel`、`DanmakuSession` | 1：`AVPlayerEngine` | AVPlayer 时钟与 Feature/Danmaku |
  | `PlaybackControlling` | 1：`GuestVideoViewModel` | 1：`AVPlayerEngine` | Feature 与 AVFoundation/loopback |
  | `DanmakuPresentationControlling` | 1：`DanmakuControlsViewModel` | 1：`DanmakuSession` | Feature controls 与 scheduler/renderer |
  | `AuthenticationQRCodeProviding` | 1：`AuthenticationViewModel` | 1：Composition provider | Feature 的 `CGImage` 与 Auth 内不可读 QR payload |

  定义位于 `BiliApplication` 或 `BiliAuthFeature`；生产 wiring 位于
  `BiliKitMac/Composition/AppEnvironment.swift:14-102`。每个 port 均有测试/UITest
  替身，但判断不以替身数量为依据。
- **它声称提供的职责**：保持 Feature 不 import BiliAPI/BiliAuth/BiliPlayback/
  BiliDanmaku；把网络、安全和平台实现留在 composition 可见侧。
- **外部事实来源**：不适用。是否为真实边界由当前 SwiftPM target dependency 和调用图
  决定，不以架构教材或“协议优先”原则裁决。
- **OSS 对照及 commit/date**：不适用。其他项目 target 布局不能证明本仓库依赖方向。
- **真实行为证据**：App live composition 的每个 port 都连接到唯一生产 adapter；UITest
  composition 能在不导入具体网络/播放器实现的情况下替换这些边界。
- **本地测试实际证明的范围**：各 Feature/Application 测试证明 port 可提供确定性输入；
  它们不能单独证明 protocol 必须存在。必须结合上表的跨 target 隔离。
- **判断：保留**。单实现/单调用者不构成删除理由；上表每项都隔离了平台、网络、安全或
  target 依赖，删除会使 Feature 直接 import adapter target，或让 Auth 与 API 反向依赖。
- **风险：影响、触发条件、可恢复性**：port 继续扩张成“万能 repository”会掩盖不同
  权限/生命周期；当前最明显风险是 `GuestContentRepository` 同时覆盖 feed 与视频，但
  已有两个真实调用者，尚无拆分收益证据。
- **下一步最小验证**：把上表写成 architecture lint 的只读输入，核对每个 port 的方法是否
  全被至少一个生产调用者使用；仅对零方法调用者另立删除项。
- **与其他 finding 的依赖或冲突**：与 ARCH-003/004 的无效 protocol 形成反例；与
  CONC/PRIV 的 lifecycle/security 边界一致。

## ARCH-002：前四个 UseCase 有编排，`SubtitleUseCase` 的 guard 尚未找到安全归属

- **finding_id**：ARCH-002
- **审计线与涉及能力**：UseCase 调用者、实现职责、删除后的变化。
- **当前实现（文件、符号、调用链）**：

  | UseCase | 生产调用者数 | 非转发职责 |
  | --- | ---: | --- |
  | `GuestFeedUseCase` | 1：`GuestBrowseViewModel` | popular/search sum type、trim、page/pageSize guard |
  | `GuestVideoUseCase` | 1：`GuestVideoViewModel` | 并行 detail/pages、取消、排序、首 P、playback 串联 |
  | `WatchHistoryUseCase` | 1：`WatchHistoryViewModel` | pageSize、空页跳过上限、cursor 不前进保护 |
  | `DanmakuSegmentUseCase` | 1：`DanmakuSession` | index/identity guard、返回 segment index 校验 |
  | `SubtitleUseCase` | 1：`SubtitleViewModel` | 空字符串/非正 cid guard，之后逐方法转发 |

  前四项分别见 `BiliApplication/.../*UseCase.swift`；
  `SubtitleUseCase` 与 protocol 同文件
  `BiliApplication/Subtitle/SubtitleContracts.swift:12-56`。
- **它声称提供的职责**：UseCase 应承载跨 adapter 调用或与 UI/endpoint 无关的应用规则，
  而不是只换一次方法接收者。
- **外部事实来源**：不适用；这是当前调用图与方法体事实。
- **OSS 对照及 commit/date**：不适用；不能用其他项目的 Clean Architecture 层数裁决。
- **真实行为证据**：
  - 前四项规则分别参与当前热门/搜索、首 P 播放、历史 cursor 与弹幕分段路径；
  - `SubtitleUseCase` 没有独立 production state，但其 `tracks/cues` 在 Application 层
    拒绝空 bvid、非正 cid 与空 trackID；`PlaybackItemIdentity` 本身允许这些无效值。
    `BiliSubtitleRepository.cues` 的 current identity + `resourceURLs[trackID]`
    fail-closed（`BiliSubtitleRepository.swift:74-83`）不等价于所有输入 guard，
    `tracks` 也会直接把 identity 交给 concrete client。
- **本地测试实际证明的范围**：
  前四项有 `BiliApplicationTests` 的直接规则测试；全仓库没有专门
  `SubtitleUseCaseTests`。2026-07-28 已补定点测试，三个非法 identity 与三个非法
  track/identity 组合均在 repository 调用前失败；这证明 guard 是当前可观察规则，但不证明
  它永远只能放在这一类型。
- **判断：保留**前四项；`SubtitleUseCase` 本轮也 **保留**，不进入当前清理批次。它不是
  纯转发：当前 model 允许构造空 bvid／非正 cid，而 Application port 也没有可执行
  precondition；删除只会迫使 guard 下沉到单一 ViewModel 或泄漏给 repository。以后只有在
  valid identity 成为模型不变量，或出现覆盖所有调用者与 adapter/fake 的唯一新归属时，
  才重新登记删除；repository 的 stateful identity/track fail-closed 校验仍须保留。
- **风险：影响、触发条件、可恢复性**：若直接删除时误删 repository 的 identity guard，
  会重新引入字幕串视频风险；因此该裁决只针对 wrapper struct，不授权改动安全校验。
- **下一步最小验证**：当前 guard 定点测试保留为回归。M5.0.1 不再为删除 wrapper 设计
  新归属；若未来重开，必须先证明模型不变量或新的 Application 边界，并让 A→B→A、
  未知 track、reset 顺序继续通过。
- **与其他 finding 的依赖或冲突**：依赖 CONC-002 与字幕 API finding；与
  ARCH-001“保留 SubtitleRepository”不冲突。

## ARCH-003：`PlayerEngine` protocol 没有任何 protocol-typed 调用者

- **finding_id**：ARCH-003
- **审计线与涉及能力**：播放器 protocol、死抽象。
- **当前实现（文件、符号、调用链）**：已实施删除。`AVPlayerEngine` 只 conform
  `PlaybackControlling`，Feature／Danmaku／字幕继续使用
  `PlaybackControlling`／`PlaybackTimelineProviding` 两个窄 Application ports；
  composition、probe 和播放器测试直接使用具体 engine。`PlaybackRequest`、
  `PlayerState`、`PlayerEvent` 保留在改名后的 `PlayerTypes.swift`。
- **它声称提供的职责**：理论上描述完整 player engine；实际上没有隔离任何调用点。
- **外部事实来源**：不适用；零调用者是仓库事实。
- **OSS 对照及 commit/date**：不适用。
- **真实行为证据**：删除 conformance 不改变 production dispatch；`AVPlayerEngine`
  的公开方法仍被 probe/host 具体调用。
- **本地测试实际证明的范围**：播放器测试覆盖 concrete engine 和窄 Application ports；
  MP-006 定点测试直接消费 concrete engine 的 `events` 并已证明 ready 后持续失败出口。
  删除 protocol 后 package gate 237 项通过；这不证明仓库外调用兼容。
- **判断：删除已实施**。`PlayerEngine` protocol 与唯一 conformance 已删除；这是已证明
  零调用者的结构噪音。`events`／`PlayerEvent` 保留为 MP-006 失败出口。
  `PlayerState` 是否应与已有 `PlaybackTimelineState` 合并不属于本项；若未来重开，
  必须按唯一状态 owner 单独裁决。保留有实际 probe/tests 调用的 `PlaybackRequest`、
  `setRate` 与 `Duration` seek。
- **风险：影响、触发条件、可恢复性**：源码兼容性只影响仓库外若有人使用该公开 SwiftPM
  product，但 BiliKitCore 未作为独立版本化 SDK 分发；本仓库 build 可直接发现遗漏。
- **下一步最小验证**：本项关闭；未来只有出现第二个完整 engine 消费边界时再按真实调用者
  引入抽象，不为类型对称恢复 protocol。
- **与其他 finding 的依赖或冲突**：不删除两个窄 Application playback ports；与
  MP-005 无关，但 event stream 的后续形态依赖 MP-006。

## ARCH-004：`BiliWatchHistoryService` 是同 target 内的一对一转发 protocol

- **finding_id**：ARCH-004
- **审计线与涉及能力**：adapter 内部 wrapper、history service。
- **当前实现（文件、符号、调用链）**：已实施删除。
  `BiliWatchHistoryRepository` 直持 `BiliAPIClient`，`AppEnvironment.live` 以
  `client:` 注入；`BiliWatchHistoryService` 及其 test fake 已不存在。Application
  `WatchHistoryRepository` port 继续隔离 Feature／UseCase 与 BiliAPI。
- **它声称提供的职责**：让 repository 不直接持有 concrete client；但两者都在
  `BiliAPI` target，protocol 没有隔离 endpoint、平台、安全或 target。
- **外部事实来源**：不适用；一实现/一调用者本身不是删除条件，关键是这里连测试或 target
  边界也不存在。
- **OSS 对照及 commit/date**：不适用。
- **真实行为证据**：实际调用仍为
  `BiliWatchHistoryRepository → BiliAPIClient.watchHistory`；protocol 不改变 runtime
  行为或错误 mapping。
- **本地测试实际证明的范围**：history UseCase/Feature tests 继续 fake
  `WatchHistoryRepository`（真实 Application 边界）。repository 定点测试现以可控
  concrete `BiliAPIClient` transport 驱动 authentication、restriction、service code、
  HTTP／未知 transport、invalid request 与 cancellation，共 9 项通过；完整 app gate
  通过。
- **判断：删除已实施**。`BiliWatchHistoryService` 已删除，repository 直接持有
  `BiliAPIClient`。
  `BiliWatchHistoryRepository` 自身仍保留，因为它把 `BiliAPIError` 映射到 Application
  error，并实现真实 `WatchHistoryRepository` port。
- **风险：影响、触发条件、可恢复性**：未来若出现第二个底层 history client，可在有事实
  时重新引入；当前删除只减少同 target dispatch，build 可完全恢复遗漏。
- **下一步最小验证**：本项关闭；未来只有出现第二个真实 history client 或新的 target
  边界时才重新登记抽象，不为测试便利恢复 protocol。
- **与其他 finding 的依赖或冲突**：不与 ARCH-001 的
  `WatchHistoryRepository` 保留结论冲突。

## ARCH-005：Networking/Auth/Danmaku 内部 protocols 隔离了实际能力

- **finding_id**：ARCH-005
- **审计线与涉及能力**：lower-layer protocol、平台/安全/transport 可替换边界。
- **当前实现（文件、符号、调用链）**：

  | Protocol | 生产调用者／实现 | 删除后的实际变化 |
  | --- | --- | --- |
  | `HTTPTransport` | `HTTPClient`、Range、API/Auth；`URLSessionTransport` | 各 client 直接依赖 URLSession，失去受控 response/redirect 测试 |
  | `HTTPTransportInvalidating` | API/Auth 动态 capability；`URLSessionTransport` | 无法在 logout/session replace 时统一 cancel，或迫使所有 transport 实现无关方法 |
  | `HTTPRequestAuthorizing` | `BiliAPIClient`；`BiliCredentialRequestAuthorizer` | BiliAPI 必须 import BiliAuth 或内建 Cookie/allowlist |
  | `WebCredentialStoring` | QR session + authorizer；Keychain store | 协议/授权逻辑直接依赖 Security storage |
  | `KeychainOperating` | Keychain store；System Security calls | 无法确定性覆盖 OSStatus 失败路径 |
  | `DanmakuPresentationSink` | Session；controller | scheduler/session 直接依赖 renderer controller |
  | `DanmakuRenderingBackend` | controller；Core Animation renderer | 调度与 Core Animation 合并，失去纯内存 placement 验证 |
  | `DanmakuRenderingBackendDelegate` | renderer；controller | CA completion 反向依赖 concrete controller |

  定义和调用分别位于 `BiliNetworking/Transport/HTTPClient.swift`、
  `BiliNetworking/Authorization/HTTPRequestAuthorizing.swift`、
  `BiliAuth/Credential/WebCredentialStore.swift`、`BiliDanmaku/Rendering/*`。
- **它声称提供的职责**：隔离 URLSession、Cookie/allowlist、Security.framework 和
  Core Animation；让核心状态机可被确定性驱动。
- **外部事实来源**：不适用；本项由 concrete platform imports 与调用方向证明。
- **OSS 对照及 commit/date**：不适用。
- **真实行为证据**：production composition 使用全部 capability；logout 会调用
  invalidator，renderer completion 会经 delegate 回收 active placement。
- **本地测试实际证明的范围**：HTTP、Auth、Keychain、Danmaku tests 都使用相应 fake；
  结合真实 platform import 边界后，证明不仅为“方便 mock”。
- **判断：保留**。这些协议即使多为单 production 实现，也隔离了明确的不稳定/安全/平台
  边界。
- **风险：影响、触发条件、可恢复性**：`HTTPTransportInvalidating` 的 optional dynamic
  cast 允许不支持 cleanup 的 transport 静默通过；这是 lifecycle 风险，但不等于 protocol
  无用，应由 CONC-005 裁决是否把 capability 变成强制 owner contract。
- **下一步最小验证**：根据 CONC-005 结果决定 invalidation 是否应成为构造时强制能力；
  其余协议只做零方法调用 scan。
- **与其他 finding 的依赖或冲突**：依赖 CONC-005、PRIV-001/002；不与 ARCH-003/004
  冲突。

## ARCH-006：十一个 library target 与 `BiliUI` 均有实际依赖边界

- **finding_id**：ARCH-006
- **审计线与涉及能力**：SwiftPM target、产品模块、共享 UI。
- **当前实现（文件、符号、调用链）**：
  `Package.swift:31-73` 定义十一个 library target。真实依赖为：

  ```text
  Feature -> BiliApplication + BiliModels (+ BiliUI)
  BiliAPI/BiliAuth/BiliPlayback/BiliDanmaku -> Application ports / Models / Networking
  BiliNetworking、BiliModels、BiliUI -> 无项目内依赖
  App Composition -> 所有 concrete adapter
  ```

  `BiliUI` 虽只有 VideoCard、ButtonStyle、GridLayout 三组源文件，但同时被 Browse 与
  Library 使用；合并到任一 Feature 会制造 Feature → Feature import 或复制。
- **它声称提供的职责**：编译期维持 Feature、Application、adapter/platform 依赖方向；
  共享 UI 仅承载两个 Feature 的真实复用。
- **外部事实来源**：不适用；SwiftPM target 是否必要由实际 imports 和调用者决定。
- **OSS 对照及 commit/date**：不适用。
- **真实行为证据**：App target 只在 Composition import concrete adapter；Feature 源码
  没有 import BiliAPI/BiliAuth/BiliPlayback/BiliDanmaku。
- **本地测试实际证明的范围**：architecture script 证明当前 import contract；build
  证明 target graph 可解析。二者不证明未来每个 target 永远保留。
- **判断：保留**当前十一个 library target；没有空 target、单文件纯占位 target 或第二个
  `Package.swift`。不因文件少合并 `BiliAuthFeature`/`BiliLibraryFeature`/`BiliUI`。
- **风险：影响、触发条件、可恢复性**：target 数会增加 build graph 与 public product
  表面积；如果某 Feature 被删除或共享 UI 不再有两个调用者，应重审，而不是永久豁免。
- **下一步最小验证**：在后续清理后生成一次 `swift package describe` 与 import graph，
  确认每个 library target 至少有一个 production consumer。
- **与其他 finding 的依赖或冲突**：与 ARCH-001 的 ports 共同构成依赖方向；工程/分发线
  负责 public products 是否需要全部暴露。

## ARCH-007：历史 Probe target 已退役

- **finding_id**：ARCH-007
- **当前判断**：这些一次性 executable target、测试入口和 runner 已删除。它们复制生产
  composition、扩大权限与隐私面，并把现场观察误包装成常驻回归契约；未来若有具体问题，
  应在明确边界内临时验证，不恢复万能 probe 或测试专用生产入口。

## ARCH-008：Repository/HTTP/Composition wrappers 多数有转换职责

- **finding_id**：ARCH-008
- **审计线与涉及能力**：wrapper、转发层、composition type erasure。
- **当前实现（文件、符号、调用链）**：
  - `BiliGuestRepository` 的五个方法看似转发，但集中把 `BiliAPIError` 映射为
    `GuestApplicationError`（`BiliGuestRepository.swift:45-84`）；
  - `BiliWatchHistoryRepository` 转换 auth/restriction/cursor error
    （`BiliWatchHistoryRepository.swift:11-49`）；
  - `HTTPClient` 被 API、Subtitle、QR、Credential 四个 owner 使用，统一 2xx status
    验证（`HTTPClient.swift:56-72`）；
  - Composition 的 `AuthenticationQRCodeProvider` 仅一行转发
    （`AppEnvironment.swift:150-155`），但避免 BiliAuth 反向 import BiliAuthFeature；
  - `makePlayerView -> AnyView`（`AppEnvironment.swift:79-89`）组装具体
    AVPlayer/Danmaku host，并支持 UITest 注入；Composition/Platform 只是同一 App target
    内的文件组织，不形成编译边界。
- **它声称提供的职责**：错误语义转换、HTTP status policy、反向依赖隔离、具体 player
  host 组装。
- **外部事实来源**：不适用。
- **OSS 对照及 commit/date**：不适用。
- **真实行为证据**：前三类 wrapper 的下游错误/依赖类型与上游不同；删除会移动而非消失
  这些职责。`AnyView` 是否是 host 组装/测试注入的必要表达尚未获得 runtime identity
  证据，且 STATE-001 已反证“root 只构造一次”的假设。
- **本地测试实际证明的范围**：adapter/HTTP tests 证明 mapping/status；App lifecycle
  tests 证明 type-erased player content 能被 production shell/fixture 装配，但不比较
  type erasure 的性能成本。
- **判断：保留** repository、HTTP 与 QR provider wrappers。player host 的组装／
  UITest 注入职责 **保留**，但 `AnyView` 这一 type erasure 形式 **尚不能判断**；
  先解决 root owner identity，再比较 opaque/generic composition 是否更清晰。
- **风险：影响、触发条件、可恢复性**：`AnyView` 隐藏 concrete identity，若 host 被频繁
  重建可能增加生命周期诊断难度；当前它由 `AppRootView` 只构造一次，尚无故障证据。
- **下一步最小验证**：将 architecture lint 与 `PlayerHostLifecycleProbeTests` 作为后续
  wrapper 清理的两个门；先增加 root re-init 下 model/engine/player surface identity
  测试，再比较是否值得替换 `AnyView`。
- **与其他 finding 的依赖或冲突**：依赖 CONC-003 的 host 生命周期；与 ARCH-004 的
  删除结论互为对照。

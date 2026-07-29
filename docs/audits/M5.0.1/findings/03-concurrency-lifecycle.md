# 03 Swift 并发与生命周期

状态：第一轮事实审计完成；尚未修改生产代码。

本文件 owner：第一轮 Agent C。取证日期：2026-07-27。SDK 核对环境：
Xcode `MacOSX26.5.sdk`。interface/header 标注确认 SwiftUI `.task` 为 macOS 12+、
`NWListener` 为 macOS 10.14+、`AVPlayer` 与 time observer 为 macOS 10.7+，均覆盖项目
最低系统 macOS 15。

## 所有者总表

| 资源类型 | 当前 owner 与释放入口 | 第一轮结论 |
|---|---|---|
| 页面加载 `Task` | `GuestVideoViewModel`、`AuthenticationViewModel`、`WatchHistoryViewModel`；由新请求、`reset`/`deactivate`/`cancelTransientWork` 取消 | generation 防陈旧结果应保留；真实窗口关闭后的释放尚未验证 |
| 字幕 `Task` / reset worker | `SubtitleViewModel`；`select`、`reset`、`suspendForAuthenticationLoss` 与 `deinit` 取消 | A→B→A 串行 reset 与 generation 应保留 |
| 弹幕 `Task` | `DanmakuSession`；`start`/`stop`/`deinit` 取消 | 主路径应保留；无人消费的 `batches()` 应删除 |
| actor 隔离 | `BiliSubtitleRepository`、`BiliAuthenticationService`、`WebQRLoginSession` | actor 只提供串行隔离，仍需 identity/generation；当前组合合理 |
| `AsyncStream` continuation | `PlaybackTimeline`、`AVPlayerEngine`、`AVPlayerItemReadiness`、`DanmakuSession.batches()` | 前三者有 finish/onTermination；最后一项为死 API |
| checked continuation | `LoopbackPlaybackServer.StartContinuationBox` | exactly-once resume 已处理；取消启动任务时不立即 cancel listener |
| timer / clock | 未发现生产 `Timer`；认证轮询使用 `ContinuousClock` 与 `Task.sleep` | 固定 2 秒轮询和 180 秒上限属于协议/产品策略，需由认证线复核，不是资源 timer |
| AVPlayer observer/KVO/通知 | `PlayerTimelineObserverBag` | 显式配对移除，符合 AVFoundation 合约 |
| loopback server / connection | `LoopbackPlaybackServer`、`PreparedPlaybackAsset` | `stop()` 路径完整；真实 socket/端口释放只由测试诊断量证明，需真实资源验证 |
| AVPlayer / bridge | `AVPlayerEngine` | 替换 item、停止 bridge、清 timeline 路径完整；真实关窗释放仍未知 |
| renderer / layer | `DanmakuPresentationController`、`CoreAnimationDanmakuRenderer`、`DanmakuOverlayHostView` | generation/render epoch 与 detach/clear 路径完整；Memory Graph 尚未验证 |

## M501-CONC-001：保留取消与 generation 的双重隔离

- **finding_id**：`M501-CONC-001`
- **审计线 / 能力**：Swift 并发；页面退出、切视频、认证状态变化时拒绝旧结果。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliBrowseFeature/VideoDetail/GuestVideoViewModel.swift:35-105`：新视频令
    `generation += 1`，取消旧 `loadTask`，并在每次跨 `await` 后同时检查
    `Task.isCancelled` 与 generation。
  - `Packages/BiliKitCore/Sources/BiliLibraryFeature/History/WatchHistoryViewModel.swift:128-190`：
    `deactivate`/新加载取消 task 并递增 generation。
  - `Packages/BiliKitCore/Sources/BiliAuthFeature/Authentication/AuthenticationViewModel.swift:157-247`：登录/恢复流程以
    generation 隔离，取消旧 task。
  - `BiliKitMac/App/AppNavigationCoordinator.swift:56-69`：目的地替换先
    `stop` 旧视频，再 `start` 新视频；
    `BiliKitMac/App/AppRootView.swift:111-116` 在根视图消失时 reset/deactivate。
- **声称承担的职责**：取消不再需要的工作，并阻止已经越过取消点或不响应取消的依赖把旧
  状态写回当前页面。
- **外部事实来源**：
  - Apple [`Task`](https://developer.apple.com/documentation/swift/task/)
    文档：取消是协作式信号，执行体必须检查并响应取消。
  - Apple [SwiftUI `task(id:)`](https://developer.apple.com/documentation/swiftui/view/task%28id%3Aname%3Apriority%3Afile%3Aline%3A_%3A%29)：
    view 消失时取消 task，id 改变时取消并重建。项目还保存了独立的 ViewModel task，
    因而不能只依赖 SwiftUI task。
  - 本机 `MacOSX26.5.sdk` 的
    `SwiftUI.swiftinterface:5071` 确认该 API 在当前 SDK 存在。
  - **证据强度**：Apple 规范 + 静态调用链 + 当前基线真实窗口行为；没有逐 Task
    signpost 或 Memory Graph。
- **OSS 对照及 commit/date**：不适用；这是 Swift 语言/SwiftUI 的规范性取消语义，
  OSS 不能替代 Apple 合约。
- **真实行为证据**：用户已复现过视频 A→B→A 的陈旧字幕问题；当前代码路径能识别
  identity/generation。修复 `STATE-001` 后，在不登录的真实 App 中连续执行 10 次同一
  公开视频的播放进入/返回，均回到同一热门工作集，未见旧页面状态写回；三次关闭/新建
  窗口后 App 仍可正常加载热门。该观察没有保存账号、媒体 URL、字幕或弹幕正文。
- **本地测试实际覆盖范围**：
  - `Packages/BiliKitCore/Tests/BiliBrowseFeatureTests/SubtitleViewModelTests.swift:121-171`
    验证受控依赖晚返回时旧 cue 不写回。
  - `Packages/BiliKitCore/Tests/BiliPlaybackTests/LoopbackPlaybackServerTests.swift:360-389`
    验证受控 transport 观察到替换导致的取消。
  - 这些测试证明“旧结果被拒绝/取消信号被测试替身观察到”，不证明真实 URLSession、
    socket、AVPlayer 或窗口资源已释放。
- **判断**：**保留**。
- **风险**：删除 generation 会把“发出取消”误当成“旧工作已经停止”，恢复陈旧写回；
  但仅保留 generation 也可能掩盖实际资源未释放。三个 ViewModel 都没有 `deinit`
  cancel 兜底；任务闭包进入 async 方法后会在 `await` 期间持有 owner，而
  `AuthenticationViewModel.cancelTransientWork` 还会新建 login cleanup task，因此释放
  依赖 AppRootView 的显式退出路径。
- **下一步最小验证**：当前用户可见返回路径已完成；若实施阶段修改 task owner，再增加
  不含 BVID/CID/URL 的 signpost，只记录 generation、任务数量和 owner 类型，作为精确
  Task 归零的回归条件。现有实测不支持删除 generation 或 deinit 兜底审计。
- **依赖 / 冲突**：依赖媒体线确认 AVPlayer/URLSession 的实际取消语义；与架构线可能提出
  的 ViewModel 简化不冲突，简化后仍需保留等价 identity 隔离。

## M501-CONC-002：保留字幕 A→B→A 串行 reset worker

- **finding_id**：`M501-CONC-002`
- **审计线 / 能力**：字幕生命周期；同一 identity 被离开后快速重新进入。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliBrowseFeature/VideoDetail/Subtitle/SubtitleViewModel.swift:61-110`：
    切换 identity/轨道时递增
    `contentGeneration`，取消 content/timeline task。
  - 同文件 `:133-157,237-280`：旧 identity 的 repository reset
    由单一 `resetTask` 串行执行；pending load 等 reset 后再启动。
  - `Packages/BiliKitCore/Sources/BiliAPI/Adapter/BiliSubtitleRepository.swift:43-147`：
    actor 内再次以
    `currentIdentity` 与 generation 隔离 catalog/body/reset。
  - 引入该防线的提交：
    `25e4b875b4f05e1ab8e9e22c6edbf280087f5ce2`，
    2026-07-25 14:59 JST，`稳定字幕生命周期并重排 v1 路线`。
- **声称承担的职责**：防止 A 的延迟 reset 在用户已重新进入 A 后清除新会话，也防止 A
  的旧字幕进入 B。
- **外部事实来源**：Apple `Task` 的协作式取消语义同
  `M501-CONC-001`；actor 串行化不等于请求版本正确，identity/generation 仍需由业务层表达。
  **证据强度**：Apple 规范 + 用户历史复现 + 确定性竞态测试。
- **OSS 对照及 commit/date**：不适用；该机制修复的是本仓库 repository reset 与页面
  identity 的具体竞态。字幕 endpoint 正确性另由 API 线审计，不能据 endpoint 修复删除
  生命周期隔离。
- **真实行为证据**：用户此前观察到字幕串视频；改用新版 endpoint 后内容来源问题消失，
  但这不证明 A→B→A 的本地异步竞态不再存在。本轮没有重复发送真实请求。
- **本地测试实际覆盖范围**：
  - `Packages/BiliKitCore/Tests/BiliBrowseFeatureTests/SubtitleViewModelTests.swift:173-223`
    `staleResetCannotInvalidateNewSessionForSameIdentity` 确定性重现旧 reset 晚到。
  - `:225-343` 覆盖认证暂停/恢复、关闭后不恢复、排队切换期间关闭。
  - 这些测试证明受控 repository 的顺序与拒绝规则，不证明远端响应正确或网络资源释放。
- **判断**：**保留**。
- **风险**：误删会重新引入低概率 A→B→A 竞态；把它宣称为 endpoint 正确性保障则会掩盖
  服务端错配。
- **下一步最小验证**：保留现有确定性测试；在真实匿名播放验证中只记录匿名 identity
  token 与 generation 转移，不保存字幕正文、BVID、CID 或 URL。
- **依赖 / 冲突**：依赖 API/字幕线确认 endpoint；若 repository ownership 被重构，
  必须迁移而不是静默删除 reset 顺序约束。

## M501-CONC-003：observer 配对与真实返回清理成立，完整对象图释放尚不能判断

- **finding_id**：`M501-CONC-003`
- **审计线 / 能力**：AVPlayer、KVO、NotificationCenter、页面退出和窗口关闭。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliPlayback/Player/AVPlayerTimelineAdapter.swift:29-153,212-288`：
    `PlayerTimelineObserverBag` 集中拥有 periodic time observer、KVO 与通知 token；
    replace/clear/deinit 均显式移除。
  - `Packages/BiliKitCore/Sources/BiliPlayback/Player/AVPlayerEngine.swift:45-50,97-185,224-235`：
    deinit/cancel/error/stop 均取消 load/readiness task，替换 player item，停止 bridge，
    清 timeline。
  - `BiliKitMac/Platform/PlayerHostView.swift:67-109`：
    `dismantleNSView` detach 弹幕 surface；AVPlayer 停止由上层导航 owner 负责，而非 host
    自行决定。
- **声称承担的职责**：observer 生命周期与当前 AVPlayerItem 一致；离开播放页、替换 item
  或释放 engine 后不再回调旧对象。
- **外部事实来源**：
  - Apple [`addPeriodicTimeObserver`](https://developer.apple.com/documentation/avfoundation/avplayer/addperiodictimeobserver%28forinterval%3Aqueue%3Ausing%3A%29)
    要求与 `removeTimeObserver` 配对。
  - 本机 `MacOSX26.5.sdk` `AVPlayer.h:440-478` 也明确要求配对移除。
  - **证据强度**：Apple 规范 + 静态清理路径 + 合成宿主测试 + 当前基线真实 App 的
    Allocations/端口/RSS 组合；没有 Memory Graph。
- **OSS 对照及 commit/date**：不适用；这是 AVFoundation 明文生命周期合约。
- **真实行为证据**：以临时 ad-hoc 签名、只为 Instruments 增加 `get-task-allow` 的当前
  Debug App 运行匿名热门路径：连续 10 次播放进入/返回后 `lsof` 不再见 BiliKit TCP
  listener；三次关闭/新建窗口后仍无 listener。30.925 秒 Allocations trace 覆盖一次
  播放进入/返回，已识别的 `DanmakuEvent`／protobuf 弹幕数组、`Task<(), Never>` 数组和
  `ListenerPair` 均为 0 persistent。trace 与临时 entitlement 只留在 `/private/tmp`，
  未进入仓库。
- **本地测试实际覆盖范围**：
  - `BiliKitMacTests/PlayerHostLifecycleProbeTests.swift:117-228` 用合成
    `NSWindow`/visibility removal
    断言两次 created/dismantled 与两次 stop。
  - `Packages/BiliKitCore/Tests/BiliPlaybackTests/LoopbackPlaybackServerTests.swift:394-480`
    通过测试诊断计数检查 12 次替换及 engine
    deinit 后计数归零。
  - 两者均不等价于真实用户关窗、WindowGroup 销毁、OS socket 回收或内存无泄漏。
- **判断**：observer bag **保留**；正常播放返回路径未观察到 listener、已识别 Task/弹幕
  容器持续驻留，但“真实关窗后所有仍可达对象已释放”仍 **尚不能判断**。
- **风险**：把合成 dismantle 误写为真实资源证明，会漏掉 SwiftUI 缓存 view、URLSession
  delegate retain cycle、系统 AVPlayer 内部资源或窗口 owner 未释放。
- **下一步最小验证**：`STATE-001` 已修正，定向 AppKit suite 2/2 普通通过，真实返回与
  端口验证也已完成。若后续修改 player/window owner，再用 Memory Graph 对
  `AVPlayerEngine`/observer bag/host/renderer 做精确代际计数；当前 Allocations 类型统计
  不能替代该结论。
- **依赖 / 冲突**：依赖性能资源线实施 Instruments；依赖隐私线规定 trace 脱敏。

## M501-CONC-004：`DanmakuSession.batches()` 仓库内无调用，外部兼容承诺未知

- **finding_id**：`M501-CONC-004`
- **审计线 / 能力**：AsyncStream 与 continuation 所有权。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliDanmaku/Session/DanmakuSession.swift:12-59`
    保存 continuation 字典，
    `batches()` 创建 `AsyncStream` 并在 termination 时移除；
    `deinit` finish 全部 continuation。
  - 全仓搜索 `batches()` 只有声明，没有生产或测试调用者。实际展示路径通过
    `DanmakuPresentationController` sink，不消费此 stream。
- **声称承担的职责**：向外暴露弹幕批次异步序列。
- **外部事实来源**：
  - Apple [`AsyncStream`](https://developer.apple.com/documentation/swift/asyncstream)
    与 [`Continuation.onTermination`](https://developer.apple.com/documentation/swift/asyncstream/continuation/ontermination)
    规定 producer 必须管理 finish/termination。
  - 当前实现满足形式上的清理要求，但没有调用者就没有独立职责。
  - **证据强度**：Apple 规范 + 完整调用图搜索。
- **OSS 对照及 commit/date**：不适用；是否存在调用者是本仓库事实。
- **真实行为证据**：当前产品弹幕由 presentation sink 显示；未发现依赖该 stream 的用户
  行为。
- **本地测试实际覆盖范围**：没有测试消费 `batches()`；现有弹幕测试覆盖 session/
  presentation 行为，不能证明这个未使用 API 有价值。
- **判断**：**尚不能判断**。当前仓库内可判定为死 API；但 `BiliDanmaku` 在
  `Package.swift` 中是 public library product。只有架构／分发线确认它从未作为受支持
  外部 API 发布、无需兼容承诺后，才能判定 **删除**。
- **风险**：保留会增加 continuation 字典、termination 回调和 deinit 分支，形成无人验证的
  生命周期表面积；删除风险限于潜在未入库调用者，当前单仓库/单 package 调用图未发现。
- **下一步最小验证**：后续修改阶段删除 API 与 continuation 存储后运行 package gate，
  并执行弹幕 session/presentation 测试；本轮不修改。
- **依赖 / 冲突**：架构必要性线可把它计入死 API；若未来确有非 UI 消费者，应以真实调用方
  重新设计，而非预留。

## M501-CONC-005：自定义 URLSession 和 loopback 启动取消边界不完整

- **finding_id**：`M501-CONC-005`
- **审计线 / 能力**：URLSession delegate、NWListener、continuation 的 owner/cancel。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliNetworking/Transport/HTTPClient.swift:75-152`：
    `URLSessionTransport` 可创建带 redirect delegate 的 session，并暴露
    `invalidateAndCancel()`，但没有 deinit 兜底，也没有在类型上区分 owned/borrowed
    session；是否调用完全依赖外层 owner。
  - `BiliKitMac/Composition/AppEnvironment.swift:104-136`、字幕 repository、
    `Packages/BiliKitCore/Sources/BiliNetworking/Range/HTTPRangeClient.swift:147-159`、
    Web QR 与认证 authorizer 均创建自定义 ephemeral
    session。认证/API 在 logout 有 invalidator；字幕 body 与 range client 没有等价显式
    session invalidation。
  - `Packages/BiliKitCore/Sources/BiliPlayback/Bridge/LoopbackPlaybackServer.swift:97-160`
    用 checked continuation 等待
    listener ready/failed；`StartContinuationBox` 保证 exactly once，但外层 task 取消
    没有 cancellation handler 立即调用 `listener.cancel()`。
  - 同文件 `:188-215` 的显式 `stop()` 会清 listener、connections 与 connection tasks。
- **声称承担的职责**：拒绝 redirect，并在 bridge/session 结束时停止网络活动。
- **外部事实来源**：
  - Apple [`URLSession`](https://developer.apple.com/documentation/foundation/urlsession)：
    session 强持有 delegate，直到显式 invalidation 或 App 退出；不 invalidation 可形成
    lifecycle leak。
  - Apple [`invalidateAndCancel`](https://developer.apple.com/documentation/foundation/urlsession/invalidateandcancel%28%29)。
  - Apple [`NWListener.cancel()`](https://developer.apple.com/documentation/network/nwlistener/cancel%28%29)。
  - **证据强度**：Apple 合约 + 静态所有权缺口；尚无真实泄漏证据。
- **OSS 对照及 commit/date**：不适用；Foundation/Network owner 合约优先于 OSS。
- **真实行为证据**：没有现场证据显示当前已泄漏；也没有真实关窗/反复播放后 session、
  delegate、listener 数量归零的证据。
- **本地测试实际覆盖范围**：loopback 测试通过内部诊断计数和受控 transport 证明显式
  `stop()`。新增
  `LoopbackPlaybackServerTests.cancellingStartDoesNotLeaveListenerRunning` 在创建
  `start()` task 后立即取消：调用仍成功返回，诊断显示 listener 继续运行；“观察到
  CancellationError”与“listener 未运行”两个目标断言以 known issue 登记。这确定了
  cancellation handler 缺口，不依赖制造慢 listener。测试结束显式 stop，因此不制造
  持久端口。Foundation owned session/delegate 仍因 transport 不暴露 owner/seam 而无法
  直接计数；Apple retain/invalidation 合约与静态调用图仍是该部分证据。
- **判断**：**替换** URLSession transport 的隐式进程级生命周期为显式 owner/invalidation；
  loopback start cancellation 的具体修法 **尚不能判断**，先增加确定性测试。
- **风险**：中等。当前确证的是 owner/invalidation 缺口，不是已经发生的 leak；窗口反复
  开关后可能累积 session/delegate 或延迟 listener。直接在
  transport deinit invalidation 又可能误伤共享 session，因此必须先区分 owned/borrowed。
- **下一步最小验证**：
  1. 给 transport 暴露只针对 owned session 的显式 invalidation，并用 spy 证明仅调用一次；
  2. loopback 取消缺口已可在真实 `NWListener` 上确定性复现；实施 cancellation handler
     同时 cancel listener，并验证 `StartContinuationBox` exactly-once 恢复，把两个
     known issue 转为普通断言；
  3. 再以 Instruments/Memory Graph 验证真实关窗，不用固定 sleep 作为完成条件。
- **依赖 / 冲突**：与认证线的 logout invalidator、媒体线的 range client owner、性能线的
  Instruments 计划有交叉；实施前需共同裁决，避免重复 invalidation。

## M501-CONC-006：分 P 切换生命周期目前没有可审计的产品入口

- **finding_id**：`M501-CONC-006`
- **审计线 / 能力**：分 P 切换时 player/subtitle/danmaku replacement。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliBrowseFeature/VideoDetail/GuestVideoDetailView.swift:152-183`
    仅把 parts 渲染为
    `HStack`/`ForEach` 文本，没有 `Button`、tap action 或 selection binding。
  - `Packages/BiliKitCore/Sources/BiliBrowseFeature/VideoDetail/GuestVideoViewModel.swift`
    只有 `loadVideo`，没有 select-part 行为。
- **声称承担的职责**：当前 scope 展示分 P 元数据；未来若加入选择行为，切换时必须清理
  上一 P 的媒体、字幕和弹幕。
- **外部事实来源**：此项是当前调用图与可交互 UI 的仓库事实；没有外部 API 能弥补不存在
  的产品入口。**证据强度**：静态完整调用图；未做 UI 自动化。
- **OSS 对照及 commit/date**：尚未对照；在入口不存在前，对比第三方实现不能证明本 App
  的生命周期正确。
- **真实行为证据**：无；当前 UI 无法触发分 P 切换。
- **本地测试实际覆盖范围**：替换视频和字幕的单元测试不等于分 P 产品流程；没有从 parts
  UI 到 player/subtitle/danmaku 的端到端测试。
- **判断**：当前无分 P 切换实现，故生命周期行为 **不适用**。`docs/ROADMAP.md:43` 的
  “分 P 纵向链路接通”与 `docs/validation/M4.5-slice-b-danmaku-2026-07-24.md:15`
  明确“不增加分 P 选择”一致；安全／ADR 中“切换分 P 时清理”只是未来不变量，不能当成
  已完成行为。
- **风险**：若路线图或完成声明把“能解析分 P 元数据”写成“支持分 P 切换”，会制造错误
  证据；未来接上入口时也可能绕过现有 replacement owner。
- **下一步最小验证**：产品线先裁决分 P 是否属于当前里程碑；若属于，先定义唯一
  `PlaybackIdentity(bvid,cid)` 切换入口，再做取消/资源释放的确定性测试和真实 UI 验证。
- **依赖 / 冲突**：依赖产品 IA、媒体播放与路线图声明审计。

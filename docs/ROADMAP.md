# BiliKit macOS 路线图

> 更新时间：2026-08-09。本文只描述本分支合并后 `main` 的产品基线、产品大方向和唯一已选择的
> 后续阶段。
> 完成状态以当前代码、自动测试和必要的真实行为证据共同判断；旧计划、分支、worktree、
> checkpoint、测试数量和 CI run ID 不构成现行契约。

## 1. 产品目标

BiliKit 是 macOS-first 的原生第三方 B 站浏览与播放客户端。v1 要形成稳定的日常观看
闭环：

```text
首页个性推荐
  → 同窗口视频页
  → 播放 + 字幕 + 弹幕
  → 相关推荐连续观看
  → 返回并恢复真实来源上下文
```

“热门”继续作为公共发现入口，不能冒充个性推荐首页。详细产品优先级见
[`product/PRODUCT-VISION.md`](./product/PRODUCT-VISION.md)，界面方向见
[`product/UIUX-VISION.md`](./product/UIUX-VISION.md)。

## 2. 当前工程基线

- Swift 6、SwiftUI、AVPlayer-first，最低 macOS 15。
- 一个本地 Swift Package，App target 负责 Scene、产品级导航、Composition 和 macOS 宿主。
- Feature 按 Browse、Auth、Library 产品域组织；跨域跳转由 App 层协调。
- Application 只暴露 use case、port 和平台无关状态；API、认证、播放与弹幕实现位于各自
  adapter target。
- 当前产品入口包含热门、搜索、观看历史、认证和同窗口视频页。
- 播放链路包含 DASH 到本机 loopback HLS bridge、单一 AVPlayer host、统一播放时间线、
  语义音轨、系统原生字幕与弹幕；HLS master 会保守发布已解析的音视频格式、语言、角色、
  closed-captions、independent-segments 与按需 I-frame metadata。

模块与依赖的持久约束见 ADR 0001–0009。当前 target、product 和 entitlement 必须以
`Packages/BiliKitCore/Package.swift` 与 Xcode 工程为准。

## 3. 工程能力状态

### M0–M2：工程、真实播放与游客闭环

- 工程、模块、CI 和最低平台基线已建立。
- 游客热门、WBI 搜索、详情、分 P 和真实播放纵向链路已接通。
- loopback 播放 bridge 的 Range、seek、替换与清理边界已有受控测试和真实样本证据。

证据：

- [`validation/M1-real-playback-2026-07-21.md`](./validation/M1-real-playback-2026-07-21.md)
- [`validation/M2-guest-api-2026-07-21.md`](./validation/M2-guest-api-2026-07-21.md)

### M3：认证与观看历史

- Web QR 登录使用独立 ephemeral session、精确来源和重定向策略、状态与次数/总时限上限。
- 凭据只进入 `BiliAuth` 内存与 Data Protection Keychain；恢复、失效和离线本地登出有
  明确清理语义。
- 观看历史通过只读授权 endpoint 接入，游客链路不携带认证信息。
- 搜索使用登录增强的账户读取：本地明确无凭据时仍匿名；凭据故障与服务端风控不静默降级。
- Popular、视频详情、Related、UP 主签名与分 P 列表使用同一登录增强账户读取语义，并在
  账户 generation 变化时丢弃旧账户工作集或详情生命周期。
- 真实扫码、重启恢复、历史读取、进入播放、登出和再次启动后的游客回退已完成受控验证。

证据：

- [`validation/M3-auth-contract-research-2026-07-21.md`](./validation/M3-auth-contract-research-2026-07-21.md)
- [`validation/M3-keychain-authorization-2026-07-21.md`](./validation/M3-keychain-authorization-2026-07-21.md)
- [`validation/M3-watch-history-2026-07-21.md`](./validation/M3-watch-history-2026-07-21.md)
- [`security/M3-threat-model.md`](./security/M3-threat-model.md)

### M4：字幕、弹幕与播放生命周期

- 播放器向上提供唯一 identity、位置、时长、速率、状态和 discontinuity generation。
- 字幕目录与按需正文经 loopback HLS WebVTT 进入 AVPlayer 原生字幕菜单，默认关闭；
  切轨、暂停、倍速、seek、替换与迟到结果隔离已接通。
- 弹幕 protobuf decoder、分段调度、有界预取/缓存/去重和 Core Animation renderer 已接通。
- 播放替换、窗口关闭和 stop 后的任务、订阅、server、renderer 与 layer 清理已有受控证据。

证据：

- [`validation/M4-protocol-contract-2026-07-22.md`](./validation/M4-protocol-contract-2026-07-22.md)
- [`validation/M4-playback-timeline-2026-07-22.md`](./validation/M4-playback-timeline-2026-07-22.md)
- [`validation/M4-subtitle-vertical-slice-2026-07-22.md`](./validation/M4-subtitle-vertical-slice-2026-07-22.md)
- [`validation/M4-danmaku-data-scheduler-2026-07-22.md`](./validation/M4-danmaku-data-scheduler-2026-07-22.md)
- [`validation/M4.4-renderer-production-2026-07-23.md`](./validation/M4.4-renderer-production-2026-07-23.md)
- [`validation/M4-closeout-2026-07-23.md`](./validation/M4-closeout-2026-07-23.md)
- [`validation/M4.6-subtitle-lifecycle-roadmap-2026-07-25.md`](./validation/M4.6-subtitle-lifecycle-roadmap-2026-07-25.md)
- [`validation/native-avplayer-subtitles-2026-08-07.md`](./validation/native-avplayer-subtitles-2026-08-07.md)
- [`security/M4-data-privacy.md`](./security/M4-data-privacy.md)

### M4.5：macOS 界面基线

- App 使用侧栏与主内容两栏外壳，热门、搜索与观看历史共享窄 `BiliUI` 视频卡片边界。
- 视频进入同窗口独立播放页；播放页在紧凑与宽布局间保持单一 player host。
- 搜索提交使用系统行为；键盘、辅助标签、深色与大字体仍以当前真实 UI 观察为准。

证据：

- [`validation/M4.5-slice-b-2026-07-24.md`](./validation/M4.5-slice-b-2026-07-24.md)
- [`validation/M4.5-high-refresh-card-scroll-2026-07-24.md`](./validation/M4.5-high-refresh-card-scroll-2026-07-24.md)

### M5.0–M5.0.2：原生日用导航、外部事实审计与登录态自动画质

- 热门、搜索与历史使用原生平级导航；视频页使用系统层级返回并保留来源工作集和语义
  滚动位置。
- 播放退出、卡片选中残留、字幕默认行为、自动画质与相关生命周期缺口已经过定点修复。
- 外部 API、媒体、认证、并发、原生 UI、缓存、辅助功能、性能、架构与分发已完成
  M5.0.1 审计；尚未实施的判断不因审计完成自动进入生产。
- 登录态自动画质使用精确 legacy playurl endpoint 级 Cookie 授权；只有明确无本地凭据时
  保持匿名。凭据故障、HTTP 403/412 与业务拒绝不匿名降级，Cookie 不进入媒体、图片、
  相关推荐或 loopback。
- 登录态进入详情时复用同一 playurl 响应的服务端分 P／毫秒断点，在首次发声和出帧前由
  单一播放器完成定位再开播；匿名、无效、片尾和 CID 不匹配记录从头播放。播放器左下角以
  当前 item token 约束的浮层提供“从头播放”操作，不增加本地进度持久化或历史写入。
- 服务实际返回且 AVC/AAC decoder 可消费的全部 representations 继续进入既有单一
  `AVPlayerItem` 原生 ABR；没有手动画质菜单、双播放器或 4K 保证。

证据：

- [`development/M5.0-daily-client-state-retention-decision.md`](./development/M5.0-daily-client-state-retention-decision.md)
- [`audits/M5.0.1/`](./audits/M5.0.1/)
- [`validation/authenticated-playback-quality-2026-08-08.md`](./validation/authenticated-playback-quality-2026-08-08.md)

### 已实现、最终真实复验待完成：语义音轨与 HLS metadata

- `PlaybackAudioTrack` 把原声／machine-generated 语义与轨内码率 representations 分离；
  已授权基础 playurl 响应可在精确 Cookie 边界内取得受限 AI 目录与媒体，Cookie 在映射前
  终止。响应语言、production type、授权来源、认证 epoch 与 HLS 时间轴不可信的可选轨
  不会进入 master。
- HLS master 已接入 `LANGUAGE`、`CHARACTERISTICS`、`CHANNELS`、`BIT-DEPTH`、
  `SAMPLE-RATE`、`DEFAULT/AUTOSELECT`、`CLOSED-CAPTIONS=NONE`、条件化
  `EXT-X-INDEPENDENT-SEGMENTS` 与字幕 localized rendition names；原声语言未知时保守使用
  `und`，不猜测 translation。
- I-frame playlist 只对严格 type-1 SAP 的完整 fMP4 fragments 发布，并复用同一无认证媒体
  route 按需 Range；没有预取、转码、下载或独立网络 owner。
- 最终实现已通过 App gate 与定点契约测试；由于审查修正后的登录态 AI 请求与可听切轨尚未
  重新执行真实复验，本 checkpoint 不把生产真实验收标为完成。只有在用户另行批准真实登录态
  验证并更新脱敏证据后，才能关闭该边界。

证据：

- [`validation/authenticated-ai-audio-2026-08-09.md`](./validation/authenticated-ai-audio-2026-08-09.md)
- [`validation/authenticated-ai-audio-stage5-2026-08-09.md`](./validation/authenticated-ai-audio-stage5-2026-08-09.md)
- [`validation/semantic-audio-hls-stage7-2026-08-09.md`](./validation/semantic-audio-hls-stage7-2026-08-09.md)
- [`adr/0002-loopback-http-playback-bridge.md`](./adr/0002-loopback-http-playback-bridge.md)

## 4. 唯一当前阶段：原生播放侧栏与只读评论

当前阶段在已经生产化的原生播放侧栏和真实选择链上接入只读评论。评论读取使用与其他公开
Browse 一致的登录增强语义：本地有凭据时携带短生命周期 Cookie 取得属地等增强字段，明确
无凭据时仍匿名读取。旧 spike 只提供性能与交互边界；生产视觉、数据状态和生命周期按当前
AppKit 架构重写。

### 用户结果

- 播放状态继续使用同一个系统 `NavigationSplitView` sidebar：显示 UP 主、五行折叠简介、
  分区／选集／分 P 与只读评论。
- 单分 P 隐藏整个目录；多分 P 显示当前项、标题和时长，并可在同一播放目的地内按真实
  `(bvid, cid)` 切换 playurl、播放器 item、字幕和弹幕；目录使用最多同时显示 5 行的
  独立滚动 `List`，标题显示总数，行高随文字尺寸缩放；折叠后重新展开会定位当前分 P，
  不会因分 P 数量撑长整个 sidebar。
- detail 主区收口为标题与元信息、带系统字幕菜单的唯一播放器和弹幕控制；简介、分 P 和旧 400 pt
  右栏不再重复出现。
- 窄窗口优先保证播放器宽度，sidebar 继续通过系统行为收起和恢复；简介展开、分 P 展开、
  sidebar 显隐、窗口 resize 和媒体替换均不得创建第二个 player host。

### 实施边界

- 先统一 detail 与 sidebar 共用的稳定展示 context，再原子完成 sidebar 接入和 detail
  重排；不能留下两处同时显示简介或分 P 的中间生产状态。
- 保持一个 `NavigationSplitView`、detail 内一个 `NavigationStack(path:)`、单层
  `PlaybackDestination` 和一个 `AppWindowOwner`／`AVPlayerEngine`／`PlayerHostView`。
- A → B 仍只替换媒体 identity；系统返回恢复来源入口、搜索草稿、工作集和语义滚动位置。
- 同 BVID 分 P 切换不增加导航层级；BVID 级展示上下文与请求中／已呈现媒体 identity 分离，
  loading、failure 与 retry 不把旧分 P 继续标作当前媒体。
- 评论 API DTO 留在 `BiliAPI`，只读 port/use case 留在 `BiliApplication`，模型留在
  `BiliModels`，唯一评论页面状态继续由 `PlaybackCommentsViewModel` 拥有；不增加第二个 Package、
  空 target、通用 Store 或第二套分页状态。
- 整条侧栏只有一个 `NSScrollView + NSCollectionView`；评论正文使用不可独立滚动的原生
  `NSTextView`，不加入每行 hosting、评论写操作或从不透明资源引用反推图片 URL。
- 横向相关推荐已经确定为后续播放工作台方向，但本阶段不建立占位 View、数据模型、fixture
  seam 或网络实现，也不把它登记为当前并行阶段。

### 完成证据

- 状态测试证明首次加载、A → B 加载／失败／重试、generation 隔离和 reset 下，detail 与
  sidebar 使用同一展示 context；旧内容在替换状态下不会保持可交互或进入辅助阅读路径。
- 分 P 状态测试证明 CID replacement、目标失败／重试、P1 → P2 → P1 ABA、reset 与迟到结果
  隔离；播放器 ready 后的异步 item failure 也必须按 identity 与不可复用 load intent 进入
  诚实失败状态并清理 item、bridge、字幕与弹幕。
- 结构测试证明单分 P 隐藏、多分 P 与空／非空简介呈现准确；真实分 P Button 的 selected、
  loading、failure 与 retry 语义与当前请求／呈现 identity 一致，并在 AX label 中稳定表达
  状态而非只依赖可关闭的 hint。
- App 生命周期测试证明媒体替换前后保持一个真实 `AVPlayerView`，Back／关窗后完成拆除与
  资源清理。窗口 resize、系统 Back、sidebar、长文本与大字体仍需按当前产品真实观察。
- VoiceOver 与 Full Keyboard Access 必须分别真人检查阅读／焦点顺序；AX tree、截图或 build
  不能替代真人辅助功能结论。
- 评论契约测试证明 A → B、排序 reset、主评论 append、1,000 条内存上限、楼中楼展开／收起／
  翻页／失败重试和迟到结果隔离；renderer 契约证明稳定 RowID、单滚动 owner、可选择 TextKit、
  2,048 高度缓存和每批 32 行 resize 精测。真实网络、连续 resize 与真人辅助功能仍单独验收。

阶段验证记录：
[`M5.0-playback-context-sidebar-2026-08-07.md`](./validation/M5.0-playback-context-sidebar-2026-08-07.md)。
在用户确认真人辅助功能检查前，本阶段仍保持进行中。

已经确认但尚未排期的事项统一登记在
[`product/PRODUCT-CANDIDATES.md`](./product/PRODUCT-CANDIDATES.md)。候选登记不表示顺序、
版本承诺或实施授权。完成或重新裁决当前阶段后，本节再替换为下一个唯一阶段。

## 5. v1 非目标

- 下载、转码、媒体导出和离线媒体库。
- 直播。
- 多账号。
- 区域解锁、DRM 绕过或权限规避。
- 评论、关注、收藏、稍后再看等写操作。
- 服务端观看进度写入；它是独立候选。

新增产品范围必须先更新产品愿景；已经接受但尚未排期的事项进入候选登记。只有被选为
唯一下一阶段时才更新本路线图，不能通过顺手增加 endpoint、占位 target 或通用基础设施
进入当前实现。

# 06 状态与缓存

状态：第二轮取证与独立交叉复核完成；`STATE-001` 经用户裁决已实施窄修复
（2026-07-27）。

## STATE-001：`@State` owner 模式正确，但当前 root 构造可能产生脱节对象

- **finding_id**：STATE-001
- **审计线与涉及能力**：SwiftUI View state、窗口 owner、Observation。
- **当前实现（文件、符号、调用链）**：
  - `BiliKitMac/App/BiliKitMacApp.swift:16-27` 的每个 `WindowGroup` content 创建一个
    `AppRootView`；
  - `BiliKitMac/App/AppRootView.swift` 现在以单一私有 `@State` 持有
    `AppWindowOwner`；owner 同时持有导航 coordinator、六个 `@Observable` ViewModel
    与 `playerContent`，sheet 与已提交搜索词仍是 root 自身的值状态；
  - `AppRootView.onDisappear` 清理导航、Browse、认证临时工作和历史
    （`AppRootView.swift:111-116`）。
- **它声称提供的职责**：让页面状态与单个窗口生命周期一致；SwiftUI 重建 View value 时
  保留 owner；子 View 只观察实际读取的属性。
- **外部事实来源**：
  - Apple《[Migrating from the Observable Object protocol to the Observable
    macro](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)》
    明确说明 macOS 14 起 `@Observable` 可由 `@State` 持有并传给子 View；
  - Apple《[State](https://developer.apple.com/documentation/swiftui/state)》将
    `State` 定义为 View hierarchy 内的单一事实来源，并给出 `@State` 持有
    `@Observable` reference 的写法；
  - 但当前 Xcode 26.6 仍要求 `State(initialValue:)` 的初始表达式在 View `init` 时先被
    求值；父级更新重建 View value 时，新构造的 class 可随后被旧 State storage 丢弃。
    Apple 在 WWDC26 介绍的 Xcode 27 State macro 才专门消除这类无用构造，本基线不能使用
    未来工具链语义反推当前安全；
  - 访问日期均为 2026-07-27。最低系统 macOS 15 覆盖上述 macOS 14 availability。
- **OSS 对照及 commit/date**：不适用。该判断只关乎 BiliKit 的窗口 owner；其他 App
  如何切分 ViewModel 不能证明本项目应采用相同生命周期。
- **真实行为证据**：M5.0 的两次热门 tab 往返中，同一窗口内工作集和位置均被保留；关窗
  后新窗口是否完整重新建立 owner 尚未做 Memory Graph 验证。2026-07-27 新增无网络
  根视图身份验证：保持同一个 `NSHostingView<AppRootView>` 的结构身份，依次赋入由两个
  environment 构造的 root；播放请求仍进入第一套被 `@State` 保留的 model/player，
  画面 probe 却记录第二次 initializer 的 `playerContent`。这把“可能脱节”从静态推断
  提升为确定性触发证据。
- **本地测试实际证明的范围**：
  `PlayerHostLifecycleProbeTests/rootReinitializationKeepsPlayerSurfaceWithRetainedModels`
  已触发同 identity root re-init。修复前为 expected failure；修复后串行 xcresult 为
  2 tests、2 passed、0 expected/failed，其中 root re-init 保留第一套 model 的同时也
  保留第一套 player surface，正常返回/移除 host 的配对仍通过。它证明确定性脱节路径已
  封闭，不证明真实窗口多久重建，也不证明 system 最终释放整个窗口对象图。
- **判断**：`@State` 持有窗口 Observation owner 的模式 **保留**；旧 root 构造方式已
  **替换**为单一 `AppWindowOwner`。SwiftUI 即使丢弃新 initializer 产生的 owner，也只会
  整套保留旧 owner，不再跨代混合 model/engine 与 player surface。
- **风险：影响、触发条件、可恢复性**：若 `onDisappear` 在窗口暂时移出层级而非销毁时
  触发，可能提前清空工作集；若对象图形成 retain cycle，`@State` 本身不会代替释放验证。
  影响限于当前窗口，重新打开可恢复。
- **下一步最小验证**：expected failure 已转为普通通过；继续创建两个窗口并用 Memory
  Graph 检查具体 ViewModel/engine/session/player host，而不是检查临时 value
  `AppEnvironment`。
- **与其他 finding 的依赖或冲突**：依赖 CONC-003 的真实窗口释放验证；不与
  STATE-008 的“无跨启动持久化”冲突。

## STATE-002：热门与最后一次搜索的两份有界工作集

- **finding_id**：STATE-002
- **审计线与涉及能力**：页面工作集、request identity、刷新与失效。
- **当前实现（文件、符号、调用链）**：
  - `GuestBrowseViewModel.swift:21-30` 只有一个 active presentation/task/generation，
    另存 `popularWorkset` 与 `searchWorkset`；
  - `activatePopular`／`activateSearch` 只在 identity 改变时替换对应 workset
    （`:36-64`），普通重新激活直接应用已存状态（`:137-154`）；
  - `refresh` 显式取消旧 task，已加载时保留内容并附加 refreshing/error
    （`:126-154,156-233`）；
  - `reset` 清空两份 workset（`:106-110`）。容量是热门一页与最后一个搜索 query 一页，
    不是按 URL 或 response 保存的通用缓存。
- **它声称提供的职责**：同一窗口内 tab/播放页往返立即恢复内容，显式刷新才重新请求；
  query/route/generation 阻止旧结果覆盖新 identity。
- **外部事实来源**：
  - Apple `State` 文档只定义 View hierarchy 内状态 owner，并不提供远端数据的 TTL、
    request coalescing 或产品失效策略；
  - 因此本项是否保留取决于仓库已记录的用户结果，而不是“系统已有 cache API”。
- **OSS 对照及 commit/date**：不适用。服务客户端的页面保留数量是产品选择；OSS
  实现不能替代本项目“热门 + 最后搜索”的明确容量。
- **真实行为证据**：
  `docs/development/M5.0-daily-client-state-retention-decision.md:17-34` 记录用户要求为
  普通往返不重载、显式刷新保留旧内容；当前真实观察证明热门工作集往返可见，但搜索结果
  自身的完整往返仍列为未关闭路径。
- **本地测试实际证明的范围**：
  `GuestBrowseAndVideoViewModelTests.swift:148-239` 证明热门/搜索各请求一次、刷新失败保留
  同 identity 内容、reset 后重新请求；fixture 不证明数据多久仍新鲜，也不证明未来推荐
  首页可复用该结构。
- **判断：保留**。它是容量明确的窗口工作集而非结构噪音；不得升级成通用 repository
  cache。新 query、显式刷新与 root 退出路径会使其失效；其中关窗是否总触发预期
  `onDisappear` 仍待 STATE-001 的真实窗口验证。
- **风险：影响、触发条件、可恢复性**：长时间停留后返回可能显示旧数据，直到用户刷新；
  搜索仅保留最后 query，输入新 query 会丢弃前一 query 工作集。两者均可用显式刷新恢复。
- **下一步最小验证**：完成“搜索结果 → 其他 tab → 搜索”和“搜索结果 → 播放 → 系统返回”
  两条真实路径，记录请求次数和可识别内容，不新增 TTL。
- **与其他 finding 的依赖或冲突**：与 STATE-004 的 HTTP response cache 正交；与
  STATE-003 的滚动位置共同构成用户可见返回上下文。

## STATE-003：每 Tab 的语义 `ScrollPosition`

- **finding_id**：STATE-003
- **审计线与涉及能力**：SwiftUI View state、滚动位置、identity。
- **当前实现（文件、符号、调用链）**：
  - `AppShellView.swift:18-26` 分别持有热门、搜索、历史三个
    `ScrollPosition(idType: String.self)`；
  - Grid 在 `PopularFeedView.swift:87-110`、
    `VideoSearchView.swift:130-155`、`WatchHistoryView.swift:106-152` 使用
    `scrollTargetLayout()` 与 `.scrollPosition($scrollPosition)`；
  - 新提交搜索词和登录身份改变时只重置对应 position
    （`AppShellView.swift:85-94`）。
- **它声称提供的职责**：由 SwiftUI 以 item identity 维护窗口内语义滚动位置；项目不再
  同时保存数值 offset 或 snapshot。
- **外部事实来源**：
  - Apple《[ScrollPosition](https://developer.apple.com/documentation/swiftui/scrollposition)》
    说明它表达 semantic position，可配合 `scrollTargetLayout` 以顶端可见 item identity
    更新位置；
  - macOS 26.5 SDK
    `SwiftUI.swiftinterface:21753-21762` 标注 `scrollPosition(_:)` 为 macOS 15；
    因此完全覆盖最低系统。
- **OSS 对照及 commit/date**：不适用。原生 API availability 与当前真实行为比第三方
  scroll workaround 更高优先级。
- **真实行为证据**：历史审计记录空 `ScrollPosition` 曾从 `0.592` 变成 `0.312`；补上
  `idType` 与 target layout 后
  两次热门往返分别为 `0.195066 → 0.194867`、`0.389877 → 0.389447`。这只是两个热门样本，
  不是搜索、历史、resize 的稳定契约。
- **本地测试实际证明的范围**：现有 Package/App unit tests 不测真实 scroll geometry；
  unsigned 辅助功能树也不能证明位置精度。
- **判断：保留**。这是最低系统已有的语义 API，且已经删除双 owner；当前没有证据支持
  恢复 offset/snapshot。
- **风险：影响、触发条件、可恢复性**：Lazy grid 在窗口 resize、内容 identity 变化或
  cell 高度变化时可回到同一语义 item 但像素比例不同；这不等同于丢失 identity。用户可
  继续滚动恢复。
- **下一步最小验证**：对热门、搜索、历史各执行 tab 往返、播放返回和 resize，记录返回前
  后顶端 item identity，而非只比较 scrollbar ratio。
- **与其他 finding 的依赖或冲突**：与 UI-线的产品导航结论相互依赖；STATE-002 保存内容，
  本项只保存 viewport，不可互相替代。

## STATE-004：生产网络统一禁用 `URLCache`

- **finding_id**：STATE-004
- **审计线与涉及能力**：URLSession response cache、认证隐私、游客 API、字幕与媒体 Range。
- **当前实现（文件、符号、调用链）**：
  - production `BiliAPIClient` 的同一个 ephemeral transport 同时承载游客、历史、登录字幕
    目录，并在 `AppEnvironment.swift:104-122` 设置 `urlCache = nil` 与
    `.reloadIgnoringLocalCacheData`；
  - 字幕正文、QR、凭据验证、Range client 也分别使用 ephemeral/no-cookie/no-cache：
    `BiliSubtitleRepository.swift:17-31`、`WebQRLoginSession.swift:505-517`、
    `BiliCredentialRequestAuthorizer.swift:269-281`、`HTTPRangeClient.swift:147-158`。
- **它声称提供的职责**：不把登录/历史/字幕/媒体响应写入共享或磁盘 cache，且每次按当前
  服务状态取数。
- **外部事实来源**：
  - Apple《[URLCache](https://developer.apple.com/documentation/foundation/urlcache)》
    说明它是 request → cached response 的内存/磁盘复合缓存，可设容量和目录；
  - Apple《[ephemeral](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)》
    只保证“不持久写盘”，session-related data 仍可存在 RAM；本项目额外将
    `urlCache = nil` 才是完全禁用；
  - Apple《[requestCachePolicy](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/requestcachepolicy)》
    说明默认 `.useProtocolCachePolicy` 依据协议缓存语义；
  - macOS 26.5 SDK `NSURLSession.h:741,839` 明确 `URLCache == nil` 表示不执行 caching。
    以上 API 均早于 macOS 15。
- **OSS 对照及 commit/date**：未使用。OSS 是否缓存 B 站响应不构成安全或新鲜度规范，
  且本轮未取得两个实现的隐私/失效证据。
- **真实行为证据**：2026-07-28 以当前匿名请求头连续读取公开热门第一页，两次均为
  HTTP 200、`Cache-Control: no-cache`，并分别完整传输约 11.5 KB；同日以签名测试宿主
  通过当前 WBI 链路连续执行同一匿名搜索，两次也均为 HTTP 200、
  `Cache-Control: no-cache`，分别完整传输 32,069 bytes，且均无 ETag、
  Last-Modified、条件请求或 304。两个样本都没有协议缓存命中收益。现有字幕错配事件仍
  要求在 endpoint/identity 未完全稳定前避免不透明响应复用，但不能据此永久禁止所有
  游客 GET 缓存。
- **本地测试实际证明的范围**：测试可检查 configuration 与请求次数；未模拟真实
  `Cache-Control`/`ETag`，不证明启用协议缓存后的服务行为或隐私边界。
- **判断：保留** V1 当前 no-cache 设计；不为热门或匿名搜索引入 `URLCache`。当前两个
  endpoint 都要求重新验证且没有 validator，开启 cache 没有已证收益。磁盘 cache 还会
  把含搜索 query 的 request key 与 response 持久化，违反 STATE-008 的当前无内容
  持久化边界。认证、历史、字幕正文和媒体 Range 的 no-cache 同样保留；不能在共享
  session 上“一键启用”。详情等未测 endpoint 若未来出现明确 validator/重复传输成本，
  作为新的定点 finding 重开，不从本结论外推。
- **风险：影响、触发条件、可恢复性**：保持现状会增加重复网络与图片之外的 API latency；
  粗暴启用可能在登出后复用历史/字幕响应、掩盖 endpoint 变化或把个人内容写盘。前者可
  重试，后者属于隐私和正确性风险。
- **下一步最小验证**：V1 无需继续。只有真实 endpoint 开始返回 validator／可缓存语义，
  或重复请求成本成为可测问题时，才以该 endpoint 单独重开；届时先设计与 authenticated
  transport 分离且登出可清理的 session，不先写通用 repository cache。
- **与其他 finding 的依赖或冲突**：依赖 API-002/005 与 PRIV-002 的会话/redirect
  边界；与 STATE-002 不重复。

## STATE-005：`AsyncImage` 在 macOS 15–26 没有项目可控缓存契约

- **finding_id**：STATE-005
- **审计线与涉及能力**：图片请求、解码、内存容量、列表复用。
- **当前实现（文件、符号、调用链）**：
  `BiliUI/VideoCard.swift:55-75,102-124` 对封面和头像直接使用
  `AsyncImage(url:)`；项目没有 image loader、`NSCache`、预取、容量、失效或登出清理。
- **它声称提供的职责**：异步下载并按 phase 显示 placeholder/success/failure；当前代码
  没有声称提供稳定缓存。
- **外部事实来源**：
  - Apple《[AsyncImage](https://developer.apple.com/documentation/swiftui/asyncimage)》
    说明 `AsyncImage` 使用 shared `URLSession`；文档只从 macOS 27 起明确“following the
    transport protocol”缓存，并新增 request/session 定制入口；
  - WWDC26《[What’s new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)》
    明确给出新增动机：此前 `AsyncImage` 不保留图片，Lazy 容器滚回已离屏内容时会重新加载；
    2027 系统开始按 HTTP cache headers 自动缓存下载的图片数据，旧 `url:` 调用无需改代码。
    只有用 Xcode 27 构建时才能使用新的 `URLRequest` initializer 与
    `asyncImageURLSession(_:)` 定制入口；
  - `URLRequest` 入口提供逐请求 cache policy 等控制，view hierarchy 上的自定义
    `URLSession` 则提供长期 `URLCache` 容量等配置。Apple 的表述是缓存 downloaded image
    data，没有承诺 decoded/transformed image cache、预取或图片处理 pipeline；
  - macOS 26.5 SDK `SwiftUI.swiftinterface:14265-14281` 中仅有 `url:` initializers，
    availability 为 macOS 12；没有 macOS 27 的 request/session API。
  - 因此最低 macOS 15 至当前 macOS 26 不能把“下载后稳定缓存、容量可控、可预取”当成
    `AsyncImage` 契约。
- **OSS 对照及 commit/date**：
  - 活跃的 ATV-Bilibili-demo（当前 checkout `86ba6f5`, 2026-07-05）使用 Kingfisher；
    卡片封面按 360×202 下采样并缓存原图，头像先请求 240×240 CDN 缩略图、再按 80×80
    下采样。项目在 `fdff13b`（2025-12-21）另加 500 MB 磁盘上限，又在 `8f10032`
    （2026-01-20）因超大头像崩溃补 CDN 缩略图，说明库不能替产品决定输入尺寸和容量；
  - 活跃的 Darock-Bili（当前 checkout `60d66761e`, 2026-06-28）使用
    SDWebImageSwiftUI，但主动关闭强内存缓存、只保留 weak memory cache，并在活跃时清理；
  - cilicili 当前 shallow snapshot `6f02857` 自建 actor pipeline，含 NSCache、in-flight
    合并、独立 URLCache、预取、失败 TTL、并发上限和自适应预算。这是重功能产品的控制面
    对照，不是 BiliKit 应复制的最小实现；
  - 较简单且已不活跃的 Bili-Swift（最后提交 `e807ce7`, 2025-12-10）仍直接使用
    `AsyncImage`。SDWebImageSwiftUI 上游 README 也明确建议：只支持 iOS 15+/macOS 12+
    且不需要动画格式时，先尝试系统 `AsyncImage`；
  - Nuke、Kingfisher 和 SDWebImage 的共同增量不是“显示远端静态图”，而是明确的
    memory/disk cache、request coalescing、downsampling/processing、prefetch、取消和
    容量/失效控制。采用率只能证明这些需求有成熟方案，不能证明当前产品已出现这些需求。
- **真实行为证据**：2026-07-28 当前 macOS 26.5.2 的签名测试宿主只访问
  `127.0.0.1` 合成图片。50 个 640×360 URL 首次各请求一次；整棵图片子树销毁后以相同
  URL 重建，即使 25 个响应声明 `Cache-Control: public, max-age=3600`，仍与 25 个
  `no-store` 响应一样全部再次请求。使用与产品相同的 `ScrollView` +
  `LazyVGrid` 加载 50 个 cacheable URL，六个成功的独立宿主样本中，首次滚至底部请求
  数在 24–50 之间；顶部 cell 均 disappear/reappear，五次回到顶部新增 0 次请求，一次
  新增 6 次。没有远端 URL、账号、Cookie 或正文参与。
- **本地测试实际证明的范围**：上述探针证明当前 OS 上 `AsyncImage` 在完整重建与
  LazyVGrid 离屏复用路径中不提供本项目可依赖的协议缓存复用。整棵重建样本 RSS
  约 109.2→151.8→152.4 MiB，清空后即时约 152.6 MiB；这只证明工作集高水位，不区分
  decoded image、URLCache data 与 allocator retained pages，也不证明泄漏。合成
  `sidebarAdaptable TabView` 宿主触发 AppKit 窗口动画释放崩溃，已作为无效探针删除，
  不作为真实 App Tab 行为证据。
- **判断：V1 保留**。产品已裁决 V1 全系统统一使用 `AsyncImage`，不引入第三方或自建
  image pipeline。完整子树重建时的重复请求已经稳定证明，但产品
  同形的 LazyVGrid 回滚没有稳定复现：六个有效样本仅一次出现 6 个额外请求。结合当前
  真实 App 短样本无 250 ms hang，以及 SDWebImage 上游对相同最低系统/静态图需求也推荐
  先用 `AsyncImage`，并且 macOS 27 已由系统补上这一核心缺口，现有证据不足以授权立即
  引入 image pipeline。该未来能力不能反推 macOS 15–26 已有缓存，也不能成为抬高 V1
  最低系统的理由。若以后
  出现稳定重复请求、可见闪烁、流量或解码开销，应替换为有明确 owner、URL identity、
  memory capacity、取消与清理规则的实现；仍不得直接推导第三方依赖、自研方案或磁盘
  持久化。
- **风险：影响、触发条件、可恢复性**：大量卡片滚动/往返时可能重复下载和解码，造成流量、
  闪烁和 CPU；自建无限字典又会造成内存增长。两者退出窗口后均可恢复。
- **下一步最小验证**：V1 无需继续。Xcode 27 可用后，先验证原 `url:` API 在 macOS 27
  的实际 HTTP cache 行为，再裁决是否需要按系统版本分层采用 request/session 新 API；
  不能预先承诺分层。若 V1 此前出现稳定重复请求、可见闪烁、流量或解码预算超限，才提前
  重开；实施前仍需复核图片 host/redirect/no-cookie 边界，并冻结 50 图首次加载、离屏
  回滚、tab 往返、容量淘汰、窗口关闭清理与 macOS 15/26 等价测试。不得借此引入磁盘
  内容缓存。
- **与其他 finding 的依赖或冲突**：依赖 PERF 图片滚动基线；与 STATE-004 的 App 自建
  `BiliAPIClient` session 无关，因为当前 `AsyncImage` 使用 shared session。

## STATE-006：WBI key 是内存 memoization，不是并发请求去重

- **finding_id**：STATE-006
- **审计线与涉及能力**：request deduplication、actor reentrancy、短期协议材料。
- **当前实现（文件、符号、调用链）**：
  - `BiliAPIClient.swift:34,462-492` 以 UTC day 保存一个 `CachedWBIKey`，强制刷新或
    authenticated session invalidation 时清空（`:282-292,464-467`）；
  - `wbiKey` 在读取空 cache 后 `await response`，没有 in-flight `Task`；actor 在 await
    期间可重入，所以同时发起的 search/subtitle 可以各自请求 `/nav`。
- **它声称提供的职责**：顺序请求同一天复用 key；并未实现所有 endpoint 的通用去重。
- **外部事实来源**：Swift actor 的隔离不等于跨 suspension point 禁止重入；本项无需用
  `URLCache` 替代，因为 key 的 identity/失效由 WBI 协议而非 HTTP response cache 决定。
  WBI TTL 外部事实由 API-001 负责，本文件不重复下结论。
- **OSS 对照及 commit/date**：见 API-001；本项没有另用 OSS 推断并发设计。
- **真实行为证据**：没有记录 production 中同时 search + subtitle 造成重复 `/nav` 的
  样本；因此“可能重复”是由调用路径推导，不是已观测故障。
- **本地测试实际证明的范围**：
  `BiliAPIClientTests.swift:109-129` 只证明两个**顺序** search 同日请求一次 `/nav`；
  没有并发 coalescing 测试。
- **判断：尚不能判断**是否需要 in-flight coalescing；保留当前有界 memoization，等待
  API-001 对 TTL/刷新语义的裁决。
- **风险：影响、触发条件、可恢复性**：并发首次调用最多造成重复小请求；若两个结果跨越
  key 更新时点，可能产生不一致签名重试。失败可由现有一次刷新恢复，频率未知。
- **下一步最小验证**：用受控 transport continuation 同时挂起 search 与 subtitle 的首次
  key fetch，统计 `/nav` 次数并验证失败/取消时 waiter 语义；不访问真实账号。
- **与其他 finding 的依赖或冲突**：直接依赖 API-001；不得把通用 HTTP cache 当成 WBI
  coalescer。

## STATE-007：弹幕三段内存工作集

- **finding_id**：STATE-007
- **审计线与涉及能力**：媒体伴随数据的内存 cache、identity、容量与失效。
- **当前实现（文件、符号、调用链）**：
  `DanmakuScheduler.swift:68-104` 将当前 `PlaybackItemIdentity`、最多三段 event 与已投递
  ID 保存在 value state；`store/trimCache` 选择离当前段最近的三段（`:121-127,218-230`）；
  `begin/reset` 清空全部，forward playback 只保留最多三段 delivered IDs
  （`:236-244`）。
- **它声称提供的职责**：当前段 + 下一段预取、seek 去重，以及最多 3 个 segment／3 组
  delivered-ID 的结构上限；不跨视频、窗口或 App 启动持久化。它不是已测的字节上限。
- **外部事实来源**：这不是 `URLCache`/SwiftData 职责；其 identity 是解码后的时间轴
  segment，失效必须跟随播放 item 与 discontinuity。
- **OSS 对照及 commit/date**：媒体对照由 MP/弹幕线负责；OSS 的段数不能证明 BiliKit
  三段容量是否最优。
- **真实行为证据**：三个普通公开分段各约 770–900 个 decoded event，独立 probe 峰值
  RSS 约 19.5 MiB；一条当前公开高弹幕长视频的首／末抽样分别约 1,000／800 个 event，
  独立 probe 峰值同样约 19.5 MiB。修复 MP-013/014 后，同一签名测试进程按页面时长选择
  最后三个合法段 5–7，共解码 2,047 条（每段 436–847）；scheduler 同时缓存三段时 RSS
  从约 104.6 MiB 到 139.3 MiB，reset 后缓存计数为 0，但即时 RSS 仍约 139.3 MiB。
- **本地测试实际证明的范围**：
  `DanmakuSchedulerTests` 证明最多三段、相邻段 event ID 去重，以及已知 duration 下末段
  不预取越界段；真实探针证明同进程三段结构 cache 可 reset 到零。RSS 不回落不能单独证明
  event 仍可达，也不能证明 allocator 已把物理页退还系统；本轮未保存 Memory Graph。
- **判断：保留**。它有独立的 timeline identity、固定容量与 reset，不应合并到页面或
  URL cache。
- **风险：影响、触发条件、可恢复性**：本样本三段使进程 RSS 高水位增加约 34.7 MiB；
  极高密度段仍可能更大。激进 trim 会在大幅回 seek 时重新请求；allocator 保留页也会让
  短时 RSS 看似不回落，即使结构 cache 已清空。
- **下一步最小验证**：结构容量与真实三段峰值已完成；不因单次 RSS 不回落改容量。若实施
  scheduler/event owner 修改，再用 Allocations 或 Memory Graph 区分仍可达 event 与
  allocator retained pages，并复跑相同最后三段 workload。
- **与其他 finding 的依赖或冲突**：依赖 MP-009 与 PERF 的失败重试/内存测量；与
  STATE-008 的媒体持久化无关。

## STATE-008：除 Keychain 外没有 App-managed 跨启动内容持久化

- **finding_id**：STATE-008
- **审计线与涉及能力**：SwiftData、用户历史、搜索、媒体持久化、隐私。
- **当前实现（文件、符号、调用链）**：
  - 全仓库没有 `SwiftData`、`@Model`、`ModelContainer`、`UserDefaults`、
    `@AppStorage` 或 `@SceneStorage`；
  - 观看历史只存在 `WatchHistoryViewModel.state`，登出/关窗 reset，UI 明示“不会保存到
    本机”（`AppShellView.swift:244-264`）；
  - 搜索、热门、字幕 cue、弹幕段与 WBI key 都是进程/窗口内；
  - loopback media response 明示 `Cache-Control: no-store`
    （`LoopbackPlaybackServer.swift:407-425`），Range transport 也禁用 URLCache；
  - 唯一由 App 明确管理的跨启动数据是 `KeychainWebCredentialStore` 登录凭据；它是秘密
    存储，不是内容 cache。系统组件是否另有缓存／恢复数据未由 source scan 证明。
- **它声称提供的职责**：最小本地数据足迹；退出后不提供离线历史、搜索或媒体恢复。
- **外部事实来源**：
  - Apple《[Preserving your app’s model data across
    launches](https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches)》
    将 SwiftData 定义为跨启动保存 model data 的方案；
  - macOS 26.5 SDK `SwiftData.swiftinterface:371,450-454` 标注 `ModelContext`/`@Model`
    为 macOS 14，最低 macOS 15 可用；
  - API 可用只证明“可以采用”，不创造 BiliKit 的离线/跨启动产品需求。
- **OSS 对照及 commit/date**：不适用。其他客户端保存观看记录或媒体文件不在当前产品
  范围，也不能放宽本项目隐私边界。
- **真实行为证据**：用户当前要求是窗口内返回，不是 App 重启恢复；没有离线历史/搜索/
  媒体需求或数据迁移观察。
- **本地测试实际证明的范围**：source scan 证明基线没有上述 persistence API；它不证明
  Foundation/AVFoundation 私有系统缓存完全不落盘，也不替代隐私实机检查。
- **判断：保留**“无 App-managed 内容持久化”的现状；不引入 SwiftData。不能绝对宣称
  只有 Keychain 能跨启动：`AsyncImage`/shared URLSession、SwiftUI 窗口恢复与系统诊断/
  缓存的实际落盘尚未实机核查。登录凭据继续由 Keychain 独立审计。
- **风险：影响、触发条件、可恢复性**：关窗/App 重启会丢失列表、搜索词和位置，这是当前
  设计；若未来产品改为跨启动恢复，需要 schema、迁移、容量、删除与账号隔离，不可把
  View state 直接序列化。
- **下一步最小验证**：安装签名 build，完成一次登录/浏览/播放后退出，检查 app container
  与缓存目录只产生系统/必要文件，并确认重新启动没有恢复内容；Keychain 单独验证。
- **与其他 finding 的依赖或冲突**：依赖 PRIV-001/006 与 distribution 的 container
  检查；不与 Apple SwiftData availability 冲突。

# BiliKit macOS 路线图

> 状态：M1、M2 已完成，M3 尚未开始。
>
> 基线日期：2026-07-21（Asia/Tokyo）。
>
> 本文描述当前事实、下一阶段和验收门槛；研究依据见
> [`RESEARCH-native-macos-client.md`](./RESEARCH-native-macos-client.md)。计划中的能力在通过对应验收前，不视为已经实现。

## 1. 产品目标

BiliKit 是一个 SwiftUI 驱动、macOS-first、第三方且非官方的 B 站浏览与播放客户端。v1 优先保证：

- 游客可以浏览、搜索并打开视频。
- 用户可以通过 Web QR 安全登录。
- AVC/AAC DASH 可以通过 AVPlayer 可靠播放、seek 和切换 CDN。
- 字幕与弹幕在暂停、倍速和 seek 后保持正确时间轴。
- 窗口、菜单、快捷键和辅助功能符合 Mac 使用习惯。

## 2. 当前仓库基线

截至基线日期，已经存在：

- 独立的 `BiliKitMac` Xcode 工程。
- App 产品名与 Swift 模块名 `BiliKit`；工程和内部 target 保留 `BiliKitMac`。
- Swift 6；App、单元测试、UI 测试和 Package deployment target 为 macOS 15。
- 模板 App、单元测试 target、UI 测试 target。
- `BiliKitCore` 本地 Swift Package，以及 `BiliModels`、`BiliNetworking`、`BiliAPI`、`BiliPlayback` 四个模块。
- HTTP transport 抽象、基础状态码检查、请求日志脱敏和播放引擎边界。
- README、MIT License、第三方声明、`.gitignore` 和共享 App scheme。
- GitHub Actions 的 Package 测试、App 无签名构建与单元测试工作流。
- 原生 macOS 客户端的竞品、技术和合规研究文档。
- 43 个 Package 测试和 8 个 App 单元测试。
- 以最低 deployment target macOS 15 通过的无签名 `build-for-testing`；构建产物不包含研究文档。
- M0 已在本地提交为 `575879a`。
- 严格 HTTP Range 校验、CDN fallback 与取消传播。
- 自制 H.264/AVC、AAC fMP4 与 SIDX v0/v1 fixture。
- SIDX parser、HLS master/media playlist builder 与 loopback HTTP playback bridge。
- 合成音视频在当前 macOS 开发机通过 AVPlayer 起播、暂停和双向 seek 测试。
- 独立、显式运行的真实播放探针；游客 AVC/AAC 样本已在本地 macOS 26 与 GitHub Actions macOS 15 环境通过连续播放、双向 seek、时间轴采样和连续替换审计。
- GitHub Actions 的 macOS 15 与 macOS 26 构建、Package 测试和 App 单元测试均已通过。
- 首批 `BiliAPI` 游客 endpoint：热门、WBI 签名搜索、视频详情、分 P 和 playurl；每个 endpoint 使用独立解码模型，并映射为公开 API 模型或 `PlaybackManifest`。
- 手写脱敏的热门、nav WBI key、搜索、视频详情、分 P 与 playurl contract fixture，以及 HTML 风控页、API code、字段缺失、输入校验和取消传播测试。
- WBI signer 已固定排序、特殊字符过滤、编码和 MD5 向量；key 按天缓存，签名遭 API 或 HTTP 403 拒绝时只刷新并重试一次。
- `GuestVideoCoordinator` 串联详情 → 分 P → 首个分 P 的 `PlaybackManifest`；新选择会取消旧 Task，并使用代次检查阻止不合作的旧请求覆盖最新状态。
- App target 已链接 `BiliAPI`；`AppEnvironment` 组装 API 与播放引擎，`GuestAppModel` 管理热门加载、视频选择、播放准备、取消和旧结果隔离。
- playurl 返回的 `Referer` 与 `User-Agent` 会保留到 `PlaybackRequest`，不再在 App 组装边界丢失。
- 真实播放探针已改为复用正式 `BiliAPI`，不再维护第二套临时 endpoint 解码代码。
- App 已接入最小三栏 `NavigationSplitView`，包含热门、WBI 搜索、详情、分 P、系统播放器以及加载、空结果、失败和重试状态。
- 图片模型会把协议相对或 HTTP CDN 地址规范化为 HTTPS；真实热门列表已显示封面。
- 本地真实界面已完成热门与搜索往返、搜索结果 → 详情/首分 P → 播放器起播，以及切换入口时清理详情并暂停播放器的验证。

尚不存在：

- 认证、Keychain、弹幕或持久化实现。

当前已知开发环境事项：

- 默认 `xcode-select` 指向 Command Line Tools；命令行构建需显式设置 `DEVELOPER_DIR`，或由开发者自行切换全局配置。

## 3. 执行原则

1. 先处理会影响后续所有工作的基础约束，再做产品 UI。
2. 优先验证 DASH→HLS→AVPlayer 这条最大技术风险，不先扩张页面数量。
3. 使用一个本地 Swift Package、多个 target 建立边界；不创建无实现的占位模块。
4. endpoint 使用独立 Codable 模型和录制 fixture；计划和第三方 README 不是运行证据。
5. Web Cookie、App token 和其他秘密只进入 Keychain 与内存，不进入日志、UserDefaults、SwiftData 或 fixture。
6. GPL 项目只用于研究机制；MIT 仓库中的实现必须来自自有代码、Apple 文档和自制测试材料。
7. 每个阶段必须通过 gate 才进入下一阶段；未通过的计划项不得写成已完成功能。

## 4. 里程碑

### M0：工程基线与最小模块骨架（已完成）

目标：让仓库可以在不依赖私人签名的环境中稳定构建、测试和演进。

交付物：

- 将 `docs/`、`references/` 从 App target resources 中移除。
- 统一 App、测试和 package 的 macOS 15 / Swift 6 配置。
- 添加 `.gitignore`、README、MIT License、非官方声明和 `THIRD_PARTY_NOTICES.md`。
- 建立一个本地 package：`Packages/BiliKitCore/Package.swift`。
- 首批只创建并使用三个 target：
  - `BiliModels`：稳定的跨模块领域模型。
  - `BiliNetworking`：HTTP client、Range、取消、错误识别和脱敏日志。
  - `BiliPlayback`：播放协议与后续 Spike 的实现位置。
- 添加 package tests 和最小 CI。

Gate：

- 全新 clone 无需私人证书即可构建 App 和全部测试 target。
- package tests 与 App tests 通过。
- 构建产物不包含研究文档、token、cookie 或本机路径。
- App target 只负责入口、窗口和依赖组装，不承载底层网络或播放算法。

### M1：播放可行性 Spike（已完成）

目标：在投入完整浏览和认证功能前，证明 AVPlayer-first 路线可行。

交付物：

- 使用自制 fMP4/SIDX fixture 实现并测试 SIDX parser。
- 根据视频、音频 representation 生成 HLS master/media playlist。
- 使用仅绑定 `127.0.0.1` 的 loopback HTTP bridge 处理 AVPlayer Range 请求；自定义 scheme 媒体分段路线已由 ADR 0002 的运行验证否决。
- 最小 `AVPlayerView` 宿主，可播放、暂停和双向 seek。
- CDN 候选排序、失败切换、取消和最小诊断事件。
- macOS 15 真实运行测试记录；条件允许时覆盖 Intel。

Gate：

- AVC 视频轨与 AAC 音频轨可以稳定起播并保持同步。
- 从中段向前、向后 seek 后可以继续播放。
- 首选 CDN 返回 403、无效 `Content-Range` 或错误页时会尝试备用线路。
- 取消或替换播放项目后没有悬挂请求和持续增长的资源占用。
- 若 Gate 失败，先通过 ADR 决定修正 Bridge 或引入可选 mpv 后端，不继续堆浏览 UI。

Gate 结论：通过。真实播放收尾矩阵已在 macOS 15.7.7 arm64 runner 上完成 30 秒连续播放、6 轮双向 seek、552 个视频时间轴采样和 12 次播放项目替换，最终 RSS 增量为 0 MiB；受控测试覆盖失败切换、取消与旧 server 资源归零。证据及测量边界见 [`validation/M1-real-playback-2026-07-21.md`](./validation/M1-real-playback-2026-07-21.md)。

### M2：游客浏览到播放的纵向闭环

目标：无账号即可完成列表 → 详情 → 分 P → 播放。

交付物：

- 增加 `BiliAPI` target，包含 endpoint 级请求/响应模型、WBI 和 fixture contract tests。
- 热门或 Web 推荐中的一个入口、搜索、视频详情与分 P。
- 最小 `NavigationSplitView`，只实现闭环所需页面。
- 加载、空状态、取消、重试、HTML 风控页和字段缺失处理。
- 将 API 返回的播放描述转换为 `BiliModels.PlaybackManifest` 后交给 `BiliPlayback`。

Gate：

- 无账号从启动进入列表，搜索或选择视频，并成功播放一个分 P。
- 快速切换视频时旧请求被取消，旧结果不会覆盖当前页面。
- endpoint fixture 能发现字段漂移，错误响应不会让 UI 卡死。

Gate 结论：通过。匿名真实界面已完成热门与 WBI 搜索、结果选择、详情/首分 P 和 AVPlayer 起播；统一 feed 状态机以代次隔离旧请求，失败态保留原请求并可重试。43 项 Package 测试固定 endpoint 和错误边界，8 项 App 单元测试固定热门/搜索切换、选择取消、播放器暂停和错误重试。完整记录见 [`validation/M2-guest-api-2026-07-21.md`](./validation/M2-guest-api-2026-07-21.md)。

### M3：Web QR 登录与安全凭据

目标：建立不泄露凭据的登录闭环，并解锁一个个性化功能。

交付物：

- 增加 `BiliAuth` target。
- Web QR 获取、轮询、过期、取消、重试和登录态验证状态机。
- Keychain credential store、内存副本清理与完整登出。
- 历史、收藏或登录推荐中的一个完整闭环。
- 凭据威胁模型与日志脱敏测试。

Gate：

- 登录、重启 App、校验登录态和登出流程可重复完成。
- 日志、UserDefaults、SwiftData、fixture 和测试失败输出中不存在 cookie/token。
- 游客模式在没有 Keychain item 或凭据失效时仍然可用。

### M4：字幕、弹幕与本地状态

目标：补齐 B 站观看体验，同时保持时间轴和性能正确。

交付物：

- 增加 `DanmakuKit` 与 `BiliPersistence` target。
- 字幕轨选择与展示。
- protobuf 弹幕解码、分段加载、预取、过滤、去重和 lane allocator。
- Core Animation 或可复用 NSView 渲染，不使用大量长期存在的 SwiftUI `Text`。
- SwiftData 保存缓存、历史、shown-BVID 和播放进度；秘密仍只在 Keychain。

Gate：

- 30 分钟连续播放、暂停、倍速和双向 seek 后无明显漂移或重复喷射。
- resize、全屏和 mini player 切换后弹幕轨道能恢复。
- 内存不随弹幕段数单调增长，并有最大同屏数量与降级策略。

### M5：Mac 产品完成度

目标：从“能播放的原型”变成遵循 Mac 习惯的日常客户端。

交付物：

- Commands、可发现快捷键和完整键盘导航。
- 独立播放器窗口、mini player、全屏和能力允许时的 PiP。
- 窗口恢复、拖入 B 站 URL、系统分享和媒体键集成。
- VoiceOver、Reduce Motion、深浅色和不同窗口尺寸检查。
- 历史、稍后再看与播放进度闭环。

Gate：

- 核心流程无需鼠标即可完成。
- 主要控件具备可理解的辅助功能标签。
- 窗口与播放状态在关闭、重开和模式切换后保持一致。

### M6：v1 发布准备

目标：形成可重复构建、可诊断、可直接分发的首个版本。

交付物：

- API、播放、凭据和 UI 的回归矩阵。
- 隐私说明、第三方 notice、非官方与风险声明。
- Developer ID 签名、notarization 和 GitHub Releases 流程。
- 崩溃与诊断信息的秘密扫描和用户可读导出。
- 更新策略和回滚说明；是否引入自动更新单独通过 ADR 决定。

Gate：

- 在干净环境完成 Release 构建、测试、签名和 notarization。
- macOS 15 与当前 macOS 上完成游客、登录、播放、seek、弹幕和登出 smoke test。
- 发布包不包含开发 fixture、研究资料、私人证书或敏感日志。

## 5. v1 明确不做

- 下载、转码和媒体导出。
- 直播与直播弹幕。
- 投稿、发动态、私信和复杂评论写操作。
- 多账号。
- 区域解锁或绕过地区限制。
- Dolby Vision、8K、互动视频和课程等长尾格式。
- 完整复刻官方客户端的全部首页入口。
- Mac App Store 上架承诺。

任何非目标若要提前进入 v1，必须说明对现有 Gate 的影响并新增 ADR。

## 6. 近期执行队列

以下顺序是当前唯一近期待办，完成前不展开后续页面：

已经完成：

- M0 已提交并推送；首次 macOS 15/26 远程 CI 已通过。
- `BiliNetworking` Range、错误 `Content-Range`、CDN fallback 与取消测试。
- 自有 fMP4/SIDX fixture、SIDX v0/v1 parser 与边界测试。
- HLS master/media playlist、loopback HTTP bridge 和离线 AVPlayer 播放/seek 验证。
- 以运行失败证据否决自定义 scheme 媒体分段，并由 ADR 0002 记录替代方案。
- 最小 `AVPlayerEngine`、`AVPlayerView` 宿主和播放项目替换取消验证。
- 使用不含凭据的真实 AVC/AAC 样本完成 Apple Silicon/macOS 26 本地环境与 macOS 15 runner 的 CDN、连续播放、双向 seek、时间轴和连续替换验证。
- 使用受控响应完成 403、无效 `Content-Range`、HTML 错误页、CDN fallback 和取消传播矩阵。
- 使用 server 诊断快照确认连续替换后旧实例的 route、连接和上游 Task 全部归零，并完成 RSS 增长审计。
- M1 Gate 已关闭；完整记录见 [`validation/M1-real-playback-2026-07-21.md`](./validation/M1-real-playback-2026-07-21.md)。
- 创建 `BiliAPI` target，并保持 `BiliAPI → BiliModels/BiliNetworking`、`BiliPlayback ↛ BiliAPI` 的单向依赖。
- 使用手写脱敏 fixture 完成热门、`pagelist`、`playurl` contract tests；覆盖 JSON/HTML、非零 API code、字段缺失、无效输入和取消。
- 将 playurl AVC/AAC representation 映射为 `PlaybackManifest`，并由真实播放探针再次验证 API → 播放链路。
- 增加视频详情 endpoint 与脱敏 fixture，固定热门条目 → 详情的最小模型边界。
- 增加可取消的 `GuestVideoCoordinator`，完成详情 → 分 P → `PlaybackManifest` 的无 UI 编排，并验证旧结果隔离。
- 实现 WBI signer、同日 key 缓存与单次刷新重试，接入匿名视频搜索并完成脱敏 contract tests。
- 新增显式运行的 `BiliAPIProbe`，在本地真实网络中完成 nav → WBI 签名 → 搜索解码验证；记录见 [`validation/M2-guest-api-2026-07-21.md`](./validation/M2-guest-api-2026-07-21.md)。
- 将 `BiliAPI` 与 `BiliPlayback` 接入 App composition root，建立可测试的游客主流程状态模型，并固定媒体请求头传递与快速切换边界。
- 接入最小三栏 `NavigationSplitView`，完成游客热门 → 详情/分 P → 首个分 P 播放的可操作闭环，并通过真实界面验证封面、起播和暂停。
- 在同一 feed 状态机接入 WBI 搜索入口，完成关键词规范化、结果/空状态、错误重试和热门/搜索切换。
- 以统一 `task(id:)` 表达最后一次界面意图；入口切换会清理旧详情并暂停播放器，旧搜索结果不会覆盖后发热门请求。
- 使用真实 `macOS` 关键词完成搜索 → 详情/首分 P → AVPlayer 起播，并完成热门/搜索往返验证；M2 Gate 已关闭。

接下来按顺序：

1. 复核 Web QR endpoint、Cookie 生命周期和匿名/登录态边界，先形成 M3 威胁模型与 ADR。
2. 创建 `BiliAuth` target，以脱敏 fixture 固定二维码获取、轮询、过期、取消和重试状态机。
3. 接入 Keychain credential store 与登录态验证；在此之前不把 Cookie 或 token 写入 App 状态持久化。

M3 期间仍不开始 SwiftData、复杂导航和视觉精修。更多真实样本与 Intel 覆盖属于兼容性扩展，但发现可重复回归时必须回到对应的 M1/M2 测试层修复。

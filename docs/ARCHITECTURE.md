# BiliKit 架构

本文只记录当前模块边界和仍约束代码的决策。事实以 `Packages/BiliKitCore/Package.swift`、
`Scripts/check-architecture.sh` 和 Xcode 工程为准；安全规则见 [`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

## 平台与命名

- Swift 6、SwiftUI + AppKit、AVPlayer；App、测试 target 与 Package 最低 macOS 15。
- 用户可见 App、构建产品与 Swift app module 为 `BiliKit`；仓库、Xcode 工程、内部 App target
  和 `BiliKitMacTests` 保留 `BiliKitMac`，与原 BiliKit userscript 仓库区分。
- Bundle ID `com.shiinayane.BiliKit`；Debug／Release 相同。Keychain access group 固定为
  `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`，更换 Team 或 Bundle ID 等于换一个
  Keychain 范围，旧登录态不迁移，也不得扩大 access group 去读取。

## 模块与依赖方向

仓库只有一个本地 Package `Packages/BiliKitCore`，以 target 作编译边界：

```text
BiliKit App（Composition Root、AppKit/AVKit 宿主、Sparkle）
 ├─ BiliBrowseFeature ─┐
 ├─ BiliLibraryFeature ┼─> BiliApplication ─> BiliModels
 ├─ BiliAuthFeature ───┘         ^ ports
 │    (Browse/Library ─> BiliUI ─> SwiftUI/Foundation)
 ├─ BiliAPI ──────┐
 ├─ BiliAuth ─────┼─> BiliApplication / BiliModels / BiliNetworking
 ├─ BiliPlayback ─┘
 └─ BiliDanmaku ─────> BiliApplication / BiliModels
BiliNetworking 不依赖任何 Bili 模块
```

| target | 拥有 | 不得依赖 |
| --- | --- | --- |
| `BiliModels` | 跨层稳定实体与值类型（视频、播放清单、字幕、弹幕、评论、账户投影） | 任何 Bili 模块、SwiftUI、AppKit、AVFoundation、Network |
| `BiliApplication` | Use Case、port（内容仓库、播放控制与时间轴、字幕、弹幕、评论、认证、观看进度）、应用级错误，以及 Feature 共用的 `package` 并发原语 `LatestTask` | 除 `BiliModels` 外的 Bili 模块、UI/播放/网络框架、DTO、Keychain、Cookie |
| `BiliNetworking` | 无业务语义的 HTTP client、Range client、`HTTPRequestAuthorizing`、URL 形状策略与 JSON 响应判定 | Bili 模块、`Security`、UI/播放框架 |
| `BiliAPI` | endpoint DTO、WBI、解码、protobuf wire、远端错误映射，并实现 Application 仓库 port | `BiliAuth`（只接受注入的授权器） |
| `BiliAuth` | Web QR 状态机、Cookie envelope、Keychain store、请求授权器，实现 `AuthenticationServicing` | `BiliAPI`、`BiliPlayback`、`BiliDanmaku`、Feature、UI 框架 |
| `BiliPlayback` | DASH→HLS bridge、loopback server、SIDX、`AVPlayerEngine`、线路偏好与测速、响度 tap | `BiliAPI`、`BiliAuth` |
| `BiliDanmaku` | 弹幕会话、按媒体时间调度、lane 分配、Core Animation renderer | `BiliAPI`、`BiliAuth`、`BiliNetworking`、`BiliPlayback`、Feature、SwiftUI |
| `Bili*Feature` | SwiftUI View 与 `@MainActor` ViewModel；Browse（Feed/Search/VideoDetail）、Library（History）、Auth | adapter target、其他 Feature、AppKit/AVKit/AVFoundation |
| `BiliUI` | Browse 与 Library 共用、无业务语义的卡片布局、网格、骨架、加载过渡与时长格式化；`package` 访问级别，无 library product | 除 Foundation、SwiftUI 外的任何模块 |
| App `BiliKitMac` | composition root、导航协调、窗口 owner、`AVPlayerView` 宿主、原生网格／侧栏、Settings、Now Playing、Sparkle | `App/` 目录不直接 import adapter、Application 或平台框架，具体实现只在 `Composition/`、`Platform/`、`Settings/` 出现 |

补充规则：

- SwiftProtobuf 只允许 `BiliAPI` import；Sparkle 只允许 App target。
- Feature 之间不互相 import，跨域跳转由 App 层协调。
- ViewModel 拥有用户意图的 Task、取消与 generation；只有最新意图能写回 UI State，单一最新
  意图统一用 `LatestTask` 隔离，不各自手写。View 的 `.task(id:)` 只把生命周期意图交给 ViewModel。
- adapter 必须传播 `CancellationError`，不把取消折叠成网络失败。
- 新 target 需同时具备稳定独立领域、独立状态或安全／性能边界、真实调用方与测试；默认在现有
  target 内加子目录。不建立 `Common`／`Shared`／`Utils`，不建立空占位 target。
- `BiliUI` 只在出现至少两个真实调用方且语义稳定时才接收新组件；B 站主机、图片参数、计数和日期
  格式化留在拥有语义的 Feature。

## 关键决策

### 播放：DASH→HLS loopback bridge

`AVAssetResourceLoaderDelegate` 可以提供 playlist，但由它返回 fMP4 媒体分段时 `AVPlayerItem` 以
`CoreMediaErrorDomain -12881` 失败；AVFoundation 需要自己加载分段来执行自适应逻辑。因此
`BiliPlayback` 在进程内起一个最小 HTTP/1.1 server，只绑定 `127.0.0.1`、系统分配端口、随机
session path，提供内存中生成的 master／media playlist，并把 AVPlayer 的 Range 转发到 CDN。

- SIDX 成功的候选成为该 representation 的唯一远端来源，后续 init、media 与 Range 不跨来源拼字节。
- 上游响应必须通过状态码、`Content-Range`、长度校验；取消不触发备用线路。
- 只有全部 SIDX reference 从 type-1 SAP 开始且 `SAP_delta_time` 为 0 时才发布 I-frame rendition，
  它复用同一 route 的完整 fragment Range，不预读、不缓存。
- 同一 AUDIO group 以原声 SIDX 起点为准；起点不一致的 AI 音轨在生成 master 前丢弃。
- 没有 DASH 但有安全单段 `durl` 时注册 progressive MP4 route：原样保留 AVPlayer 的单一 Range，
  验证后逐 chunk 写入 loopback，不累积整段；不支持多段 `durl` 拼接。
- `AVPlayerEngine` 是 `AVPlayerItem`、loopback server、原生字幕 route 的唯一 owner；替换、停止或
  释放时关闭 server 并取消连接与上游 Task。不使用私有 AVFoundation header 注入。

### 媒体时间轴

`BiliApplication.PlaybackTimelineProviding` 是弹幕、Now Playing 与观看进度的唯一时间来源，由
`BiliPlayback` 用 AVPlayer observation 实现，表达 item identity、位置、速率、状态和 discontinuity
generation。消费者不自建 wall-clock timer，也不接触 `AVPlayer`／`CMTime`／KVO；各自 timer 无法正确
表达卡顿、暂停、倍速和 seek。字幕作为原生 subtitle rendition 进入同一 `AVPlayerItem`，由系统字幕
菜单选择。

### 弹幕

- 分段是 protobuf。`BiliAPI` 以 exact 1.38.1 依赖 SwiftProtobuf（Apache 2.0 + runtime exception），
  `.proto` 自行编写，用同版本 `protoc-gen-swift` 显式生成并提交 `.pb.swift`，不挂 build plugin。
  手写 wire reader 要长期自维护 varint、未知字段和恶意长度边界，成本高于约 1.8 MiB 的体积。
- wire 类型解码后立即映射为 `BiliModels.DanmakuEvent`；`BiliDanmaku` 只见 Models/Application。
- renderer 使用 Core Animation layer 与纹理缓存，调度与 lane 分配可用虚拟时间独立测试。

### 原生 AppKit 集合视图

- **播放侧栏**：上传者、简介、选集／分 P、评论与分页 footer 由一个 `NSScrollView + NSCollectionView`
  拥有，全部是原生 item。真实长评论下 `ScrollView + LazyVStack` 产生不收敛的 SwiftUI
  transaction／AttributeGraph 工作；逐行 `NSHostingView` + `fittingSize` 会把全表重测放大到秒级。
  正文使用可选择、不可编辑的 `NSTextView`；diffable identity 为 subject + root `CommentID`；
  高度缓存按 identity、宽度桶、内容 revision 做有界 LRU，resize 分批精测并恢复语义 anchor。
  `PlaybackCommentsViewModel` 仍唯一拥有 subject、排序、分页、并发上限与 generation。
- **浏览网格与 shelf**：首页推荐、热门、搜索、历史的网格和相关推荐 shelf 使用
  `NSCollectionView` + 复用的原生卡片。热门 50 卡 A/B 表明 SwiftUI `LazyVGrid`/AttributeGraph
  是主要滚动成本；卡片 overlay 与文字改为持久 `CALayer`／`CATextLayer` 后，同样约 20 秒滚动
  cycles 下降约 39%，0 hitch。SwiftUI Feature 保留 loading／empty／failure 等状态所有权。
- 封面、头像与评论图片由 `AppWindowOwner` 持有的窗口级匿名、有界 `NativeVideoImagePipeline`
  加载（Now Playing 封面另有进程级实例）；cell 离屏、复用和 teardown 取消等待者。

### 认证

Web QR 协议没有官方稳定文档，按“fixture 固定的外部观察”处理，未知状态一律失败关闭。秘密只在
`BiliAuth`；Application 只暴露非秘密认证状态与 `AuthenticationServicing`，二维码图像走
`BiliAuthFeature` 定义的窄 Presentation port 注入。`BiliAPIClient` 的请求 builder（`RequestAccess`
与请求管线）只在 `BiliAPI` 内部可见，由同 actor 的各域 endpoint 扩展逐请求选择匿名或账户读取；
Repository adapter 只调用 endpoint 方法，不自行构造 `RequestAccess`。授权器由 Composition 注入。
唯一写能力是观看进度 heartbeat。具体边界见
[`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

多窗口共享一个 App 级账户 session coordinator：窗口出现后注册其 API transport，登出／换号／凭据
失效时先全局推进 authentication epoch，其他窗口再复核 Keychain 并按新 generation 重启依赖账户的
内容；窗口关闭时注销。

### 播放线路偏好与测速

同一 fMP4 播放中换源会破坏字节一致性和单一播放器 owner，一次样本也不能代表未来视频，所以只做
显式选择：Settings 提供服务端默认、服务端原始 Akamai／bilivideo 与固定 bilivideo 镜像；每次新
load 只读一次，只调整视频候选。实验镜像只替换原始 bilivideo URL 的 host，保留签名；缺失时回退
服务端顺序。测速仅在已登录用户显式点击后运行，样本与路线严格串行、流量有硬上限、结果只存在于当前
Settings 窗口，从不自动改选。

### 响度均一化（实验，仅 macOS 26）

UGC playurl 带 `voice_balance=1` 时返回 loudness 元数据。macOS 26 上 loopback HLS item 可挂
无显式 track 的 post-effects `MTAudioProcessingTap`；macOS 15 实测不回调，Apple 也未承诺 HLS 支持。
因此默认关闭、仅 macOS 26 显示与安装，新 load 读一次设置。gain 为
`min(targetI−I, targetTP−TP, +6 dB)`，下限 −12 dB；元数据缺失、音轨无法唯一映射或 tap 失败时保持
unity，播放不得失败。实时回调只读固定内存／原子值，不分配、不加锁、不记日志。

### 分发

- Developer ID 站外 DMG + 公证，不走 Mac App Store；更新用 Sparkle 2.9.6 完整包 + Cloudflare 静态签名
  appcast，不自研更新器。
- 1.0.0 是最后一个 Universal 版本；此后 Release 主程序只含 `arm64`，Sparkle 官方嵌套组件保留其自带
  架构。CI 只在 Apple Silicon 的 macOS 15／26／27 上运行。不为旧 Intel 用户建立专用 feed。
- macOS 15 是 GitHub 仍持续提供 runner 的最低运行时；项目没有 macOS 14 设备，deployment target
  编译成功不能证明 AVFoundation、loopback 与窗口行为可用。

## 不采用

- 每条评论或每张卡片嵌入 `NSHostingView`；`List`／`LazyVStack`／`LazyVGrid` 作为生产长列表容器。
- 第三方 DI、Coordinator 框架、Redux／TCA。
- 每个模块独立 `Package.swift`；为单一调用方新建 renderer／Shared target。
- Feature 直接观察 `AVPlayer`；字幕或弹幕独立 timer；弹幕放进 Feature 或在 `BiliDanmaku` 解码 wire。
- mpv 等第二播放后端；AVPlayer + loopback 能满足当前需求。
- `*.bilibili.com` 后缀匹配授权；WKWebView 登录；共享 `HTTPCookieStorage` 或 `URLSession.shared`
  作为登录态。
- 播放中自动换源、后台测速、按测速结果自动改选。

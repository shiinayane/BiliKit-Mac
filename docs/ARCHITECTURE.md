# BiliKit 架构

本文只记录三类内容：模块边界、仍约束代码的决定（连同不采用的替代），以及跨多个文件、单看一个类型
看不出来的不变量。单个类型的行为、取值与实测的系统行为写在该类型的文档注释和测试里，不在这里重复。
事实以 `Packages/BiliKitCore/Package.swift`、`Scripts/check-architecture.py` 和 Xcode 工程为准；安全规则见
[`SECURITY-MODEL.md`](SECURITY-MODEL.md)。

## 平台与命名

- Swift 6、SwiftUI + AppKit、AVPlayer；App、测试 target 与 Package 最低 macOS 15。
- App、App 测试与 Package 用同一组并发语义：Swift 6 语言模式、默认 `nonisolated` 隔离，加
  `InferIsolatedConformances` 与 `MemberImportVisibility`；不开 Approachable Concurrency 的
  `NonisolatedNonsendingByDefault`（`Scripts/check-project-contract.sh` 固定）。因此 `nonisolated async`
  不继承调用方 actor：bridge 解析、授权器读 Keychain、Range 流、图片解码这类工作在 `@MainActor`
  调用时仍离开主线程。代码在 App 与 Package 之间移动时不改变执行位置。
- 最低系统低于 SDK 时，编译器会把部分系统 API 编成“新系统调用新符号、旧系统走内联”的弱链接分支；新符号在
  版本号已到、实际却还没有它的测试版系统上为空地址，一调用就崩溃。Xcode 27.2 SDK 的 `Date` `<=`／`>=` 即如此
  （macOS 27.2 测试版扫码登录闪退），所以 `Date` 只用 `<`／`>` 比较。发版时 `release.py prepare` 列出主程序的
  弱链接符号，不在白名单里的就停止，见 `docs/release/README.md`。
- 用户可见 App、构建产品与 Swift app module 为 `BiliKit`；仓库、Xcode 工程、内部 App target
  和 `BiliKitMacTests` 保留 `BiliKitMac`，与原 BiliKit userscript 仓库区分。
- App 身份按渠道而不按 Debug／Release 区分，只在 `Configuration/BiliKit-Channel.xcconfig` 派生。正式渠道是
  Bundle ID `com.shiinayane.BiliKit`、显示名 BiliKit、`AppIcon`、正式 feed，只由 `release.py` 的 archive 传
  `BILIKIT_CHANNEL=Production` 得到，archive 后立即核对；其余构建（本机 Debug 与 Release、Gate、CI）都是
  开发渠道：`com.shiinayane.BiliKit.dev`、BiliKit Dev、`AppIcon-Dev`、无 feed，渠道值缺失或拼错也回落到开发渠道。
  开发版因此与安装版分开偏好域、沙盒容器和 Keychain 范围，不检查更新。不采用按 Build Configuration 区分：
  本机实测常把 Run 切到 Release，那样的包会和正式版无法区分。`PRODUCT_NAME`、模块名与 `CFBundleName`（菜单栏 App 菜单）
  两个渠道都是 `BiliKit`，进程按 Bundle ID 定位（`open -b`），不按名字。
- Keychain access group 固定为 `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`，更换 Team 或 Bundle ID
  等于换一个 Keychain 范围，旧登录态不迁移，也不得扩大 access group 去读取。
- 强调色是资源目录的 `AccentColor`（B 站粉调深，让上面的白字仍可读），界面只经系统强调色（`controlAccentColor`／`Color.accentColor`）取用；
  用户在系统设置里选了具体主题颜色时以系统为准。

## 模块与依赖方向

仓库只有一个本地 Package `Packages/BiliKitCore`，以 target 作编译边界：

```text
BiliKit App（Composition Root、AppKit/AVKit 宿主、Sparkle）
 ├─ BiliBrowseFeature ──────┐
 ├─ BiliVideoDetailFeature ─┤
 ├─ BiliLibraryFeature ─────┼─> BiliApplication ─> BiliModels
 ├─ BiliAuthFeature ────────┘         ^ ports
 │    (全部 Feature ─> BiliUI ─> BiliApplication / SwiftUI)
 │    (Browse/VideoDetail/Library ─> BiliVideoCollectionUI)
 ├─ BiliVideoCollectionUI ─> BiliUI / AppKit
 ├─ BiliAPI ──────┐
 ├─ BiliAuth ─────┼─> BiliApplication / BiliModels / BiliNetworking
 ├─ BiliPlayback ─┘
 └─ BiliDanmaku ─────> BiliApplication / BiliModels
BiliNetworking 不依赖任何 Bili 模块
```

表里只写各 target 拥有哪一类东西；具体类型以代码为准，逐文件的 import 白名单在 `check-architecture.py`。

| target | 拥有 | 不得依赖 |
| --- | --- | --- |
| `BiliModels` | 跨层稳定实体与值类型 | 任何 Bili 模块、SwiftUI、AppKit、AVFoundation、Network |
| `BiliApplication` | Use Case 与 port、应用级错误、界面可用的账户投影、窗口账户复核的参与者契约与共用的复核进度（Feature ViewModel 实现、App 汇总，不是 adapter 实现的 port），以及 Feature 共用的并发原语、列表状态机与有界缓存（`LatestTask`、`AsyncBroadcast`、`PagedVideoList`、`PageReplacementPaging`、`CostBoundedLRUCache`） | 除 `BiliModels` 外的 Bili 模块、UI/播放/网络框架、DTO、Keychain、Cookie |
| `BiliNetworking` | 无业务语义的 HTTP 与 Range client、`HTTPRequestAuthorizing` 与签名请求的 `HTTPSigningRequestAuthorizing`、URL 形状策略、query 的 unreserved 编码与 JSON 响应判定 | Bili 模块、`Security`、UI/播放框架 |
| `BiliAPI` | endpoint DTO、WBI、解码、protobuf wire、远端错误映射，并实现 Application 仓库 port | `BiliAuth`（只接受注入的授权器） |
| `BiliAuth` | TV 扫码状态机与 APP 签名、凭据 envelope（Cookie 加 App token）与续期、Keychain store、请求授权器（含 App 端读取与写入），实现 `AuthenticationServicing` | `BiliAPI`、`BiliPlayback`、`BiliDanmaku`、Feature、UI 框架 |
| `BiliPlayback` | DASH→HLS bridge、loopback server、SIDX、`AVPlayerEngine`、线路偏好与测速 | `BiliAPI`、`BiliAuth` |
| `BiliDanmaku` | 弹幕会话与分段缓存、车道布局、按媒体时间的 materializer、Core Animation renderer。`Session/`、`Layout/`、`Presentation/` 是纯逻辑，渲染框架只在 `Rendering/` | `BiliAPI`、`BiliAuth`、`BiliNetworking`、`BiliPlayback`、Feature、SwiftUI |
| `Bili*Feature` | SwiftUI View 与 `@MainActor` ViewModel：Browse（推荐、热门、搜索）、Library（观看历史、稍后再看、收藏夹）、Auth（扫码登录、登出与账户投影的来源）。来源条目到卡片的网格包装在拥有该来源的 Feature | adapter target、其他 Feature、直接 import AppKit/AVKit/AVFoundation |
| `BiliVideoDetailFeature` | 播放页、侧栏上下文层的 UP 主空间预览与右侧的整页空间页（页面由 App 构造，其他 Feature 经 App 的导航打开它）：视频与分 P 意图、续播与链接起播、评论、弹幕设置、空间投稿，以及这些页面的呈现投影与 AppKit 视图（播放侧栏、评论图片预览、相关推荐横排、空间列表）。导航给出的选择意图怎样落到当前视频、失败后由谁重试，以及播放页失败的文案与是否可重试，只在这里 | 同其他 Feature，但可 import AppKit、CoreText（评论排版）与 ImageIO（动图逐帧解码）；不依赖 AVKit/AVFoundation、网络与 adapter；下载、校验、首帧解码、动图门槛与缓存只在 App 管线 |
| `BiliUI` | Feature 共享的 SwiftUI 呈现：卡片与网格几何、骨架、状态胶囊、页码条、失败视图与文案、登录门槛、格式化、B 站图片缩略地址、临时反馈的读屏通告（全仓唯一入口，App 的播放器浮层也用它）；自己的字符串目录。默认 `package`，App 直接使用的才 `public`；无 library product | 除 Foundation、SwiftUI、BiliApplication 外的任何模块（含 BiliModels、AppKit 与其他 Feature） |
| `BiliVideoCollectionUI` | 网格与横排共用的 AppKit 卡片（视频卡片、关注列表的人物卡片）、按卡片种类泛型的原生网格及其状态（回顶、锚点、准备区域）、集合视图的悬停、键盘与通知观察、可点条目的悬停与按下外观（卡片与 UP 主空间投稿行共用）与网格卡片共用的交互状态、大会员名字配色 `NativeMemberNameColor`（评论、播放侧栏与空间页头部也用）、图片淡入、近尾分页、内容差异、卡片取图 port `NativeVideoImageLoading` 与网格从窗口拿到的依赖 `NativeVideoGridHostContext`。App 用到的为 `public`，只有 Feature 用到的为 `package` | 除 BiliUI 外的 Bili 模块（含 BiliNetworking、adapter 与 Feature）；图片下载与缓存只经 port 注入 |
| App `BiliKitMac` | composition root（`Composition/` 的进程级与窗口级组装）、导航协调、来源描述、复核汇总与账户写入的协调和效果路由（`Navigation/`）、AVKit 宿主、图片管线、Settings、Now Playing、Sparkle | `App/` 与 `Navigation/` 不直接 import adapter 或平台框架，`Navigation/` 只依赖 Feature、Application 与 Models；具体实现只在 `Composition/`、`Platform/`、`Settings/`；`App/` 里 import Application 或 BiliVideoCollectionUI 的文件由脚本逐个登记 |

补充规则：

- SwiftProtobuf 只允许 `BiliAPI` import；Sparkle 只允许 App target。
- Feature 之间不互相 import，跨域跳转由 App 层协调。
- ViewModel 拥有用户意图的 Task、取消与 generation；只有最新意图能写回 UI State，单一最新
  意图统一用 `LatestTask` 隔离，不各自手写。View 的 `.task(id:)` 只把生命周期意图交给 ViewModel。
- adapter 必须传播 `CancellationError`，不把取消折叠成网络失败。
- adapter 只经 `BiliAPIError.Failure`（`domainError`）分类远端错误，各域只把分类对应到自己的 Application
  错误；内容类读取共用 `BiliAPIError.contentApplicationError(for:)` 映射到 `ContentApplicationError`。是否复核
  账户、是否给重试只由 Application 错误的 `requiresAccountRevalidation`／`isRetryable` 决定，Feature 不各自判断。
- 新 target 需同时具备稳定独立领域、独立状态或安全／性能边界、真实调用方与测试；默认在现有
  target 内加子目录。不建立 `Common`／`Shared`／`Utils`，不建立空占位 target。
- 两个以上 Feature（或 Feature 与 App）共用的呈现放进 `BiliUI`，只有一个调用方的留在拥有它的 Feature。
  BiliUI 的组件只负责排版与措辞，标签、动作与“是否可重试”由调用方给出。B 站图片 CDN 上封面与头像的缩略参数
  只由 `BiliImageThumbnail` 追加；评论资源是不透明引用，其图片地址只由 BiliAPI 的 resolver 生成。
- Feature 视图直接渲染自己的网格、横排与 loading／empty／failure，不经 App 填充的泛型内容插槽；App 只注入
  窗口级依赖（取图 port、每个来源一个 `NativeVideoGridHostContext`、评论资源地址闭包、评论图片预览与保存图片的 owner）。
- 图片只经 port 取：卡片与网格经 `NativeVideoImageLoading`（只分封面与头像、结果只带图与是否淡入），某个
  Feature 自己的图片用途另设该 Feature 的窄 port，不放宽卡片 port。实现都是 App 的 `NativeVideoImagePipeline`，
  无凭据 session、来源与响应校验、缓存上界只在那里（见 `SECURITY-MODEL.md` §4、§6）。App 自己的侧栏账号头像与
  管线同在 App，直接按头像用途取图，不另设 port。

## 关键决策

### 组装分层

- 进程级 `ProcessComposition`（`BiliKitMacApp` 持有唯一一份，随进程存活、不关闭）：账户会话协调器、进程
  唯一的观看进度 writer、窗口间的账户写入效果集线器 `AccountWriteEffectHub`、设置与线路测速、系统 Now Playing、
  本机搜索历史与更新器。生产 `BiliAPIClient` 只由 `LiveAPIClients` 构造，各授权器的 allowlist 也只在那里声明。
- 窗口级 `WindowComposition`（每个窗口一份，由 `AppRootView` 在视图身份首次出现时构造一次）：全部模型、
  账户写入的协调者与效果路由、导航协调、来源描述与复核参与者、播放器视图、窗口图片管线、来源网格的保活。它只引用进程级对象，不替它们创建或关闭。
  具体实现只经 `WindowAdapters` 进入，生产由 `WindowAdapters.live(process:)` 一处构造，测试换成替身后走同一条
  组装路径。
- 窗口出现时先把当前账户范围同步为观看进度的上报权限，再 `open()`（同时把本窗口的写入效果路由登记进集线器）。窗口消失时 `close()`（不可逆）按序：
  从进程级测速注销本窗口 → 关闭播放并恢复新窗口的来源 → 拆除常驻的播放器宿主 → 各来源丢弃内容 → 取消认证临时任务与评论 → 取消在途账户写入并从集线器注销 → 取消短链
  解析 → 关闭评论图片预览（挂在上面的保存面板按取消结束）→ 取消图片保存 → 停止观看进度与 Now Playing → 丢弃保活的网格 → 关闭图片管线 → adapter 取消内存压力监听、停止偏好持久化、
  注销会话并失效短链 session。adapter 这一步只在窗口打开过之后执行。

### 播放：DASH→HLS loopback bridge

`AVAssetResourceLoaderDelegate` 可以提供 playlist，但由它返回 fMP4 媒体分段时 `AVPlayerItem` 以
`CoreMediaErrorDomain -12881` 失败；AVFoundation 需要自己加载分段来执行自适应逻辑。因此
`BiliPlayback` 在进程内起一个最小 HTTP/1.1 server，只绑定 `127.0.0.1`、系统分配端口、随机
session path，提供内存中生成的 master／media playlist，并把 AVPlayer 的 Range 转发到 CDN。

- SIDX 成功的候选成为该 representation 的唯一远端来源，后续 init、media 与 Range 不跨来源拼字节；
  正文逐 chunk 流式转发，不整段缓存。唯一改写字节的地方是全景声组的 init（见下面的音频组），它也只读自
  同一来源。上游响应必须通过状态码、`Content-Range` 与长度校验；取消不触发
  备用线路，AVPlayer 断开或下游写入失败都按取消处理。
- 附加档位失败不拖垮播放：某一档视频 SIDX 读取失败只丢弃该档，原声的某个附加音频版本失败只丢那一组，
  某个 AI 配音语言失败就停止后续配音请求；
  全部视频档失败、原声音轨失败、凭据失效或会话变化才让播放失败。读取成功之后生成 playlist 出错仍让整次播放失败。
  代价是附加档被丢掉时没有任何提示，也不写诊断（日志规则见 SECURITY-MODEL §8）：过滤条件写错时附加格式
  会一直悄悄缺席，测试与日常播放都看不出来（例如只认杜比视界 profile 8 时，B 站的 profile 5 档永远不会出现）。
  改附加档的过滤条件时，要用真实 B 站样本的形状写测试，并在 App 里确认这一档确实被选中。
- 视频编码：每次播放的 SDR 阶梯只用一种编码。按清晰度 ID 比较，HEVC 覆盖 AVC 的全部档位时用 HEVC（8K 等
  HEVC 独有的档位一并加入），同一份 playurl 的 AVC 阶梯留作回退；否则全用 AVC。HEVC 的 item 在就绪前失败时，
  engine 在同一次 load 内换 AVC 阶梯重建一次，回退也失败才算播放失败。阶梯不设分辨率上限，依赖 AVPlayer
  按 player 视图的像素尺寸限制所选分辨率（实测系统行为，文档没有写）。`dash.video` 逐条宽松解码，认不出的
  档位只丢这一条。
- HDR：SDR 阶梯是 HEVC 时，master 至多再加一个 HDR 档，按杜比视界（126）、HDR 真彩（125）的顺序取第一个
  能用的；这几个 ID 都不进 SDR 阶梯。HDR Vivid（129）不用，也不进 SDR 阶梯：请求它要在 fnval 里带 16384 位，
  Web playurl 对此一律返回 -400（游客与登录态相同，实测）。
  AVPlayer 每个 item 只在一个 `VIDEO-RANGE` 内做 ABR，有资格播 HDR 时就选 HDR 且不受视图尺寸限制（实测，与
  Apple 论坛及 HLS Authoring Spec“每种动态范围给完整阶梯”的要求一致）；B 站 HDR 只有一档，选中后弱网也降不到
  SDR，所以只在加载时满足全部条件才加入：“HDR 视频”开关开着、`AVPlayer.eligibleForHDRPlayback`、播放器所在
  屏幕的 EDR 能力大于 1、不在低电量模式、网络不昂贵也不受限。HDR 档的 `VIDEO-RANGE` 取自它的 init：`colr`
  的 PQ／HLG，或杜比视界 profile 8 基础层（8.4 写 HLG、8.1 写 PQ）加 `SUPPLEMENTAL-CODECS`，或 `dvh1` 的
  杜比视界 profile 5（没有基础层，按 Authoring Spec 写 `CODECS="dvh1.05.LL"` 与 PQ、不写 `SUPPLEMENTAL-CODECS`，
  playurl 的编码与 init 不符时丢弃，master 的 `CODECS` 照抄 playurl）；有 HDR 档时 SDR
  档与全部 I-frame 行也写 `VIDEO-RANGE`，要么都写要么都不写。HDR 档缺帧率、SIDX 没有可播分段、init 不是 HDR 或解析失败、
  时间轴起点与 SDR 档不同时只丢这一档（连同它的 I-frame），在生成字幕 route 之前完成。HEVC 回退到 AVC 时不带 HDR 档。
  B 站杜比视界 profile 5 稿件的 HEVC SDR 档在 AVPlayer 里画面偏绿（实测），这类稿件只有杜比视界档颜色正确。
  B 站不给 30fps 及以下的 HDR 档，不满足 Authoring Spec 对 HDR 阶梯的要求，这是已知偏离。
- 音频组：原声的每个版本各成一个 AUDIO group——码率最高的 AAC（默认组）、其余 AAC 档、杜比音频（E-AC-3）、
  “无损音频”开关开着时的 FLAC。每组成员相同（RFC 8216bis §4.4.6.1.1）：原声取这一组的版本、同名“原声”，
  配音只有 AAC、在每组引用同一个 URI；每个视频档（含 HDR 档）与每组各写一行 variant，CODECS 与带宽只计这一组。
  同名的原声在系统菜单里合并成一项，组之间由 AVPlayer 选择（实测）：AAC 档按网速切换；E-AC-3 写声道数后，
  内置扬声器与 AirPods 都在起播约 2 秒后从 AAC 切到杜比组，所以不进菜单、不手动选；FLAC
  只有设了 `variantPreferences = .scalabilityToLosslessAudio` 才会在带宽足够时选中。
  附加版本的 SIDX 起点等于视频或默认组原声之一即可：较早稿件的 AAC 各档都比视频晚约 83 ms 起播，杜比却
  与视频同从 0 开始（实测）。只认 AAC 会丢掉杜比组，只认视频又会丢掉其余 AAC 组。读取失败、SIDX 没有可播分段、
  读不出声道等音频格式或起点两者都不等时只丢这一组；AI 配音与原声同组，仍以默认组原声的起点为准。无损关时
  不读 FLAC 的 SIDX。
  全景声（`dash.dolby.type == 2`）：B 站 init 的 `dec3` 缺 JOC 扩展字节，码流本身却带 JOC；系统只按 init 的
  这两个字节决定是否按全景声渲染（实测：缺它们时控制中心显示“多声道”，补上后显示“杜比全景声”）。bridge 读
  音频格式时顺带在内存里补上 `flag_ec3_extension_type_a = 1` 与 `complexity_index_type_a = 16`，`dec3` 与各级
  祖先 box 长度加 2，由 loopback 作为这一组的 `EXT-X-MAP` 提供，分段仍按区间转发 CDN；master 按 Apple HLS
  Authoring Spec 写 `CODECS="ec-3"`、`CHANNELS="16/JOC"`。只改与实测形状相同的 init（唯一 `ec-3`、5 字节
  `dec3`、一个独立子流且没有依赖子流、32 位 box 长度），结果须恰好多 2 字节并能重新解析；其他形状不改，
  按普通杜比音频发布。`EXT-X-MAP` 与 `/JOC` 只由同一份改写结果决定。
- 没有 DASH 但有安全单段 `durl` 时走 progressive MP4 route；不支持多段拼接与 FLV。
- 没有声音的稿件 `dash.audio` 为 null：清单没有音轨，master 只有视频 variant，不声明 AUDIO group，也不请求
  AI 配音。这时播放时钟由视频渲染推进，item 必须接在 player host 的 `AVPlayerView` 上才会走。
- 音轨与字幕都写成 master 里的原生 rendition，由系统菜单选择；名称标注按 HLS 媒体特征交给系统本地化，
  原声不写 LANGUAGE（B 站不给可验证的原声语言）。起播总是原声：配音 `AUTOSELECT=NO`，播放器关闭自动媒体
  选择，只按 DEFAULT 起播。系统可能在字幕菜单里插入不在 BiliKit 目录里的翻译轨，没有公开 API 可以关掉。
- `AVPlayerEngine` 是 `AVPlayerItem`、loopback server、原生字幕 route 的唯一 owner；替换、停止或
  释放时关闭 server 并取消连接与上游 Task。不使用私有 AVFoundation header 注入。

### 媒体时间轴

`BiliApplication.PlaybackTimelineProviding` 是弹幕、Now Playing、观看进度与播放页章节的唯一时间来源，由
`BiliPlayback` 用 AVPlayer observation 与 item 通知实现。消费者不自建 wall-clock timer，也不接触
`AVPlayer`／`CMTime`／KVO：各自的 timer 无法正确表达卡顿、暂停、倍速和 seek。唯一的例外是弹幕动画：弹幕
layer 挂在时钟层下，由 item timebase 直接驱动；哪些弹幕在屏上也按时钟层发布的显示时间 D 决定，时间线
快照只用来确认 identity、作检查节拍与决定请求哪些分段。`BiliDanmaku` 经 `DanmakuDisplayClock` 读 D，
不接触 AVFoundation 与 Core Media。

- 续播位置在 load 时写入 master playlist 的 `#EXT-X-START`，item 就绪即位于该处，不再“先就绪、再 seek”，
  也就没有 seek 期间辨认 time-jump 来源的竞态。progressive 单文件没有 playlist，不续播。
- `discontinuityGeneration` 只给 Now Playing 决定何时重新发布已播时长、给章节提示认出跳变；观看进度与弹幕不读它。
  同一次 seek 只推进一次（吞掉落点附近的重复跳变）。跳变通知与新位置的周期快照到达先后不固定，识别 seek 的消费者
  不能只看代次：章节提示把同一代里位置的大步移动也当作跳变。
- 关心边界的消费者（观看进度、播完的处理）用 `observe`，不用 `updates()`：后者订阅时补发当前快照、只保留最新值，
  会把已经结束的快照当成新的结束，或漏掉夹在中间的边界。seek 会把 `ended` 改成 `paused`，所以“播完后又开始
  播放”只能按会话是否已报过 ended 判断，不能只看上一个快照；观看进度据此把重播当作新的一次观看。
- 播完的处理（「播放结束后」）只在同一 item 刚进入 `ended` 时触发一次，由 `VideoViewModel.handlePlaybackEnded`
  核对快照仍属于此刻呈现、也是最新请求的那一项再动作；重播与断点浮层的「从头播放」共用引擎里同一条回到开头的 seek。
  连播的下一项由视频模型决定（`PlaybackNextItem`），跳转由 App 经窗口导航执行，与侧栏选分 P、横排选集同一条路：视频模型
  不导航，否则导航层的去重、当前意图与上下文层会和真实播放对不上。
- 弹幕时钟层（App `Platform/DanmakuTimebaseClock`，owner 是 `DanmakuOverlayView`）是普通 `CALayer`，本地时间
  跟随当前 item `timebase`，更新不经过主线程。跨文件必须守住的约束：
  - timebase 的通知由播放器内部队列在持有 MediaToolbox 锁时同步发出：回调里调用 AVPlayer／AVPlayerItem
    的 API 必然死锁，任何等待都会延长持锁、挡住主线程，所以回调只向私有串行队列投递，队列上读最新锚点。
  - 三个时间属性在 `CATransaction.lock()` 内赋值、在锁外提交：持着全局锁提交会与其他线程的提交反序加锁，
    实测死锁。绑定与发布值的锁是叶子锁，只有「Core Animation 锁 → 绑定锁」一种嵌套。
  - 播放中不往回跳（单调下限），速率为 0 时一律严格跟随：seek、拖动与暂停都经过速率 0，所以不需要识别 seek。
    换绑后的第一次同步也严格跟随。D 只由 `DanmakuClockWrite.displayTime(at:)` 一个纯函数计算。
  - 宿主在 `currentItem` 的 KVO 里先让呈现控制器清屏再换绑，两步在 `replaceCurrentItem` 之内同步完成，旧弹幕
    不会在新 item 上多留一个回合。解绑只停住、不发布 D。
  - 前提是时钟层的祖先都没有修改时间属性；不成立时 DEBUG 断言、Release 记一条固定分类日志。

### 弹幕

- 分段是 protobuf。`BiliAPI` 以 exact 1.38.1 依赖 SwiftProtobuf，`.proto` 自行编写，在 `Packages/BiliKitCore` 下
  运行 `buf generate`（`buf.yaml`／`buf.gen.yaml`，调用 PATH 上同版本的本地 `protoc-gen-swift`，buf 不校验插件版本）
  显式生成并提交 `.pb.swift`，不挂 build plugin：手写 wire reader 要长期自维护 varint、未知字段和恶意长度边界，成本高于约 1.8 MiB 的体积。
  wire 类型解码后立即映射为 `BiliModels.DanmakuEvent`。
- 系统内存压力的监听由窗口 adapter（`WindowAdapters.live`）持有，与图片管线共用 `SystemMemoryPressureObserver`，
  窗口关闭时先于会话注销取消；`BiliDanmaku` 不自己监听。
- 在同一组已缓存分段、同一组设置下，画面是媒体时间与窗口尺寸的纯函数：seek 到某一时刻与连续播放到该时刻
  看到同样的弹幕，不需要识别 seek、没有投递游标或补位。由三部分保证：
  - 车道布局在后台按分段整张排好，分段边界以上一段末尾的占用为种子；设置变化时整张重排，generation 丢弃
    过期结果。
  - materializer 按 D 从布局表取出此刻在屏与即将进场的弹幕；时间推进、跳变、布局表替换都是同一种对齐，
    屏上的 placement 总出自当前布局表。
  - renderer 没有时钟：暂停、倍速、缓冲与 seek 都由时钟层跟随 timebase。
- 取景框：布局表按规划画布（屏幕与窗口尺寸的较大者）排一次，窗口尺寸只决定露出表中的哪一部分；resize
  不重排、不整屏替换，只移动锚点。成立前提是运动速度与画布宽度无关（`DanmakuMotionPolicy`）、车道分配前缀稳定
  （`DanmakuLaneAllocator`），改策略时不要弄坏。允许叠放的密度档、跨可见边界的多车道弹幕与按全部车道计数的
  同屏上限会打破前缀稳定，所以小窗口里比直接按小窗口排的更稀；换到更大的屏幕时整张重排一次。
- 何时对齐只看 D 是否离开上次对齐后的一个步长，不识别 seek 或拖动；步长加相邻两次检查的间隔必须短于前瞻。
- 重复弹幕合并在车道布局之前、按分段进行（`DanmakuDuplicateMerger`）：同一位置、归一化后同文、组首后固定 4 秒
  内的弹幕并成组首一条。窗口与文字宽度、窗口尺寸都无关，组成员在排车道前就确定，所以合并后的布局仍是缓存分段与
  设置的纯函数、种子只向前传；不跨分段，分段边界附近同一句话可能出现两次。组首正文不变，车道请求按正文宽加上
  最终条数的计数胶囊宽申请，条数增长只在预留的空间里。纹理与在屏 layer 按 ID 复用，只有组首靠并入才带上高赞
  图标时正文纹理会变，这时换 ID，否则旧纹理会被拉伸到新宽度。
- 计数胶囊是正文 layer 的子层，条数、胶囊宽度与显隐都写成从弹幕时间点开始的关键帧动画，由时钟层按媒体时间
  切换，不随对齐步长刷新：materializer 只按步长对齐，暂停在两次对齐之间时按步长刷新的计数会停在旧值。胶囊里的
  “×”与数字是按字号与 backing scale 缓存的白色字形图，不经纹理准备 owner、不占正文纹理的准备名额。
- 互动弹幕（`dm/web/view`）由弹幕会话在进入视频时读一次，失败只让它缺席。UP 主弹幕按时间并入对应的已缓存分段，
  与分段弹幕一起排车道（不参与重复合并）；它的 ID 带 `command:` 前缀，不与分段弹幕的 ID 冲突。互动弹幕通常先于
  分段到达；晚到时含 UP 主弹幕的分段重新交一次，该段与末尾占用因此变化的后续分段重排一次车道（只在视频有 UP 主
  弹幕时发生）。不让分段等互动弹幕，接口慢或失败时普通弹幕不被拖住。互动弹幕卡片不占车道：renderer 把它们挂在所有弹幕之上的容器层里，显隐是从卡片时间点开始的
  关键帧动画（淡入、淡出，出现时略微放大；与顶部弹幕同一做法，由时钟层按媒体时间切换），位置按窗口尺寸换算，改窗口
  尺寸只重新定位。用户的弹幕透明度落在三个弹幕锚点层上，不落在 `rootLayer`，所以卡片不随它变淡。
  呈现控制器只在弹幕开着、已有本视频时间线、时钟读得到 D 时把卡片交给 renderer，换 item 时先撤下：与弹幕同一条
  “读不到 D 时什么都不挂”，否则换视频的加载期间卡片会按旧视频停下的时刻挂上、冻在画面上。
- 关联视频卡片是弹幕层里唯一接收点击的东西。弹幕 overlay 的 `hitTest` 只在此刻显示的关联视频卡片上返回自己，
  “此刻显示”按 overlay 时钟的 D 与卡片的时间区间判断（与显隐动画同一个时间），不读动画的呈现值；其余位置照常
  穿透给 AVKit。点击在应用内打开该视频，走窗口导航的 `openPlayback`，与评论里不带时间的视频链接同一条路。封面经
  BiliDanmaku 的取图 port 由窗口的图片管线加载，到达后只换卡片的封面子层，不重画卡片图；窗口组装播放器时把
  管线交给 renderer，因为构造窗口 adapter 时管线还不存在。
- 自己发的弹幕：发出成功后由输入胶囊交给弹幕会话（`DanmakuSessionControlling.presentOwnDanmaku`），按时间并入已缓存的分段，
  与 UP 主弹幕一样不参与重复合并；分段重新读到时服务端那份同 ID 的换成本地这一条，所以只显示一次、始终带边框（画在纹理
  已有的留白里，不改尺寸，测量与车道布局不变）。只在会话内存里，换视频时随会话清空。不强行挤进已满的车道：取景框依赖的
  前缀稳定不为它破例，车道满时它与普通弹幕一样可能不上屏。
- 大会员彩色弹幕的外观按官方贴图的结论内置，不下载分段给的贴图，官方更换贴图时不会跟随。高赞弹幕的赞图标
  同样内置（SF Symbol），与文字一起栅格化进同一张纹理，是测量与纹理缓存 key 的一部分。

### 原生 AppKit 集合视图

- **播放侧栏**：上传者、简介、分 P、评论与分页 footer 由一个 `NSScrollView + NSCollectionView`
  拥有，全部是原生 item。真实长评论下 `ScrollView + LazyVStack` 产生不收敛的 SwiftUI
  transaction／AttributeGraph 工作；逐行 `NSHostingView` + `fittingSize` 会把全表重测放大到秒级。
  `PlaybackCommentsViewModel` 仍唯一拥有 subject、排序、分页、并发上限与 generation。
- **浏览网格与 shelf**：各来源的网格和播放页横排使用 `NSCollectionView` + 复用的原生卡片。热门 50 卡 A/B
  表明 SwiftUI `LazyVGrid`/AttributeGraph 是主要滚动成本；卡片 overlay 与文字改为持久 `CALayer`／`CATextLayer`
  后，同样约 20 秒滚动 cycles 下降约 39%，0 hitch。网格只是已加载状态的呈现，loading／empty／failure 在同一个
  Feature 视图里。
- 网格按卡片种类泛型（`NativeGridView<Kind>`；视频卡片是 `NativeVideoGridView`，关注列表的人物卡片是
  `NativePersonCardKind`）。网格拥有保活、滚动位置与锚点恢复、近尾翻页与尾部状态、顶部附加视图、「返回顶部」、键盘
  选择与卡片菜单的取用；卡片种类只给出展示值（`NativeGridCardPresentation`）、集合项（外观、读屏描述与取图，
  `NativeGridCardItem`）与几何。不为人物卡片另写一份网格：保活、锚点与翻页的这些不变量只能有一份。
- 网格几何是一个参数化的值 `CardGridGeometry`（在 BiliUI，加载骨架也要用）：内容边距、列距、行距、最小卡片宽度、
  列数范围与卡片高度。列数、卡片尺寸、内容高度、骨架占位数、布局的一节与近尾判断都只按它实现一份，各种卡片是它的
  实例；准备区域与近尾倍数不随种类变化，是网格共用的策略常量。
- 集合项的尺寸只由布局给出：所有集合项继承 `NativeLayoutSizedCollectionItem`，对 `preferredLayoutAttributesFitting`
  原样返回。默认实现在每次排可见项时为整棵条目视图临时建 Auto Layout 引擎量尺寸，而我们的布局不采纳结果；1.6.1
  评论区滚动的 Time Profiler 里它约占主线程三分之一。
- 网格提前准备：AppKit 默认只为视野内创建卡片，封面要等卡片露出来才开始加载，所以网格用
  `prepareContent(in:)` 把准备区域扩到视野上下各一屏。`NSCollectionViewPrefetching` 只给出即将进入视野的
  index、不创建卡片，替代不了。
- 网格用组合布局（`NSCollectionViewCompositionalLayout`），唯一一节按容器宽度由 section provider 给出，卡片尺寸取
  该卡片种类的 `CardGridGeometry`（视频卡片的实例与骨架同源）；宽度一变由系统失效重排，卡片尺寸不靠网格同步。不用流式布局加
  `sizeForItemAt`：它在宽度变化时先按旧卡片尺寸重排，要等网格手动失效才换尺寸，其间按旧尺寸排出少一列的错列。
  provider 读到的布局环境之外的状态（末行下方留白）变化时仍要手动失效。
- 网格的视口锚点是用户最后看到的视野首卡：只在滚动或程序定位落定、且排版就是当前视口尺寸时捕获；宽度、
  高度变化与整体替换都按它恢复，恢复后不重新捕获：连续宽度变化中逐帧重新捕获会让首卡逐行漂移。视口尺寸一变，
  AppKit 会在网格按锚点恢复之前先按新宽度重排、夹取偏移，这段过渡里的偏移不可信，不捕获锚点、不判断翻页；
  宽度变化只吸收浮点误差，半点也算（`NativeViewportSize`），否则跨列数分界的那一步不恢复，视野跳一行。
  纯删除（例如稍后再看的乐观移除）删掉锚点卡片时，由旧顺序里它之后第一张仍在的卡片按同一距离接替，视野不跳。
- 分页：推荐、热门、搜索、观看历史、稍后再看、关注列表与 UP 主空间投稿由 `PagedVideoList` 承担，来源只把远端页适配为
  “条目 + 下一页游标”，去重与条目上限只在那里（上限按列表给出：视频来源 1000 条，关注列表 2000 人）（集合层的 `NativeCardContents` 另按卡片 ID 兜底）；收藏夹按页整体替换，翻页
  状态是 `PageReplacementPaging`。
- 已有内容、且条件与解析出的请求不变时，刷新原地进行：网格不卸载，成功后整体替换并回顶，失败保留已显示内容。
- 来源网格由窗口保活：切换来源与压一层其他页面时 SwiftUI 会拆掉根页面，网格的 Coordinator（连同滚动视图、集合视图、
  滚动位置与锚点）由窗口的 `NativeVideoGridRetainer` 每个来源留住一个，同一来源、同一内容身份再次出现时交回同一个
  滚动视图，不重建、不重排位置。内容身份给按内容重建视图的来源用：收藏夹换夹时 Feature 整块重建，新夹不沿用旧夹的
  位置、锚点与图。同一来源同时出现两个实例（过渡中）时留下新的，旧的拆除时照常 `reset()`。
- 集合视图离开窗口会回收全部卡片，挂回后卡片要重新配置，而窗口图片缓存可能已被别的来源挤掉、又没有磁盘缓存，
  卡片会先闪占位再重新下载；所以保活的网格离开窗口之前收走卡片正显示的封面与头像（`NativeVideoGridHeldImages`），
  挂回后先从这里取。摘下期间不记录滚动、不判断翻页：离开窗口时自动 contentInsets 会变、bounds 可能被夹取。
- 账户变化与关窗时丢弃全部保活的网格（关窗在关闭图片管线之前），系统内存压力时只释放留住的图。不采用让各来源
  根页面常驻层级、只隐藏不选中的页面：隐藏的 AppKit 视图仍占着 cursor rect、tracking area 与读屏树，
  NavigationSplitView 的工具栏与标题也要逐页另行仲裁。
- 网格的差异动画：内容身份变化、不是严格的尾部追加、已在窗口里排过版、没开「减少动态效果」时，快照带差异动画应用。
  动画进行中 `NSCollectionView` 不为新露出的区域创建卡片（纯原生实测约 250ms、0 张），所以网格的 clip view
  （`NativeVideoGridClipView`）在动画中每次视野移动之后补一次无动画的空批量更新，新视野的卡片立即补齐，进行中的动画
  不受影响。`apply` 返回时排版已是新内容，重配卡片、重排 document、回顶或锚点恢复与翻页判断都在同一轮里做完，不等
  完成回调，没有“新内容、旧偏移”的中间态。
- 网格可选两样装饰（`NativeVideoGridDecorations`）：内容顶部的附加视图与右下角的「返回顶部」。附加视图是 SwiftUI
  内容的 `NSHostingView`，作为集合视图的子视图放在首行上方让出的空间里，随文档原生滚动；高度由调用方的几何常量给出、
  与宽度无关，布局顶边距、它的 frame 与近尾判断共用这一个值。宿主建立后保留到网格拆除，内容变化只换 `rootView`，
  焦点与 SwiftUI 状态不丢；读屏时排在卡片之前；焦点在它里面时，它没处理的按键不当成卡片的激活与选择移动。不用组合
  布局的 boundary supplementary item：它滚出准备区域就被回收，焦点与状态随之丢失，高度也仍要自己给。「返回顶部」
  按钮（`NativeScrollToTopButton`）与播放侧栏评论区、UP 主空间预览共用一份；网格上点它像用户滚动一样带动画滚到顶部，
  落定后把位置同步回 binding；来源刷新的回顶是程序定位，仍经 `scrollReset` 直接跳转。
- 卡片菜单：各来源的网格、相关推荐横排与 UP 主空间的投稿行共用一份菜单描述 `NativeVideoCardMenu`，由拥有来源的
  Feature 按视频 ID 与能否播放构造、经 `cardMenu` 注入，不经 App 插槽。右键、Control-点按与读屏「显示菜单」走集合视图
  基类 `NativeVideoCardCollectionView` 的同一条右键路径，集合项只提供卡片 ID 与上下文描边（`NativeVideoMenuTargetItem`），
  读屏自定义操作取同一份描述，项、顺序与标题与菜单一致。右键与访达、「音乐」一致，不改选中、不移动键盘选择框。链接项
  只给卡片 ID 是合法 BVID 的可播放卡片（人物卡片是正整数 mid 的空间链接），打开只经系统 `OpenURLAction`（见
  `SECURITY-MODEL.md` §4）。「已关注」菜单的三项只由 BiliUI 的 `UploaderFollowingMenuContent` 定义（只用基本类型），
  `NativeVideoCardMenu.Item.following` 把它变成菜单项（关注页卡片的右键，以及整页空间页头部与播放页侧栏点「已关注」弹出的
  菜单，后两处经 VideoDetail 的 `UploaderFollowingMenu`，由 App 经环境注入状态与写入口），`NativeVideoCardMenu.makeMenu()`
  是生成 `NSMenu` 的唯一入口。空间页头部是嵌套 `NSHostingView` 里的 SwiftUI，`Menu` 在 macOS 上不吃按钮样式，所以「已关注」
  在 macOS 26 起是玻璃按钮、点按时在按钮背后的 AppKit 视图下方弹出这份菜单。
- **UP 主空间列表**：头部、投稿行与底部加载行是同一个 `NSCollectionView` 的原生 item，随列表滚到工具栏下由系统做边缘
  模糊。底部加载行进入视野时请求下一批（`NearEndPagination`，每个尾部一次，实时滚动中一次手势一次）；App 端投稿接口
  只有游标，不能跳页，所以不用页码条。列表不接收键盘焦点，方向键、空格留给播放器快捷键。
- 空间顶部浮动的一行（返回按钮与空间内搜索框）不随列表滚动；搜索框是 AppKit `NSSearchField`：SwiftUI `.searchable`
  只能放进窗口工具栏，放不进侧栏的上下文层。只在回车或清空时提交，提交后放下焦点，空格与方向键回到播放器快捷键。
- 图片由窗口级匿名、有界的 `NativeVideoImagePipeline` 加载（Now Playing 封面另有进程级实例）；cell 离屏、复用
  和 teardown 取消等待者，缓存上界只在 `NativeVideoImageCacheLimits`。缓存之外只有卡片自己正显示的图，以及保活的
  网格摘下时替卡片留住的那一份（每个网格以它实例化的卡片数为界）。
- 评论图片预览的图片区是 AppKit `NSScrollView`：SwiftUI 没有现成的“触控板双指缩放 + 两指平移 + 回弹”容器。
- 评论图片预览由铺满父窗口的子窗口面板承载，父窗口是被点开的格子所在的窗口（AVKit detached 全屏时仍是主窗口）。
  面板是自己的 key window，而播放器快捷键只截获播放窗口的事件，Esc、←→ 与 ⌘S 直接交给预览；导航、侧栏与工具栏
  不必为预览守护，换视频、退出播放与关窗时由窗口级 owner 关闭。不采用主窗口里的全屏 overlay（要另行接管第一响应者、
  隐藏工具栏并拦截导航写入）、sheet（失去灯箱观感与点背景关闭），也不采用 Quick Look（要本地文件，违反
  `SECURITY-MODEL.md` §6 不落盘）。

### 加载呈现

- 骨架屏只给形态固定、能照原样画出的内容：各来源的视频卡片网格、相关推荐横排与播放页主区，用于首次加载与
  整块换掉内容（换来源、排序、夹内翻页）。骨架立即出现：它占住版面，延迟只会先露出空白。
- 其余加载用系统转圈：形态不一的内容（评论、楼中楼、投稿列表、热搜、收藏夹列表、关注分组）不画占位行，免得误导条数与
  长度；人物卡片矮、每屏条数多，关注页的第一批也用转圈；追加、刷新、缓冲与评论图片预览也用转圈，封面与头像只显示占位。占满一块区域时用大转圈居中，行内、
  页脚与胶囊里用小转圈。
- 转圈（连同旁边的“正在加载…”文字）一律等 `LoadingIndicatorPolicy.presentationDelay` 后仍在加载才露出：
  SwiftUI 用 `revealsAfterLoadingDelay()`，AppKit 侧栏用 `NativeLoadingReveal`，楼中楼与播放器浮层在各自的
  状态里计时，都读同一个常量。请求很快时什么都不显示、内容直接出现；露出前后版面不变。例外是接续已经露出的
  转圈（播放页三段转圈）与露出会改变行高的楼中楼空面板，二者立即显示。

### 播放页布局

- 主区固定不滚动：视频取剩余空间里最大的 16:9，下方是固定高度的横排；真实页面与加载骨架
  共用 `PlaybackDetailLayout`。布局交给 SwiftUI，不测量 frame。横排分「相关视频」「刚才看过」「章节」「合集」
  （`PlaybackShelf`）：合集的分区与选集只在横排，侧栏只留分 P；“当前是哪一集”只由 `PlaybackSelectionProjection`
  判断，横排与侧栏都读它。「刚才看过」由导航协调器按窗口持有（见下文历史栈）。分段章节与“当前是哪一章”只由
  `VideoChapterModel` 按时间线维护，横排、动作菜单的「章节」子菜单与播放器上的章节提示（AVKit 的
  `flashChapterNumber`）都读它；提示只在播放落定到另一章时发出，跳转方（横排、菜单）不各自提示。AVKit 在 macOS 上没有
  章节导航与进度条缩略图，章节不画在原生进度条上；不按固定间隔铺缩略图做时间轴：普通视频的等距截图看不出内容。
- 骨架与内容切换只在外层交叉淡化，`PlaybackDetailLayout` 内部整体不参与动画：新建的 AppKit 视图会随布局
  动画从初始 frame 移到最终位置，看起来像“飞入”。
- 横排用 `NSScrollView.automaticallyAdjustsContentInsets` 延伸到侧栏下。不用 SwiftUI 纵向 `ScrollView` 承载
  详情：它延伸进安全区后不再向内容传递横向安全区，只能靠测量 frame 模拟。同一原因，横排外面不加会让 SwiftUI 给 AppKit
  视图套容器的修饰符或过渡：换视频途中挡住旧详情的 `.allowsHitTesting(false)` 只挂在播放器上（挂在整页时横排被套进一层不
  传递安全区的 `_NSGraphicsView`，前缘边距归零，整排卡片左右跳一下），横排靠 `isEnabled` 自己拦截点击、悬停与菜单；
  切分页的淡入改横排自己 AppKit 视图的透明度，不用 SwiftUI 过渡。
- 右侧不用 NavigationStack，`AppDetailColumn` 按 coordinator 只渲染历史栈顶（来源根页、播放页或整页空间页），工具栏左侧
  的「返回｜回到「来源名」」一组控件由 App 自绘，根页时整个工具栏项不放（控件组的按钮数在 1、2、3 之间增减会排版出错，只
  在 0 与 2 之间变化没有问题）。detail 视图必须是独立的 View：写在 `NavigationSplitView` 的 detail 闭包里时，闭包内读到
  的 Observable 状态不会让 detail 列刷新。进入播放页时来源根页随即移除，回来时重建（来源网格由窗口保活原样挂回）。macOS
  没有给页面设底色的接口（`ContainerBackgroundPlacement.navigation` 在 macOS 不可用），页面本身透明；历史页（播放页、整
  页空间页）自铺不透明窗口背景并延伸到工具栏与侧栏下，来源根页保持透明。这样工具栏的返回控件、结果胶囊与转场锚点都在
  detail 这一层挂一次，不随换页重建；用 NavigationStack 时挂在它上面的修饰符归根页面所有、压栈后随根页面移除，这些都得每
  个页面各挂一份，系统返回按钮还要逐页隐藏。
- 右侧换页的转场（`NavigationPageTransitions`）用 Core Animation 的 `CATransition`，挂在 `NavigationSplitView` 两栏的图
  层上：主区覆盖与揭开，侧栏淡入淡出，「减少动态效果」时都淡入淡出；随后在同一次提交里无动画地换页。移动的总是历史页（压
  一层时是压进来的新栈顶，返回时是弹出去的旧栈顶），根页从不移动：压一层时新页从右边盖在不动的页面上，返回时旧页向右滑走、
  露出下面的页面。这要求历史页都铺不透明底色，否则叠着滑会透出下面那一页；新增的历史页类型同样要铺。新旧两个状态由系统合
  成层截取，视频画面与玻璃材质都在，真实视图不参与动画；截取依赖 SwiftUI 在当前隐式事务提交之前落地换页，这个时序没有文
  档保证（见 `NavigationPageTransitions`）。换页的侧栏淡入淡出挂在侧栏那一栏的外层：macOS 26 起挂在外层截不到玻璃视图里
  侧栏内容的旧状态，旧侧栏不交叉淡出，但换页大多同时改变侧栏宽度，外层的淡入把玻璃底的宽度变化也一起淡过去，比挂在
  内容层（内容交叉淡化、玻璃底硬跳）柔和。上下文层的推不改宽度，挂在 `NSGlassEffectView.contentView` 上（见下文）。
  工具栏不在两栏里，转场开始时就换成新页面的。压一层、返回、⌂ 与画中画「还原」转场；同类替换、换来源、登出与关窗不
  转场。不采用 SwiftUI 自带转场：`PlaybackDetailLayout` 为防新建的 AppKit 视图“飞入”而关掉的事务动画会连整页位移一起关掉，AppKit 列表不随 SwiftUI 位移，`geometryGroup()`／`clipped()` 会打乱横排与网格依
  赖的自动内容边距，`.animation(_:value:)` 在 detail 列里不触发；也不采用自己拍快照（`cacheDisplay` 拍不到图层内容，
  `CALayer.render` 把侧栏的玻璃材质画成白板）。
- 离开活视频所在的播放页时旧页面要带着当前画面离开，所以：播放器宿主随窗口常驻（`PlayerHostOwner`），页面卸载只把它
  摘下（被空间页盖住时也是），关窗才拆除；离开时先暂停，转场结束后才停止播放，期间又进入播放页、换来源、登出或关窗都提前完成这次停止（代次见
  `AppNavigationCoordinator`）。停止播放与拆宿主都会立即清空画面，任何一个落在换页的同一次提交里，旧页面的视频区都会
  先变黑。延后只为留住画面：还在加载、没有画面可留时立即停止（暂停拦不住加载完成后的自动起播），栈顶是空间页时回根页
  也立即停止；延后期间播放已离开播放页，播完的自动连播不再生效，宿主摘下时也停掉了播完观察。
- AVKit 没有公开进入／退出全屏的方法，`enterFullScreen:`／`exitFullScreen:` 是唯一允许使用的私有 AVKit 接口：
  调用前确认响应，系统移除后 F 键静默无效；是否全屏由公开的 `AVPlayerViewDelegate` 回调记录。
- 加载转圈分三段衔接：详情未到时是骨架上的转圈；已有详情而 player 还没挂上 item 时由播放器浮层画同款转圈；
  item 挂上到就绪之间由 AVKit 自己的转圈接手。开播后的 seek 与缓冲卡住 AVKit 不画，由浮层按
  `PlayerLoadingPolicy` 判定；暂停中 seek 与原生进度条拖动只能从 seek 调用看出，所以窗口播放器是记录在途
  seek 的 `SeekTrackingPlayer`。
- 键盘快捷键以 content overlay 中弹幕层所在窗口为准：AVKit detached 全屏只携带 content overlay。
- 播放器上针对当前视频的低频操作（稍后再看、分享链接）放进 AVKit 控制条自带的动作菜单（`actionPopUpButtonMenu`），
  不在画面上另加浮动按钮：它随原生控件显隐、外观原生，全屏时 AVKit 把它收进浮动控制条的「»」→「其他」。浮动按钮要么
  自己计时显隐、与原生控件不同步，要么读 AVKit 的私有视图层级，目前都不采用（发送弹幕的入口另议，见 ROADMAP）。
- 播放态侧栏替换导航侧栏，不另开右侧 inspector：播放期间导航使用率低，双栏把宽度留给视频。
- 进出播放时程序不收起、不展开系统侧栏：改 `columnVisibility` 必然整列跳变。浏览态与播放态的列宽范围
  （`SidebarColumnMode`）不重叠，各自记住用户拖出的宽度：`NavigationSplitView` 没有宽度绑定，系统只在一次运行内记
  一个宽度、切换状态时按新范围夹取。所以 `SidebarWidthRestoringView` 找到底下的 `NSSplitView`，在系统按新范围改宽度的
  那次 resize 回调里同步调用 `setPosition`，中间宽度不会被画出来。不采用改 min/max 钉住宽度（放开时被系统打回，
  再钉会反复振荡），也不自管 `NSSplitViewController`（要重做 `NavigationSplitView` 的工具栏与侧栏行为）。

### 动线与侧栏上下文层

- 平级来源（搜索、首页、热门、稍后再看、观看历史、收藏夹）以 `AppTab` 为 id，各由一份 `AppSourceDescriptor`
  描述标题、侧栏分组、是否要求账户、整体替换代次、停用、账户变化通知、复核参与者与 reset。侧栏行、刷新回顶、
  离开停用、账户变化、关窗清理都遍历 `AppSources`；根视图构造与 Browse 激活仍是 `AppTab` 上的穷尽 switch。
- 侧栏按 `AppSourceGroup` 分段；「收藏夹」组由一个来源为每个收藏夹提供一行，选择值 `AppSidebarSelection`
  让每行带不同的 tag。
- 右侧是历史栈（`AppNavigationCoordinator.history`，空栈是来源根页）：同类页面原地替换（播放页里换视频、选集、连播），
  异类页面压一层（播放页之上的整页空间页、空间页之上的播放页），层数不设上限，返回回到上一屏，不做前进。页面分两类：
  浏览类（来源根页、空间页）侧栏是来源导航，内容类（播放页）侧栏是它的详情，侧栏随栈顶页面的类别。与首页、热门平级的
  来源进导航侧栏；播放页上围绕当前视频的浏览（UP 主空间预览）是侧栏上下文层，压栈与返回时关闭，预览里的按钮在右侧
  压一层整页空间页。点侧栏其他来源或另一个收藏夹、登出、换号、其他窗口复核与关窗都清空历史并停止播放；点已选中的那
  一行列表不发选择变化，所以在 AppKit 层识别（`SidebarReselectDetector`：前台 key 窗口里不带修饰键的单击，按下与抬起
  都在按下前已选中的行上），同样回到这个来源的根页；SwiftUI 手势只覆盖行里的文字，不采用。
- 窗口只有一个播放器，所以只有最近一次播放是活的：“栈顶是哪一页”与“活视频在哪一项”分开记，历史项带 id，活视频按
  id 绑定。活视频所在的播放页被空间页盖住时暂停，回到它时只恢复由盖住暂停的（用户自己暂停或已播完的不动；被盖住期间
  经媒体键或控制中心播放、拖动过的，位置已不是盖住时的，也不动）；还在加载、没有画面的直接停止（暂停拦不住加载完成后
  的自动起播），回来重新加载。被新视频取代时，把离开时的分 P 与秒数写回历史里
  同一视频最近的播放项，回到它时据此重建（秒数续播只对 DASH 生效）；换的是另一个视频时同时记进「刚才看过」，经「返回」离开活视频时也记
  （`recentlyWatched`，最近离开的在前、按 BVID 去重、不含正在播放的，只在窗口内存里，清空历史时一起清空）。空间页里又点了被盖住的那个视频，活视频改绑到新
  压的一项，不重新起播。被盖住时连播不生效（只在栈顶就是活视频时生效），迟到的下一集解析也不会换片。
- 画中画中被盖住时不暂停，继续播放；播到结尾停在结尾，不循环、不连播（宿主被摘下时播完观察随之停止，换集还会换掉
  item、结束画中画）。画中画被关掉（不是还原）时已没有可见的播放器，按被盖住处理。「还原」弹掉上面的层回到活视频的
  播放页，等宿主随新页面回到窗口才回答 AVKit（`PlayerPictureInPicture`），太早回答时 AVKit 把画面还给不在窗口里的视图。
- 整页空间页只有一个模型（每窗口一份，与预览的模型分开），属于最上面的空间项；被另一项占用前把排序与搜索词写回原来
  那一项，回到更早的空间项时按它记下的条件从第一批重建并回顶。网格保活只占一个位置（内容身份是空间项），空间页关闭时
  丢弃，层数增加时内存不随之增长。
- 侧栏 = 底层（导航或播放详情）+ 可选的上下文层。上下文层打开时底层保留状态，但必须真正隐藏：AppKit 底层
  设 `isHidden`，只设 SwiftUI 透明度与 hit testing 管不到 cursor rect 和 tracking area。进出用侧栏上的 Core Animation
  `push` 转场（`NavigationPageTransitions.performSidebarContext`，挂在侧栏玻璃视图的 `contentView` 上，挂在外层时被推走
  的一层是空的）：用户打开时新层从右边推进来，用户关闭（返回按钮、⌘[、从上下文层以外换视频）时原来的侧栏从左边推回来，
  两层一起平移、不重叠（侧栏半透明，不能像主区那样叠着滑）。不用 SwiftUI 过渡：它会把底层 AppKit 集合视图的布局变化一起
  做成动画。换页的同时关闭（压一层、返回、回首页、换来源、登出、关窗）交给换页转场的侧栏淡入淡出，不再叠一次推。
- 上下文层的打开与关闭都经 `AppNavigationCoordinator`，按“从哪里打开”判断是否关闭：在上下文层里选的视频保留
  它，其他入口换视频或关闭播放时关闭。播完后的自动连播与列表循环不是用户从别处换视频，同样保留它。不比较新视频的
  UP 主：联合投稿的 UP 主字段可能是另一位。
- 简介与评论里的链接：BiliAPI 分类目标（`CommentTextLinkDetector` 识别纯文字、`BiliShortLinkResolver` 读短链
  跳转），Composition 的 `CommentLinkRouting` 是目标到 App 路由的唯一翻译处，路由只由 `Navigation/` 的
  `CommentLinkOpener` 执行；时间跳转由 Composition 的 `seekPlayback` 校验 item 仍属该视频再跳。来源与形状
  规则见 `SECURITY-MODEL.md` §4。

### 搜索起始页

- 草稿、排序与筛选、已提交的条件都在每个窗口一份的 `VideoSearchSession`（Browse），历史在它的 `submit()` 里
  统一写入；搜索历史由进程级 `SearchHistoryStore` 持有，Feature 只经 `SearchStartPageContext` 拿到闭包。
- 工具栏正中的搜索框是 AppKit `NSSearchField`，挂系统联想菜单（`NSTextSuggestionsDelegate`）：SwiftUI
  `.searchable` 放在工具栏正中时不显示 `.searchSuggestions`。
- 搜索框只把外部改动写回字段，且在输入法组字时不写：直接赋值会丢掉未确认的拼音或假名。
- 搜索词按 `URLQueryUnreservedEncoding` 编码，与 WBI 签名一致：`queryItems` 会保留 `+`，被服务端当成空格。

### 稍后再看的排序、筛选与搜索

- 条件只在每个窗口一份的 `WatchLaterSession` 内存里，关窗与账户范围变化恢复默认。条件变化以新条件的第一页
  从空列表重新加载，不原地刷新：旧条件的条目不能留在新条件下显示。
- 加入时间的区间语义与搜索的发布日期不同（结束取明天 0 点），两者不共用解析，只共用拒绝规则
  `DateRangeFilterValidation`。
- 番剧／影视、课程与已失效的条目本来就打不开，接口常给不全，字段缺失时放宽、不让整页失败；可播放的行仍严格校验。

### 收藏夹的排序与搜索

- 选中的收藏夹、排序与关键词只在每个窗口一份的 `FavoriteFolderViewModel` 内存里。
- 只有 type 2 的普通视频可以播放；合集、音频、番剧／影视、未知类型与已失效是不可用卡片，不可用原因与稍后
  再看共用 `LibraryUnavailabilityFormatting`。

### 认证

登录用 TV 端扫码：成功正文同时带网页 Cookie 与 App 端 access_token、refresh_token，三者存在同一份凭据里，一起过期、一起删除；
续期用 refresh_token 换回整份新凭据（Cookie 一并换新），由进程唯一的 `AccountCredentialRenewal` 串行执行，认证服务在恢复确认仍登录
后调用它、等它结束才发布已登录：启动时只在临近到期时续期，复核时强制续期一次，使只有 token 失效的凭据在复核后的重载里恢复；
续期失败不改变登录状态。网页接口用 Cookie，App 端接口（首页推荐与它的「不感兴趣」，播放页的点赞、投币、三连，UP 主空间投稿，发评论）经 App 授权器带 access_token 并签名，读取在未登录时匿名签名，写入从不匿名。协议没有官方稳定文档，按“fixture 固定的外部观察”处理，未知状态一律失败关闭。秘密只在
`BiliAuth`；Application 只暴露非秘密认证状态与 `AuthenticationServicing`，二维码图像走 `BiliAuthFeature`
定义的窄 Presentation port 注入。请求 builder（`RequestAccess` 与请求管线）只在 `BiliAPI` 内部可见，由各域
endpoint 扩展逐请求选择访问方式，Repository adapter 不自行构造 `RequestAccess`；授权器由 Composition 注入。
哪些请求可以带凭据、有哪些写能力，见 [`SECURITY-MODEL.md`](SECURITY-MODEL.md) §3。

窗口复核：凭据失效只由 ViewModel 记录。参与者实现 `AccountRevalidationParticipant`，发现需要复核的失败时以
`&+=` 递增 `authenticationRevalidationGeneration`。参与者集合由 `WindowComposition` 构造一次，`AppRootView`
只比较各参与者的代次，前后不等（不比大小，回绕仍算）就调用一次 `revalidate()`，结束后把结果（仍登录、确认未登录或
没能确认）交给参与者；
绑定来源的参与者只在该来源是当前来源时收到，不在本页时不在后台读取账户内容。收藏夹列表与关注分组（连同全部关注人数）
是侧栏常驻的元数据，共用 `LibrarySidebarListModel`，按窗口级登记，例外地不论当前来源都读取并接收结果。Feature 不直接调用认证服务。用户发起的账户写入由窗口的
写入协调者作为窗口级参与者，凭据类失败只请求一次复核，同一账户与会话代次里直到下一次写入成功不再请求。

内容域的认证失败分四态，由 `ContentApplicationError` 决定是否复核与是否给重试：无凭据是“需要登录”（不给重试）、
凭据失效触发复核、本地凭据读不到可重试但不复核、风控按受限。观看历史、稍后再看与收藏夹只在窗口已登录时
显示，所以读取时本地无凭据也复核；复核确认仍登录后，由凭据失效引发的自动重载在下一次加载成功前最多一次
（`AccountRevalidationProgress`），挡住“复核 → 重载 → 失效”的循环。首页推荐、热门、搜索与 UP 主空间能匿名读取，确认未登录
同样重载一次停住的失败页：读取先于复核删掉损坏或过期的凭据时账户范围不变，不会经账户变化重启。

多窗口共享一个进程级账户会话协调器：登出、换号或凭据失效时先全局推进 authentication epoch，其他窗口再复核
Keychain，并按新 generation 重启依赖账户的内容。账户变化由来源自己处理，App 只经来源描述通知；其他窗口换号
时，本窗口先丢弃要求账户的来源的内容再复核。

### 账户写入

- 链路：卡片菜单、读屏操作与 ⌘⌫ 只转发意图（BVID，收藏夹页的移除是收藏夹与条目 av 号）→ App
  `Navigation/AccountWriteCoordinator`（每窗口一个，拥有在途写入的 Task（含发送弹幕与评论写入）、「收藏到…」与「设置分组…」面板、结果胶囊的最新结果与复核代次）→ BiliApplication 的写 use case → BiliAPI 的 adapter 与 `BiliAPIClient+AccountWrite`
  （表单编码、固定 header、状态 envelope 与 -101／-111 映射只在共用的写管线，heartbeat 也走它）→ 账户写授权器（见
  `SECURITY-MODEL.md` §3）。只有窗口主 API 有写授权器。
- 门槛由 App 算出后经 SwiftUI 环境注入卡片菜单（BiliUI `VideoCardAccountWriting`），与收藏夹列表读取同一规则，不满足时菜单项
  禁用、读屏操作不列出；协调者每次执行时重新核对，不依赖菜单构造时的状态。同一改动同时只有一个在途。
- 「收藏到…」面板由协调者持有、`AppShellView` 以 sheet 呈现；每次打开都按窗口账户重读归属（收藏夹列表带 `rid`），
  确认时只提交勾选与初始归属的差异，一次请求。面板绑定打开时的窗口账户（含会话代次）：窗口账户一变就关闭，重试与确认
  前再核对一次，否则会在另一个账户下显示、重读或提交上一账户的归属；面板读取的凭据类失败与写入共用一次复核的节流。
- 关注关系：关注、取消关注、特别关注与设置分组是同一族写入，同一个人同时只有一个在途（`isRelationWrite`，播放页与空间页的
  关注按钮也按它判断）：它们改同一份关系，到达服务端的先后不可知，而设置分组（`tags/addUsers`）按完整集合覆盖，后到的会抹掉
  先到的。在途登记在每个窗口自己的协调者里，互斥只在窗口内：两个窗口同时改同一个人时互不阻挡，后到服务端的写入仍可能抹掉
  另一个窗口先到的，两个窗口按各自收到的效果显示、直到下一次读取。不做进程级登记：那要跨窗口共享在途状态与关窗取消，而
  同时在两个窗口改同一个人很少见。特别关注与设置分组的状态不放进播放页的整份互动快照（那份回滚会把它们拖进与点赞、投币的互斥），放在窗口级的
  `Navigation/FollowRelationStore`：按 mid 的已知关系（单人关系读取、关注页每一页说明的关系、写入确认的值与乐观改动；
  `FollowRelation` 区分没有关注、分组已知与只知道已关注），关注页卡片的菜单与特别关注标记、空间页与播放页「已关注」菜单的
  状态（两处在关注状态是已关注时预读，侧栏的空间预览不读）、「设置分组…」面板的底、写入的
  前置条件（只对已知关注的人发特别关注与设置分组）与写前关系都只从这里取，账户一变就清空。写后立刻读到的关系、人数与分组成员
  可能还是旧值：存储里的 `FollowRelationLedger`（BiliApplication，纯值、时刻由调用方传入）记下写入确认的关系与时刻，宽限期
  （`relationReadLagGrace`）内与之矛盾的单人关系按确认值，关注页的一页去掉确认已离开的人、换上确认的分组
  （`FollowListViewModel` 的 `reconcile`，在到底判断之后）；存储持有唯一一个等到宽限期结束的 Task，把关注页标记为过期。侧栏
  人数的旧值由侧栏列表自己处理（见下文「效果分发」）。不采用写后立即重读：读到的是旧值，按它作
  「设置分组…」的底会把刚加入的分组悄悄抹掉。效果带写前与写后的分组（`.followSpecialChanged`、`.followGroupsChanged`；
  `.followChanged` 不带，各窗口取自己的关系存储），每个窗口按前后差异在本地改人数（各行按 `FollowMembership.groupIDs` 计，
  只加入特别关注时默认分组随之减一），任一侧分组未知时只等宽限期后的补读；关注页去掉已不属于正在显示的列表的卡片，刚加入的人不插入。
  「收藏到…」与「设置分组…」面板的开、关、重试、账户变化与确认是同一个按账户绑定的帮手 `AccountBoundPanel`。
- 播放页互动：点赞、投币、收藏按钮的状态在 BiliVideoDetailFeature 的 `VideoEngagementModel`（每窗口一个，按展示的详情与
  写入门槛的账户读取 `archive/relation`），按钮经环境 `VideoEngagementActions`、快捷键 Q／W／E 经 `PlayerEngagementShortcuts`
  把意图交给同一个协调者。同一视频的点赞、投币、三连同时只发一个（都可能改点赞，到达服务端的先后不可知）；保留的旧详情
  不可操作（换视频正在加载或失败）时快捷键与按钮一样不响应。点赞乐观改动、失败放回，是否“已在本地改过”在写入成功时判断；
  投币与三连不可撤回，成功后才改状态，并让更早的回滚与在途读取作废，失败时重读一次（服务端可能已部分生效）；三连的收藏
  进默认收藏夹，按收藏写入刷新收藏夹。键盘状态机在 keyUp 判断短按点赞，按住 `longPressDelay` 显示三连进度、`tripleHoldDuration` 时三连，中途松开不
  动作。投币面板与「收藏到…」在主窗口里，AVKit 独立全屏时 W／E 只提示先退出全屏。点赞、投币、三连走 App 端接口：
  网页的这三个接口对部分账号或稿件以 -401／-403 拒绝第三方客户端（补网页统计字段、视频页 Referer 与 B 站下发的 buvid 都
  没有改善），同一时刻 App 端成功；不采用网页失败后再试 App 端的回退，同一意图只发一次。App 端仍返回 -403 时结果胶囊给出
  「在浏览器中打开」（停留更久）。互动状态的读取与关注仍走网页。
- 关注 UP 主：播放侧栏 UP 主行的关注按钮读同一个 `VideoEngagementModel`，关注状态取自同一次 `archive/relation`（`attention`），
  随它按账户重读与复核；播放页不用名片里的 `following`：名片按 UP 主沿用（`VideoViewModel`），不随账户重读。
  粉丝数与投稿数取自名片，只读展示，关注后不在本地增减。意图只带 BVID，协调者从互动状态取 UP 主 mid（自己的视频不发），
  乐观改动与回滚同点赞；互动状态的快照与回滚是整份的，所以关注与点赞、投币、三连在一个窗口里不同时在途。其他窗口按 mid
  重读正在显示同一 UP 主视频的互动状态。
- 整页空间页的关注按钮：空间页没有 BVID，读不了 `archive/relation`，关注状态取自整页空间模型读名片时同一响应的
  `following`（`UploaderCard.viewerFollows`）。它属于发出读取的账户，所以只在读取实际带了凭据时采用，匿名回退读到的
  按未知（按钮禁用，不当成“未关注”）；读取发出与落地时窗口账户不同也按未知；换 UP 主或关闭时清空。账户一变历史就清空，
  空间页不会带着旧账户的状态留下。不采用另建关注读取（多一次请求、多一个 endpoint），也不把它放进 `UploaderProfile`
  （名片会跨视频、跨账户沿用）。写入按 mid（意图取自空间页模型的 UP 主，自己的空间不显示按钮），乐观改动只在空间模型里，
  不碰播放页的整份互动快照；同一 mid 同时只有一次关系写入在途，不分方向与种类（见上文「关注关系」）。成功的效果让各窗口正在显示这位 UP 主的空间页取
  确认的状态、播放页按 mid 重读互动状态。
- 发送弹幕：播放器 content overlay 里的输入胶囊（BiliVideoDetailFeature 的 `DanmakuComposerModel`，每窗口一个、关窗时 reset；
  视图在 App `Platform/`）由回车、播放器动作菜单与播放页工具栏呼出，窗口与 AVKit 独立全屏同一套，不做读取 AVKit 私有视图
  层级的悬浮按钮。请求交给同一个协调者（`postDanmaku`），窗口里同时只有一条在途、关窗取消、凭据类失败按同一节流复核；
  结局交回胶囊：失败在胶囊下方说明、草稿保留；成功另作为一条写入结果（见「临时提示与结果」），弹幕关着或车道已满时画面上
  看不到那一条。措辞取自结果胶囊的同一套文案。成功不产生跨视图效果。换视频与离开
  播放页时收起胶囊，草稿不会发到另一个视频上。样式选项是胶囊上方同一浮层里的一行，不用 popover：popover 是另一个窗口，会让输入框失去第一响应者，
  播放器快捷键随之接管按键。
- 评论的发表与赞踩：写入状态在 BiliVideoDetailFeature 的 `PlaybackCommentWriteModel`（每窗口一个、关窗时 reset，持有草稿、回复对象、
  展开状态与失败说明），请求交给同一个协调者（`AccountWriteCoordinator+Comments`）：窗口里同时只有一条评论在发、同一条评论同时
  只有一次表态在途（赞与踩互斥，两次请求到达服务端的先后不可知），关窗取消、凭据类失败按同一节流复核。表态先在
  `PlaybackCommentsViewModel` 里乐观改动同一条评论的每一处出现（根评论、预览、当前页、对话），失败或被取消时放回，换对象、换排序、
  重载（`rootGeneration`）或评论已不是改动后的样子时丢弃回滚；失败作为写入结果，成功不提示（结果就在那一行上）。发评论的结局交回
  输入卡片：失败在卡片里说明、草稿保留；成功另作为一条写入结果，服务端给回的那条按列表的同一映射插入，解不出时只是不插入、
  不报失败（否则用户会重发一条已发出的评论），这时那条写入结果是唯一的确认。点赞数与表态不进
  行的 `revision`（正文渲染作用域与行高缓存键），单独的 `reactionRevision` 让这一行就地重新配置，点赞不重新渲染正文。发评论走 App
  端接口、赞踩走网页，理由见 `SECURITY-MODEL.md` §3。
- 评论入口是叠在播放侧栏底部的 SwiftUI 浮层：收起时是右下角一枚玻璃圆钮，展开时同一块玻璃改尺寸与圆角长成卡片（内容淡入淡出、
  按形状裁剪）。不采用两个视图加 `glassEffectID` 的变形：实测在 macOS 上它不论隐式动画、`withAnimation` 还是声明 matched-geometry
  过渡都直接跳到终态。「返回顶部」是侧栏滚动视图里的 AppKit 按钮，叠在入口上方：入口里一个 `Animatable` 视图按同一条动画曲线逐帧
  报告看起来的高度，`NativePlaybackComposerClearance` 直接改按钮的 frame（逐帧写 SwiftUI 状态会在渲染中再触发更新）；列表末尾按入口的
  布局高度留白，展开、收起各变一次。按键与焦点沿用输入胶囊的规则：输入框永不禁用，收起前先同步放下第一响应者，不按失焦收起。
- 首页推荐的「不感兴趣」：反馈走 App 端接口（推荐流来自 App 端，服务端按 access_token 认出是谁的推荐流）。子菜单的原因是
  卡片自己给出的列表（id 与中文名字原样显示，不本地化，不设固定原因），Browse 按选中的原因构造反馈；卡片没给原因就没有这一项。
  标记属于 `BrowseViewModel` 的推荐工作集、跟着卡片走（刷新成功后只留新推荐里仍有的）。协调者先乐观标上或去掉，失败或被取消时凭改动时的工作集身份
  放回，工作集换过（换号、`reset`）就不放回，免得把上一账户的反馈标到新推荐上；同一视频的反馈与撤销同时只发一个，撤销
  必须带发出时的同一份反馈。效果不落到其他窗口：各窗口的推荐流本来就各不相同。
- 乐观移除：稍后再看页与收藏夹页的移除先在本地删掉，失败或被取消时放回原位（稍后再看按 `PagedVideoList` 的并入序号，
  收藏夹按页内位置）；之后内容被整体替换过就不再放回。已知边界：页码分页在服务端删掉条目后整体前移，移除之后继续向下加载可能漏掉与移除条数相同的几条，刷新后恢复。
- 效果分发：成功的写入带着账户 mid 与发起时的会话代次，经本窗口的 `AccountWriteEffectRouter` 与进程级集线器转给所有窗口；
  只处理与本窗口账户、会话代次都一致的效果。稍后再看只标记为过期，下次页面出现时原地刷新一次，不在后台读取；收藏写入在
  每个窗口按效果增减侧栏收藏夹的条数（三连不知道写前是否已在默认收藏夹，不改），受影响的收藏夹正在显示时原地刷新（不回
  顶部），不在本页时回来再刷新。侧栏的条数（收藏夹与关注分组）写后立刻重读到的可能是旧值：`LibrarySidebarListModel` 的
  `adjustAfterWrite` 在本地改值，宽限期（`countReadLagGrace`）内落地的后台重读丢弃，宽限期结束时补读一次；不采用写后立即
  重读，它会把刚改过的条数改回写前。乐观移除是否“已在本地改过”在写入成功时判断：期间有读取落地或在途，就按未改过处理、重读一次。

### 临时提示与结果

- 写入结果同一时刻只在一处显示、只通告一次。窗口里是详情栏底部的写入结果胶囊（`AccountWriteStatusCapsule`，只挂在 detail
  视图上一处，来源页与播放页互相替换时它都在）；AVKit 独立全屏时在播放器顶部反馈徽标的下方，全屏窗口里看不到主窗口的胶囊。
  位置由写入协调者的 `resultSurface` 决定，播放器宿主在进入、退出全屏、挂上与摘下播放页、拆除时经 `PlayerWriteResults`
  切换（全屏中离开播放页时 AVKit 是否先回调退出全屏不确定，摘下时一律交回窗口）；切换时正在显示的
  那条换个位置，不重新计时、不再通告。新结果替换旧的，不排队，失败也会被随后的结果替换（读屏两条都会报）。全屏下不放「在
  浏览器中打开」：跳到浏览器会打断观看，说明里已写着可以在网页上完成。
- 播放器顶部的徽标分两档（`PlayerShortcutFeedback.Tier`）：回显只确认按键被接收（进退、音量、开关、拷贝），停得短、单行、
  高优先级通告，连按时只读最新；说明是做不了的原因或播放器自己做了什么（登录后可…、接着播放…），停到读得完、最多两行、按
  默认优先级通告。会自己消失的提示时长都取 `TransientNoticePolicy`。
- 发出写入的按键（Q 点赞、长按 Q 三连、动作菜单加入稍后再看）不在播放器上另给反馈，否则一次写入有两条提示：窗口里工具栏的
  按钮当下就翻转，结果在胶囊里；全屏时看不到按钮，在结果的位置先显示「正在…」（不通告），结果到达后原位换成结果，写入被
  取消、没有结果时按说明的时长收起。长按 Q 的三连进度环照旧是回显。
- 窗口里的状态胶囊（刷新、分页、写入结果）共用一份外观（`statusCapsuleChrome()`）；列表底部有会停留的分页胶囊（失败、
  「继续加载」）时，写入结果胶囊排在它上方（`PaginationStatusLaneHeightKey`）。加载更多的转圈不让位，否则写入结果会随翻页上下跳。
- 有输入框的写入（弹幕、评论）失败时说明留在输入框里、草稿保留，不进写入结果；成功与其他写入一样作为一条写入结果。失败
  说明与其他提示一样用感叹号图标与正文颜色，红色只留给字数超限。
- 会停留的失败（刷新、分页、输入框里的说明）留到下一次操作，出现时通告一次；常驻状态（失败页、空列表、登录门槛）不通告；
  播放器自己做的事（从上次的位置续播、试看结束）出现时通告一次，读屏焦点不在浮层上。播放器底部正中的试看结束徽章在弹幕
  输入胶囊呼出时排到它上方。
  读屏通告只经 BiliUI 的 `accessibilityAnnouncement`，视图首次出现时不发，切回页面时已有的失败不会重读。
- 不建统一的提示中心或队列，也不做系统通知中心推送：提示的位置跟着它属于哪块内容（列表、输入框、播放器），只有写入结果
  需要在窗口与全屏之间换位置，一个 `resultSurface` 就够。

### 播放线路偏好与测速

同一 fMP4 播放中换源会破坏字节一致性和单一播放器 owner，一次样本也不能代表未来视频，所以只做
显式选择：Settings 提供服务端默认、服务端原始 Akamai／bilivideo 与固定 bilivideo 镜像；每次新
load 只读一次，只调整视频候选。实验镜像只替换原始 bilivideo URL 的 host，保留签名；缺失时回退
服务端顺序。测速仅在已登录用户显式点击后运行，样本与路线严格串行、流量有硬上限、结果只存在于当前
Settings 窗口，从不自动改选。

### 分发

- Developer ID 站外 DMG + 公证，不走 Mac App Store；更新用 Sparkle 完整包 + Cloudflare 静态签名 appcast，
  不自研更新器。
- Homebrew 只走自有 tap `shiinayane/homebrew-tap`，cask 指向同一个 GitHub Release DMG，由 `release.py publish`
  在 feed 上线后更新；cask 声明 `auto_updates`，升级仍交给 Sparkle。官方 cask 有知名度门槛，不自行提交。
- 1.0.0 是最后一个 Universal 版本；此后 Release 主程序只含 `arm64`，Sparkle 官方嵌套组件保留其自带
  架构。不为旧 Intel 用户建立专用 feed。
- 只维护发布工具链 Xcode 27 一个版本，不保留按编译器版本分叉的代码。CI 在 macOS 27 上跑完整
  Gate；macOS 26／15 只启动同一 App 做冒烟：旧 runner 上的 Xcode 加载不了 27 构建的测试 bundle，而 Xcode 27
  不支持 macOS 15。因此 AVFoundation、loopback 与窗口行为在最低系统上没有自动验证。
- Gate 判定包测试通过不只看 `swift test` 的退出码：测试进程中途正常退出时退出码仍是 0。`package_test` 把
  xUnit 结果与 `swift test list` 逐个比对（`Scripts/check-package-test-results.py`）。
- 包测试进程里不进入 AppKit 事件循环（弹出菜单、`nextEvent(matching:)`、模态会话）：事件线程会向主 run loop
  投递 `CFRunLoopStop`，Swift 并发主执行器被停下后运行时直接 `exit(0)`，测试静默中断。
- App 测试不读仓库源文件：仓库在外接卷上时系统每次都会弹出访问授权，Gate 无法无人值守。源文件检查放在
  static 阶段的脚本里。
- 字符串目录按位置发现：App 用 `BiliKitMac/Localizable.xcstrings`，Package target 用本 target 的
  `Resources/Localizable.xcstrings` 与 `XxxFeatureStrings`。Package 里未指定 bundle 的 SwiftUI 字面量会查 App 的
  `Bundle.main`，非 ASCII 文案必须走本 target 的 helper；key 的完整性由 `Scripts/check-localization.py` 检查。
- 计数、日期、相对时间、时长与百分比的格式化 locale 只取 BiliUI 的 `InterfaceLocale.current`：语言是字符串目录实际
  选中的语言，地区与格式偏好沿用系统。系统语言都不受支持时目录回退到 zh-Hans，`Locale.current` 却是 en，直接用它会
  中英混排。格式化函数的默认参数取它；SwiftUI 环境 `locale` 仍是系统 locale（工程不在根上强制界面 locale，它同时
  决定排版语言与字形，见 `check-project-contract.sh`），视图不把环境 `locale` 传给格式化。
  单位与词序（万／K、分钟前、昨天、月日）交给系统格式，字符串目录只存没有系统对应的「刚刚」；发布时间与评论时间
  的相对时间规则只在 BiliUI 的 `DateDisplayFormatting`。

## 不采用

- 每条评论或每张卡片嵌入 `NSHostingView`；`List`／`LazyVStack`／`LazyVGrid` 作为生产长列表容器。
- 第三方 DI、Coordinator 框架、Redux／TCA。
- 每个模块独立 `Package.swift`；为单一调用方新建 renderer／Shared target。
- Feature 直接观察 `AVPlayer`；字幕或弹幕独立 timer；弹幕放进 Feature 或在 `BiliDanmaku` 解码 wire。
- 弹幕按时间线快照自建动画时钟（按快照改 `rootLayer` 的速率与时间）或靠识别 seek 清屏、补位：时钟切换与
  误判的跳变都会闪，画面也依赖到达顺序；弹幕动画只由时钟层按 item timebase 驱动（见「媒体时间轴」）。
- 弹幕挂在 `AVSynchronizedLayer` 下：它的速率与时间由 AVFoundation 在主线程更新，暂停时主线程被播放器
  挡住期间它晚停 30～40ms，弹幕先多走一段再跳回。
- 弹幕按窗口尺寸布局、resize 后去抖重排并整屏替换：拖动窗口边缘时画面整屏跳变，去抖期间还要为居中、
  贴底与按旧宽度运动写特判；取景框模型让 resize 只移动锚定边。
- mpv 等第二播放后端；AVPlayer + loopback 能满足当前需求。
- AV1：AVPlayer 只在带 AV1 硬件解码的 Mac（M3 起）上能播，其他机器整条视频放不了。
- 同一 master 混入 AVC 与 HEVC：ABR 换档时会在两种编码之间切换；只用一种编码，回退规则也只需一条。
- HDR 卡顿时自动以 SDR 重建播放项：要判断“卡顿是 HDR 档造成的”、重建会打断播放并丢失缓冲；加载时的条件
  过滤与“HDR 视频”开关已能避开主要情形。
- 杜比视界（HLG 基础层）不写 `VIDEO-RANGE` 混进 SDR 阶梯以获得降档：它会受视图尺寸上限约束，常见窗口里根本
  选不到；HDR 真彩（PQ）不写时 item 直接失败。
- 杜比音频与无损音频作为菜单里单独的音轨（不同 NAME）：要手动选，选中后系统也不会按输出设备或网速换回；
  同名分组让 AVPlayer 按输出声道与带宽自动选择，与 Apple Music 的做法一致。
- 响度均一化：只能压低不能放大（放大需要限幅器），依赖 playurl 的响度元数据（许多较早的视频没有），
  只在 macOS 27 起有官方接入点；它按“原声只有一条”匹配音轨，音轨按编码与码率分成多组后系统会合并同名选项、
  换组时不发通知，无法确定当前播放的是哪一组。
- `*.bilibili.com` 后缀匹配授权；WKWebView 登录；共享 `HTTPCookieStorage` 或 `URLSession.shared`
  作为登录态。
- 播放中自动换源、后台测速、按测速结果自动改选。
- 评论加载时不显示任何提示（B 站 App 的做法）：它的评论在另一个标签页，打开时多已加载完；这里评论与播放器
  同屏，慢请求下空白分不出加载中、无评论还是卡住。延迟露出的转圈在快请求下效果相同（见「加载呈现」）。

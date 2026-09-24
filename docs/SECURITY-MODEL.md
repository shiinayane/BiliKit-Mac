# BiliKit 安全模型

本文只列可执行、可测试的规则。认证、远端来源、重定向、本地服务器、字幕、弹幕、图片、缓存或
更新相关改动必须先对照本文；模块边界见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## 1. 秘密与凭据

| 资产 | 规则 |
| --- | --- |
| Web Cookie | 只接受 QR 成功响应 `Set-Cookie` 中的白名单 `DedeUserID`、`DedeUserID__ckMd5`、`SESSDATA`、`bili_jct`、`sid`；未知 Cookie 丢弃 |
| `qrcode_key`、完整二维码 URL | 只在 `BiliAuth` 内存；URL 封装为不可读的 `WebQRCode`，只在内存生成图像，不复制、不导航、不落盘 |
| `refresh_token` | 轮询响应只解码状态码，不读取、不保存、不使用该字段，不实现自动刷新 |
| 登录身份 | Presentation 只拿显示所需的非秘密投影；Keychain item 名称不含 UID |

- 持久秘密只存 Keychain：Security.framework generic-password、固定 service/account、
  `kSecUseDataProtectionKeychain`、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、非 synchronizable，
  保存一个版本化 envelope；解码后重新校验名称、domain、path、Secure、值字符与大小。
- 凭据类型的 `description`／Mirror 不展示值。UserDefaults、文件、fixture、日志、截图、崩溃信息、
  App 恢复状态和验证记录都不得出现 Cookie、QR key、token 或完整认证 URL。
- Cookie、QR key、Keychain 类型、endpoint DTO 不越过 `BiliAuth`／`BiliAPI` 进入 Application 或 Feature。
- 不使用 `URLSession.shared`、共享 `HTTPCookieStorage`、`URLCredentialStorage` 或 WebView Cookie；
  不导入浏览器或手动粘贴的 Cookie，不接入 App token 登录。

## 2. 登录状态机

- QR 生成与轮询只连 `https://passport.bilibili.com`；待显示 URL 只接受精确 `https://account.bilibili.com`。
  已确认状态为 `86101` 未扫码、`86090` 已扫码待确认、`86038` 过期、`0` 成功；其他值失败关闭，不
  回显服务端 message/payload。
- 成功后先在内存组 Cookie 请求 `/x/web-interface/nav`，`isLogin=true` 才在同一 actor generation 内
  写入 Keychain；旧 generation、取消、过期、校验或存储失败都清除临时秘密，不能返回登录成功。
- 轮询有最小间隔、总时限和次数上限；ViewModel 拥有 Task，actor 用 generation 与 poll ID 隔离旧结果。
- 恢复时重新校验：远端明确失效则清理；本地缺失／损坏／过期回退未登录；临时网络失败不删凭据。
- 登出顺序：取消认证任务 → 清二维码与内存 → 删除 Keychain item → 失效并重建 session → 发布未登录。
  本地登出不依赖网络；Keychain 删除失败时不得发布未登录。
- 账户变化（登出、换号、凭据失效）先全局推进所有窗口 API transport 的 authentication epoch；旧
  epoch 的请求与响应不得写回，并关闭依赖账户的播放器与报告 owner。
- 认证失败不得影响游客热门、搜索、详情和播放。

## 3. 哪些请求可以带凭据

默认所有网络匿名。只有两个授权器，均由 Composition 注入 `BiliAPI`：

**账户读取**（`BiliCredentialRequestAuthorizer`）

- 只允许 `https://api.bilibili.com`、端口缺省或 443、GET、无 userinfo／fragment、路径编码规范，
  且 path 在 `AppEnvironment` 声明的 allowlist 内（主客户端、测速客户端、会话校验各一组）。
- 调用方已带 `Cookie`、`Authorization` 或 `X-CSRF-Token` 时拒绝；每次授权生成新请求，不缓存 header。
- `BiliAPIClient` 的 endpoint 扩展逐请求决定匿名或账户读取，并独占 path/query schema；请求 builder
  只在 `BiliAPI` 内部可见，adapter 不构造 `RequestAccess`；授权器不复制业务规则。
- 本地明确无凭据时匿名请求同一 endpoint；凭据损坏、过期、Keychain 不可用、403/412、业务拒绝、
  非 JSON、redirect 一律失败关闭，不自动匿名重试。
- WBI key 的 nav 请求保持匿名。

**唯一写能力：观看进度**（`BiliPlaybackHeartbeatRequestAuthorizer`）

- 仅 `POST https://api.bilibili.com:443/x/click-interface/web/heartbeat`；header 集合固定为 `Accept`、
  `Content-Type`、`Referer`、`User-Agent`，query 与表单字段按固定 schema 逐项校验并交叉核对。
- 只发送 `SESSDATA`，`bili_jct` 仅在 `BiliAuth` 内作为 `csrf` 注入表单。
- 游客不创建写意图。403/412、认证、网络、解析或业务失败只关闭匹配的报告会话，不触发认证重校验，
  不影响 AVPlayer。进程内单并发，每窗口有界合并，最终退出边界优先。
- 不建立离线队列，不持久化位置或待发送请求，不崩溃恢复写入。
- 任何其他写操作都需要新的产品决定、精确 endpoint／method／schema 和对应授权器，不得泛化此授权器。

**永不携带凭据**：WBI nav、图片、视频／音频 CDN、字幕正文、loopback server、二维码 URL、评论外链、
Sparkle 更新网络，以及任何 redirect 后的主机。不使用 `*.bilibili.com` 后缀匹配。

## 4. 远端来源与重定向

所有 API、媒体、字幕与图片 session 均为 ephemeral、`httpShouldSetCookies = false`、无 Cookie
storage、无 URL cache，并拒绝 redirect。`PublicHTTPSURLPolicy` 是基线：HTTPS、无 userinfo／fragment、
端口缺省或 443，拒绝 IP literal 与 `localhost`／`.local`／`.internal`／`home.arpa`。它不解析 DNS，
不能证明域名不指向私网，所以各用途再叠加专属规则：

| 用途 | 允许来源 | 其他限制 |
| --- | --- | --- |
| 媒体（DASH、progressive） | `BiliMediaCDNURLPolicy`：`bilivideo.com`／`bilivideo.cn`／`szbdyd.com` 及子域、`upos-*.akamaized.net` | DTO 映射与实际连接前各检查一次；响应须为精确 206、`Content-Range`、长度；映射后的媒体 headers 去除 `Cookie`／`Authorization` |
| 字幕正文 | `SubtitleURLPolicy`：`https://aisubtitle.hdslb.com/bfs/...` | 正文 ≤ 2 MiB；新主机先失败关闭 |
| 评论头像、表情、正文图片 | `i0`／`i1`／`i2.hdslb.com` 的 `/bfs/` 路径 | 拒绝 query、fragment、点段、编码分隔符 |
| 视频封面 | 接口返回的 HTTPS URL（`http:`、协议相对地址升级为 HTTPS） | 由图片管线限制 |
| 评论外链 | 视频链接只回送合法 BVID；成员只允许正整数 MID → `space.bilibili.com`；其他目标经公开 HTTPS 形状复核 | 仅用户点击后交给系统 `OpenURLAction`；不预取、不解析 DNS、不附加凭据 |

- 弹幕分段与评论页须通过状态、Content-Type 与 2 MiB 上限，再交给解码器；JSON、protobuf、HTML 错误页和
  空响应不能互相降级解析。未知接口状态失败关闭。
- 图片管线（`NativeVideoImagePipeline`）：无凭据 session，响应必须 2xx、HTTPS、同主机、`image/*`、
  ≤ 8 MiB；按用途限制解码尺寸；只有有界内存 cache，没有磁盘 cache。

## 5. 本地回环服务

- `LoopbackPlaybackServer` 只绑定 `127.0.0.1`，系统分配端口，每实例使用随机 session path。
- 只实现最小 HTTP/1.1：限定方法、路由和 header 大小；剥离 `Cookie`／`Authorization`，只转发经解析
  验证的单一 Range。
- playlist 只在内存；媒体正文逐 chunk 转发并等待下游 send completion 形成背压，不整段缓存、不落盘。
- 播放项目替换、停止、关窗或登出时关闭 server，取消连接与上游 Task。
- 诊断不输出 Cookie、token、上游响应 body、host、query 或签名 URL。

## 6. 本地持久化

- UserDefaults 只保存非内容偏好：播放音量、静音、首选倍速；弹幕速度、透明度、显示区域、密度；
  版本化播放线路 route identifier 与响度均一化开关。未知或损坏值回退默认。
- 不持久化 BVID、CID、AID、播放位置、标题、字幕／弹幕正文、字幕选择、远端 URL、测速样本与结果，
  以及任何响应正文。观看 identity 与位置只存在于当前进程内存；服务端返回的续播位置只作一次性
  内存候选，匿名响应丢弃该字段。
- 没有本地数据库或磁盘缓存；新增持久化必须先定义 schema 版本、容量、期限、登出清理并更新本文。
- 响度元数据只保存策略所需数值，不含原始响应或内容身份；gain 不写入 `AVPlayer.volume` 或偏好。

## 7. 应用更新

- Sparkle 只链接 App target，由唯一 `AppUpdater` 持有；它不引用 `BiliAuth`、账户 coordinator、授权器
  或播放器，更新失败不进入认证或播放清理链路。
- `AppUpdater` 仅在配置完整时启动：`BiliKitUpdaterEnabled`、HTTPS `/appcast.xml`（无 query、userinfo、
  非标准端口）、32 字节 `SUPublicEDKey`、`SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction`、
  `SUSignedFeedFailureExpirationInterval = 0`、启用 Installer XPC、禁用 Downloader XPC；另关闭
  `SUEnableSystemProfiling`。
- entitlement 只为 Sparkle 增加 `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`／`-spki` mach lookup，不加文件权限或
  runtime exception。
- 自动下载与安装默认关闭。不添加账号标识、查询参数或自定义请求头。
- Cloudflare 只托管已签名 `appcast.xml` 与 `_headers`；DMG 只来自固定仓库的 GitHub Release
  `/releases/download/<tag>/<file>.dmg`，拒绝草稿、latest 与 query。build 号正整数递增，资产不覆盖，
  坏版本用更高 build 前向修复。
- EdDSA 与 Developer ID 私钥只在发布机 Keychain 与加密备份，不进仓库、CI、Cloudflare、参数或日志。

## 8. 日志、fixture、截图

- 产品代码不输出网络日志；错误只含阶段与分类。新增任何日志或诊断前必须先加脱敏并更新本文。日志与诊断不记录内容身份组合、标题、位置、
  Referer、query/body、Cookie、CSRF、账号标识、完整 URL 或响应正文。
- fixture 只用手写假值与 `example.invalid`（媒体地址用虚构的 `*.fixture.bilivideo.com`，生产 allowlist 不为测试开口），不录制现场响应；`Scripts/check-secrets.sh` 在 static Gate
  中扫描已知秘密模式。
- 现场探针只输出字段名、类型、长度、计数、状态与分类。
- 含标题、账号、二维码、字幕或弹幕正文的真实截图不进仓库。

## 9. 剩余风险

- Web QR 与各 Web 接口未公开，可能无通知漂移；漂移应表现为失败关闭，而不是降级。
- Keychain 不能抵御已控制当前用户会话、可调试进程或可读屏幕的攻击者。
- 响度 tap 依赖 macOS 26 未文档化行为；未回调只能表现为静默 unity。
- 签名私钥丢失时，拒绝降级策略可能要求用户手动安装新版。

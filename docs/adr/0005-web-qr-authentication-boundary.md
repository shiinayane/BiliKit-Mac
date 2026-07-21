# ADR 0005：Web QR 认证与凭据边界

- 状态：已接受
- 日期：2026-07-21
- 关联：ADR 0004、[`../security/M3-threat-model.md`](../security/M3-threat-model.md)

## 背景

M2.5 已把游客功能整理为 `Domain ← Application ← Presentation`，具体 API 与播放实现通过 port 注入。M3 要加入 Web QR、Cookie、Keychain 与登录态请求；若让 `BiliAPI`、ViewModel 或共享 `URLSession` 直接持有 Cookie，会重新形成跨层全局状态，并可能把凭据带入 CDN、日志和持久化系统。

2026-07-21 的现场探针确认 `passport.bilibili.com` 当前存在二维码生成与轮询响应，但未发现对应的官方公开稳定 API 文档。因此该协议被视为“经过 fixture 固定的外部观察”，不是受支持的产品契约；任何漂移必须失败关闭。

## 决策

继续使用一个本地 Swift Package、多个 target，并在真正有调用方时新增两个边界：

```text
BiliAuthFeature ──→ BiliApplication ──→ BiliModels
                         ↑
                         │ non-secret AuthenticationServicing
                         │
BiliAuth ────────────────┘
   ├── BiliNetworking.HTTPRequestAuthorizing
   ├── Web QR endpoint/state adapter
   └── Security.framework Keychain adapter

BiliAPI ──→ BiliNetworking.HTTPRequestAuthorizing（可选注入）
```

### Application 与 Presentation

- `BiliApplication` 定义认证用例需要的非秘密 port、状态与身份投影。它不知道 QR endpoint、Cookie 名称、Keychain 或 `URLSession`。
- `BiliAuthFeature` 在开始真实登录 UI 时创建，保存 SwiftUI View、二维码展示和 `@MainActor` ViewModel；只依赖 `BiliApplication` 与 `BiliModels`。
- ViewModel 拥有登录意图的 Task、取消和页面生命周期，但不解析 endpoint DTO、不读写 Keychain，也不取得 Cookie。
- App composition root 创建具体 `BiliAuth` adapter，并把非秘密认证用例注入 Feature。

### Auth adapter

- `BiliAuth` 保存 Web QR DTO/状态映射、轮询 actor、成功结果校验、Keychain store 和凭据 provider。
- QR key、Cookie 和以后可能支持的 refresh token 都是 `BiliAuth` 内部类型，不进入 `BiliModels` 公共实体。完整 QR URL 只封装在 `BiliAuth.WebQRCode` 的不可公开字段中；Presentation/开发探针只能请求在内存生成图像，不能直接读取 URL。
- 状态机只在最新 generation 的成功结果通过登录态验证后提交 Keychain；取消、过期、协议错误和身份校验失败都会清除临时秘密。
- M3 首版不实现自动 refresh，也不保存 `refresh_token`。需要刷新时新增证据、测试并修订本 ADR。

### Networking 与 API adapter

- `BiliNetworking` 增加不含 Bilibili 业务语义的窄 `HTTPRequestAuthorizing` 协议；`BiliAuth` 实现它，`BiliAPI` 只接受可选注入，不依赖具体 `BiliAuth`。
- 每个 `BiliAPI` endpoint 明确声明匿名或需要登录。只有后者能请求授权；授权器仍独立验证 HTTPS、精确主机和 endpoint 范围。
- 不使用 `*.bilibili.com` 通配；Cookie 不发送给图片/视频 CDN、loopback server、二维码嵌入 URL 或重定向后的其他主机。
- 认证 transport 使用专用 ephemeral session，禁止自动 Cookie 存储和跨主机自动重定向。游客请求继续保持无认证可用。

### Keychain

- 使用 Security.framework generic-password item 和 Data Protection Keychain。
- 使用固定 service/account、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、非 synchronizable；保存一个版本化 credential envelope。
- Keychain 是唯一持久秘密存储。UserDefaults、SwiftData、文件、fixture、日志和 App 恢复状态均不得保存认证材料。
- 登出先取消活跃任务，再清内存、删除 Keychain item、失效 session，最后发布 signed-out；网络失败不能阻止本地登出。

## 不采用的方案

- 不让 `BiliAPIClient` 成为全局登录态或 Cookie owner；它只负责 endpoint 和 DTO。
- 不让 `BiliApplication` 暴露 `[HTTPCookie]`、Cookie header 或 refresh token。
- 不使用 `URLSession.shared`、共享 `HTTPCookieStorage`、`URLCredentialStorage` 或 WebView Cookie 作为 App 登录持久层。
- 不通过 WKWebView 打开二维码登录页；M3 只显示服务端生成的二维码并轮询确认。
- 不复制浏览器 Cookie、不导入用户手动粘贴的 Cookie，也不接入 App token 登录。
- 不把完整成功响应录制为 fixture；fixture 只使用手写假值。
- 不在没有 UI 调用方时提前创建空的 `BiliAuthFeature` target。

## 影响

正面影响是秘密被限制在一个 adapter 内，游客模式与认证失败解耦，API/Feature 可以使用假 port 独立测试；主机白名单与 endpoint 声明形成双层防误发。代价是认证需要额外 target、专用 transport、Keychain 测试隔离和更显式的 composition。

Web QR 协议仍可能漂移，因此 M3 的契约 fixture、脱敏现场探针和未知状态处理属于产品正确性的一部分，不是一次性研究脚本。

## 首批实现落点

M3 第 2 步已按本决策建立 `BiliAuth` 与 `BiliAuthProbe`：

- 生产构造固定连接 `passport.bilibili.com`，使用独立 ephemeral session，关闭 Cookie store/cache、设置明确请求/资源超时并拒绝重定向。
- 生成结果只接受 `https://account.bilibili.com` 精确主机；相似后缀主机失败关闭。
- 首批实现只接受当时已确认的 `86101` 未扫码状态，其他业务状态映射为不包含服务端 message/payload 的安全失败。
- QR URL 以不可直接读取的 `WebQRCode` 保存，由 Core Image 在内存生成 `CGImage`；探针不写临时图片或打印原始内容。
- actor 使用 generation 与 poll ID 阻止旧生成/轮询结果覆盖最新意图，并传播 `CancellationError`。
- 首批实现不包含 Cookie 解析、Keychain 或登录态授权；随后通过下述人工扫码 Gate 固定成功与过期契约。

## 人工扫码 Gate 结论

2026-07-21 的脱敏探针确认：

- `86101` 为未扫码，`86090` 为已扫码待手机确认，`0` 为成功结果，`86038` 为二维码过期。
- 成功 JSON URL 指向 `passport.biligame.com`，查询中包含认证相关值；BiliAuth 只观察查询键名，不采集其中的值，也不导航该 URL。
- 成功响应同时提供标准 `Set-Cookie`。权威凭据来源确定为响应 header，精确白名单是 `DedeUserID`、`DedeUserID__ckMd5`、`SESSDATA`、`bili_jct`、`sid`；未知 Cookie 丢弃。
- 五项 Cookie 的 domain 均为 `.bilibili.com`、path 均为 `/`、均带 `Secure` 和过期时间；`SESSDATA` 额外带 `HttpOnly`。
- `refresh_token` 在成功结果中存在，但 M3 首版继续不采集、不存储、不使用。
- 以上 Cookie 在短生命周期内存中组成 header，请求精确的 `https://api.bilibili.com/x/web-interface/nav`，现场得到 `isLogin=true`；验证后立即清空。

因此 M3 可以进入 Keychain 与 endpoint 授权实现，但仍不能把收到 `code=0` 直接等同于持久登录成功：必须先通过 nav 校验，再原子提交 Keychain。

## Keychain 与请求授权实现落点

M3 第 4 步的代码与自动化边界已经落地：

- 五项 Cookie 进入 schema v1 envelope；名称集合、domain、path、Secure、值字符与大小在解码后重新校验，公开描述和 Mirror 不展示值。
- generic-password store 使用固定 service/account，每次 SecItem 操作都带 Data Protection Keychain 与非同步条件；新增使用 `WhenUnlockedThisDeviceOnly`，重复主键走单 item update。
- `BiliNetworking` 只定义无业务语义的 `HTTPRequestAuthorizing`；BiliAuth 当前只允许经过审计的 nav endpoint，并在读取时清理损坏或过期凭据。
- Web QR 保留“只校验”和“校验后提交”两个显式入口。提交入口在同一 actor generation 内完成 nav 校验和同步 store 写入，旧 generation、`isLogin=false` 或存储失败都不能返回持久登录成功。
- 恢复入口重新请求 nav；远端明确失效时清理，本地缺失/损坏/过期时回退未登录，临时网络失败不误删。
- 认证 transport 拒绝 HTTP 重定向；授权器还会独立拒绝 HTTP、相似主机、CDN、loopback、错误 path/method、userinfo、fragment 和调用方预置 Cookie。

第 4 步实现期间，未签名 SwiftPM 测试进程直接执行 Data Protection Keychain SecItem 往返时返回 unavailable；该安全错误同时覆盖系统的 missing-entitlement 与 not-available 状态，因此本记录不进一步猜测具体 OSStatus。自动测试通过注入的窄 SecItem 后端验证完整查询和状态映射；随后签名 App smoke 已使用隔离的测试 service/account 完成真实 Security.framework add/update/read/delete 与无残留确认，证据见 [`../validation/M3-keychain-authorization-2026-07-21.md`](../validation/M3-keychain-authorization-2026-07-21.md)。

## Application/Feature 与登出实现落点

M3 第 5 步已经按本决策接入真实 App：

- `BiliApplication` 只公开非秘密认证状态与 `AuthenticationServicing` 用户意图 port；Cookie、QR key、完整 QR URL、Keychain 类型和 endpoint DTO 均未越过 adapter 边界。
- `BiliAuthenticationService` actor 将现有 Web QR session 与请求授权器编排为恢复、请求二维码、单次轮询、最终提交、取消和登出；认证状态走 Application port，二维码图像走 Auth Feature 定义的窄 Presentation port，两者由 composition root 注入同一个具体 Auth adapter。`CGImage` 不进入 Application。
- `BiliAuthFeature` 只依赖 Application；`@MainActor` ViewModel 拥有两秒轮询 Task 与界面代次，旧任务、取消或新登录意图不能覆盖当前状态。
- App composition root 创建唯一认证服务并注入账号 sheet，不让游客 Feature、播放器或 App shell 持有认证材料。
- 登出依次取消认证任务、清除二维码、删除 Keychain item、失效 Web QR 与授权 session、重建空 session，最后发布未登录。若 Keychain 删除失败，则保持安全错误且后续取消也不能伪装成已退出。

自动化与当前 macOS 的未登录/二维码/取消 UI smoke 证据见 [`../validation/M3-auth-feature-2026-07-21.md`](../validation/M3-auth-feature-2026-07-21.md)。观看历史 endpoint 已按同一授权边界接入；真实扫码、重启恢复、个性化读取与界面登出证据见 [`../validation/M3-watch-history-2026-07-21.md`](../validation/M3-watch-history-2026-07-21.md)。

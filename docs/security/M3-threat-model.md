# M3 Web QR 登录威胁模型

> 状态：M3 实现前安全基线
>
> 日期：2026-07-21（Asia/Tokyo）
>
> 范围：Web QR 获取与轮询、登录结果确认、Keychain 持久化、已登录请求授权和本地登出。

本文先定义需要保护的资产、信任边界和失败方式，再允许实现认证。它不是对 Bilibili 未公开 Web 接口稳定性的承诺；当前现场观察见 [`../validation/M3-auth-contract-research-2026-07-21.md`](../validation/M3-auth-contract-research-2026-07-21.md)，架构决策见 [`../adr/0005-web-qr-authentication-boundary.md`](../adr/0005-web-qr-authentication-boundary.md)。

## 1. 保护目标

### 1.1 秘密与敏感数据

| 资产 | 风险 | 处理规则 |
| --- | --- | --- |
| `qrcode_key` 与完整二维码 URL | 在有效期内可能代表一次待确认登录会话 | 只存在于认证 adapter 的内存；不进日志、剪贴板、持久化、崩溃附件或 fixture |
| Web Cookie 值 | 可代表用户会话，并可能包含 CSRF 与网络身份信息 | 只存在于 Keychain 和短生命周期内存快照；绝不进入 UI、Domain、UserDefaults、SwiftData 或测试输出 |
| `refresh_token` | 可能延长或更新会话 | M3 首版不采集、不存储、不使用；以后实现刷新前必须补充协议证据并修订 ADR |
| 登录身份与登录状态 | 可关联真实账号和使用行为 | Presentation 只消费显示所需的非秘密身份；诊断不得输出 UID、昵称与请求历史的组合 |
| Keychain item 元数据 | 可暴露使用过本 App 登录的事实 | 使用固定、不含账号标识的 service/account；不把 UID 写进 item 名称 |

Bilibili 隐私政策将 Cookie 用于识别注册用户、登录简化、历史和个性化，并说明只在必要期间保留个人信息。BiliKit 因此把会话 Cookie 视为高敏感认证材料，而不是普通偏好设置：<https://www.bilibili.com/blackboard/privacy-policy.html>。

### 1.2 安全目标

1. 未经用户在 Bilibili 客户端确认，App 不能进入已登录状态。
2. 认证材料只能发往经过代码白名单确认的 HTTPS 主机和明确声明需要登录的 endpoint。
3. 一次旧二维码、已取消轮询或旧任务的结果不能覆盖更新的登录意图。
4. 只有在登录结果结构有效、凭据通过登录态 endpoint 校验后，才允许原子写入 Keychain。
5. 登出必须在离线情况下也能清除本地会话；服务端登出不能成为本地清理的前置条件。
6. 任何认证失败不得破坏游客热门、搜索、详情和播放链路。

## 2. 信任边界

```text
用户的 Bilibili 移动端
        │ 扫码并确认
        ▼
passport.bilibili.com ── 未公开 Web QR 协议 ── BiliAuth 内存状态机
        │                                      │
        │ 登录结果                             ├── Keychain（唯一持久秘密存储）
        ▼                                      │
api.bilibili.com ◀── endpoint 级授权器 ───────┘
        │
        └── 非秘密身份/结果 ── BiliApplication ── BiliAuthFeature
```

- 二维码请求只允许连接 `https://passport.bilibili.com`。
- 生成结果中待显示的二维码 URL 当前观察为 `https://account.bilibili.com/...`；实现采用精确 scheme/host 校验，变化时失败关闭并重新审计。
- Cookie 只允许注入 `https://api.bilibili.com` 上经过显式标记的登录 endpoint。不能使用 `*.bilibili.com` 通配，也不能发往图片、视频 CDN、loopback playback bridge 或重定向后的其他主机。
- QR 返回 URL 只作为待编码的数据和成功结果的待解析输入；App 不在 WebView/浏览器中自动导航，也不跟随其中的目标。

## 3. 威胁与控制

| 威胁/失败方式 | 可能后果 | 必须落实的控制与测试 |
| --- | --- | --- |
| 日志、错误描述或测试失败打印 QR key/Cookie | 会话被复制或长期留存 | 扩充 `HTTPLogRedactor`；认证错误只含阶段与分类；秘密使用不可 `CustomStringConvertible` 的内部类型；加入负向秘密扫描测试 |
| 二维码 URL 被复制到剪贴板或落盘缓存 | 待登录会话泄露 | 只在内存生成二维码图像；不提供复制操作；不使用磁盘 URL cache；页面销毁即清空图像与 key |
| 恶意或漂移响应把 Cookie 送往其他主机 | 账号会话外泄 | HTTPS + 精确 host 白名单；禁用跨主机自动重定向；授权器再次独立检查请求主机 |
| 用后缀匹配 `*.bilibili.com` | 相似或受影响子域得到 Cookie | 使用 endpoint 级精确集合，不使用字符串后缀、包含匹配或调用方自报可信 |
| 未完成确认就持久化部分结果 | 重启后出现伪登录或损坏会话 | 状态机只有 `finalizing` 可验证；登录态校验成功后一次写入完整版本化 envelope |
| 旧轮询结果覆盖新二维码 | 用户确认 A，App 保存 B 或反之 | ViewModel 拥有 Task；actor 内使用不可复用 generation ID；取消后结果不可提交 |
| 未知状态码被当作成功 | 保存无效或攻击者构造的数据 | 只接受 fixture 固定且经过现场验证的状态；所有未知值映射为安全失败，不猜测语义 |
| Cookie 自动存入共享 `HTTPCookieStorage` | 跨请求、跨模块或磁盘持久化边界失控 | 认证使用 `.ephemeral` session；不使用 `.shared`；关闭自动 Cookie 处理并按需构造授权头 |
| Cookie 被附加到媒体/图片请求 | CDN 或第三方获得账号材料 | 播放和图片链路永不持有授权器；`BiliAPI` 只有明确的 authenticated endpoint 才请求授权 |
| Keychain item 随设备迁移或同步 | 会话超出原设备边界 | Data Protection Keychain、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、不设置 synchronizable |
| App 崩溃或被调试时读取内存 | 活跃会话被本机进程取得 | 缩短明文生命周期、actor 隔离、退出/登出清空；文档明确 Keychain 无法抵御已控制用户会话或进程调试 |
| 登出只更新 UI | Keychain 或内存仍可发起登录请求 | 先取消轮询/请求，再清内存、删除 Keychain item、失效 ephemeral session，最后发布 signed-out 状态；每步幂等 |
| 服务端登出失败导致本地无法退出 | 用户无法撤销本机访问 | 本地清理不依赖网络；若未来加入服务端登出，只作为尽力而为的前置请求 |
| 真实 Cookie 被录入 fixture、CI artifact 或 issue | 长期公开泄露 | fixture 只能手写假值；现场采集工具只输出字段名、类型、长度与状态，不输出值；CI 增加已知秘密键值模式扫描 |
| 未公开接口字段或风控策略漂移 | 登录循环、误判或意外 HTML | endpoint 独立 DTO、Content-Type/JSON envelope 校验、单次重试边界、现场探针与脱敏 contract fixture |

## 4. 持久化与请求授权基线

### 4.1 Keychain

- 使用一个 generic-password item 保存版本化二进制/JSON envelope；固定 service 与 account，不包含 UID。
- 在 macOS 上显式启用 Data Protection Keychain，再使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`；Apple 文档说明该可访问性只允许设备解锁时读取，且 item 不迁移到新设备：<https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly>。
- 不设置 `kSecAttrSynchronizable`。新增、更新、读取、删除分别封装并映射可测试错误；更新必须是单 item 原子替换。
- envelope 首版只保存现场成功响应确认过、且登录态校验实际需要的 Cookie 名称和值及 schema version。未知 Cookie 不“顺便”保存。
- 不把 Cookie 的过期时间、UID 等复制到 UserDefaults；需要判断时从 Keychain envelope 读取到短生命周期内存。

Apple 将 Keychain 定位为替 App 安全存储小块秘密数据的加密数据库，并建议不需要服务器等属性时使用 generic password：<https://developer.apple.com/documentation/security/keychain-services/>、<https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain>。

### 4.2 网络会话

- QR 与登录态校验使用独立的 `URLSessionConfiguration.ephemeral`，同时把 `httpShouldSetCookies` 设为 `false`、`httpCookieStorage` 设为 `nil`、URL cache 设为 `nil`。
- Apple 文档说明 ephemeral configuration 不把 cache、Cookie 或 credential 持久化到磁盘；session 失效后其内存数据被清除：<https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral>。
- 不复用当前 `URLSession.shared` 的默认 transport 处理认证。后续如需共享 HTTP 抽象，应注入专用 session/transport，而不是扩大共享全局状态。
- 授权器从 Keychain provider 获取不可公开的快照，只为精确允许的请求临时生成 `Cookie` header；调用结束后不缓存完整 header。

## 5. 状态机与提交规则

```text
signedOut
   └── requestQR → awaitingScan
                      ├── notScanned → awaitingScan
                      ├── scanned → awaitingConfirmation
                      ├── expired → expired ── retry → awaitingScan
                      ├── cancel → signedOut
                      └── success → finalizing
                                        ├── validate identity → persist → signedIn
                                        └── failure → clear transient data → signedOut/error
signedIn
   └── logout → cancel + local purge → signedOut
```

轮询必须有固定最小间隔、总超时与单实例 Task；网络错误可以退避重试，协议错误不得无限重试。当前只现场确认 `86101` 为“未扫码”；成功、已扫码未确认、过期及 Cookie 来源必须在脱敏人工扫码验证后写入 fixture，不能仅凭第三方实现直接定为契约。

## 6. M3 实现前 Gate

只有以下条件全部满足，才开始持久化真实凭据：

- 使用一次人工扫码，在本地探针中只记录状态码序列、字段名、Cookie 名称/属性和主机，不记录任何值。
- 确认成功凭据的权威来源、必需 Cookie allowlist、过期语义和登录态验证 endpoint。
- 用全假值手写成功、过期和已扫码 fixture，并证明任何未知状态安全失败。
- Keychain 测试使用独立 service/account，并在 teardown 删除；测试失败消息不含 secret。
- secret scan 覆盖源码、fixture、测试输出和构建日志中的 QR/Cookie/refresh-token 模式。
- 游客模式在 Keychain 缺失、损坏、访问失败和远端凭据失效时均保持可用。

## 7. 剩余风险

- Web QR 是面向网页的未公开接口，服务端可以在无版本通知的情况下改变字段、状态或风控要求。
- Keychain 保护静态存储，但不能抵御已经控制当前 macOS 用户会话、能调试 App 进程或能读取屏幕的攻击者。
- 第三方客户端本身不等同于 Bilibili 官方授权客户端；发布前仍需补齐面向用户的隐私说明、非官方声明与账号风险提示。

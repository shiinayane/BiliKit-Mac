# 01 API、WBI、认证与安全策略

状态：第一轮取证完成，等待交叉复核。<br>
审计日期：2026-07-27（Asia/Tokyo）。<br>
现场边界：本轮未发起真实账号请求、未读取 Keychain、未生成二维码，也未保存远端响应。

## Reference 快照

以下 remote HEAD 已于 2026-07-27 用 `git ls-remote <remote> HEAD` 只读核对；checkout
均 clean。代码位置用于行为对照，不复制实现：

| 项目 | remote HEAD／commit date | license | 本文件使用范围 |
| --- | --- | --- | --- |
| ATV-Bilibili-demo | `86ba6f5bb9d6860cb47522a037ef02ab43a4ad55`／2026-07-05 | GPL-2.0 | player WBI endpoint、字幕错配修复历史 |
| PiliPlus | `f1b79eeafc586b4dab5b4c067f3936b90fef133c`／2026-07-24 | GPL-3.0 | endpoint 常量、WBI signer |
| wiliwili | `88e5876bea9502d06f46a8656e3530684d3aaf7d`／2026-04-25 | GPL-3.0 | endpoint、WBI、QR、历史、Cookie／refresh token |
| cilicili | `6f02857c6cac849df3c9f6eecefe483c1b720230`／2026-07-26 | GPL-3.0 | 搜索、历史、QR、Cookie 当前实现 |

`cilicili` checkout 的历史从当前 snapshot 开始，不能用其 `git blame` 证明实现早于
2026-07-26。其价值是当前独立实现对照，不是长期提交历史。

## Endpoint 全量枚举

生产 `BiliAPIClient` 当前只使用 `GET https://api.bilibili.com`：

| 能力 | path | query | Cookie／WBI | 代码 |
| --- | --- | --- | --- | --- |
| 热门 | `/x/web-interface/popular` | `pn, ps` | 无／无 | `BiliAPIClient.swift:58-75` |
| 搜索 | `/x/web-interface/wbi/search/type` | `keyword, page, search_type, wts, w_rid` | 无／有 | `BiliAPIClient.swift:77-100,421-437` |
| 详情 | `/x/web-interface/view` | `bvid` | 无／无 | `BiliAPIClient.swift:102-116` |
| 分 P | `/x/player/pagelist` | `bvid` | 无／无 | `BiliAPIClient.swift:118-128` |
| 播放地址 | `/x/player/playurl` | `bvid, cid, qn, fnval=16, fnver=0, fourk=0` | 无／无 | `BiliAPIClient.swift:130-170` |
| WBI key | `/x/web-interface/nav` | 无 | 无／无 | `BiliAPIClient.swift:462-493` |
| 字幕目录 | `/x/player/wbi/v2` | `bvid, cid, wts, w_rid` | 五项登录 Cookie／有 | `BiliAPIClient.swift:173-198,439-460` |
| 弹幕分段 | `/x/v2/dm/web/seg.so` | `type=1, oid, segment_index` | 无／无 | `BiliAPIClient.swift:200-253` |
| 观看历史 | `/x/web-interface/history/cursor` | `max, view_at, business, ps` | 五项登录 Cookie／无 | `BiliAPIClient.swift:255-280` |

Web QR 另使用 `GET https://passport.bilibili.com`：

- `/x/passport-login/web/qrcode/generate`，无 query；
- `/x/passport-login/web/qrcode/poll`，仅 `qrcode_key`；
- 成功候选用 Cookie 请求 `GET https://api.bilibili.com/x/web-interface/nav` 验证。

对应代码为
`Packages/BiliKitCore/Sources/BiliAuth/WebQR/WebQRLoginSession.swift:4-22,60-195,240-353`。
JSON 请求固定 `Accept` 与 `User-Agent`；API 和 nav 验证另带对应 `Referer`，QR
generate／poll 不带 `Referer`。认证／API production transport 使用 ephemeral
configuration、关闭 Cookie jar/cache、设置 15/30 秒 timeout 并拒绝 redirect
（`WebQRLoginSession.swift:240-353,505-516`、
`BiliCredentialRequestAuthorizer.swift:269-280`）。

---

## M501-API-001：WBI signer 与字幕目录迁移有多源支持

**finding_id**<br>
`M501-API-001`

**审计线与涉及能力**<br>
API、WBI、字幕目录 endpoint、签名 key 缓存和一次刷新重试。

**当前实现（文件、符号、调用链）**<br>
`BiliAPIClient.subtitleResources → signedSubtitleResources → wbiKey → WBISigner.sign →`
`GET /x/player/wbi/v2`：

- `Packages/BiliKitCore/Sources/BiliAPI/Client/BiliAPIClient.swift:173-198,439-493`
- `Packages/BiliKitCore/Sources/BiliAPI/Remote/WBISigner.swift:4-74`

签名按 key 排序，过滤 `!'()*`，RFC 3986 unreserved 百分号编码，加入秒级 `wts`，再对
canonical query 与 32 字符 mixin key 计算 MD5。key 按 UTC 日缓存；API／HTTP `403`
会清 key、重取、重签且只重试一次。

**它声称提供的职责**<br>
使搜索和字幕目录符合当前 WBI 请求形状，并避免旧 `/x/player/v2` 的随机字幕目录问题；
缓存减少重复 nav 请求，单次刷新处理 key 漂移。

**外部事实来源**

- Bilibili 没有公开 WBI 契约。`bilibili-API-collect` 的当前远端已永久关闭并删除文档，
  原 `main` 链接不可复核，因此本项不再把它计作“当前社区事实”；签名结构只由下列多个
  独立当前 OSS 与一次现场样本交叉支持。

**OSS 对照及 commit/date**

- wiliwili `1e49a60fc1e59605040accea50c8c527d9b79e69`
  （2024-11-05，`Temporary fix for subtitle`）将字幕信息改到 WBI path；当前 HEAD
  `wiliwili/include/api/bilibili/api.h:32` 仍为 `/x/player/wbi/v2`，并在
  `wiliwili/source/api/video_detail_api.cpp:29-48` 对 `aid|bvid + cid` 使用
  `getResultWithWbiAsync`。2025-08-06 的
  `24fa88eed356ab9b1f2fc9b4d71b3beb974b0f11` 再次明确使用 WBI helper。
- ATV-Bilibili-demo
  `559a972f4f4e1caff1d2e543b3c7d9b4e6d55537`
  （2024-12-01）记录“疑似被风控导致返回随机字幕”，随后
  `f4a851df4e38df399fae50c3fde0b36486a4e4c3`
  （2024-12-01）把 player info 改为 WBI；当前 HEAD
  `BilibiliLive/Request/WebRequest.swift:42` 仍使用 `/x/player/wbi/v2`。
- PiliPlus 当前 HEAD `lib/http/api.dart:32` 也将 `playInfo` 指向
  `/x/player/wbi/v2`，`lib/utils/wbi_sign.dart:19-75` 使用相同签名结构。

**真实行为证据**<br>
旧路径在同一 BVID/CID 上曾返回不同目录；2026-07-26 新路径的签名 App 生产探针一次取得
2 轨并到达 `decoder=ready`。见
`docs/validation/M4.6-subtitle-lifecycle-roadmap-2026-07-25.md:19-43`。它证明当前样本
可用；用户随后也确认该样本恢复正常，但没有留下连续复测记录。它不证明 endpoint 长期
稳定或所有视频都需登录。证据强度：单次记录加一次用户观察。

**本地测试实际证明的范围**<br>
`BiliSubtitleRepositoryTests` 与 `BiliAPIClientTests` 证明项目构造预期签名形状、只在
403 时刷新一次、目录请求经 authorizer、正文不携带 Cookie；fixture 不能证明远端 key
轮换周期、403 的唯一成因或 endpoint 稳定性。

**判断：保留 / 替换 / 删除 / 尚不能判断**<br>
**保留** WBI signer 和 `/x/player/wbi/v2`。bounded 403 refresh 当前是有界且可恢复的
workaround，可暂时继续存在，但没有真实 403/key 漂移记录证明它必要；UTC 日缓存时长也
**尚不能判断**。当前 OSS 使用不同 TTL，说明没有可采信的稳定契约，不能仅凭实现惯例
裁决 BiliKit 的 TTL。

**风险：影响、触发条件、可恢复性**<br>
影响高（字幕正确性、搜索可用性）；key 在同一 UTC 日内轮换或 403 不是 key 失效时会多发
一次请求，但第二次失败即停止，可恢复。

**下一步最小验证**<br>
无需真实账号：连续两日各运行一次脱敏 nav + WBI search probe，只记录 key 指纹是否变化、
状态和是否触发 refresh；不保存 key、query 或 body。若同日出现 key 变化，再裁决缓存 TTL。

**与其他 finding 的依赖或冲突**<br>
依赖 `M501-API-002` 的匿名搜索 Cookie 结论；字幕正文来源属于媒体审计线。

---

## M501-API-002：匿名搜索缺少设备 Cookie，现有成功证据不足以证明稳定

**finding_id**<br>
`M501-API-002`

**审计线与涉及能力**<br>
游客搜索、WBI、Cookie 边界、反风控请求事实。

**当前实现（文件、符号、调用链）**<br>
`BiliAPIClient.searchVideos` 获取匿名 nav key 后直接请求 WBI search，未调用 credential
authorizer，也没有匿名 Cookie jar：
`Packages/BiliKitCore/Sources/BiliAPI/Client/BiliAPIClient.swift:77-100,366-418,421-437`。
`guestEndpointsNeverRequestCredentialAuthorization`
只直接覆盖热门，但 API client 的 search 调用同一无认证 `get` 路径。

**它声称提供的职责**<br>
登录完全失败时仍提供游客搜索，同时保证登录 Cookie 不进入游客链路。

**外部事实来源**

- `bilibili-API-collect` 原搜索文档的当前链接已随仓库永久关闭而失效，因此本轮不能把
  `buvid3` 必需或具体 `-412` code 当作已确认当前事实。
- `URLSessionConfiguration.ephemeral` 官方文档说明它只保证不把 Cookie、cache、credential
  持久化到磁盘，仍可在 RAM 中保存 session data；BiliKit 进一步显式禁用 Cookie storage，
  因而不会自然获得站点发放的匿名设备 Cookie。访问日期 2026-07-27。事实类型：Apple
  规范；证据强度：已确认。

**OSS 对照及 commit/date**

- cilicili 当前 HEAD `bili/Sources/Services/BiliAPIClient.swift:4902-4924` 使用同一 WBI
  search；调用继续经过 `get:5846-5868 → makeRequest:6032-6059`，未显式传 Cookie 时
  使用 `cookieHeader()`，登出 snapshot 至少包含生成的 `buvid3`
  （`SessionStore.swift:158-165,601-605`）。
- wiliwili 当前 HEAD 的 search endpoint 为
  `wiliwili/include/api/bilibili/api.h:205`，2026-01-03
  `a26dabdc2071aeaccea55e59274a966fcfbe9fdb`
  将 Search Tab 切换到 WBI；其 HTTP 层维护全局 Cookie。它不能证明“没有设备 Cookie”
  也稳定。
- 两个活跃实现均支持 WBI search，但没有找到明确、长期无任何 Cookie 的独立对照。它们
  只能说明匿名设备 Cookie 是常见策略，不能证明 BiliKit 当前请求必然失败。

**真实行为证据**<br>
2026-07-21 匿名 probe 一次成功，HTTP 200，19 条可用结果；App UI 也完成一次真实搜索。
见 `docs/validation/M2-guest-api-2026-07-21.md:13-38,53-66`。这直接反驳“每次请求绝对
必须有 buvid3”，但不能证明跨 IP／时段／风控状态稳定。证据强度：单次观察。

**本地测试实际证明的范围**<br>
`BiliAPIClientTests.swift:68-203` 证明 WBI 构造、fixture 解码和 403 后重签，不覆盖
`-412`、匿名设备 Cookie 或服务端风险控制。

**判断：保留 / 替换 / 删除 / 尚不能判断**<br>
**尚不能判断**。不能直接把登录 Cookie 加进游客请求，也不能依据一次成功继续声明该
endpoint 稳定匿名可用。若需要匿名设备身份，它必须是与账号 Cookie 分离、生命周期和隐私
已定义的机制，不得放宽现有 credential authorizer。

**风险：影响、触发条件、可恢复性**<br>
中等影响：特定网络／风控条件下搜索可能 `-412`；当前只对 `-403/403` 重取 WBI key，
因此用户重试也可能持续失败。失败不泄露登录凭据，重启可恢复性未知。

**下一步最小验证**<br>
预先定义两次无账号、无 Keychain 的 probe：A 为当前“无 Cookie”请求；B 只允许服务端先
发放并在 ephemeral RAM 中保留匿名 Cookie，输出仅 Cookie 名称集合、业务 code 和计数。
任一请求出现验证码／风险控制即停止，不生成或伪造 `buvid3`。

**与其他 finding 的依赖或冲突**<br>
与“游客 API 不携带认证授权器”的安全原则不冲突；若 B 需要匿名 Cookie，应由状态／缓存和
隐私审计共同定义 owner，而不是复用 WebCredential。

---

## M501-API-003：Web QR 核心 path 和状态有支持，额外设备字段必要性未知

**finding_id**<br>
`M501-API-003`

**审计线与涉及能力**<br>
Web QR 生成、轮询、状态映射、query/header 与成功凭据来源。

**当前实现（文件、符号、调用链）**<br>
`WebQRLoginSession.requestQRCode/pollOnce` 使用 generate 无 query、poll 仅
`qrcode_key`；只接受 `0/86101/86090/86038`，未知状态失败关闭。二维码 payload 只接受
HTTPS 精确 `account.bilibili.com`：
`Packages/BiliKitCore/Sources/BiliAuth/WebQR/WebQRLoginSession.swift:22-195,390-400`。

**它声称提供的职责**<br>
以未公开 Web QR 协议建立一次短生命周期登录挑战，拒绝旧轮询结果、未知状态和不可信
二维码来源。

**外部事实来源**<br>
没有 Bilibili 官方公开 Web QR 契约；最高级事实只能来自脱敏真实响应。2026-07-21 研究
记录确认 endpoint、字段形状与 `86101`；同日人工扫码确认四个状态、响应 Set-Cookie 和
nav `isLogin=true`。见
`docs/validation/M3-auth-contract-research-2026-07-21.md:8-61,89-101`。事实类型：
当前行为；证据强度：单次观察。

**OSS 对照及 commit/date**

- wiliwili 当前 HEAD
  `wiliwili/include/api/bilibili/api.h:173-174` 使用相同 generate/poll path；
  `wiliwili/source/api/mine_api.cpp:31-36,70-107` 在二者都加
  `source=main_electron_pc`，poll 还带 PC/device 匿名 Cookie。相关新 QR 迁移 commit
  `99174aae11c85620f755929413cea20bc84d159d`
  （2023-03-19）说明旧接口造成账号异常，并已加入 device 字段；2026-01-18 的后续提交
  调整了 buvid 生成和手写 Cookie header，不是首次加入设备身份。
- cilicili 当前 HEAD
  `bili/Sources/Services/BiliAPIClient.swift:5025-5035,5189-5208`
  在 query 层与 BiliKit 相同：generate 无 query、poll 仅 qrcode_key；但它还带 passport
  Referer、Web UA，并经默认请求路径携带匿名 Cookie。
- 两个仍活跃实现都使用更宽的匿名设备 Cookie；主要分歧是 `source` 与设备字段集合，而
  不是“是否使用设备 Cookie”。

**真实行为证据**<br>
BiliKit 当前无 `source`／设备 Cookie 的流程于 2026-07-21 完成一次真实扫码、重启恢复、
历史读取和登出；这证明当时可用，不证明服务端长期允许缺省字段。

**本地测试实际证明的范围**<br>
`WebQRLoginSessionTests.swift:1-490` 固定 URL、query、四种状态、恶意 host、取消和
成功 Cookie fixture；它不能证明字段仍是服务端当前契约。

**判断：保留 / 替换 / 删除 / 尚不能判断**<br>
**保留** 精确 host/path、未知状态失败关闭和当前最小 query；是否增加 `source` 或设备
Cookie **尚不能判断**。BiliKit 的最小请求曾成功一次，而两个活跃 OSS 都采用更宽请求；
现有证据不足以证明额外字段必要，不应凭实现惯例扩大身份面。

**风险：影响、触发条件、可恢复性**<br>
协议漂移会使登录无法开始或轮询被风控；失败关闭，不会把账号 Cookie 发往新 host。用户可
取消并重试，但服务端策略变化时无法自行恢复。

**下一步最小验证**<br>
仅当登录出现可重复失败时做一次人工扫码：先运行当前请求；只记录 path、query 名、
业务 code、响应字段名和 Cookie 名称。若当前失败，再在用户批准下对照只增加
`source=main_electron_pc` 的单变量请求；不伪造设备 ID，不连续重试。

**与其他 finding 的依赖或冲突**<br>
依赖 `M501-API-004` 对成功凭据和 refresh token 的裁决；生命周期细节由并发审计复核。

---

## M501-API-004：五项 Cookie 曾建立当前会话，refresh 能力仍属未决产品边界

**finding_id**<br>
`M501-API-004`

**审计线与涉及能力**<br>
Cookie allowlist、Keychain envelope、过期、恢复、refresh 和登出。

**当前实现（文件、符号、调用链）**<br>
成功响应只接受 `DedeUserID`、`DedeUserID__ckMd5`、`SESSDATA`、`bili_jct`、`sid`，
且必须五项齐全、`.bilibili.com`、`Path=/`、Secure、有 expiry：

- `Packages/BiliKitCore/Sources/BiliAuth/WebQR/WebQRLoginSession.swift:466-503`
- `Packages/BiliKitCore/Sources/BiliAuth/Credential/WebCredential.swift:3-70`

任一项过期即删除完整 credential：
`BiliCredentialRequestAuthorizer.swift:63-81`。JSON `refresh_token` 被识别为“存在／
不存在”用于脱敏观察，但不存值、不持久化、不刷新：
`WebQRLoginSession.swift:420-463,553-560`。

**它声称提供的职责**<br>
只保存一次现场确认过的最小认证集合，避免未知 Cookie 与 refresh token 扩大秘密面；
过期／远端失效时安全退回游客状态。

**外部事实来源**

- RFC 6265 第 4.1.2/5.3 节确认 Domain、Path、Secure、HttpOnly、expiry 是 Cookie
  独立属性，Secure 限制 Cookie 只经安全通道发送；访问日期 2026-07-27。事实类型：
  标准；证据强度：已确认。
- `bilibili-API-collect` 原登录与 Cookie 刷新文档的当前链接已经失效，不能作为当前协议
  事实。它们只保留为历史线索：已知社区流程曾使用登录响应中的旧 `refresh_token` 并在
  刷新后确认旧 token，正式采用前必须由当前现场行为或可达历史快照重新取证。
- Apple Keychain 官方文档确认 Keychain 适合存储小块秘密；
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 在设备解锁时可读且不迁移到新设备。
  BiliKit 的具体 SecItem 属性由工程分发审计另行复核。

**OSS 对照及 commit/date**

- wiliwili 新 QR commit
  `99174aae11c85620f755929413cea20bc84d159d`
  （2023-03-19）从成功响应保存全部 response Cookie，并把 `data.refresh_token` 交给
  persistence callback；commit message 同时写明“cookie 有效期半年没有接入自动刷新，
  不过储存下刷新 token”。当前 HEAD
  `wiliwili/source/api/mine_api.cpp:93-107` 仍保留该行为。
- cilicili 当前 HEAD
  `bili/Sources/Services/SessionStore.swift:444-480,764-790` 至少要求
  `SESSDATA + DedeUserID`，允许保存更宽的已知 Cookie 集合；其 Web QR current path
  从 response 解析 Cookie，但未见 Web refresh token 持久化。
- 两个实现都不以“精确五项齐全”作为唯一登录判据；这证明 BiliKit 策略更严格，不证明
  它错误。

**真实行为证据**<br>
2026-07-21 单次成功响应恰好确认五项均有相同 domain/path/Secure/expiry，
`SESSDATA` 额外 HttpOnly；五项通过 nav 校验并完成重启恢复。该证据不能证明以后永远五项
齐全，也不能证明最早 Cookie expiry 等于服务端 session 的真实失效时刻。精确属性记录见
`docs/adr/0005-web-qr-authentication-boundary.md:91-92`。

**本地测试实际证明的范围**<br>
`WebCredentialTests` 证明 schema、结构拒绝和脱敏；authorizer tests 证明本地 expiry/
损坏时 purge、nav `isLogin=false` 时 purge、临时网络错误时保留。fixture 不证明当前
Set-Cookie 集合或 refresh 必要性。

**判断：保留 / 替换 / 删除 / 尚不能判断**<br>
**保留** 当前五项、Keychain 和失败关闭，作为已验证的 M3 最小切片。长期登录是否应
**替换**为“保存 refresh token 并实现完整 refresh/confirm 流程”目前
**尚不能判断**：这会扩大秘密、endpoint、POST/CSRF 和服务端写操作范围，需要产品需求与
新的威胁模型，不能在审计中顺手加入。

**风险：影响、触发条件、可恢复性**<br>
中等产品风险、低泄露风险：Cookie 到期后用户必须重新扫码；若单个非关键 Cookie 的 expiry
先到，BiliKit 会提前清除整个会话。可通过重新登录恢复；实现 refresh 错误则可能反而损坏
会话，故当前失败关闭更安全。

**下一步最小验证**<br>
不读取值：下次用户正常重新登录时，只比较五项 Cookie 的名称、属性和 expiry 相对顺序，
并记录 refresh token 字段是否存在；随后由用户裁决“允许到期后重新扫码”是否为产品接受
的行为。只有要求无感续期时才另建 refresh 威胁模型。

**与其他 finding 的依赖或冲突**<br>
依赖隐私／日志审计确认 Keychain 查询和错误附件不泄密；与当前 ADR 明确“不保存
refresh_token”一致，不是未授权缺陷修复。

---

## M501-API-005：endpoint 级 Cookie allowlist 与 redirect 拒绝应保留

**finding_id**<br>
`M501-API-005`

**审计线与涉及能力**<br>
认证请求 host/path/method/query allowlist、预置 Cookie、redirect、session 隔离。

**当前实现（文件、符号、调用链）**<br>
`BiliCredentialRequestAuthorizer.isAllowed` 只允许 HTTPS `api.bilibili.com:443`、
GET、无 userinfo/password/fragment：

- nav：无 query；
- history：精确 `max,view_at,business,ps`，拒绝重复／额外项并校验范围；
- subtitle catalog：精确 `bvid,cid,wts,w_rid`，拒绝旧 `/x/player/v2`。

见
`Packages/BiliKitCore/Sources/BiliAuth/Credential/BiliCredentialRequestAuthorizer.swift:51-91,150-240`。
调用方预置任何大小写的 Cookie 会被拒绝。App production composition 和 BiliAuth
自建的认证 session 使用
`RejectHTTPRedirectDelegate`，delegate 对 redirect completion 传 `nil`：
`App/Composition/AppEnvironment.swift:104-122`、
`Packages/BiliKitCore/Sources/BiliNetworking/Transport/HTTPClient.swift:75-152`。
公开 `BiliAPIClient` initializer 的默认 transport 并不自动提供同一边界。

**它声称提供的职责**<br>
即使 API 层构造错误或远端发起 redirect，Cookie 也只会进入已明确审计的 Bilibili API
请求，不进入 CDN、相似 host、loopback 或新增 endpoint。

**外部事实来源**

- Apple
  [`URLSessionTaskDelegate willPerformHTTPRedirection`](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))
  明确 completion handler 传 `nil` 可拒绝 redirect 并返回 redirect response body；
  该 delegate 回调适用于 default/ephemeral session。访问日期 2026-07-27。事实类型：
  Apple 规范；证据强度：已确认。
- Apple
  [`URLSessionConfiguration.ephemeral`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)
  明确不把 cache、Cookie、credential 写入磁盘，invalidate 后清除 session data。访问日期
  2026-07-27。事实类型：Apple 规范；证据强度：已确认。
- RFC 6265 允许 `.bilibili.com` Domain Cookie 发送到匹配子域；因此不能依赖 Cookie
  自带 domain 防止它被手工 header 发往错误的 Bilibili 子域，应用层精确 allowlist 有
  独立安全职责。证据强度：已确认。

**OSS 对照及 commit/date**

- wiliwili 当前 HEAD 的全局 Cookie 模型会供大量 API 共用，且新 QR 流程主动增加设备
  Cookie；cilicili 当前 HEAD 也维护更宽的 per-account Cookie header。它们能印证各
  endpoint 的确需要 Cookie，但没有提供与 BiliKit 等价的 endpoint 级最小授权边界。
- 这不是“多数 OSS 都这么做”的结论；BiliKit 的窄 allowlist 主要由标准安全语义和自身
  threat model 支持。

**真实行为证据**<br>
2026-07-21 已用当前 allowlist 完成 nav、history 和登出；2026-07-26 增加 WBI subtitle
后一次签名 probe 成功。没有观察到合法请求必须 redirect。证据强度：单次观察／少量路径
复测。

**本地测试实际证明的范围**<br>
`BiliCredentialRequestAuthorizerTests.swift:7-188` 证明精确允许、相似 host、HTTP、
CDN、loopback、错误 method/path/query、重复项、旧 subtitle path、userinfo、fragment
和预置 Cookie 均失败关闭；`HTTPClientTests.swift:55-81` 证明 delegate 拒绝测试构造的
redirect（直接调用 delegate，不是实际网络 redirect 集成测试）。测试不能证明未来
endpoint/query 不漂移。

**判断：保留 / 替换 / 删除 / 尚不能判断**<br>
**保留**。它隔离的是 bearer Cookie 的真实安全边界，不是结构噪音。该判断明确适用于
`AppEnvironment.live()` 及 BiliAuth 自建 transport；新增 endpoint 必须逐项加入，不得
改成 `*.bilibili.com`、path prefix 或调用方自报“需要认证”。

**风险：影响、触发条件、可恢复性**<br>
安全影响高：误放宽可能泄露账号 Cookie；误锁死只会使新增／漂移请求失败，用户仍可使用
游客功能，属于可恢复的 fail-closed。

**下一步最小验证**<br>
交叉复核 production composition 中所有持有 authorizer 的对象，确认没有其它 transport
能从 Keychain 取 Cookie；对每个未来 authenticated endpoint 要求一条正向和 host/path/
method/query/redirect 负向测试。

**与其他 finding 的依赖或冲突**<br>
与 `M501-API-002` 的匿名设备 Cookie 不能混用；匿名 Cookie 即使需要，也不得进入
`WebCredential` 或该 authorizer。

---

## M501-API-006：游客 endpoint 当前可用，但“非 WBI 版本长期正确”证据不完整

**finding_id**<br>
`M501-API-006`

**审计线与涉及能力**<br>
热门、详情、分 P、playurl、历史的 endpoint/query/header 当前性。

**当前实现（文件、符号、调用链）**<br>
见本文件“Endpoint 全量枚举”和
`Packages/BiliKitCore/Sources/BiliAPI/Client/BiliAPIClient.swift:58-170,255-280`。
所有请求使用同一个 `api.bilibili.com` base、GET、JSON Accept、Bilibili Referer 和固定
浏览器样式 User-Agent；playurl 仍为 `/x/player/playurl`，未 WBI 签名。

**它声称提供的职责**<br>
以最小 Web endpoint 提供游客热门→详情→分 P→AVC/AAC playback，以及登录历史。

**外部事实来源**<br>
Bilibili 没有公开这些 Web endpoint 的稳定官方契约。社区文档与 OSS 只能多源印证当前
形状，不能升级为服务 SLA。证据强度：多源印证。

**OSS 对照及 commit/date**

- wiliwili 当前 HEAD
  `wiliwili/include/api/bilibili/api.h:29,42,52,126,177` 分别仍使用
  `/view`、非 WBI `/playurl`、`/pagelist`、`/popular`、`/history/cursor`；
  `wiliwili/source/api/mine_api.cpp:242-251` 的 history query 与 BiliKit 相同。
- ATV-Bilibili-demo 当前 HEAD
  `BilibiliLive/Request/WebRequest.swift:31,42-44` 使用 `/view`，但 playback 已用
  `/x/player/wbi/playurl`；迁移 commit 为
  `f4a851df4e38df399fae50c3fde0b36486a4e4c3`（2024-12-01）。
- cilicili 当前 HEAD
  `bili/Sources/Services/BiliAPIClient.swift:1812-1822` 使用相同 history path，但额外
  `type=archive` 且省略 `business`；它的 playback 同时支持
  `/x/player/playurl` 与 `/x/player/wbi/playurl`。
- 活跃实现对 playback 和 history query 存在分歧，不能仅凭“两个 OSS 使用”裁决唯一
  正确形状。

**真实行为证据**<br>
2026-07-21 一次匿名 probe 与真实 UI 已走通热门、搜索、详情、分 P 和 playback；同日
登录历史真实读取成功。见
`docs/validation/M2-guest-api-2026-07-21.md:13-66`、
`docs/validation/M3-watch-history-2026-07-21.md:44-64`。证据强度：单次观察。

**本地测试实际证明的范围**<br>
`BiliAPIClientTests.swift:8-67,205-345` 证明当前 fixture 解码、query/header 构造、
媒体来源拒绝和 history 授权；不证明 endpoint 当前服务行为。

**判断：保留 / 替换 / 删除 / 尚不能判断**<br>
热门、详情、分 P、历史当前 **保留**；非 WBI playurl 是否应替换为
`/x/player/wbi/playurl` **尚不能判断**，交给媒体审计结合清晰度、风控和真实 DASH
响应裁决。不能因字幕 endpoint 的结论类推所有 `/x/player/*` 都必须 WBI。

**风险：影响、触发条件、可恢复性**<br>
中到高：endpoint 风控漂移会中断搜索／播放／历史；当前没有 fallback endpoint，失败对
用户可见但不会泄密。贸然增加 fallback 可能掩盖错误响应或重复造成本次字幕问题。

**下一步最小验证**<br>
只在媒体审计预先定义的同一公开样本上，对旧/WBI playurl 各一次无账号脱敏请求；只比较
业务 code、字段名、representation 数量和 codec/quality ID，不保存 URL/body。history
只有出现实际失败时才用用户批准的签名 App 单请求核对 query 差异。

**与其他 finding 的依赖或冲突**<br>
playurl 结论依赖媒体审计；history query 若改变，必须同步复核
`M501-API-005` 的精确授权 allowlist。

---

## 第一轮裁决摘要

| finding | 当前裁决 | 证据强度 | 需要 Gate 3 吗 |
| --- | --- | --- | --- |
| M501-API-001 | 保留 WBI；403 retry 必要性与缓存 TTL 尚不能判断 | 多源印证＋单次真实观察 | 非阻塞；跨日无账号 probe |
| M501-API-002 | 尚不能判断匿名搜索 Cookie | 官方 session 语义＋冲突事实＋单次真实观察 | 是，仅无账号 A/B |
| M501-API-003 | 保留 QR 最小请求；source/device 尚不能判断 | 两 OSS 更宽实现＋一次完整真实流程 | 仅实际登录失败时 |
| M501-API-004 | 保留五项最小凭据；长期 refresh 尚不能判断 | 标准＋一次真实流程＋OSS 分歧 | 由产品续期需求触发 |
| M501-API-005 | 保留精确 allowlist／拒绝 redirect | Apple/RFC 已确认＋本地负向测试 | 否；需交叉复核 |
| M501-API-006 | 现有 endpoint 保留；WBI playurl 尚不能判断 | 多源印证＋单次真实观察 | 由媒体审计决定 |

本轮没有发现需要立刻放宽安全策略或紧急修改生产代码的证据。主要未决风险是“匿名搜索
无设备 Cookie 的稳定性”和“是否接受 Cookie 到期后重新扫码”；二者都不能由 fixture
关闭。

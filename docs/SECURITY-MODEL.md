# BiliKit 安全模型

本文列可执行、可测试的安全与隐私规则，每节先写它防什么。认证、远端来源、重定向、本地服务器、字幕、
弹幕、图片、缓存或更新相关改动必须先对照本文；模块边界与账户状态的界面行为见
[`ARCHITECTURE.md`](ARCHITECTURE.md)，单个类型的取值写在该类型的注释里。

## 威胁模型

保护的资产：

- **账号凭据**（`SESSDATA`、`bili_jct`、App 端 `access_token`）：拿到就能以用户身份读写账号；`access_token` 单独就够，
  不需要 CSRF。
- **观看与搜索隐私**：看了什么、搜了什么、属于哪个账号。
- **本机**：进程内的 loopback server，以及写到磁盘上的东西。
- **更新链**：最终安装到用户 Mac 上的代码。

防的对手：

- 网络路径上的第三方：重定向、非预期主机、协议降级。
- B 站接口返回的异常数据：任意 URL、超大或畸形正文、未知状态码，以及未公开接口的无通知漂移。
- 本机其他进程与浏览器里的网页：访问 loopback 端口、DNS rebinding。
- 我们自己的编程失误：把凭据带到不该带的路径、把内容写进日志或磁盘、把旧账户的结果写回新账户。

不防：已控制当前用户会话、可调试进程或可读屏幕的攻击者（见 §9）。

默认姿态：未知即失败关闭；失败时不降级为匿名、不跟随重定向、不换来源续传。

## 1. 秘密与凭据

防：凭据离开 `BiliAuth` 与 Keychain，或被持久化到其他地方。

| 资产 | 规则 |
| --- | --- |
| Web Cookie | 只接受 TV 端扫码轮询成功或续期成功正文 `cookie_info.cookies` 里的白名单 `DedeUserID`、`DedeUserID__ckMd5`、`SESSDATA`、`bili_jct`、`sid`，五个必须齐全、不重名，`DedeUserID` 必须等于正文 `token_info.mid`，`cookie_info.domains` 必须含 `.bilibili.com`；未知 Cookie 丢弃。正文只给名称、值、到期时间与 `http_only`，domain（`.bilibili.com`）、path（`/`）与 Secure（真）由 `BiliAuth` 填写，不是服务端声明：这些 Cookie 只经授权器发往 HTTPS 的精确主机 |
| `auth_code`、完整二维码 URL | 只在 `BiliAuth` 内存；URL 封装为不可读的 `TVQRCode`，只在内存生成图像，不复制、不导航、不落盘 |
| `access_token` | 只接受同一份成功正文 `token_info` 里的 `access_token`（扫码签发为 32 个十六进制字符，续期签发约 220 个；只接受 32–512 个字母、数字、`-` 与 `_`，不需要转义也不会改变 query 结构）与 `expires_in`（正数，到期时刻按收到响应时计算）；轮询正文顶层的副本不解码；与 Cookie 存进同一个 envelope，任一过期整份凭据按过期删除，不存在只有其一的状态；只由 App 授权器放进发往 `app.bilibili.com` 的请求 query 或表单正文（§3） |
| `refresh_token` | 只接受同一份 `token_info` 里的 `refresh_token`（32 个十六进制字符），与 access_token 同存同删；只由续期放进发往 `passport.bilibili.com` 的续期请求（§2），不进入任何业务请求；`sso` 等其他字段不解码 |
| 登录身份 | Presentation 只拿显示所需的非秘密投影；Keychain item 名称不含 UID |

- 持久秘密只存 Keychain：Security.framework generic-password、固定 service/account、
  `kSecUseDataProtectionKeychain`、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、非 synchronizable，
  保存一个版本化 envelope（版本 3：Cookie 加 `access_token` 与 `refresh_token`）；解码后重新校验名称、domain、path、Secure、
  值字符与大小以及 token 形状（domain、path、Secure 来自上表由 `BiliAuth` 填写的值，这里只防 envelope 被改写）。读到只有
  Cookie 的版本 1 或不含 refresh_token 的版本 2 按损坏凭据删除，用户重新登录一次；旧版 App 读到版本 3 同样会删除它。
- 凭据类型的 `description`／Mirror 不展示值。UserDefaults、文件、fixture、日志、截图、崩溃信息、
  App 恢复状态和验证记录都不得出现 Cookie、QR key、token 或完整认证 URL。
- Cookie、QR key、Keychain 类型、endpoint DTO 不越过 `BiliAuth`／`BiliAPI` 进入 Application 或 Feature。
- 不使用 `URLSession.shared`、共享 `HTTPCookieStorage`、`URLCredentialStorage` 或 WebView Cookie；
  不导入浏览器或手动粘贴的 Cookie（来源与范围无法校验）。

## 2. 登录状态机

防：未经验证的凭据被当成登录成功；登出或换号后旧账户的请求与结果继续生效。

- 登录用 TV 端扫码：取码（`/x/passport-tv-login/qrcode/auth_code`）与轮询（`.../qrcode/poll`）只连
  `https://passport.bilibili.com`，都是带 APP 签名（TV 的 appkey）的 urlencoded POST，不带 Cookie。`auth_code` 只接受 32 个
  十六进制字符；待显示 URL 只接受精确 `https://passport.bilibili.com/x/passport-tv-login/h5/qrcode/auth`，query 只能是
  这一次的 `auth_code`，防止二维码把手机带去别处确认。轮询状态在顶层 `code`：`86039` 未扫码、`86038` 过期、`0` 成功
  已经现场确认，`86090` 已扫码待确认按协议文档接受；其他值失败关闭，不回显服务端 message/payload。
- 成功后先在内存组 Cookie 请求 `/x/web-interface/nav`，`isLogin=true` 才在同一 actor generation 内
  写入 Keychain；旧 generation、取消、过期、校验或存储失败都清除临时秘密，不能返回登录成功。
- 轮询有最小间隔、总时限和次数上限；ViewModel 拥有 Task，actor 用 generation 与 poll ID 隔离旧结果。
- 续期（`AccountCredentialRenewal`，进程唯一、串行）：确认仍登录后，启动恢复与其他窗口换号后的复核只在凭据离到期（token
  与各 Cookie 里最早的到期时刻）不足 30 天时续期，本窗口之后的复核不论离到期多久都续期；两次续期请求至少相隔 10 分钟，不论
  起因与成败。请求是发往 `https://passport.bilibili.com/x/passport-login/oauth2/refresh_token` 的 APP 签名 POST，只带
  Keychain 里同一份凭据的 `access_key` 与 `refresh_token`。成功正文按上表同一规则校验成新凭据，账户必须与原凭据相同、
  不能已经过期，写回前再读一次 Keychain，仍是原来那一份才覆盖（防止把等待网络期间登出或换号的旧会话结果写回去；比较与
  写回之间仅一次 Keychain 调用的窗口不加锁）。续期失败（网络、业务码、正文不合规、Keychain）不删除凭据、不改变登录状态、
  不重试；续期一旦发出就做完，取消不打断，因为服务端可能已经轮换 token。
- 复核判定远端未登录时，只删除被校验的那一份凭据：校验期间凭据已被续期换掉就用新凭据再校验一次，不删刚续期的凭据。
- 恢复时重新校验：远端明确失效则清理（nav 的 `data.isLogin=false`，`code` 为 0 或 -101；其他非 0 码按
  校验不可用处理）；本地缺失／损坏／过期回退未登录；临时网络失败不删凭据。
- 登出顺序：取消认证任务 → 清二维码与内存 → 删除 Keychain item → 失效并重建 session → 发布未登录。
  本地登出不依赖网络；Keychain 删除失败时不得发布未登录。
- 账户变化（登出、换号、凭据失效）先全局推进所有窗口 API transport 的 authentication epoch；旧
  epoch 的请求与响应不得写回，并关闭依赖账户的播放器与报告 owner。登录成功不推进 epoch：登录方向由
  关闭依赖账户的播放器与各页面的 generation 隔离旧结果，新页面必须自己做到这一点。
- 认证失败不得影响游客热门、搜索、详情和播放。窗口已确认未登录（未登录状态、没有进行中或失败的复核、
  进程内没有窗口已发布登录）时，Keychain 不可用按“本地无凭据”处理；只有窗口主 API 的授权器读取该确认，
  认证服务自身的复核仍失败关闭。其余情况 Keychain 不可用一律失败关闭，不让已登录用户在不知情时降级为
  匿名；启动时 Keychain 就不可用会让复核失败，此时游客内容同样失败关闭，因为无法区分“从没登录”与
  “已登录但读不到凭据”。

## 3. 哪些请求可以带凭据

防：凭据被带到预期之外的主机、路径或方法；写请求被构造成预期之外的操作。

默认所有网络匿名，且不带任何 Cookie。搜索页的 B 站热搜（`/x/web-interface/search/square`）与
搜索框联想（`/x/web-interface/suggest`）无论是否登录都匿名读取。联想是唯一会发送未提交输入的请求：
只在搜索框获得焦点或编辑、系统索取联想时停顿后发出，新输入、提交、选中或失去焦点都取消在途请求；输入按
搜索规则规范化（≤ 100 字），结果只在内存中用于当次菜单。唯一的非凭据 Cookie 是 `buvid3`：搜索
`/x/web-interface/wbi/search/type` 要求 Cookie 含它（缺它会触发风控），`BiliAPI` 为此在进程内存中随机生成一个
`buvid3=<小写 UUID>infoc`，不持久化、不激活、不与账户关联；搜索请求在授权之后附加它（与授权器给出的 Cookie 并列），任何其他
请求（含 WBI nav 与写请求）都不携带。只有五个授权器，均由 Composition 注入
`BiliAPI`：账户读取、App 端读取、自动的观看进度写入，与用户发起的网页端和 App 端账户写入。

**账户读取**（`BiliCredentialRequestAuthorizer`）

- 只允许 `https://api.bilibili.com`、端口缺省或 443、GET、无 userinfo／fragment、路径编码规范，
  且 path 在 `LiveAPIClients`（Composition）声明的 allowlist 内（主客户端、测速客户端、会话校验各一组）。allowlist 只引用
  endpoint 导出的 path 常量：BiliAPI 的 `BiliAccountReadPath`，会话校验为 BiliAuth 的
  `BiliAuthenticationService.sessionValidationPath`；WBI nav 与它同 path 但永远匿名，在 BiliAPI 另有一份。endpoint 与 allowlist 两处
  声明是有意的：把一个 endpoint 误标成账户读取需要同时改两处。
- 调用方已带 `Cookie`、`Authorization` 或 `X-CSRF-Token` 时拒绝；每次授权生成新请求，不缓存 header。
- 授权器拒绝（path 不在 allowlist、形状不合规）是客户端编程错误，映射为 `invalidRequest` 失败关闭，不给
  重试、不触发复核；新增账户读取 endpoint 漏配 allowlist 就表现为该功能稳定失败。
- `BiliAPIClient` 的 endpoint 扩展逐请求决定匿名或账户读取，并独占 path/query schema；请求 builder
  只在 `BiliAPI` 内部可见，adapter 不构造 `RequestAccess`；授权器不复制业务规则。
- 业务码 -101 只在请求实际带凭据发出时映射为凭据失效；匿名发出的请求收到 -101 是“需要登录”，不触发
  复核。两种写请求自行把 -101／-111 视为凭据失效，见下文。
- 只按账户读取的 endpoint（观看历史、稍后再看、收藏夹、字幕目录、测速样本、播放页的点赞投币收藏状态等）在本地无凭据时
  直接失败，不匿名回退；其余登录增强读取匿名请求同一 endpoint，主播放 playurl 改用带游客参数的匿名请求。
  以窗口账户 mid 为参数的读取（收藏夹列表），mid 只取自窗口账户范围，认证仍在确认、或其他窗口换号而本窗口
  还没复核到时不读取，否则会用新账户的 Cookie 读旧账户的 mid。
- 只按账户读取的来源只在是当前来源时读取，不在本页时不在后台读取账户内容；例外是侧栏的收藏夹列表
  （名称、私密与默认标记）：窗口已登录就读取，账户变化时清空并按新账户重读，夹内视频仍只在本页读取；以及用户打开
  「收藏到…」面板时读取同一列表附带该视频的归属，面板关闭即丢弃。
- 凭据损坏、过期、Keychain 不可用（§2 已确认未登录的窗口除外）、403/412、业务拒绝、非 JSON、redirect
  一律失败关闭，不自动匿名重试。唯一的重试例外是弹幕分段被 HTTP 412 拒绝时，以同一授权方式、同一 WBI key
  再请求一次，不降级为匿名，弹幕会话不再叠加重试。复核与重载见 ARCHITECTURE「认证」。
- WBI 签名请求在授权前先匿名取 nav；只按账户读取的签名 endpoint 在本地无凭据时，在 nav 之后的授权阶段
  失败，不发出该 endpoint 请求。WBI key 的 nav 请求保持匿名。只有业务码 -403 或 `v_voucher` 挑战时强制刷新 key 并重试一次；HTTP 403／412 是风控，按受限失败关闭，不换 key。
  所有签名读取共用 `BiliAPIClient.signedRequest`：取 nav、换 key 重试与响应返回期间认证 epoch 变化时丢弃结果，
  不以新会话补发；会话失效后返回的 nav 也不写回 key 缓存。

**App 端读取**（`BiliAppRequestAuthorizer`）

防：access_token 被带到 `app.bilibili.com` 之外或 allowlist 之外的接口；签过名的带凭据 URL 被改写或泄露。

- 只允许 `https://app.bilibili.com`、端口缺省或 443、GET、无正文、无 userinfo／fragment、路径编码规范，且 path 在
  `LiveAPIClients` 声明的 App allowlist 内（只引用 BiliAPI 的 `BiliAppReadPath`，目前是首页推荐 `/x/v2/feed/index`、UP 主空间投稿
  `/x/v2/space/archive/cursor` 与空间内搜索 `/x/v2/space/search`；空间投稿的翻页游标取自上一批响应，只接受十进制数字后才
  拼回 query；空间内搜索只在用户回车提交时发送规范化后的关键词，不发未提交的输入）；
  只有窗口主 API 注入它。调用方自带 `access_key`、`appkey`、`ts`、`sign`、`mobile_access_key`、重复的 query 字段或凭据类
  header 一律拒绝。
- 凭据按账户读取的同一规则读取（每次读 Keychain，损坏或过期删除后报告失效，Keychain 不可用只在 §2 已确认未登录时按
  无凭据处理）。有凭据时把 `access_key` 放进 query，再用 TV 的 appkey 对全部参数做 APP 签名；本地明确无凭据时只签名、
  不带凭据（未登录用户的匿名 App 推荐、空间投稿与空间内搜索）。凭据失效、Keychain 不可用与请求不合规都不降级为匿名签名。
- App 端请求即使匿名也必须签名：`appRead` 访问总是经这个授权器，没有它的 client 不发出请求，授权失败也不退回未签名的
  原请求。授权结果带回是否附带了凭据，业务码 -101 只在带了凭据时是凭据失效（触发复核），否则是“需要登录”。
- 签名后的 URL 本身就是凭据：管线原样发出、拒绝 redirect，不改写 query；日志与诊断按 §8 不记录 URL。

**自动写入：观看进度**（`BiliPlaybackHeartbeatRequestAuthorizer`）

- 仅 `POST https://api.bilibili.com:443/x/click-interface/web/heartbeat`；header 集合固定为 `Accept`、
  `Content-Type`、`Referer`、`User-Agent`，query 与表单字段按固定 schema 逐项校验并交叉核对。
- 只发送 `SESSDATA`，`bili_jct` 仅在 `BiliAuth` 内作为 `csrf` 注入表单。
- 游客不创建写意图。403/412、认证、网络、解析或业务失败只关闭匹配的报告会话，不触发认证重校验，
  不影响 AVPlayer。进程内单并发，每窗口有界合并，最终退出边界优先。
- 不建立离线队列，不持久化位置或待发送请求，不崩溃恢复写入。
- 这个授权器只放行 heartbeat；用户发起的写入走下面的独立授权器，两者不互相泛化。

**用户发起的账户写入**（`BiliAccountWriteRequestAuthorizer`）

防：点错或被构造的请求改动账号；写入落到另一个账户；一次写入扩大成批量或清空。

- 目前只有稍后再看的加入（`POST /x/v2/history/toview/add`）与移除（`POST /x/v2/history/toview/del`），收藏的归属改动
  （`POST /x/v3/fav/resource/deal`）与夹内移除（`POST /x/v3/fav/resource/batch-del`），以及播放页侧栏的关注与取消关注（`POST /x/relation/modify`，只收单个 UP 主
  `fid`（正整数），`act` 只能是 1（关注）或 2（取消），`re_src` 固定为 11；拉黑、悄悄关注、移除粉丝等其他 `act` 一律拒绝）。
  `toview/del` 的 `aid` 在接口文档里
  可选、带 `viewed=true` 会删除全部已看完的视频；schema 强制要求 `aid` 并拒绝 `viewed`，所以发不出“一次清空”，不得把 `aid`
  改成可选。`batch-del` 接受逗号分隔的多个条目，schema 只收单个 `<aid>:2`；`deal` 只收单个视频、固定 `type=2`，两侧夹 id
  列表各自不重复、互不相交、至少一侧非空、有上限。换用其他接口时同样只收单个视频，不收批量；需要 WBI 签名或 multipart 正文时，要给 schema 加对应维度
  并封闭校验，不得放宽成接受任意正文或 query。
- 只有窗口主 API 注入这个授权器，写 allowlist 由 `LiveAPIClients` 声明、只引用 BiliAPI 的 `BiliAccountWritePath`；测速与
  观看进度 client 没有写能力。新增写操作需要 ROADMAP 里的产品决定，并在授权器的 schema 表里逐条登记 path、表单字段与
  取值形状、固定 Referer 与 Cookie 白名单，不得放宽为通用写入。
- 每个请求必须精确命中：`https://api.bilibili.com`、端口缺省或 443、POST、无 query／userinfo／fragment、path 同时在
  allowlist 与 schema 表里；header 集合固定（`Accept`、urlencoded `Content-Type`、`Origin: https://www.bilibili.com`、该 path
  规定的固定 `Referer`、`User-Agent`）；表单有大小上限，字段名恰为 schema 的必需字段加可选字段的子集，同名字段重复、调用方
  自带 `csrf` 或凭据类 header 一律拒绝。
- 账户绑定：写请求带窗口账户的 mid（`RequestAccess.accountWrite(expectedAccountID:)`），授权器每次读 Keychain，凭据的
  `DedeUserID` 不等于它时按凭据失效拒绝，但不删除凭据（多半是本窗口范围过期、Keychain 里已是另一窗口登录的账户）。损坏或
  过期的凭据照常删除；Keychain 不可用一律失败关闭，不读“已确认未登录”。
- 只发送该 path 白名单里的 Cookie（目前只有 `SESSDATA`），`bili_jct` 只作为表单 `csrf` 由授权器拼在末尾；不附加 `buvid3`。
- 只在窗口账户已确认登录且 mid 已知、不在复核、没有其他窗口换号待复核时发出（与收藏夹列表同一规则）；认证 epoch 推进时
  在途写入按取消结束、结果不写回。
- 响应先判定状态 envelope（有大小上限、须像 JSON，不回显 message），`code` 为 0 但 `data` 只有 `v_voucher` 是风控挑战、
  不算成功；-101、-111 与账户不符为凭据失效，触发一次窗口复核；风控按受限；关注的 -403 是 B 站拒绝这个客户端（不复核、
  不重试，胶囊只说明被拒，不给网页入口）；其余业务码的分类在 `AccountWriteError`。一律不自动重试、不排队、不持久化
  待写入请求或结果。

**用户发起的 App 端写入**（`BiliAppWriteRequestAuthorizer`）

防：access_token 被带进 allowlist 与 schema 之外的 App 接口；写入以匿名或另一个账户的身份发出；举报类反馈被当作「不感兴趣」
发出；一次写入扩大成多个稿件或超出投币上限。

- 目前有两类，方法按 path 固定：
  - 首页推荐的「不感兴趣」与撤销（`GET https://app.bilibili.com/x/feed/dislike` 与 `.../dislike/cancel`）：query 恰为
    `goto=av`、单个稿件 `id`（正整数）、一个 `reason_id`（正整数，取自卡片给出的原因），以及与首页推荐请求相同的
    `mobi_app=iphone`、`device=pad`、`build=1`。卡片同一处的举报类反馈以 `feedback_id` 发送，不提供，schema 也不接受。
  - 播放页的点赞（`POST /x/v2/view/like`，单个 `aid`，`like` 只能是 0（点赞）或 1（取消））、投币（`POST /x/v2/view/coin/add`，
    `multiply` 只能是 1 或 2、`select_like` 0 或 1）与三连（`POST /x/v2/view/like/triple`，只有 `aid`）：urlencoded 表单，只收
    实测成功的最少字段。网页的这三个接口会对部分账号或稿件以 -401／-403 拒绝，同一时刻 App 端成功，所以改走这里。
- 只有窗口主 API 注入这个授权器，allowlist 由 `LiveAPIClients` 声明、只引用 BiliAPI 的 `BiliAppWritePath`，与 App 端读取的
  allowlist 分开；新增 App 写操作同样需要 ROADMAP 的产品决定，并在授权器的 schema 表里逐条登记。
- 目标校验与 App 端读取相同（精确主机与端口、路径规范、无 userinfo／fragment）；GET 无正文，POST 无 query、
  `Content-Type` 为 urlencoded、正文有大小上限；调用方自带 `access_key`、签名参数、重复字段或凭据类 header 一律拒绝，
  授权器拒绝映射为 `invalidRequest`。不带 Cookie、csrf 与 Referer。
- 写入从不匿名：凭据按写入的规则读取（本地无凭据失败，损坏或过期删除后报告失效，Keychain 不可用失败关闭）；账户绑定与网页
  写入相同（`RequestAccess.appWrite(expectedAccountID:)`，`DedeUserID` 不符时按凭据失效拒绝、不删除）。通过后把 `access_key`
  放进 query 或表单再做 APP 签名，签名后的 URL 或正文只能原样发出，见上文 App 端读取。
- 响应按网页写入的同一规则判定（同一段代码），只有投币（附带点赞是否成立）与三连（逐项结果、`multiply`、风控标记）解码
  `data`，三连报告风控时按受限处理；点赞、投币、三连的 -403 仍按 B 站拒绝这个客户端处理（结果胶囊给出「在浏览器中
  打开」）。App 端对已赞的视频再点赞同样返回成功，原状态只取自读到的互动状态。发出条件、epoch 与不重试、不排队也相同。

**永不携带凭据**：WBI nav、图片、视频／音频 CDN、字幕正文、loopback server、二维码 URL、评论外链与短链解析、
Sparkle 更新网络，以及任何 redirect 后的主机。只认精确主机，不使用 `*.bilibili.com` 后缀匹配：后缀匹配会把凭据交给任何子域。

## 4. 远端来源与重定向

防：接口返回的地址把请求引到非预期主机或本机网络；畸形或超大响应进入解码器。媒体、字幕、图片与外链请求本来不带凭据，
来源白名单主要限制连接面与 IP 暴露，并让来源变化表现为失败而不是悄悄放行。

所有 API、认证、媒体、字幕、短链与图片 session 都从 `BiliNetworking` 唯一的
`URLSessionConfiguration.credentialFreeEphemeral()` 基线构造：ephemeral、`httpShouldSetCookies = false`、
无 Cookie 与凭据 storage、无 URL cache，默认交互式请求超时，只有用途确实不同的调用方覆盖超时；持有 session
的一方都拒绝 redirect，`URLSessionTransport` 没有跟随选项。Range 媒体 transport 与图片管线在重定向回调里就以该 3xx 失败并取消 task：被拒绝的
重定向要等 3xx 正文传完才作为最终响应交给 delegate，正文卡住或涓流时请求会拖到空闲超时。
`PublicHTTPSURLPolicy` 是基线：HTTPS、无 userinfo／fragment、端口缺省或 443，拒绝 IP literal 与
`localhost`／`.local`／`.internal`／`home.arpa`。它不解析 DNS，不能证明域名不指向私网，
所以各用途再叠加专属规则：

| 用途 | 允许来源 | 其他限制 |
| --- | --- | --- |
| 媒体（DASH、progressive） | `BiliMediaCDNURLPolicy`：`bilivideo.com`／`bilivideo.cn`／`szbdyd.com` 及子域、`upos-*.akamaized.net` | DTO 映射时、bridge 读取 SIDX 前与 loopback 媒体资源构造时各检查一次；Range client 本身只执行 `PublicHTTPSURLPolicy`。响应须为精确 206 与起止一致的 `Content-Range`，正文逐字节计数、长度必须精确；媒体分段另核对 `Content-Range` 完整长度、不要求 `Content-Length`（部分 CDN 省略），progressive 另要求 `Content-Length` 与 `Content-Type`；SIDX 与 init（音频格式、HDR 档的动态范围）区间有上限，超限时不发请求。读取都先验证响应头再接收正文，超出区间立即取消。构造每个 Range 请求时统一去除调用方 headers 里的 `Cookie`／`Authorization` |
| 字幕正文 | `SubtitleURLPolicy`：`https://aisubtitle.hdslb.com/bfs/...` | 正文 ≤ 2 MiB；新主机先失败关闭 |
| 评论头像、表情、正文图片、链接前置图标，热搜图标 | `BiliBFSImageURLPolicy`：`i0`／`i1`／`i2.hdslb.com` 与相册域名 `album.biliimg.com` 的 `/bfs/` 路径（`http:` 与协议相对地址先升级为 HTTPS） | 拒绝 query、fragment、点段、编码分隔符；缩略参数写在 path 上，加参数后的地址再过一次同一规则；热搜图标不合规时只丢图标、保留文字 |
| 视频封面，卡片与侧栏账号头像 | 接口返回的 HTTPS URL（`http:`、协议相对地址升级为 HTTPS），映射时与图片管线请求前各过一次 `PublicHTTPSURLPolicy` | 由图片管线限制；加缩略参数后再过一次同一基线 |
| 评论与简介外链 | 视频链接只回送合法 BVID（av 号在本地换算，不发请求），分 P 序号与起播秒数只取正整数；@ 成员与空间链接只允许正整数 MID，在应用内打开空间；搜索词链接不生成；纯文字里识别出的网址只认 `https`（`http` 仅在指向站内目标时升级），外链须先通过公开 HTTPS 复核才显示为链接；其余外链（含短链解析失败时回退的原短链）打开前都经公开 HTTPS 形状复核 | 仅用户点击后交给系统 `OpenURLAction`；不预取、不解析 DNS、不附加凭据 |
| 评论与简介短链 | 只认 `https://b23.tv/{1–16 位 ASCII 字母数字}`，请求时去掉 query 与 fragment；其他短链域名按评论外链处理 | 仅用户点击后发一次无凭据 `HEAD`（拒绝 redirect、短超时、不读正文），只读一次 3xx 的绝对或协议相对 `Location`，目标按评论外链同一规则分类；目标仍在 b23.tv（不论形状）、不是跳转或失败时，把原短链交给系统浏览器，不连续跟随；同一窗口同时只解析一个，新点击、换视频或关窗取消，关窗时释放 session；不记录短码与目标地址 |

- 弹幕分段与评论页须通过状态、Content-Type 与 2 MiB 上限，再交给解码器；JSON、protobuf、HTML 错误页和
  空响应不能互相降级解析。未知接口状态失败关闭。互动弹幕（`dm/web/view`）走同一套 protobuf 校验，上限 512 KiB；
  其中的 JSON `extra` 逐条限长解析，不合规只跳过这一条。远端图片只读关联视频封面 `arc_pic`：升级为 HTTPS 后须过
  BFS 图床规则（`BiliBFSImageURLPolicy`），不合规时卡片只缺封面；跳转地址 `jump_url` 不读，点击只按校验过的
  BVID 在应用内打开，防止弹幕数据把用户带到任意网址。
- 所有远端图片（含侧栏账号头像）都经图片管线加载，不用 `AsyncImage` 等走系统共享 session、URL cache 或跟随
  redirect 的加载方式。
- 图片管线（`NativeVideoImagePipeline`）：无凭据 session，响应必须 2xx、HTTPS、同主机、`image/*`、
  ≤ 8 MiB（评论图片预览请求原图，按 B 站评论图片上传上限单独放宽到 ≤ 20 MiB）；按用途限制解码尺寸；
  只有有界内存 cache（系统内存压力时清空），没有磁盘 cache。动图只在帧数与每帧像素都在上限内时播放，超出的只显示第一帧。
- 评论图片预览的「保存图片」：先由系统保存面板选位置，再经图片管线同一套请求与响应校验、≤ 20 MiB 上限
  重新请求原图（不缓存），只有 ImageIO 能识别的位图才原样写入所选文件（SVG、HTML 等拒绝）；默认文件名取
  图床文件名并去掉开头的点。

## 5. 本地回环服务

防：本机其他进程或浏览器网页借 loopback 端口读取媒体、发起上游请求或耗尽资源。

- `LoopbackPlaybackServer` 只绑定 `127.0.0.1`，系统分配端口（不复用本地端点），每实例使用随机
  session path。
- 只实现最小 HTTP/1.1：请求目标必须以 `/` 开头（query 不参与路由），方法只允许 `GET`／`HEAD`（其他
  405），`Host` 必须恰好一个且与 `127.0.0.1:<端口>` 精确相等（防 DNS rebinding），请求头 ≤ 16 KiB
  （超出 431）；畸形请求一律 400。
- 连接数、未收齐请求头的连接数与收齐请求头的时限都有上限，名额满时优先关闭最早接受、仍未发完请求头的
  连接，保证进入响应阶段的连接总有余量。每个响应都带 `Connection: close`，一条连接只服务一个请求。
- 内存资源（playlist、字幕等）支持单一 Range，多段或非 `bytes` 单位忽略并返回完整 200；远端媒体路由没有
  可用 Range 时返回 400，起点越界返回 416，都不发起上游请求。DASH 分段只向 SIDX 读取成功的那一个来源
  转发解析后的闭区间 Range；progressive 原样转发 AVPlayer 的单一 Range 头（先经解析验证），首个通过
  响应头验证的候选固定给后续 Range。上游请求去除 `Cookie`／`Authorization`。
- 206 响应头发出后的任何失败只能断开连接，不换来源续传。
- 收齐请求头后继续监听下游：EOF 或连接错误即视为断开，关闭连接并取消上游请求；向下游写入失败同样按取消
  处理，不换备用线路。
- playlist 只在内存；媒体正文逐 chunk 转发并等待下游 send completion 形成背压，下游写入期间上游已到达
  的字节暂存有上限，超出即失败；不整段缓存、不落盘。
- 播放项目替换、停止、关窗或登出时关闭 server，取消连接与上游 Task。
- 诊断不输出 Cookie、token、上游响应 body、host、query 或签名 URL。

## 6. 本地持久化

防：观看内容、账号关联数据与远端响应留在磁盘上。

- UserDefaults 保存非内容偏好：播放音量、静音、首选倍速、「播放结束后」；弹幕速度、透明度、显示区域、密度、是否合并重复弹幕；
  版本化播放线路 route identifier；“HDR 视频”与“无损音频”开关；浏览态与播放态的侧栏宽度。未知或损坏值回退默认；已移除功能的偏好键
  （响度均一化开关）在读取时删除。
- 本机搜索历史（`SearchHistoryStore`，schema 1）是 UserDefaults 中唯一的内容数据：保存用户提交的
  搜索词原文，只做搜索规则的规范化（去首尾空白、≤ 100 字），因此可能包含用户自己输入的 BV 号或链接；
  最近在前、去重，最多 20 条，没有时间期限。它属于本机而不属于账号：BiliKit 不附加账号标识，未登录也
  记录，登出不清理；用户可在搜索页逐条删除或全部清除，清除时移除对应键。schema 不符或类型错写时启动即
  删除这两个键；非法条目不显示，下次写入时被覆盖。
- B 站热搜结果，以及稍后再看、收藏夹的条件、选择与侧栏折叠状态，只在窗口内存中，不持久化。
- 不持久化 BVID、CID、AID、播放位置、标题、字幕／弹幕正文、字幕选择、远端 URL、测速样本与结果，
  以及任何响应正文。观看 identity 与位置只存在于当前进程内存；服务端返回的续播位置只作一次性
  内存候选，匿名响应丢弃该字段。
- 没有本地数据库或磁盘缓存；新增持久化必须先定义 schema 版本、容量、期限、登出清理并更新本文。

## 7. 应用更新

防：被替换或降级的更新包、更新链路上泄露账号信息、签名私钥外泄。

- Sparkle 只链接 App target，由唯一 `AppUpdater` 持有；它不引用 `BiliAuth`、账户 coordinator、授权器
  或播放器，更新失败不进入认证或播放清理链路。
- 只有正式渠道构建带 `SUFeedURL`；开发渠道（本机 Debug／Release、Gate、CI，见 ARCHITECTURE「平台与命名」）
  的 feed 为空，按未配置不启动 Sparkle。`AppUpdater` 仅在配置完整时启动：`BiliKitUpdaterEnabled`、HTTPS `/appcast.xml`（无 query、userinfo、
  非标准端口）、32 字节 `SUPublicEDKey`、`SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction`、
  `SUSignedFeedFailureExpirationInterval = 0`、启用 Installer XPC、禁用 Downloader XPC、显式关闭
  `SUEnableSystemProfiling`（缺失同样视为不完整）。
- entitlement 只为 Sparkle 增加 `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`／`-spki` mach lookup，不加 runtime
  exception。唯一的文件权限是 `com.apple.security.files.user-selected.read-write`，只供评论图片预览的
  「保存图片」经系统保存面板写入用户所选位置。
- 自动下载与安装默认关闭。不添加账号标识、查询参数或自定义请求头。
- Cloudflare 只托管已签名 `appcast.xml` 与 `_headers`；DMG 只来自固定仓库的 GitHub Release
  `/releases/download/<tag>/<file>.dmg`，拒绝草稿、latest 与 query。build 号正整数递增，资产不覆盖，
  坏版本用更高 build 前向修复。
- EdDSA 与 Developer ID 私钥只在发布机 Keychain 与加密备份，不进仓库、CI、Cloudflare、参数或日志。

## 8. 日志、fixture、截图

防：凭据与观看内容经日志、测试数据或截图离开本机或进入仓库。

- 产品代码不输出网络日志；错误只含阶段与分类。新增任何日志或诊断前必须先加脱敏并更新本文。日志与诊断不记录内容身份组合、标题、位置、
  Referer、query/body、Cookie、CSRF、账号标识、完整 URL 或响应正文。
- 现有的产品日志只有一处：弹幕时钟的平台前提不成立时，Release 构建记一条固定的英文分类字符串
  （`DanmakuClock` 类别，public），不带任何时间值、位置或参数。
- fixture 只用手写假值与 `example.invalid`（媒体地址用虚构的 `*.fixture.bilivideo.com`，生产 allowlist 不为测试开口），不录制现场响应；`Scripts/check-secrets.sh` 在 static Gate
  中扫描已知秘密模式。
- 现场探针只输出字段名、类型、长度、计数、状态与分类。
- 含标题、账号、二维码、字幕或弹幕正文的真实截图不进仓库。

## 9. 剩余风险

- TV 扫码与各 Web 接口未公开，可能无通知漂移；漂移应表现为失败关闭，而不是降级。
- TV 扫码与 App 端推荐的 APP 签名用的是从官方客户端提取、公开流传的 TV appkey／appsec；B 站轮换或停用它时扫码登录与
  首页推荐一起失效，只能换 key 并发版。
- Keychain 不能抵御已控制当前用户会话、可调试进程或可读屏幕的攻击者。
- 签名私钥丢失时，拒绝降级策略可能要求用户手动安装新版。
- 图片管线不核对图片内容是否完整：服务端正常结束响应但内容被截断的 JPEG／PNG（无论是否声明长度）会被
  ImageIO 容错解码为缺了一部分的图，照常显示并进内存缓存；传输中断由 URLSession 报错，不会进入解码。
- 收藏夹列表在 Cookie 失效时不报 -101，而是退化为访客视角（`data` 为 null 或只剩公开夹）。自己视角下没有默认
  收藏夹才按凭据失效复核；默认收藏夹公开时访客视角仍返回它，列表只是悄悄少了私密收藏夹，直到其他账户读取
  返回 -101 才会复核。

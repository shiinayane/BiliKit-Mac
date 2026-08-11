# 04 隐私、日志与 redirect

状态：第一轮事实审计完成；`M501-PRIV-003` 的 probe/CI 安全修复已实施，播放等产品生产
路径未因该项修改。

本文件 owner：第一轮 Agent C。取证日期：2026-07-27。此次未使用真实账号、未扫码登录、
未发起签名请求；“现场行为”只引用仓库中已有且可脱敏复核的记录。
本机 Xcode `MacOSX26.5.sdk` header 标注确认
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 为 macOS 10.9+、
`kSecUseDataProtectionKeychain` 为 macOS 10.15+、ephemeral URLSession configuration
为 macOS 10.9+、AVPlayer access/error log 为 macOS 10.7+，均覆盖项目最低系统 macOS 15。

## M501-PRIV-001：Keychain 存储策略符合当前 Apple 合约

- **finding_id**：`M501-PRIV-001`
- **审计线 / 能力**：Cookie/token 的 Keychain 可访问性、同步与删除。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliAuth/Credential/WebCredentialStore.swift:17-23,90-97`
    使用固定 service/account，
    `kSecClassGenericPassword`、`kSecUseDataProtectionKeychain = true`、
    `kSecAttrSynchronizable = false`。
  - `:53-81` 保存时使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`；
    `:84-88` 删除。
  - `Packages/BiliKitCore/Sources/BiliAuth/Application/BiliAuthenticationService.swift:159-190`
    logout 取消当前登录、清内存，
    删除 Keychain，再 invalidation 认证/API transport；删除失败不会虚报 signed-out。
- **声称承担的职责**：认证材料只在设备解锁时可读、不经 iCloud 同步/迁移，并在登出时
  删除。
- **外部事实来源**：
  - Apple [`kSecUseDataProtectionKeychain`](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)。
  - Apple [`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
    与 [Restricting Keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)。
  - 本机 `MacOSX26.5.sdk` `Security.framework/Headers/SecItem.h:588-613,1033-1055`
    确认属性在当前 SDK 存在并适用于 Data Protection Keychain。
  - **证据强度**：Apple 规范 + 静态查询字典 + mock 顺序测试；没有读取真实 Keychain。
- **OSS 对照及 commit/date**：不适用；Keychain 属性以 Apple 合约为准，且项目的
  “不迁移/不同步”是自身安全策略。
- **真实行为证据**：2026-07-28 使用 Apple Development 签名 Debug test host 和专用
  `com.shiinayane.BiliKitMac.tests.signed-keychain-smoke.v1` service，完成
  add/update/read/属性查询/delete；`WhenUnlockedThisDeviceOnly`、非 synchronizable
  均符合预期，最终查询确认 item 不存在。未登录、未访问生产 service、未输出 value。
- **本地测试实际覆盖范围**：
  - `Packages/BiliKitCore/Tests/BiliAuthTests/BiliAuthenticationServiceTests.swift:72-114`
    验证受控 credential store 删除成功的
    logout 顺序。
  - `:128-171` 验证删除失败仍 invalidation，但不发布 signed-out。
  - mock 调用顺序不证明真实 `SecItemDelete`、签名 entitlement 或 Keychain UI 行为。
- **判断**：当前 Keychain 存储策略与签名 Debug 运行行为均 **保留**。
- **风险**：低。该 smoke 不证明 Developer ID 分发签名、覆盖安装、换签名或卸载语义。
- **下一步最小验证**：若制作 Developer ID 包，在隔离测试 service 上复跑相同属性与删除
  矩阵；不导出 value，不截图 Cookie。
- **依赖 / 冲突**：依赖工程分发线确认签名与 entitlement；不得把真实凭据写进 xcresult、
  probe 或截图。

## M501-PRIV-002：生产请求的 ephemeral/cookie/redirect 默认值应保留

- **finding_id**：`M501-PRIV-002`
- **审计线 / 能力**：URLSession 持久化、Cookie 自动注入和 HTTP redirect。
- **当前实现（文件 / 符号 / 调用链）**：
  - `BiliKitMac/Composition/AppEnvironment.swift:104-136` 为生产 transport 建
    `.ephemeral` configuration，关闭 cookie、清空 cookie/cache storage、采用
    `reloadIgnoringLocalCacheData`，并注入 `RejectHTTPRedirectDelegate`。
  - 字幕 body repository、
    `Packages/BiliKitCore/Sources/BiliNetworking/Range/HTTPRangeClient.swift:147-159`、
    Web QR 与认证 authorizer 使用相同的 ephemeral/no-cookie/no-cache/reject 配置。
  - `Packages/BiliKitCore/Sources/BiliNetworking/Transport/HTTPClient.swift:141-152`
    在 redirect delegate 回调中
    `completionHandler(nil)`。
- **声称承担的职责**：请求不落入共享持久缓存/凭据/Cookie storage，不自动跨 host
  携带 Cookie；redirect 必须由调用方显式裁决。
- **外部事实来源**：
  - Apple [`URLSessionConfiguration.ephemeral`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)：
    不使用持久 cache、cookie、credential storage。
  - Apple [`URLSession.shared`](https://developer.apple.com/documentation/foundation/urlsession/shared)
    与 [`default`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/default)：
    共享默认 cache/cookie/credential 行为与此安全边界不同。
  - Apple [redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29)：
    传 `nil` 拒绝 redirect，并把 redirect 响应 body 交回调用方。
  - **证据强度**：Apple 规范 + 生产 composition 静态证据 + 本地受控 redirect 测试；
    没有真实恶意重定向现场。
- **OSS 对照及 commit/date**：不适用；URLSession 行为以 Apple 合约为准。B 站 host
  allowlist 与 endpoint 由 API/安全线另行审计。
- **真实行为证据**：本轮没有发送真实请求。已有一次成功不等价于 endpoint/redirect
  长期稳定。
- **本地测试实际覆盖范围**：测试能证明本地 3xx 响应不被跟随、Cookie header 由授权器
  显式决定；不能证明所有现场 CDN/认证 host 的 redirect 策略都正确。
- **判断**：`AppEnvironment.live()` 与上述专用 transport 的默认值 **保留**；
  host/endpoint 是否需个别受控 redirect **尚不能判断**。这不是全仓保证：
  `BiliAPIClient` 公共默认仍可能使用 `.shared`/默认 follow、Cookie 与 cache 行为；历史
  probe transport 已删除，不再属于当前调用面。
- **风险**：改回 `.shared` 或允许自动 redirect 可能把凭据、Cookie 或签名 query 暴露给
  非预期 host；一刀切拒绝又可能锁死服务端已改变的合法协议事实。
- **下一步最小验证**：API/认证/媒体线给出当前允许的逐跳 host 事实；用本地两 host server
  覆盖 301/302/307/308，断言认证 header/Cookie/query 不跨 host。只记录 host 分类，不
  记录完整 URL。
- **依赖 / 冲突**：依赖 API/auth allowlist 与媒体 CDN fallback 审计；与
  `M501-CONC-005` 的 session invalidation 是不同问题。

## M501-PRIV-003：真实标识符曾进入 probe 参数、CI 元数据、stdout 与已提交验证文档

- **finding_id**：`M501-PRIV-003`
- **审计线 / 能力**：probe、CI、验证记录和本地临时产物的数据最小化。
- **当前实现（文件 / 符号 / 调用链）**：
  - `.github/workflows/ci.yml` 已删除 GitHub-hosted 真实播放 job 及 BVID/CID
    `workflow_dispatch` inputs；远端 CI 只保留无签名确定性 gate。
  - 一次性真实网络、签名 UI、播放器和 renderer probe 及其 runner 已从当前树删除；
    不再为历史验证路径保留可执行 target、launch flag、输入解析器或测试专用日志。
  - 以下是历史问题而非当前行为：旧 probe 曾打印内容 identity/CDN host，workflow
    曾接受 BVID/CID，旧 runner 曾写仓库根 `test.log` 并留下完整临时产物。
  - `docs/validation/M1-real-playback-2026-07-21.md:46-57` 提交了现场 BVID/CID；
    `docs/validation/M2-guest-api-2026-07-21.md:28-35` 提交了搜索结果 BVID。
- **声称承担的职责**：probe 应验证现场行为但不保存个人内容、秘密、完整 URL 或可关联的
  内容身份。
- **外部事实来源**：
  - 仓库 `docs/security/M4-data-privacy.md` 与本次审计 contract 明确禁止 BVID/CID、
    完整远端响应/URL 进入验证记录。
  - Apple [Generating log messages](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)
    与 [`OSLogPrivacy`](https://developer.apple.com/documentation/os/oslogprivacy) 提供显式
    隐私标注；直接 `print`/CI 日志没有这层控制。
  - **证据强度**：已提交文件、脚本与 workflow 的直接证据；无需真实账号即可确认。
- **OSS 对照及 commit/date**：尚未对照；这是 BiliKit 自己的采集/保留政策，OSS 是否也
  泄漏不能降低风险。
- **真实行为证据**：仓库历史验证文档已持久保存内容标识；2026-07-28 进入第五组前按当前
  工作树重新核对，`workflow_dispatch` 仍把 BVID/CID 作为 input/env，播放 probe 仍向
  stdout 输出 BVID/CID/CDN host，两个旧 runner 仍写仓库根 `test.log`，其中认证契约
  runner 仍使用固定 `/tmp` 且不删除完整 DerivedData/xcresult。无需运行真实请求即可确认
  这些数据保留路径；本轮没有把新的内容标识送入 CI 或 probe。
- **本地测试实际覆盖范围**：`Scripts/check-secrets.sh:5-17` 只扫描 QR/Cookie/token
  等模式，且允许 fixture 哨兵；通过它不能证明没有 BVID、CID、搜索词、字幕正文或签名
  URL。
- **判断**：**已替换当前执行路径**。用户裁决真实远端播放/字幕/弹幕 probe 不进入
  GitHub-hosted CI，只允许本机显式、脱敏、自动清理运行；第五组因此解除本项暂停。
- **风险**：当前执行路径降为低到中。BVID/CID 仍会在本机 mode 600 临时文件中短暂存在，
  probe 或框架若未来新增未审计输出仍可能重新引入泄漏；已提交验证文档和 Git 历史中的
  旧内容标识未处理，也不属于本次授权。
- **验证证据**：
  1. 反向静态扫描未发现 executable path 中残留的 `PROBE_BVID`、`PROBE_CID`、
     `--bvid`、`--cid`、内容环境变量、identity/CDN-host stdout 模式；
  2. 八个本机 runner 的 `zsh -n` 通过，真实 runner 均具有可执行权限；
  3. `app` gate 通过；Package 223 项测试通过（20 个既有 known issues），App
     build-for-testing 与单元测试通过，未提供安全输入文件的真实 probe 均跳过；
  4. 本轮未运行真实远端 probe，也没有把新的内容 identity 写入 CI、日志或验证记录。
- **下一步最小验证**：为 probe 输出模式增加自动静态契约；历史验证文档与 Git 历史另行
  制定处置方案，未获明确授权不得改写。
- **依赖 / 冲突**：依赖工程/CI 线、文档真实性线和用户对历史重写/远端日志删除的明确授权；
  本轮只记录，不删除。

## M501-PRIV-004：HTTP 数据结构和 Range 错误保留完整 URL，诊断边界只靠调用者克制

- **finding_id**：`M501-PRIV-004`
- **审计线 / 能力**：错误、反射、调试输出中的 header/query/媒体 URL。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliNetworking/Transport/HTTPClient.swift:8-40`
    的 `HTTPRequest`/`HTTPResponse` 是公开
    `Equatable` 值，直接保存完整 URL、headers、body；没有自定义安全 description。
  - `Packages/BiliKitCore/Sources/BiliNetworking/Range/HTTPRangeClient.swift:117-140,179-225`
    的
    `HTTPRangeAttempt`/error 保存每次尝试的完整 URL；媒体 URL 可能含签名 query。
    `HTTPRangeFetchResult.sourceURL` 也会把完整来源 URL 带过执行边界。
  - `Packages/BiliKitCore/Sources/BiliNetworking/Transport/HTTPLogRedactor.swift:3-53`
    能遮 query/header，但全仓生产调用为零，
    仅测试使用。
  - 正面证据：
    `Packages/BiliKitCore/Sources/BiliAPI/Client/BiliAPIError.swift:1-59` 的公开
    description 不复述服务端 message；
    `Packages/BiliKitCore/Sources/BiliPlayback/Player/AVPlayerEngine.swift:155-167` 与
    `Packages/BiliKitCore/Sources/BiliPlayback/Player/AVPlayerItemReadiness.swift:26-30`
    只发 error type；
    `Packages/BiliKitCore/Sources/BiliApplication/Playback/PlaybackTimeline.swift:14-17`
    的 identity description 已脱敏。
- **声称承担的职责**：保留足够网络诊断信息并避免输出 Cookie、签名 query、个人响应 body。
- **外部事实来源**：
  - Apple OSLog 隐私文档同 `M501-PRIV-003`：敏感值应在输出点显式标注/脱敏。
  - 本次安全合约要求完整认证 URL、远端响应与带签名媒体 URL 不进入日志/验证记录。
  - **证据强度**：类型定义与调用图的静态证据；未发现当前生产 logger 泄漏，故不是已发生
    泄漏结论。
- **OSS 对照及 commit/date**：尚未对照；日志最小化是项目安全边界，不能以第三方调试
  输出惯例放宽。
- **真实行为证据**：没有生产日志泄漏现场；风险来自公开值的默认反射、未来 `print(error)`
  或 test failure 附件。
- **本地测试实际覆盖范围**：redactor 测试只证明显式调用 redactor 时遮罩正确；当前生产
  诊断没有统一经过它。
- **判断**：**替换** error/diagnostic projection，使其不携带 URL/query/header/body；
  请求执行所需的原始 `HTTPRequest`、`HTTPResponse` 和 range result 本身仍需保留。
- **风险**：中到高。一次普通 debug/error interpolation 就可能把 Cookie、WBI/媒体签名
  query 或响应 body 写入 Console、CI/xcresult。
- **下一步最小验证**：为可跨边界的 error/attempt/request 摘要提供只含 method、状态码、
  host 分类、range 和错误类型的安全表示；哨兵测试可证明显式安全表示，但不能自动证明
  所有 XCTest failure/附件安全，测试输出点需另行枚举。不要让 redactor 成为“先收集完整
  数据再补救”的唯一防线。
- **依赖 / 冲突**：依赖 API/媒体线确定诊断所需最小字段；避免改变真正 HTTP 执行请求。

## M501-PRIV-005：AVPlayer access log 含敏感字段，当前不主动导出的策略应保留

- **finding_id**：`M501-PRIV-005`
- **审计线 / 能力**：`AVPlayerItemAccessLog`、`AVPlayerItemErrorLog`、Console/诊断附件。
- **当前实现（文件 / 符号 / 调用链）**：生产代码没有调用
  `AVPlayerItem.accessLog()`、`errorLog()` 或 `extendedLogData()`；当前 player error
  只向 UI 发布类型。测试只在内存读取字段并断言布尔结果，不输出值。
- **声称承担的职责**：播放诊断不应持久化 loopback token、CDN 签名 URL、IP、header 或
  playback session identity。
- **外部事实来源**：
  - Apple [`AVPlayerItemAccessLog`](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslog)
    及其 [`uri`](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/uri)
    字段。
  - Apple [`AVPlayerItemErrorLogEvent`](https://developer.apple.com/documentation/avfoundation/avplayeritemerrorlogevent)
    文档列出 URI、server address、playback session ID、HTTP headers 与错误注释等字段。
  - **证据强度**：Apple 字段定义 + 生产调用静态搜索 + 本地合成 HLS 运行检查。
- **OSS 对照及 commit/date**：不适用；是否采集系统播放器日志应按 Apple 字段与本项目
  隐私策略裁决。
- **真实行为证据**：2026-07-28 本地合成 AVC/AAC HLS 播放成功后，只在内存检查
  access log：事件非空，`uri` 包含完整 loopback 路径哨兵，`serverAddress` 非空。换用
  从未出现过的新哨兵后，无 predicate 扫描最近两分钟 unified log 未命中。首次以哨兵
  作为 `log show` predicate 的命中已确认来自 `/usr/bin/log` 自身记录查询字符串，是
  假阳性，不作为产品泄漏证据。
- **本地测试实际覆盖范围**：证明 access log 对象本身包含不可直接导出的 URI/server
  字段，并在一次成功合成播放窗口内未观察到 unified log 哨兵；没有覆盖失败路径
  error log、崩溃诊断包、真实 CDN 或其他系统版本。
- **判断**：生产代码不读取或导出原始 AVPlayer log 的策略 **保留**；若未来需要播放器
  诊断，只允许投影状态、计数、bitrate 与错误类型，不能附加原始 event/extended log。
- **风险**：中。未来为排障直接附加 `extendedLogData` 会泄漏完整媒体/loopback URL；
  即使 App 不调用，也不能凭静态搜索宣称系统从不记录。
- **下一步最小验证**：若新增诊断或制作发布包，再用合成失败样本检查 error log 与崩溃
  诊断附件；验证记录仍只写字段名和布尔值，不写 URI、IP、header、session ID 或正文。
- **依赖 / 冲突**：依赖性能/播放器线的真实签名运行；trace 和诊断包必须按本文件规则脱敏
  或立即销毁。

## M501-PRIV-006：fixture 未见明显违规，但 provenance 与 secret scan 证明力有限

- **finding_id**：`M501-PRIV-006`
- **审计线 / 能力**：fixture、测试产物和完成声明的证据真实性。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Tests/BiliAPITests/Fixtures/README.md:1-18` 声明 API fixture
    为手写、脱敏最小样本，
    M4 字幕/弹幕为虚构值，远端地址为 `example.invalid`。
  - `Packages/BiliKitCore/Tests/BiliAuthTests/Fixtures/README.md:1-8` 声明认证 JSON
    手写且不来自真实登录响应，
    `FIXTURE_`/诊断哨兵不是凭据。
  - `Packages/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/README.md:1-22` 记录合成
    MP4/SIDX 的 FFmpeg 来源。
  - `Scripts/check-secrets.sh:5-17` 扫描的模式集合只覆盖部分 secret，不覆盖个人内容身份、
    搜索词、字幕正文、完整 URL 或日志/xcresult 的生命周期。
- **声称承担的职责**：测试材料可复现且不包含个人内容、凭据或真实响应副本。
- **外部事实来源**：本次证据优先级明确指出 fixture 只能证明代码符合写下的预期，不能证明
  服务事实；安全合约禁止 probe/fixture 保存个人数据。**证据强度**：仓库 provenance
  声明 + 内容模式检查；不是独立外部事实。
- **OSS 对照及 commit/date**：不适用；fixture 来源是本仓库供应链事实。
- **真实行为证据**：没有发现 fixture 中的真实 Cookie/token/字幕正文；但
  `M501-PRIV-003` 已证明验证文档与 probe 路径仍可保存内容标识。
- **本地测试实际覆盖范围**：fixture/parser 测试证明解析预期形状；secret scan 只证明其
  正则命中的已知模式未出现，不能证明协议正确或数据完全匿名。
- **判断**：静态检查未发现 fixture 违反当前策略；其 provenance 仍主要来自仓库自述，
  二进制 MP4 来源也未获独立证明。“secret scan 通过即隐私通过”的完成声明 **删除**。
- **风险**：中。把自声明 fixture 或有限正则升级成外部协议/整体隐私证据，会再次产生
  “测试全绿但事实错误”。
- **下一步最小验证**：把检查拆成 secret、内容 identity、完整 URL/正文、临时产物清理四类，
  并在审计表中分别标记其证明范围；线上协议仍需脱敏现场证据与外部来源。
- **依赖 / 冲突**：依赖工程/文档线修正完成声明；不应把 `references/` 或真实响应复制进
  fixture 来“提高真实性”。

## M501-PRIV-007：loopback Host 已按实际 listener authority 严格校验

- **finding_id**：`M501-PRIV-007`
- **审计线 / 能力**：本地播放服务器暴露面、redirect 与远端来源隔离。
- **当前实现（文件 / 符号 / 调用链）**：
  - `Packages/BiliKitCore/Sources/BiliPlayback/Bridge/LoopbackPlaybackServer.swift:71-82,102-107`
    为每次 server 保存随机
    session token，并只绑定 `127.0.0.1`。
  - HTTP 解析拒绝重复 `Host`；方法校验后、route/token 查找前，要求唯一值精确等于
    当前 listener 的 `127.0.0.1:<port>`。
  - `:188-215` stop 后清 routes、connections、connection tasks 与 listener。
  - range client 使用无 Cookie 的 ephemeral session并拒绝 redirect；游客/CDN 请求不经
    认证 authorizer。
- **声称承担的职责**：仅允许本机访问，并以当前 session 的高熵 token 作为 bearer
  capability；远端 CDN 请求不带认证，redirect 不越过 allowlist。它不提供本机进程身份
  认证，获知 token 的其他本机进程仍可访问。
- **外部事实来源**：
  - Apple Network `NWListener` 生命周期与 URLSession redirect/ephemeral 合约，见
    `M501-CONC-005`、`M501-PRIV-002`。
  - 仓库 `docs/security/M3-threat-model.md` 的 loopback/远端来源边界。
  - **证据强度**：静态 bind/token/transport 证据 + `/usr/bin/nc` 独立本机进程测试。
- **OSS 对照及 commit/date**：尚未对照；token/本机访问模型是本项目威胁模型，OSS 只能
  提供实现对比，不能代替攻击面验证。
- **真实行为证据**：2026-07-28 修复前由 `/usr/bin/nc` 子进程确认有效 token/path 配
  `Host: attacker.invalid` 返回 200。修复后同一独立进程矩阵确认：正确 authority 与
  token/path 返回 200；错误 token/path 返回 404；任意、缺失、重复或格式异常的 Host
  均返回 400；8 个并发不完整请求断连后 active connection/task 均归零，`stop()` 的
  异步取消传播完成后端口拒绝连接。完整 package gate 的 224 项测试通过，保留 20 项
  已登记 known issue。
- **本地测试实际覆盖范围**：证明 bearer/path、断连清理与端口释放在本机独立进程成立，
  以及 Host 失败关闭；不提供本机进程身份认证，也不证明恶意浏览器能取得高熵 token。
  `NWListener.cancel()` 到内核端口拒绝新连接之间不是同步承诺，测试以实际拒绝连接为
  完成条件，固定上限仅作超时。
- **判断**：bind、高熵 token、匿名 range 与 stop 设计 **保留**；严格 Host 边界已
  **替换完成**，本项重大安全暂停解除。
- **风险**：修复后为中。128-bit bearer token 仍是主要防线；Host 校验增加针对
  DNS rebinding 和非预期 HTTP 客户端的独立防御层，但不构成本机进程身份认证。
- **下一步最小验证**：保留独立进程矩阵为回归；若未来改变 bind address、端口表达或
  引入 IPv6 loopback，必须先同步修改 authority allowlist 与失败矩阵。
- **依赖 / 冲突**：依赖媒体/安全线复核 host allowlist；依赖性能线验证端口和 connection
  资源释放。

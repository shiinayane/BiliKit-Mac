# M4 字幕、弹幕与本地状态数据边界

> 状态：M4.0–M4.3 Gate 已通过；字幕与弹幕数据只使用进程内存，尚未创建持久化 schema

## 1. 保护对象

M4 新增的数据本身不是登录秘密，但可以反映用户观看行为：

- BVID、CID、播放项目 identity、最近播放时间和播放位置；
- 字幕轨、字幕地址、字幕正文与当前 cue；
- 弹幕分段、弹幕正文、发送时间、过滤词和用户弹幕偏好；
- 缓存键、命中记录及与已登录会话关联的获取范围。

Cookie、token、二维码 key 和 refresh token 继续只由 `BiliAuth` 管理，不能进入上述模型或缓存。字幕地址可能带有动态参数，应按敏感远端 URL 处理，不记录完整值。

## 2. 当前阶段规则

在 `BiliPersistence` 出现首个真实调用方前：

- 字幕目录、正文、弹幕分段和播放位置只保存在当前进程内存中；
- 切换视频/分 P、关闭详情或替换播放项目时，以 identity/generation 取消旧请求并清空呈现状态；
- 登出时取消已授权请求并清除所有由登录态取得的内存字幕/弹幕数据；
- UserDefaults 只允许保存字号、透明度、密度、屏蔽开关、播放器音量、静音和首选倍速等非内容偏好，不保存 BVID、CID、播放位置、正文、字幕选择或远端 URL；
- 日志、崩溃诊断和探针只输出阶段、状态、Content-Type、字节数、字段名、计数和非内容
  的枚举分类。AI 音轨语言目录、语义轨和系统选择结果只存在于当前播放会话内存。

## 3. 首个持久化切片的准入规则

创建 `BiliPersistence` 时必须同时实现以下上限，不能先建立无限缓存：

| 数据 | 初始上限 | 到期与删除 |
| --- | --- | --- |
| 可重建字幕/弹幕响应 | 总计 256 MiB | 最长 7 天；LRU 淘汰；手动清理全部删除 |
| 本机最近播放 | 最多 200 项 | 最长 90 天；只保存最小标识、位置和更新时间 |
| 播放进度 | 每个播放项目一项 | 与最近播放共同淘汰；播放结束可归零或删除 |
| 已登录会话取得的缓存 | 不与账号标识建立长期映射 | 登出时删除，不降级为游客缓存继续保留 |

容量和期限是保守初始值，只有真实测量证明不够时才能调整，并同步更新本文和测试。损坏、未知 schema 版本或来源范围不明的数据必须失败关闭并可安全删除。

## 4. 网络与来源边界

- 字幕目录和弹幕接口只能使用精确 HTTPS host/path/method/query allowlist；需要登录时由 `BiliAuth` 的授权器添加 Cookie，Feature 不接触凭据。
- 当前字幕目录只允许 `GET https://api.bilibili.com/x/player/wbi/v2`。query 必须且只能包含合法 BVID、正 CID、正整数 `wts` 和 32 位小写十六进制 `w_rid`；其他 host/path/method/query、重复参数和额外参数全部拒绝。WBI key 仍通过无认证 `/x/web-interface/nav` 获取，只有签名后的字幕目录请求可由授权器附加 Cookie。
- 字幕正文 URL 必须单独验证 scheme、userinfo、端口、允许的主机和每次重定向；不得复用媒体 CDN 或游客图片的宽泛策略。M4.0 现场证据当前只确认 `aisubtitle.hdslb.com`，新增主机必须先失败关闭并取得同等级脱敏证据。
- 目录、正文、弹幕元数据和分段分别设置 Content-Type 与大小上限。JSON、protobuf、HTML 错误页和空响应不能互相降级解析。
- 取消、超时和换集必须终止网络与解码 Task；未知接口状态默认失败关闭。
- 登录态 playurl 的 Cookie 必须在 API 响应前终止；映射后的 playback manifest 与媒体
  headers 不保留 Cookie。DASH SIDX/媒体 Range、图片、相关推荐与 loopback 请求继续使用
  各自无认证 transport，不能从播放信息请求继承授权状态。
- playurl 的可选 `cur_language` 只能从同一响应内存中的受限语言目录选择，并且仍由
  `BiliAuth` 对精确 host/path/method/query 独立复核。语言目录、语言标题、所选媒体 URL
  和原始响应不持久化；多音轨只进入当前 `PlaybackManifest`、loopback routes 与同一个
  `AVPlayerItem`。系统 media selection 是当前唯一选择 UI，自定义音轨 UI 尚未加入。
- 播放侧栏 UP 主签名只允许匿名 `GET https://api.bilibili.com/x/web-interface/card`；query
  只能包含正 `mid` 与固定 `photo=false`。响应 `data.card.mid` 必须与请求值一致，redirect、
  HTTP／业务失败、解码失败与空白签名均只隐藏签名行。该请求不使用 Cookie、Authorization、
  WBI、设备画像或登录授权器，也不传播 card 中的昵称、头像及其他资料字段。

## 5. Fixture、探针与验证记录

- fixture 只能使用 `example.invalid`、虚构标识和自写文本；不保存现场响应 body。
- 现场探针不得打印 BVID、CID、标题、字幕/弹幕正文、完整 URL、用户标识或凭据。
- AI 音轨探针还不得打印语言标题、媒体 host 或响应正文；只允许记录目录与 AAC 数量、
  production type 集合、所选语言是否被回显、来源集合是否变化、SIDX 是否可读及媒体请求
  是否无 Cookie。
- UP 主签名探针不得打印 MID、签名正文或完整 URL；只记录 HTTP／业务分类、MID 是否匹配、
  签名是否存在与长度区间。
- 验证记录可保存日期、系统、接口路径、认证需求、Content-Type、大小级别、字段名、计数和安全分类。
- 真实 UI 截图若包含标题、账号、二维码、字幕或弹幕正文，不进入仓库。

## 6. Gate

M4.0 已形成匿名与已登录边界、字幕正文来源、二进制弹幕响应、负向 fixture、依赖选择和清理规则的可重复基线，因此允许进入 M4.1。该结论只关闭实现前 Gate，不证明远端接口长期稳定，也不替代 M4.2/M4.3 必须使用这些 fixture 固定的生产 decoder 负向测试。

M4.2 已将字幕负向 fixture 接入生产 decoder。字幕目录最初使用 `/x/player/v2`；2026-07-26 根据真实错配观察与多个独立客户端的既有修复迁移到精确授权的 `/x/player/wbi/v2`。字幕 URL 不离开 `BiliAPI`；正文只能由无 Cookie、无缓存、拒绝重定向的专用 ephemeral transport 请求；当前只允许 `https://aisubtitle.hdslb.com:443/bfs/...`。轨道、cue 与播放 identity 只存在于内存；`AVPlayerEngine` 是原生字幕 item、loopback route 与 server 的唯一 owner，切换视频、分 P、关闭详情或登出都会通过 stop/generation 清除旧状态。

现场目录可能包含 `subtitle_url` 为空字符串的不可用占位轨。生产 decoder 只忽略这种明确无正文来源的条目；非空但无法解析、来源不可信或字段异常的条目仍使整个目录失败关闭。探针必须实际出现生产 decoder 的 ready 标志，不能把“全部轨道均为空占位”造成的 skip 当作 Gate 通过。

M4.3 的 protobuf wire 类型只存在于 `BiliAPI` 解码边界；映射后的 `DanmakuEvent` 不保留发送者 hash、创建时间、action 或原始 wire。分段正文、事件 ID 和过滤关键词只存在于当前进程内存，`BiliDanmakuProbe` 只输出解码/调度/缓存计数。会话最多并发 2 个分段请求并保留 3 段；切换 identity、stop 和 discontinuity 会取消或隔离旧任务与游标。真实匿名首段已通过生产 decoder 与调度器，日志未保存内容标识、正文、完整 URL、用户标识或凭据，因此 M4.3 Gate 已关闭。

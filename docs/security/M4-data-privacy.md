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
- 播放线路偏好只保存版本化的稳定 route identifier；不保存完整 URL、query、BVID/CID、标题、作者、
  IP、Referer、测速结果或原始指标。未知 schema/route 必须回退服务端默认；
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

- 字幕目录和弹幕接口只能由 `BiliAPI` 的精确 HTTPS host/path/method/query builder 创建；需要登录时由 builder 私有选择账户读取能力，再由 `BiliAuth` 验证精确 API origin 与 GET 并添加 Cookie。Feature 不接触凭据。
- 当前字幕目录只允许 `GET https://api.bilibili.com/x/player/wbi/v2`。builder 必须且只能生成合法 BVID、正 CID、正整数 `wts` 和 32 位小写十六进制 `w_rid`；无效输入在发请求前拒绝。WBI key 仍通过无认证 `/x/web-interface/nav` 获取，只有签名后的字幕目录请求选择账户读取。
- 当前弹幕分段统一使用 `GET https://api.bilibili.com/x/v2/dm/wbi/web/seg.so`。builder 必须且只能生成固定 `type=1`、正 CID、`1...10000` 的 segment index、正整数 `wts` 和 32 位小写十六进制 `w_rid`。WBI key 仍匿名取得；本地存在有效凭据时该请求可附加 Cookie，明确没有凭据时仍请求同一 WBI endpoint，凭据损坏、不可用或拒绝时不得匿名降级。
- 评论根列表只允许账户增强读取 `GET https://api.bilibili.com/x/v2/reply/wbi/main`，楼中楼只允许 `GET https://api.bilibili.com/x/v2/reply/reply`。前者只能包含固定 `type=1`、正 AID、受限排序、opaque continuation 与有效 WBI 签名；后者只能包含固定 `type=1`、正 AID/root/page 与 `ps=10`。登录 Cookie 只为服务端返回属地等只读增强字段；明确无凭据时仍匿名读取，凭据故障不静默降级，评论模型、日志和 fixture 均不得保留 Cookie。
- 字幕正文 URL 必须单独验证 scheme、userinfo、端口、允许的主机和每次重定向；不得复用媒体 CDN 或游客图片的宽泛策略。M4.0 现场证据当前只确认 `aisubtitle.hdslb.com`，新增主机必须先失败关闭并取得同等级脱敏证据。
- 目录、正文、弹幕元数据和分段分别设置 Content-Type 与大小上限。JSON、protobuf、HTML 错误页和空响应不能互相降级解析。
- 取消、超时和换集必须终止网络与解码 Task；未知接口状态默认失败关闭。
- 账户读取 Cookie 必须在各 API 响应前终止；映射后的 playback manifest 与媒体 headers
  不保留 Cookie。DASH SIDX/媒体 Range、图片与 loopback 请求继续使用
  各自无认证 transport，不能从播放信息请求继承授权状态。
- 评论头像、自定义表情与正文图片只消费当前评论 `member.avatar`／`content.emote`／
  `content.pictures` 返回的资源，不下载或维护全量头像、表情包或图片索引。
  映射层把接口历史遗留的 HTTP／协议相对地址升级为 HTTPS；实际加载前由具体 adapter 再次限制
  精确 `i0.hdslb.com`／`i1.hdslb.com`／`i2.hdslb.com`、默认或 443 端口，以及
  非空且无歧义的 `/bfs/` 资源路径；不把其下 `emote`、`garb`、`activity-plat` 等服务端内部
  子目录当作稳定 API 契约，并拒绝 userinfo、query、fragment、点段、编码分隔符与全部
  redirect。加载复用无 Cookie、无 credential、无磁盘 cache 的图片会话，响应必须是图片且不超过
  8 MiB；表情解码最长边不超过 128 px、头像不超过 96 px、正文图片不超过 1,024 px；cell 离屏、
  复用和窗口 teardown 必须取消等待者，
  内存 cache 继续服从既有有界上限。
- 评论链接只在用户明确点击后行动。视频 `jump_url` 仅把合法 BVID 回送现有 App 内播放导航；成员提及
  仅允许正整数 MID 并交给 `https://space.bilibili.com/<mid>`；其他目标必须保持不透明，直到 App
  composition 复核 HTTPS、无 userinfo、默认／443 端口、非本地域名且非 IP literal 后才交给系统
  `OpenURLAction`。App 不预取、不解析 DNS、不跟随目标重定向，也不为该导航附加 Cookie 或 credential。
- 登录态 playurl 可把同一响应中的服务端分 P 与毫秒位置映射为一次性的首次定位候选；匿名
  响应不消费该账户字段。播放器在首次 `play` 前完成受 identity、load intent、item generation
  与用户交互 revision 保护的 seek，切视频、切 P、暂停、拖动或 teardown 都能否决迟到提交。
  该位置不落盘；本阶段不发送 heartbeat 或任何观看历史写请求。
- 账户变化会由 App 级 owner 推进所有存活窗口 API transport 的 authentication epoch；各窗口
  的旧 Popular/Search 分页、视频详情、Related、UP 主签名、分 P、播放信息、字幕目录与弹幕
  响应不得越过该 epoch 写回。
- I-frame trick play 只复用同一无认证 loopback 媒体 route，并按需代理完整 fMP4 fragment
  Range；不新增远端来源、预读、持久化或独立网络 owner，也不能继承 playurl Cookie。
- playurl 的可选 `cur_language` 只能从同一响应内存中的受限语言目录选择，并且仍由
  `BiliAPI` 私有 builder 限制精确 path/query、由 `BiliAuth` 独立复核 API origin 与 GET。语言目录、语言标题、所选媒体 URL
  和原始响应不持久化；多音轨只进入当前 `PlaybackManifest`、loopback routes 与同一个
  `AVPlayerItem`。系统 media selection 是当前唯一选择 UI，自定义音轨 UI 尚未加入。
- 显式线路测速的近期投稿发现保持匿名且有界；不同分区、投稿者与当前设置窗口已测稿件的去重集合只
  存在于 discoverer 内存，并在关闭 Settings 或账户退出时清除。只有精确 playurl GET 可通过现有
  authorizer 得到 Cookie；该 capability 只映射视频候选，不读取音频或断点字段。原始 bilivideo 基准与
  测量连接池使用相互独立的 ephemeral client；二者均无 Cookie/credential/cache 并拒绝 redirect。
  Settings 关闭、取消、登出或 owner 销毁时取消，结果、样本 identity 与去重集合均不得持久化或进入日志。
- 播放侧栏 UP 主签名只允许账户读取 `GET https://api.bilibili.com/x/web-interface/card`；query
  只能包含正 `mid` 与固定 `photo=false`。响应 `data.card.mid` 必须与请求值一致，redirect、
  HTTP／业务失败、解码失败与空白签名均只隐藏签名行。仅本地明确无凭据时匿名；凭据故障
  不静默降级。该请求不使用 Authorization、WBI 或设备画像，也不传播 card 中的昵称、头像
  及其他资料字段。

## 5. Fixture、探针与验证记录

- fixture 只能使用 `example.invalid`、虚构标识和自写文本；不保存现场响应 body。
- 现场探针不得打印 BVID、CID、标题、字幕/弹幕正文、完整 URL、用户标识或凭据。
- AI 音轨探针还不得打印语言标题、媒体 host、具体系统菜单文案或响应正文；只允许记录目录、
  AAC、生产语义轨、系统选项、I-frame variant 与实际 playurl 请求的有界计数，以及
  production type 集合、语言／production type 是否回显匹配、请求是否未重复、来源集合是否
  变化、SIDX／I-frame playlist 是否可读、系统名称是否为友好语义、media selection／
  A → B → A 是否完成、loopback 是否清理，以及媒体请求是否无 Cookie／Authorization。
- UP 主签名探针不得打印 MID、签名正文或完整 URL；只记录 HTTP／业务分类、MID 是否匹配、
  签名是否存在与长度区间。
- 验证记录可保存日期、系统、接口路径、认证需求、Content-Type、大小级别、字段名、计数和安全分类。
- 真实 UI 截图若包含标题、账号、二维码、字幕或弹幕正文，不进入仓库。

## 6. Gate

M4.0 已形成匿名与已登录边界、字幕正文来源、二进制弹幕响应、负向 fixture、依赖选择和清理规则的可重复基线，因此允许进入 M4.1。该结论只关闭实现前 Gate，不证明远端接口长期稳定，也不替代 M4.2/M4.3 必须使用这些 fixture 固定的生产 decoder 负向测试。

M4.2 已将字幕负向 fixture 接入生产 decoder。字幕目录最初使用 `/x/player/v2`；2026-07-26 根据真实错配观察与多个独立客户端的既有修复迁移到精确授权的 `/x/player/wbi/v2`。字幕 URL 不离开 `BiliAPI`；正文只能由无 Cookie、无缓存、拒绝重定向的专用 ephemeral transport 请求；当前只允许 `https://aisubtitle.hdslb.com:443/bfs/...`。轨道、cue 与播放 identity 只存在于内存；`AVPlayerEngine` 是原生字幕 item、loopback route 与 server 的唯一 owner，切换视频、分 P、关闭详情或登出都会通过 stop/generation 清除旧状态。

现场目录可能包含 `subtitle_url` 为空字符串的不可用占位轨。生产 decoder 只忽略这种明确无正文来源的条目；非空但无法解析、来源不可信或字段异常的条目仍使整个目录失败关闭。探针必须实际出现生产 decoder 的 ready 标志，不能把“全部轨道均为空占位”造成的 skip 当作 Gate 通过。

M4.3 的 protobuf wire 类型只存在于 `BiliAPI` 解码边界；映射后的 `DanmakuEvent` 不保留发送者 hash、创建时间、action 或原始 wire。分段正文、事件 ID 和过滤关键词只存在于当前进程内存。会话最多并发 2 个分段请求并保留 3 段；切换 identity、stop 和 discontinuity 会取消或隔离旧任务与游标。历史一次性 probe 已删除；当前确定性测试只固定 decoder、调度、identity 与清理契约。

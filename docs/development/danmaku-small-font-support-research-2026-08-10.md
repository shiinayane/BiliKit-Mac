# 弹幕小字号支持调研（2026-08-10）

> 范围：只读代码与公开 Web 资源调研；没有登录、读取凭据、发送弹幕或保存远端响应。
> 本文不是实现授权，不更新 `ROADMAP.md` 完成状态。

## 结论

“小字号”必须拆成两个能力：

1. **按收到的字号渲染**：当前数据链路已经保留字号，但生产 renderer 没有使用它。这个能力
   可以在不增加写操作的独立显示正确性切片中安全支持。
2. **选择小字号并发送**：当前仓库没有弹幕草稿、发送 Use Case、写 Repository、POST
   endpoint 或发送 UI；现行路线图也没有授权该写操作。现在不应实现，应延期到独立写操作
   milestone，先完成产品范围、协议、认证和风控 Gate。

公开证据支持 `fontsize` 是发送字段、接收 protobuf field 4 是 `font_size`，小字号长期对应
数值 18、标准字号对应 25；36 常见于大字号。但本次没有真实发送，不能把 18/25/36 的
当前服务端接受范围、账号等级权限或失败码宣称为已验证契约。

## 当前 BiliKitMac 能力

### 接收与模型

- clean-room `danmaku.proto` 将 element field 4 定义为 `int32 font_size`。
- `DanmakuPayloadDecoder` 把值限制到 `12...64` 后写入
  `DanmakuEvent.fontSize: Double`；当前 fixture 固定并断言标准值 25。
- decoder 只接受滚动、顶部和底部基础类型；高级、互动、代码和反向类型在 adapter 边界
  丢弃。字号本身不是 mode。

### 渲染

- `CoreAnimationDanmakuRenderer` 测量和生成 attributed string 时都使用固定
  `NSFont.systemFont(ofSize: 24, weight: .semibold)`。
- 因此 `DanmakuEvent.fontSize` 当前是“已解码但未呈现”的字段：收到 18、25 或 36 都按
  24pt 渲染。BiliKitMac **尚不能诚实声称会显示收到的小字弹幕**。
- lane allocator 使用 renderer 的测量结果；未来使用事件字号时，必须让测量、lane 高度、
  碰撞判断和最终 `CATextLayer` 共用同一个规范化字体，不能只缩放最终 layer。

### UI 与写操作

- 当前 `DanmakuControlsView` 只有开关、显示类型、显示区域、密度、滚动速度和透明度；没有
  字号选择，也没有输入框或发送按钮。
- `DanmakuSegmentRepository` 只有只读 `segment(index:for:)`；`BiliAPIClient` 只有弹幕
  分段 GET。仓库中没有 `/x/v2/dm/post`、发送 DTO、CSRF 写授权器或发送失败状态。
- 现有认证边界只允许凭据进入精确批准的读取请求。Feature 不接触 Cookie/token；游客、
  图片、媒体和 loopback 也不能继承认证。

## 2026-08-10 公开 Web 观察

### 官方可观察资源

匿名获取一个公开 B 站视频页时，页面声明当前播放器资源为：

- `https://s1.hdslb.com/bfs/static/player/main/core.238e0712.js`

只读检查该 B 站托管脚本可确认：

- 普通弹幕发送 endpoint 为 `POST https://api.bilibili.com/x/v2/dm/post`；请求设置
  `withCredentials: true`。
- 发送状态默认 `fontsize: 25`。
- 脚本维护 7 个字号权限槽位。普通注册/普通用户只开放相邻的第 3、4 个槽位；VIP、UP 主/
  管理角色和高级权限开放集合不同。因此“大字号是否可选”至少受身份/权限影响，不能只靠
  客户端枚举决定。
- 通用 POST 中间件会从 `bili_jct` 注入 `csrf`；该 endpoint 同时进入播放器的请求治理
  列表。脚本还包含 ticket、指纹和风控相关中间件，说明“有 Cookie + CSRF”不等于请求就
  可以稳定成功。

这份压缩脚本没有给 7 个权限槽位保留可读的语义标签，因此仅凭官方脚本不能严格证明每个
索引对应哪个像素值。B 站站内长期公开资料与当前仓库接收协议一致地把 18/25/36 描述为
小/标准/大；较新的站内界面观察只明确提到“小/正常”两个普通选项。故本调研采用以下
证据分级：

| 判断 | 可信度 | 边界 |
| --- | --- | --- |
| 收发协议存在独立字号字段 | 高 | 官方脚本 + 当前生产 protobuf 解码 |
| 25 是 Web 默认/标准字号 | 高 | 官方脚本默认值 + 当前 fixture |
| 18 是小字号，36 是大字号 | 中高 | B 站站内长期资料交叉一致；本次未发送验证 |
| 普通账号当前可发送大字号 | 未确认 | 官方权限数组显示身份差异，但语义索引已压缩 |
| POST 当前需要 WBI `w_rid/wts` | 未确认 | 当前脚本可见请求治理，但本次未观察实际网络请求 |
| 当前频率限制、审核与风控失败码 | 未确认 | 未登录、未发送，不能复用旧经验冒充当前契约 |

公开参考：

- [B 站公开视频页](https://www.bilibili.com/video/BV1xx411c7mD/)
- [该页面声明的 B 站播放器脚本](https://s1.hdslb.com/bfs/static/player/main/core.238e0712.js)
- [B 站站内 2020 年发送字段观察](https://www.bilibili.com/opus/387946262497681345)
- [B 站站内 2023 年弹幕字号结构说明](https://www.bilibili.com/opus/772763602867191830)

站内文章是用户内容，不是官方 API 文档，只用于解释官方压缩脚本中缺失的语义标签。发送
实现前仍必须重新观察当前官方客户端的实际请求，并用全假值 contract 固定允许集合。

## 可安全实施的拆分

### A. 只呈现收到的小字号

建议作为独立只读切片，且在当前唯一产品阶段完成或重新裁决后再排期：

1. 在 `BiliModels` 将任意 `Double` 收敛成有界的 presentation size，或在 `BiliAPI`
   映射为明确的受支持字号值；不要让 renderer 再做一套不一致的 clamp。
2. `CoreAnimationDanmakuRenderer` 的 CoreText 测量和 attributed string 使用同一事件字号。
3. 重新验证 lane 高度、滚动碰撞、顶部/底部锚定、显示区域、resize、对象上限与长文本上限。
4. 远端异常字号继续失败关闭或按已批准规则规范化；不能让超大字号绕过 512px 高度、
   8192px 宽度和 active layer 上限。

这不需要新增账号权限、endpoint 或 Cookie，但会改变真实视觉密度，不能只用 build 证明。

### B. 用户选择小字号并发送

若未来进入路线图，至少需要：

- **模型/Application**：`DanmakuDraft`、离散字号枚举（不要暴露任意 `Int`）、文本/时间/
  mode/color/pool 限制、`SendDanmakuUseCase`、可取消且防重复提交的状态机。
- **API**：用途专属 `POST /x/v2/dm/post` adapter，精确 host/path/method/content-type/字段
  allowlist，响应大小与 JSON 业务码校验，拒绝重定向；先确认是否需要 WBI/ticket/设备字段，
  证据不足时失败关闭。
- **认证**：由 `BiliAuth` 的新写授权器在最后一跳注入最小 Cookie 与 CSRF；Feature、draft、
  日志和 fixture 不得持有凭据。游客或凭据损坏不能匿名发送，也不能自动扩大 Cookie 集合。
- **UI**：明确账号/等级能力、字符计数、发送中防连点、成功/审核中/被拒绝/风控/登录失效/
  网络不确定状态；“超时”不能直接当失败重发，否则可能重复发送。
- **生命周期**：发送意图绑定 `(bvid, cid)` 与当前 progress generation；切 P、换视频、返回、
  登出时取消未发请求。服务器已受理但客户端丢失响应时，必须呈现结果未知而不是自动重试。
- **隐私与治理**：不持久化草稿正文、发送历史、完整 URL 或响应；需要新的写操作威胁模型、
  审核/频率限制/服务条款评估与显式真实账号验证授权。

## 失败路径与测试建议

### 只读呈现

- decoder：18/25/36、边界 12/64、越界、缺省 0、超大文本组合；明确 clamp 或拒绝策略。
- renderer：同一 event 的测量字体等于渲染字体；18 小于 25、36 大于 25；三种 mode 的 lane
  和锚点不重叠越界；resize/seek/替换/stop 后无残留 layer。
- UI/性能：合成 fixture 对比 18/25/36 的可见大小；高密度 30 分钟对象与 layer 上限；大
  文字、Reduce Motion、VoiceOver 不因弹幕字号功能退化。

### 发送（未来）

- contract：只允许离散字号，精确字段、POST、来源、CSRF 注入位置；Cookie 不进入 GET
  游客、媒体、图片或 loopback。
- 状态：401/登录失效、403/412/业务拒绝、频率限制、审核、超时、取消、响应丢失、重复点击、
  A→B→A 迟到结果与 logout 清理。
- fixture：全部使用虚构 identity/text 和 `example.invalid`，不保存真实请求或响应。
- 真实验证：另行取得用户授权后，使用专用测试账号和一条明确允许测试的内容；记录字段名、
  状态分类和计数，不记录正文、Cookie/token、完整认证 URL 或完整响应。

## 建议

- **现在不做发送。** 它是新的认证写操作和产品范围，不是“小字号 UI”附带的一行参数。
- **拆分两个 milestone。** 先把收到的字号正确呈现，作为只读播放正确性；发送能力只有在
  被选为唯一下一阶段、更新产品愿景/路线图并建立写操作威胁模型后再实施。
- 若只想让用户整体缩放所有弹幕，那是本地显示偏好，与“按发送者选择的小字号呈现”及
  “发送小字号”是第三个不同需求，应单独命名，避免复用 `fontSize` 造成语义混淆。

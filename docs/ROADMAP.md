# BiliKit macOS 路线图

> 更新时间：2026-07-26。本文只描述当前 `main` 的产品基线、尚未完成的结果和实施顺序。
> 完成状态以当前代码、自动测试和必要的真实行为证据共同判断；旧计划、分支、worktree、
> checkpoint、测试数量和 CI run ID 不构成现行契约。

## 1. 产品目标

BiliKit 是 macOS-first 的原生第三方 B 站浏览与播放客户端。v1 要形成稳定的日常观看
闭环：

```text
首页个性推荐
  → 同窗口视频页
  → 播放 + 字幕 + 弹幕
  → 相关推荐连续观看
  → 返回并恢复真实来源上下文
```

“热门”继续作为公共发现入口，不能冒充个性推荐首页。详细产品优先级见
[`product/PRODUCT-VISION.md`](./product/PRODUCT-VISION.md)，界面方向见
[`product/UIUX-VISION.md`](./product/UIUX-VISION.md)。

## 2. 当前工程基线

- Swift 6、SwiftUI、AVPlayer-first，最低 macOS 15。
- 一个本地 Swift Package，App target 负责 Scene、产品级导航、Composition 和 macOS 宿主。
- Feature 按 Browse、Auth、Library 产品域组织；跨域跳转由 App 层协调。
- Application 只暴露 use case、port 和平台无关状态；API、认证、播放与弹幕实现位于各自
  adapter target。
- 当前产品入口包含热门、搜索、观看历史、认证和同窗口视频页。
- 播放链路包含 DASH 到本机 loopback HLS bridge、单一 AVPlayer host、统一播放时间线、
  字幕与弹幕。

模块与依赖的持久约束见 ADR 0001–0009。当前 target、product 和 entitlement 必须以
`Packages/BiliKitCore/Package.swift` 与 Xcode 工程为准。

## 3. 已完成能力

### M0–M2：工程、真实播放与游客闭环

- 工程、模块、CI 和最低平台基线已建立。
- 游客热门、WBI 搜索、详情、分 P 和真实播放纵向链路已接通。
- loopback 播放 bridge 的 Range、seek、替换与清理边界已有受控测试和真实样本证据。

证据：

- [`validation/M1-real-playback-2026-07-21.md`](./validation/M1-real-playback-2026-07-21.md)
- [`validation/M2-guest-api-2026-07-21.md`](./validation/M2-guest-api-2026-07-21.md)

### M3：认证与观看历史

- Web QR 登录使用独立 ephemeral session、精确来源和重定向策略、状态与次数/总时限上限。
- 凭据只进入 `BiliAuth` 内存与 Data Protection Keychain；恢复、失效和离线本地登出有
  明确清理语义。
- 观看历史通过只读授权 endpoint 接入，游客链路不携带认证信息。
- 真实扫码、重启恢复、历史读取、进入播放、登出和再次启动后的游客回退已完成受控验证。

证据：

- [`validation/M3-auth-contract-research-2026-07-21.md`](./validation/M3-auth-contract-research-2026-07-21.md)
- [`validation/M3-keychain-authorization-2026-07-21.md`](./validation/M3-keychain-authorization-2026-07-21.md)
- [`validation/M3-watch-history-2026-07-21.md`](./validation/M3-watch-history-2026-07-21.md)
- [`security/M3-threat-model.md`](./security/M3-threat-model.md)

### M4：字幕、弹幕与播放生命周期

- 播放器向上提供唯一 identity、位置、时长、速率、状态和 discontinuity generation。
- 字幕目录、正文解析、切轨、暂停、倍速、seek、替换与迟到结果隔离已接通。
- 弹幕 protobuf decoder、分段调度、有界预取/缓存/去重和 Core Animation renderer 已接通。
- 播放替换、窗口关闭和 stop 后的任务、订阅、server、renderer 与 layer 清理已有受控证据。

证据：

- [`validation/M4-protocol-contract-2026-07-22.md`](./validation/M4-protocol-contract-2026-07-22.md)
- [`validation/M4-playback-timeline-2026-07-22.md`](./validation/M4-playback-timeline-2026-07-22.md)
- [`validation/M4-subtitle-vertical-slice-2026-07-22.md`](./validation/M4-subtitle-vertical-slice-2026-07-22.md)
- [`validation/M4-danmaku-data-scheduler-2026-07-22.md`](./validation/M4-danmaku-data-scheduler-2026-07-22.md)
- [`validation/M4.4-renderer-production-2026-07-23.md`](./validation/M4.4-renderer-production-2026-07-23.md)
- [`validation/M4-closeout-2026-07-23.md`](./validation/M4-closeout-2026-07-23.md)
- [`validation/M4.6-subtitle-lifecycle-roadmap-2026-07-25.md`](./validation/M4.6-subtitle-lifecycle-roadmap-2026-07-25.md)
- [`security/M4-data-privacy.md`](./security/M4-data-privacy.md)

### M4.5：macOS 界面基线

- App 使用侧栏与主内容两栏外壳，热门、搜索与观看历史共享窄 `BiliUI` 视频卡片边界。
- 视频进入同窗口独立播放页；播放页在紧凑与宽布局间保持单一 player host。
- 键盘返回、搜索提交、焦点、辅助标签、深色与大字体的核心路径已有自动和真实 UI 观察。

证据：

- [`validation/M4.5-slice-b-2026-07-24.md`](./validation/M4.5-slice-b-2026-07-24.md)
- [`validation/M4.5-slice-c-2026-07-25.md`](./validation/M4.5-slice-c-2026-07-25.md)
- [`validation/M4.5-high-refresh-card-scroll-2026-07-24.md`](./validation/M4.5-high-refresh-card-scroll-2026-07-24.md)

## 4. 当前实施队列

### M5.0：日用状态保留与真实返回上下文

状态：进行中；2026-07-26 已开始原生导航与窗口内工作集切片，M5.0 Gate 尚未关闭。

目标：

- 普通 tab 往返或从视频页返回时，已成功内容立即可见，不自动重复请求。
- 恢复用户离开前可识别的真实视图上下文，不以“选中项重新可见”替代滚动/视口结果。
- 刷新是独立意图；刷新中保留旧内容，失败不清空仍有效的同一 identity 数据。
- route、query、刷新和关窗后的迟到结果不能覆盖当前状态。

当前 revision 已选择 macOS 15 `TabView(.sidebarAdaptable)` 表达搜索／热门／历史三个
平级来源，每个 Tab 内以 `NavigationStack(path:)` 推入类型化播放 destination，系统
pop 负责返回。App 不再用 `AppRoute` 和 `AppReturnSnapshot` 重建来源页面；热门／最后
搜索分别从 Browse Feature 的每窗口双工作集读取 presentation，Tab 与
`NavigationStack` 负责来源返回；App shell 为热门、搜索和历史各持有一个以视频
identity 为目标的原生 `ScrollPosition`，不再维护数值 offset。新搜索词或登录身份
变化会重置对应位置，同一工作集的 Tab 往返继续保留。视频卡片不再具有持久 selected
API 或高亮分支。完整边界见
[`development/M5.0-daily-client-state-retention-decision.md`](./development/M5.0-daily-client-state-retention-decision.md)。

完成证据至少包括确定性请求/取消测试，以及热门、搜索、tab 往返、视频进入/返回和窗口
尺寸变化的真实 UI 路径。首次修复不引入数据库、通用 cache、图片 pipeline 或媒体缓存。
当前定向 Package/App 测试已通过；未签名 fixture XCUI runner 在 worker 启动阶段
阻塞，签名 runner 能启动测试但 App 激活停在 `Running Background`，均未进入用户
路径，尚不能作为 UI 通过证据。完整 App Gate 已通过；直接 UI 验收、review 与 CI
仍待完成。

### M5.1：首页个性推荐

状态：等待 M5.0。

- 对 App 端与 Web 端候选做最小、脱敏的结构和登录边界比较。
- 只选择一个生产来源；热门不能作为推荐 fallback 或完成证据。
- 首页使用稳定 item identity、明确刷新/追加/失败语义和有界内存工作集。
- 接入前补充 endpoint DTO、来源策略、取消、分页和真实样本验证。

### M5.2：相关推荐与连续观看

状态：等待 M5.1。

- 视频页取得真实相关推荐并支持 A → B → C 同窗口切换。
- 保持单一 player host；新 identity 必须取消并隔离旧详情、媒体、字幕、弹幕和推荐结果。
- 返回来源页面时仍满足 M5.0 的上下文恢复结果。

### M5.3：核心播放缺口

状态：按真实日用反馈选择，不预建功能。

只处理阻塞 v1 闭环的最窄控制或交互缺口。独立播放器、mini player、画中画、完整媒体键、
拖入 URL 和高级窗口恢复默认进入 v1.1 候选。

### M6：v1 发布准备

状态：等待 M5 核心闭环。

- 对支持的 macOS 版本和目标硬件完成签名、权限、Keychain、播放、字幕、弹幕、窗口与
  辅助功能回归。
- 固定隐私说明、第三方许可、非官方品牌边界、失败文案和日志脱敏。
- 验证归档、升级、卸载和本地数据清理边界。
- 只有代码、自动 Gate、真实行为与发布文档一致时才形成可发布候选。

## 5. v1 非目标

- 下载、转码、媒体导出和离线媒体库。
- 直播。
- 多账号。
- 区域解锁、DRM 绕过或权限规避。
- 评论、关注、收藏、稍后再看等写操作。
- 服务端观看进度写入和完整评论阅读；它们是独立的 v1.1 候选。

新增目标必须先更新产品范围和路线图，不能通过顺手增加 endpoint、占位 target 或通用
基础设施进入当前实现。

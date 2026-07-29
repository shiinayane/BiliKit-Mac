# BiliKit macOS 路线图

> 更新时间：2026-07-29。本文只描述当前 `main` 的产品基线、产品大方向和唯一已选择的
> 后续阶段。
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

### M5.0–M5.0.1：原生日用导航与外部事实审计

- 热门、搜索与历史使用原生平级导航；视频页使用系统层级返回并保留来源工作集和语义
  滚动位置。
- 播放退出、卡片选中残留、字幕默认行为、自动画质与相关生命周期缺口已经过定点修复。
- 外部 API、媒体、认证、并发、原生 UI、缓存、辅助功能、性能、架构与分发已完成
  M5.0.1 审计；尚未实施的判断不因审计完成自动进入生产。

证据：

- [`development/M5.0-daily-client-state-retention-decision.md`](./development/M5.0-daily-client-state-retention-decision.md)
- [`validation/M5.0-native-navigation-state-retention-2026-07-26.md`](./validation/M5.0-native-navigation-state-retention-2026-07-26.md)
- [`audits/M5.0.1/`](./audits/M5.0.1/)

## 4. 后续方向

下一阶段尚未选择，不以旧编号或旧顺序自动启动。确定下一项后，本节只展开该一个阶段的
用户结果、进入条件与完成证据；完成或重新裁决后再替换，不提前书写更后面的 phase。

已经确认但尚未排期的事项统一登记在
[`product/PRODUCT-CANDIDATES.md`](./product/PRODUCT-CANDIDATES.md)。候选登记不表示顺序、
版本承诺或实施授权。

长期方向仍包括：

- 个性推荐首页，复用现有响应式视频网格；
- 相关推荐与同窗口连续观看；
- 日用播放体验收口；
- v1 发布准备。

## 5. v1 非目标

- 下载、转码、媒体导出和离线媒体库。
- 直播。
- 多账号。
- 区域解锁、DRM 绕过或权限规避。
- 评论、关注、收藏、稍后再看等写操作。
- 服务端观看进度写入和完整评论阅读；它们是独立的 v1.1 候选。

新增产品范围必须先更新产品愿景；已经接受但尚未排期的事项进入候选登记。只有被选为
唯一下一阶段时才更新本路线图，不能通过顺手增加 endpoint、占位 target 或通用基础设施
进入当前实现。

# BiliKit macOS 路线图

> 更新时间：2026-08-25。本文只记录当前产品基线、唯一正在推进的阶段和非目标。历史阶段过程由
> Git 历史和 `evidence/` 中的带日期摘要承担，不再在路线图中逐阶段复述。

## 产品目标

BiliKit 是原生、macOS-first、非官方的 B 站浏览与播放客户端。V1 的日用闭环是：

```text
首页个性推荐／热门／搜索／观看历史
→ 同窗口视频页
→ 播放 + 字幕 + 弹幕 + 分 P + 只读评论
→ 登录后自动同步服务端观看进度
→ 相关推荐连续观看
→ 返回并恢复来源上下文
```

产品结果和界面方向分别见 [`product/PRODUCT-VISION.md`](./product/PRODUCT-VISION.md) 与
[`product/UIUX-VISION.md`](./product/UIUX-VISION.md)。

## 当前产品与工程基线

- Swift 6、SwiftUI、AppKit 与 AVPlayer-first，最低 macOS 15。
- V1 Developer ID 成品冻结为 `arm64 + x86_64` Universal App；无签名 Release 双 slice 已验证，
  真实 Intel macOS 15 关键路径仍是发布 Gate。
- 首页个性推荐、热门、搜索、二维码登录、观看历史和各自窗口内工作集已经接入；普通切换和从播放页
  返回不会把已成功内容退回首次加载。
- 视频页保持单一 player host，支持分 P、自动画质、seek、倍速、系统字幕、弹幕、语义音轨、
  Now Playing、全屏与 PiP 边界。
- 只读评论覆盖排序、主评论分页、楼中楼、图片和受控外链；评论失败不阻断播放。
- 相关推荐位于详情页横向 shelf，可在同一窗口连续切换视频并隔离旧详情、媒体、字幕、弹幕和评论结果。
- Cookie 只进入 `BiliAuth` 的短生命周期内存与 Data Protection Keychain；游客、图片、媒体 CDN、
  字幕正文和 `127.0.0.1` loopback 不持有认证授权器。
- 登录播放默认通过 V1 唯一获批的认证写能力同步服务端观看记录，不提供关闭选项；游客、凭据故障、
  风控或上报失败保持播放可用，不建立离线队列，也不把观看 identity 或位置写入本地持久化。
- 播放线路与测速为用户显式选择的实验能力，不自动改线、不保存测速结果；macOS 26 的响度均一化
  同样为默认关闭的实验能力。

当前 target、product、依赖和 entitlement 以 `Packages/BiliKitCore/Package.swift`、Xcode 工程与
质量 Gate 为准；本文不复制易漂移的源码行号或测试数量。持久架构与安全决策见 ADR 0001–0013。

## 唯一当前阶段：V1 观看历史闭环与 Developer ID 发布准备

当前只新增登录播放的服务端观看进度同步，然后把完整 V1 闭环变成可验证、可安装和可恢复的站外
分发成品。该能力是 V1 唯一认证写操作，不借机增加其他写 endpoint 或通用写入基础设施。

观看历史写入基线：

1. 只允许 `POST https://api.bilibili.com:443/x/click-interface/web/heartbeat`，首版仅普通投稿视频；
2. `BiliAPI` 固定 endpoint、WBI query 与非秘密表单，`BiliAuth` 独立复核精确写能力并只注入
   `SESSDATA` 与 CSRF；
3. 开始立即发送，播放中每 15 秒发送，暂停、恢复、自然结束与退出边界即时发送；进程 writer
   单并发，窗口 owner 有界合并周期和高频中间状态，但最终退出边界始终保留；
4. 游客不创建写意图；失败不影响 AVPlayer，不持久化待上报位置，不离线重放，不记录请求正文；
5. 2026-08-24 spike 与 2026-08-25 当前 Debug 生产实现均由用户完成有界真实可见性验证；后者确认
   开始、暂停、退出、15 秒周期及 Web/BiliKit 历史一致。后续协议或发送时机变化必须重新申请授权。

已完成：

- 稳定产品标识候选为 `com.shiinayane.BiliKit`，Team 为 `2B3LZ256AG`；
- `1.0.0 (1)`、版权、类别、Privacy Manifest 与 Universal Release 配置已进入工程；
- 当前发布 Mac 已有有效 Developer ID Application identity；
- `BiliKit-Notary` 公证凭据已通过 Apple 服务端 validation；
- 公开分发、隐私、安全报告草案和发布 manifest 模板已经建立。

当前硬阻塞：

- explicit App ID `com.shiinayane.BiliKit` 在 Apple 服务端不可用；当前 Team 只有 wildcard App ID，
  Apple Developer Support 工单正在调查旧 Personal Team／残留登记。不得以改 Bundle ID 或 wildcard
  profile 绕过稳定身份裁决。

工单解决后的发布 Gate：

1. 注册并核对 explicit App ID、AppIdentifierPrefix、capabilities 与最终 Keychain access group；
2. 从干净 commit 生成 Release archive，使用 Developer ID Application 导出并逐项检查双架构、
   签名、Hardened Runtime、secure timestamp、entitlements 和嵌套代码；
3. 公证并 staple App，制作只含已验 App 与 Applications 快捷方式的只读 DMG；
4. 签名、公证、staple 和 validate 最终 DMG，记录最终 SHA-256；
5. 从真实 HTTPS 浏览器下载，在 Apple Silicon 与真实 Intel macOS 15 上验证 Gatekeeper、登录、
   Keychain、loopback 播放、字幕／弹幕、升级、删除与重装；
6. 完成不含更新器的 Developer ID 基线后，再裁决是否在同一 V1 接入 Sparkle。Cloudflare Worker
   默认不部署，只有静态 appcast 的域名稳定性或故障隔离出现真实需求时才重新立项。

执行顺序和停止条件见 [`release/README.md`](./release/README.md) 与
[`release/CHECKLIST.md`](./release/CHECKLIST.md)。

## V1 非目标

- 下载、转码、媒体导出和离线媒体库；
- 直播；
- 多账号；
- 区域解锁、DRM 绕过或权限规避；
- 评论、关注、收藏、稍后再看等写操作；
- 自研更新器、自动降级和未验证的 Cloudflare 下载代理。

新增产品范围必须先更新产品愿景；已确认但未排期的用户结果进入
[`product/PRODUCT-CANDIDATES.md`](./product/PRODUCT-CANDIDATES.md)，不能通过顺手增加 endpoint、
占位 target 或通用基础设施进入当前阶段。

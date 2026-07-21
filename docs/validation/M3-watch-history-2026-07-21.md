# M3 观看历史纵向闭环与最终实机验证（2026-07-21）

> 结论：观看历史已按 Domain → Application → Feature MVVM → App composition root 接入；当前 macOS 的真实扫码、历史读取、详情/播放器跳转、进程重启恢复、界面登出与游客回退全部通过，随后 macOS 15/26 CI 也已通过。本记录证明当时纵向链路；后续独立审查发现的安全与状态机阻断仍须另行整改。

## 1. 选择范围

M3 的首个个性化功能选择“观看历史”，理由是它是只读 GET 链路，不引入 CSRF 写操作、收藏状态同步或业务持久化。实现只映射可由现有游客详情/播放链处理的 `archive` 条目；其他业务类型安全跳过。

依赖落点如下：

- `BiliModels`：`WatchHistoryItem`、分页 cursor 与 page。
- `BiliApplication`：`WatchHistoryRepository`、安全错误与 `WatchHistoryUseCase`。
- `BiliAPI`：独立 endpoint payload、DTO 映射和 `BiliWatchHistoryRepository` adapter。
- `BiliHistoryFeature`：拥有加载、刷新、分页、取消与旧结果隔离的 ViewModel，以及不接触 Cookie 的 SwiftUI sheet。
- App composition root：让同一个 `BiliAPIClient` 分别服务游客与历史 port，并把历史条目交回既有详情/播放器 ViewModel。

历史 sheet 关闭或登出时会取消任务并清空个性化列表；不会把标题、BVID、观看时间或进度写入 UserDefaults、SwiftData、fixture 或日志。

## 2. endpoint 与授权边界

匿名请求 `GET /x/web-interface/history/cursor` 的现场结果为 API code `-101`、账号未登录。成功 contract 使用全假值手写 fixture，不保存真实响应 body。

授权器只接受以下精确请求：

- HTTPS、`api.bilibili.com`、GET、无 user info 与 fragment；
- 路径精确为 `/x/web-interface/history/cursor`；
- query 只能且必须包含唯一的 `max`、`view_at`、`business`、`ps`；
- cursor 非负，`ps` 为 1～50，`business` 只接受有限 ASCII 字母数字。

游客 endpoint 不调用授权器；历史 endpoint 缺少授权器时在 transport 前失败关闭。登出会失效历史/API 的 ephemeral transport 并用全新、无 Cookie storage/cache、拒绝重定向的 session 替换。

真实签名 App 首次运行时还发现 App Sandbox 缺少网络 entitlement：无签名构建会掩盖该问题。最终 entitlement 增加 `network.client` 供 API/CDN 请求使用，增加 `network.server` 供只绑定 loopback 的播放桥监听；Keychain access group 保持不变。

## 3. 自动化结果

当前开发机结果：

- 107 项 Package 测试、20 个测试套件全部通过。
- 历史 contract 覆盖显式授权、archive 过滤、字段映射、分页、游客请求不授权和无授权器失败关闭。
- History Use Case/ViewModel 覆盖输入、分页去重、认证失效、旧请求隔离、加载中 reset 与个性化数据清空。
- 登出顺序测试新增 API session invalidation，并覆盖 Keychain 删除失败时仍失效 session、但不能伪装成已退出。
- 架构边界、秘密模式与 `git diff --check` 通过。
- deployment target macOS 15 的 App 无签名 `build-for-testing` 与 composition 测试通过。
- Apple Development 签名宿主的 Data Protection Keychain add/update/read/delete 与最终清理通过。

签名调试期间需要为私钥设置包含 `apple:` 的 key partition list，才能让 `/usr/bin/codesign` 使用该私钥。这属于本机开发证书配置，不进入仓库或产品运行要求。

## 4. 当前 macOS 真实 UI 验证

使用本次 Apple Development 签名的 arm64 Debug App 完成：

1. 通过内存二维码真实扫码并在手机客户端确认；App 在 nav 校验和 Keychain 提交后进入已登录。
2. 打开观看历史；列表返回 20 个 archive 行和分页入口，没有认证失效、风控或解码错误。
3. 选择首个可见历史条目；历史 sheet 关闭，既有详情与系统播放器时间轴出现。
4. 完全退出进程并重新启动；账号由 Keychain 恢复为已登录，历史 endpoint 再次成功读取 20 行。
5. 从账号 sheet 执行退出登录；界面回到未登录，无删除错误。
6. 再次完全退出并启动；恢复结果保持未登录。
7. 未登录时点击观看历史只打开登录入口，不暴露上次历史列表；游客主界面仍可使用。

验证只记录状态、行数和结构结果；没有输出、截图、复制或保存二维码、UID、昵称、标题、BVID、Cookie、token 或响应 body。

## 5. 适用边界

- 观看历史是未公开 Web endpoint，字段和风控策略可能漂移；真实响应异常时必须经 adapter 映射为安全错误，不得把 body 打进日志。
- 当前只映射普通视频 archive，不承诺番剧、直播、课程或其他业务类型。
- 本记录对应的 macOS 15/26 Package、架构、秘密扫描与 App 无签名构建随后通过；无签名 CI 不覆盖真实 Keychain entitlement。
- 2026-07-21 后续独立审查发现：媒体 URL/重定向来源策略不足、恢复失败无清除坏凭据出口、QR 轮询无本地总时限，以及 archive 过滤后的空首页隐藏分页入口。它们不否定本记录中的实机观察，但在修复与回归前阻止 M3 关闭。

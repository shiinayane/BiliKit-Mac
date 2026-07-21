# M3 独立审查整改验证（2026-07-22）

> 结论：四项 M3 收口阻断与两项结构清理已在当前 Apple Silicon Mac 完成实现和本地回归。当前变更集尚未提交，macOS 15/26 远程 CI 仍待确认；确认前 M3 保持“等待关闭”。

## 1. 整改范围

本轮只处理 2026-07-21 独立审查记录的事项，没有开始 M4、SwiftData 或 UI/UX 精修：

1. 为播放媒体 URL 增加用途专属来源策略；只接受 HTTPS、默认或 443 端口、无 userinfo/fragment、非本机地址，且主机属于已审计媒体家族。Range session 使用 ephemeral 配置、禁用 Cookie/cache，并拒绝重定向。
2. 恢复登录失败状态增加显式“清除本机登录状态”出口，复用完整本地登出流程，不直接在 Feature 接触 Keychain。
3. QR 轮询增加可注入的总时限与最大次数；本地上限触发后取消 challenge、清空二维码并进入过期状态。
4. 观看历史过滤出空页时由 Use Case 有上限地继续翻页；达到上限仍保留 continuation 和显式“加载更早的记录”入口，非前进令牌失败关闭。
5. 将远端观看历史 cursor 字段从 Domain/Application 公共模型移入 `BiliAPI`；Application 与 Feature 只持有不可读、只能回传的 `WatchHistoryContinuation`。
6. 增加 `Scripts/check-project-contract.sh` 并接入 CI，固定 App Debug/Release entitlement、Sandbox、产品名、bundle identifier、三个产品域 Feature product 和 macOS 15 deployment target。

## 2. 自动化验证

环境：当前 Apple Silicon Mac；命令显式使用 `/Applications/Xcode.app/Contents/Developer`。SwiftPM/Clang module cache 放在 `/tmp`；这是本机沙箱运行约束，不改变测试内容。

- `xcrun swift test --package-path Packages/BiliKitCore`：118 项测试、21 个套件全部通过。
- 新增或扩充的负向覆盖包括：不可信媒体主机、loopback、明文 HTTP、userinfo、异常端口、fragment、Range transport 前置拒绝、playurl 全部不可信时失败关闭、畸形 history continuation 在 transport 前拒绝。
- Auth Feature 覆盖恢复失败后的本地清除，以及轮询次数上限触发取消和二维码清理。
- History Use Case/Feature 覆盖连续过滤空页、有界扫描、保留手动 continuation 与非前进令牌。
- `Scripts/check-architecture.sh`：通过。
- `Scripts/check-secrets.sh`：通过。
- `Scripts/check-project-contract.sh`：通过。
- `git diff --check`：通过。
- macOS 15 deployment target、`CODE_SIGNING_ALLOWED=NO` 的 App `build-for-testing`：通过。
- `test-without-building -only-testing:BiliKitMacTests`：composition test 通过；签名 Keychain smoke 因无签名按设计跳过，未计作真实 Keychain 证据。

## 3. 真实播放回归

使用仓库既有公开游客样本运行最小真实播放探针，不记录内容标识、完整媒体 URL 或响应 body。结果：

- playurl 返回的 AVC 与 AAC 候选分别落在专用 Bilibili 媒体域和受限 `upos-*` Akamai 媒体域，两类均通过新来源策略；
- AVPlayer 到达 `readyToPlay`，完成 1 秒初始播放、一次向前 seek、一次回到起点 seek；
- 采集 36 个视频时间线样本，最大偏差 0.03 秒；
- 探针结果为 `PASS`。

这次运行证明当前样本与 allowlist 兼容，不承诺未公开 playurl 永不新增 CDN 家族。新家族必须通过现场观察、最窄规则和负向测试后加入，不能退回任意公网主机。

## 4. 仍未覆盖的边界

- 当前变更集尚未提交推送，因此 GitHub Actions 的 macOS 15/26 矩阵不是本次代码的证据。远端矩阵通过后才能正式关闭 M3。
- 本轮没有重复真实扫码、账号历史读取或签名 Keychain 往返；这些纵向 Gate 已有 2026-07-21 的受控记录。本轮触及的新增状态和分页行为由 deterministic tests 固定。
- `PublicHTTPSURLPolicy` 不执行任意 DNS 解析后的私网判定。播放入口在其上叠加专用媒体主机 allowlist，并拒绝重定向，因此未审计域名不能进入 transport；这不是可复用于任意用户输入 URL 的通用 SSRF 证明。
- 无签名 App 构建不能证明 entitlement 在签名产物中的实际执行效果。静态契约只防止配置漂移，真实签名 Keychain smoke 仍是受控发布 Gate。

## 5. M3 关闭条件

本地实现和回归已经满足审查整改要求。剩余动作是提交、推送并确认当前变更集的 macOS 15/26 CI；该动作需要用户明确授权。CI 通过后可把 M3 标为完成，并进入 M4 实施计划阶段。

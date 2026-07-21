# M3 进入 M4 前的架构审查与领域 Feature 整理（2026-07-21）

> 结论：三路独立只读审查完成；产品领域 Feature target 整理与 Application 二维码平台边界修复已经通过本地 Package/App 验证。审查同时发现 4 项 M3 收口阻断，整改前不关闭 M3。

## 1. 审查范围

审查覆盖：

- SwiftPM/Xcode target 与 Clean Architecture 依赖方向；
- Browse、Auth、History 的 SwiftUI/MVVM 状态与取消；
- Web QR、Cookie 授权、Keychain、ephemeral session、媒体 Range 与 loopback 边界；
- Package/App 测试、GitHub Actions、架构/秘密脚本、README、ADR、威胁模型和路线图。

审查未修改或采集真实账号、历史内容、二维码、Cookie、token、BVID 或响应 body。

## 2. 架构决定与实施

- 接受 ADR 0006，将 `BiliGuestFeature` 重命名为 `BiliBrowseFeature`，将 `BiliHistoryFeature` 重命名为 `BiliLibraryFeature`，`BiliAuthFeature` 保持领域名称。
- Browse target 按 BrowseScene、Feed、Search、VideoDetail 划分；Library 当前只有 History，Auth 当前只有 Authentication。没有创建 Favorites、WatchLater 或 DesignSystem 占位目录/target。
- 原 359 行浏览场景拆为领域场景、热门、搜索、详情与失败展示文件；ViewModel、Use Case 和用户行为不变。
- SwiftPM product、测试 target、Xcode package product、App imports、composition test 与架构脚本同步使用新名称。
- `BiliApplication.AuthenticationServicing` 不再暴露 `CGImage`；`BiliAuthFeature` 定义独立的二维码 Presentation port，composition root 把同一个具体 Auth adapter 分别注入状态 port 和图像 port。架构脚本新增 Application 对 CoreGraphics/CoreImage 的禁止导入。
- 根 `AGENTS.md` 成为项目协作规范单一事实源；`CLAUDE.md` 使用相对符号链接，不复制第二份规则。

## 3. 审查发现

关闭 M3 前必须修复：

1. playurl 当前接受任意带 host 的 HTTP/HTTPS 媒体 URL，Range transport 默认可跟随重定向；需要媒体来源与每次重定向策略，拒绝明文、loopback、私网和链路本地目标。
2. 恢复登录失败时服务要求先登出，但界面只有“重试恢复”，用户可能无法清除坏凭据并重新登录。
3. Auth Feature 的 QR 轮询没有本地总时限，只依赖远端返回过期，与威胁模型不一致。
4. 历史 adapter 过滤非 archive 条目后，首页可能为空但仍有下一页 cursor；当前空状态隐藏加载更多入口。

进入 M4 前的后续清理：

- 把 Bilibili wire cursor 从 Domain/Application 公共模型收回 API adapter，改为不透明 continuation token。
- 为 App entitlement 与 PBX product/deployment 设置增加静态契约；无签名 CI 中的 Keychain smoke 会跳过，真实签名往返继续作为受控发布 Gate。
- 在跨域目的地增加前，将 History → VideoDetail 的可选 BVID Binding 改为 App 层类型化 Route。

已确认保持正确的边界包括：Feature 不直接依赖 API/Auth/Playback，Cookie 只由精确授权器注入，认证/API 使用 ephemeral session 并拒绝重定向，Keychain 使用本机非同步保护，loopback 只绑定 `127.0.0.1`，登出会清理内存/Keychain/session。

## 4. 本地验证

环境：当前 Apple Silicon Mac，Xcode active developer directory 显式指向 `/Applications/Xcode.app/Contents/Developer`。

- `xcrun swift test --package-path Packages/BiliKitCore`：107 项测试、20 个套件通过。
- macOS 15 deployment target、`CODE_SIGNING_ALLOWED=NO` 的 App `build-for-testing`：通过；Xcode dependency graph 已解析 `BiliBrowseFeature`、`BiliLibraryFeature`、`BiliAuthFeature`。
- `test-without-building -only-testing:BiliKitMacTests`：composition test 通过；签名 Keychain smoke 按无签名边界跳过，未把 skip 计作真实 Keychain 证据。
- `Scripts/check-architecture.sh`、`Scripts/check-secrets.sh` 与 `git diff --check`：通过。

本次只验证结构重组、平台边界与现有自动化没有回归；没有重复真实扫码、真实历史或真实媒体网络验证。远程 macOS 15/26 CI 要在提交推送后另行确认。

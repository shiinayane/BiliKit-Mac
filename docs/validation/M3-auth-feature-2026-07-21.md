# M3 认证 Feature 与本地登出验证（2026-07-21）

> 结论：M3 第 5 步的 Application port、`BiliAuth` adapter、Feature MVVM、App 接线和完整本地登出自动化已经通过；当前 macOS 的未登录、二维码显示与取消 UI smoke 也已通过。M3 尚未关闭，仍需一个已登录业务纵向闭环，以及真实扫码、重启恢复和界面登出的最终验收。

## 1. 实现边界

- `BiliApplication` 新增非秘密的 `AuthenticationState`、安全错误分类和 `AuthenticationServicing`。接口不返回 Cookie、QR key、完整 QR URL、Keychain item 或 endpoint DTO。
- `BiliAuthenticationService` actor 复用已经验证的 Web QR session 和请求授权器，负责恢复、二维码请求、单次轮询、最终 nav 校验与 Keychain 提交、取消和登出。
- 二维码完整 URL 始终保留在 `BiliAuth.WebQRCode` 的不可公开字段中；Feature 只请求进程内 `CGImage`，不提供复制、导出或落盘入口。
- `BiliAuthFeature` 只依赖 `BiliApplication`。`AuthenticationViewModel` 拥有两秒轮询 Task、界面代次、页面生命周期取消与按最后一次操作区分的恢复/登录/登出重试；SwiftUI View 只展示非秘密状态。
- App target 只在 `AppEnvironment` 组合具体认证 adapter，并通过工具栏账号 sheet 注入 Feature。

## 2. 登出与并发边界

本地登出按以下顺序执行：

1. 递增认证代次并取消活跃 Web QR 请求。
2. 清除内存二维码与临时登录材料。
3. 删除固定 service/account 的 Keychain item，不依赖服务端网络成功。
4. 失效 Web QR 与请求授权器各自的 ephemeral `URLSession`，随后重建空 session。
5. 只有 Keychain 删除成功后才发布 `signedOut`。

自动测试额外固定：

- Keychain 删除失败时仍会失效两类 session，但状态保持 `credentialUnavailable`。
- 删除失败后的取消操作不能把状态伪装为已退出。
- 旧二维码请求、旧轮询和旧 Feature 意图均不能覆盖更新意图；恢复或登出失败时，重试不会误启动新的登录流程。
- 只有最新代次通过 nav 校验并成功写入 Keychain 后才能进入已登录状态。

## 3. 自动化结果

在当前开发机执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/BiliKitCore
```

结果：97 项测试、18 个测试套件全部通过。新增覆盖包括 Application adapter 的成功提交、恢复、登出顺序和删除失败，以及 Feature 的完整 QR 状态推进、旧意图隔离、恢复/登出、按原操作重试和取消。

随后以 deployment target macOS 15 执行无签名 App `build-for-testing`，构建通过；`BiliKitMacTests` composition 测试通过。未签名运行中的签名 Keychain smoke 按设计跳过，真实 Data Protection Keychain 往返证据仍以 [`M3-keychain-authorization-2026-07-21.md`](./M3-keychain-authorization-2026-07-21.md) 的已签名结果为准。

架构依赖检查与秘密模式扫描均通过。新增规则禁止 `BiliAuthFeature` 导入 API、Auth、Networking、Playback 或 AppKit/AVKit，并继续禁止 Application/Domain 反向依赖外层 adapter。

## 4. 当前 macOS UI smoke

使用本次无签名 Debug App 完成以下操作：

1. 启动 App，确认游客热门列表仍可加载。
2. 从工具栏打开账号 sheet，恢复结果显示“尚未登录”。
3. 点击“显示登录二维码”，现场请求成功并进入“请扫码登录”。
4. 不扫描二维码，点击“取消”，界面回到“尚未登录”。
5. 关闭 sheet 与测试 App。

验证过程没有输出、截图、复制或保存二维码内容，也没有产生真实账号凭据。因此它证明的是账号入口、未登录恢复、二维码内存渲染状态和取消行为，不是完整登录证据。

## 5. 剩余 Gate

- 在历史、收藏或登录推荐中选择一个纵向闭环，让 `BiliAPI` 的该 endpoint 显式请求认证授权。
- 完成一次真实扫码登录、个性化数据读取、App 重启恢复和界面登出。
- 登出后确认 Keychain item 已删除、两类 session 已失效，且游客热门、搜索、详情和播放仍可用。
- 在 macOS 15 CI 通过本次新增的 Package、架构、秘密扫描与 App composition 回归后，才能将 M3 关闭。

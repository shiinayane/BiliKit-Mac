# BiliKit 分发说明

> 当前公开版本与测试标记以 [GitHub Releases](https://github.com/shiinayane/BiliKit-Mac/releases) 为准。
> 每个候选的实际验证和未覆盖边界均写入对应发布说明；测试版不等同于正式验收。

## 系统要求

- macOS 15 或更高版本；
- Universal App，同时支持 Apple Silicon（`arm64`）和 Intel（`x86_64`）；
- 视频可用性、画质和接口行为取决于 Bilibili 服务、账号权限、地区和网络状态。

BiliKit 是非官方第三方客户端，与哔哩哔哩不存在隶属、认可或赞助关系。

## 获取与安装

从 [GitHub Releases](https://github.com/shiinayane/BiliKit-Mac/releases) 下载 BiliKit 的 DMG，
打开后将 BiliKit 拖入“应用程序”，再从“应用程序”启动。

安装包经过 Developer ID 签名与 Apple 公证。请使用本仓库提供的下载，避免来源不明的重新打包版本。
标有 Pre-release 的版本用于测试。

## 更新与故障恢复

Sparkle 已接入。应用菜单提供“检查更新…”、自动检查和自动下载并安装设置。
更新元数据与完整安装包分别验签，安装包同时经过 Developer ID 签名与 Apple 公证。
旧 build 1 不含更新器，需手动下载安装。build 2/3 为历史测试版本。

更新失败时先保留当前 App，从可信 GitHub Releases 下载更新版本，退出 App，
再拖入“应用程序”覆盖安装。
签名或公证异常应停止安装并报告；无可信更高版本时保留当前可用版本。

坏版本使用更高 build 前向修复，不覆盖公开同名资产、不移动旧 tag，也不自动降级。
自动更新正常路径已完成 build 2→3 本机验证；异常恢复与跨系统矩阵的实际状态见
[发布清单](docs/release/CHECKLIST.md)，不把历史结果当作新候选验收。

## 登出与卸载

登录 Cookie 只保存在本机 Data Protection Keychain。应用内“退出登录”会取消认证会话并删除该
Keychain 凭据；如果删除失败，BiliKit 会报告失败而不会假装已经安全退出。

仅在 Finder 中删除 App 不保证同时删除 Keychain item 或 macOS 保存的偏好。准备永久卸载时，应先在
BiliKit 内退出登录，再退出 App 并删除 `/Applications/BiliKit.app`。V1 发布前仍需用隔离测试凭据完成
删除、重装和不同用户矩阵；本文不把尚未验证的系统清理行为写成保证。

数据边界见 [`PRIVACY.md`](./PRIVACY.md)，第三方许可证见
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md)，安全问题请按 [`SECURITY.md`](./SECURITY.md)
私下报告。

# BiliKit 分发说明

> 状态：V1 发布前准备。当前没有公开安装包；下载 URL、DMG 文件名和 SHA-256 只能在最终不可变
> 发布资产生成后填写。

## 系统要求

- macOS 15 或更高版本；
- Universal App，同时支持 Apple Silicon（`arm64`）和 Intel（`x86_64`）；
- 视频可用性、画质和接口行为取决于 Bilibili 服务、账号权限、地区和网络状态。

BiliKit 是非官方第三方客户端，与哔哩哔哩不存在隶属、认可或赞助关系。

## 获取与安装

正式发布后，只信任本仓库的 GitHub Releases 页面提供的 Developer ID 签名、公证并 staple 的
只读 DMG。V1 计划让 DMG 仅包含 `BiliKit.app`、`Applications` 快捷方式和必要声明。

- 下载页面：`待发布`
- DMG 文件名：`待发布`
- 最终 SHA-256：`待发布`

下载后可在终端核对：

```sh
shasum -a 256 /path/to/BiliKit.dmg
```

只有输出与同一不可变 GitHub Release 公布的 SHA-256 完全一致时才继续安装。打开 DMG 后，将
`BiliKit.app` 拖入“应用程序”；不要从来源不明的镜像、网盘或重新打包站点安装。

## 更新与故障恢复

首发是否同时启用应用内自动更新尚未裁决。在 Sparkle 完整签名更新链通过前，更新只通过不可变
GitHub Release 人工下载。发现坏版本时优先发布更高 build number 的前向修复，不覆盖同名资产或
静默把更新元数据指回旧 build。

- 当前稳定下载：`待发布`
- 人工恢复说明：`待发布`

## 登出与卸载

登录 Cookie 只保存在本机 Data Protection Keychain。应用内“退出登录”会取消认证会话并删除该
Keychain 凭据；如果删除失败，BiliKit 会报告失败而不会假装已经安全退出。

仅在 Finder 中删除 App 不保证同时删除 Keychain item 或 macOS 保存的偏好。准备永久卸载时，应先在
BiliKit 内退出登录，再退出 App 并删除 `/Applications/BiliKit.app`。V1 发布前仍需用隔离测试凭据完成
删除、重装和不同用户矩阵；本文不把尚未验证的系统清理行为写成保证。

数据边界见 [`PRIVACY.md`](./PRIVACY.md)，第三方许可证见
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md)，安全问题请按 [`SECURITY.md`](./SECURITY.md)
私下报告。

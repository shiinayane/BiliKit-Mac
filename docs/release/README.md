# V1 Developer ID 发布准备

状态：当前执行入口；explicit App ID 工单待 Apple Developer Support 处理

## 已冻结事实

- 分发方式：Developer ID 站外 DMG，不走 Mac App Store；
- App：`BiliKit`，Bundle ID `com.shiinayane.BiliKit`，Team `2B3LZ256AG`；
- 版本：`1.0.0 (1)`，后续 build number 全局单调递增且不复用；
- 系统与架构：macOS 15+，`arm64 + x86_64` Universal；
- 权限：App Sandbox、Hardened Runtime、network client、仅用于 `127.0.0.1` loopback 的
  network server、单一 Keychain access group；
- 载体：只读 DMG；当前不需要 Developer ID Installer certificate；
- 当前发布 Mac 已有有效 `Developer ID Application: YANKAI WANG (2B3LZ256AG)` identity；
- `BiliKit-Notary` Keychain profile 已通过 Apple validation，公证历史为空；
- 首个基线成品不含 Sparkle，不部署 Cloudflare Worker。

证书指纹、submission ID、机器路径和最终哈希只进入每次发布候选的
[`MANIFEST.md`](./MANIFEST.md) 副本；私钥、`.p12` 密码、App 专用密码和 API key 永不进入仓库。

## 当前阻塞

正式 Team 只有 wildcard App ID。手工注册 explicit App ID `com.shiinayane.BiliKit` 返回
`not available`，App Store Connect 没有 App；Apple Developer Support 工单正在调查旧 Personal
Team 或残留登记。在 Apple 明确归属前：

- 不修改稳定 Bundle ID；
- 不把 wildcard development profile 当作正式身份；
- 不生成最终 Release archive、公开 DMG、release 或 appcast；
- 可以维护文档、备份现有证书、运行无签名 Release compile 和准备真实 Intel 环境。

## 严格发布顺序

### 1. 身份与恢复

1. Apple 工单解决后，在 Team `2B3LZ256AG` 注册精确 explicit App ID；
2. 只启用当前 App 实际需要的 capabilities；
3. 核对 AppIdentifierPrefix 与最终 Keychain access group；
4. 确认 Developer ID certificate、notary credential、账号恢复、泄漏停止和发布复核 owner；
5. 对 Developer ID 证书和私钥做加密离线备份，并在隔离 Keychain／备用 Mac 做一次恢复验证。

任何 Team、prefix、Bundle ID、Keychain group 或证书 owner 不清楚时停止。

### 2. 冻结候选

1. 工作树必须 clean，记录 commit SHA；
2. 运行最高适用 App Gate；
3. 冻结版本、build、依赖锁、Xcode build、SDK、隐私和许可；
4. 复制 `MANIFEST.md` 为带版本和日期的候选记录；
5. 从同一冻结 commit 只生成一次 Release archive。

签名后若修改 App bundle 内任何文件，当前候选立即作废；增加 build number 后从 archive 重新开始。

### 3. Developer ID 导出与静态检查

首个候选使用 Xcode Organizer 的 Developer ID／Direct Distribution 路径，不先固化自写
ExportOptions。导出后逐项检查 App 和所有 Framework、XPC、helper 与其他 Mach-O：

```sh
codesign -vvv --deep --strict /path/to/BiliKit.app
codesign -dvv /path/to/BiliKit.app
codesign -d --entitlements :- /path/to/BiliKit.app
spctl -vvv --assess --type exec /path/to/BiliKit.app
```

`--deep` 只用于验证，不用于掩盖嵌套签名。所有 Mach-O 必须同时包含 `arm64` 与 `x86_64`，使用同一
Developer ID Team、Hardened Runtime 和 secure timestamp。有效 entitlement 不得出现
`get-task-allow`、Disable Library Validation、JIT、unsigned executable memory、多余文件权限、
App Group 或意外 Keychain group。

若导出 App 包含 `Contents/embedded.provisionprofile`，必须解码并核对 Team、精确 App ID、到期日和
Keychain group；若没有，记录 Xcode 的实际导出行为，并由最终 Keychain 运行 Gate 证明边界。

### 4. 公证 App

提交 Developer ID 导出的 App 候选，等待 `Accepted`，下载并审查完整 notary log。Accepted 不能
替代 warning 审查；任何未裁决 warning/error 都停止。取得 ticket 后 staple/validate；若 Organizer
流程要求重新 export，最终使用重新导出的含 ticket App。

不得使用已经停止服务的 `altool`，命令行只引用 `BiliKit-Notary` profile，不在参数中放密码。

### 5. 制作并公证最终 DMG

DMG 只包含：

- 已签名、公证、staple 并复核 hash 的 `BiliKit.app`；
- `/Applications` symlink；
- 已裁决的简短声明（若需要）。

不得包含源码、fixture、`references/`、trace、日志、dSYM、Keychain 导出或其他开发产物。DMG 使用
Developer ID Application identity 和 secure timestamp 签名，再单独提交公证：

```sh
xcrun notarytool submit /path/to/BiliKit.dmg --keychain-profile BiliKit-Notary --wait
xcrun notarytool log SUBMISSION_ID --keychain-profile BiliKit-Notary /path/to/notary-log.json
xcrun stapler staple /path/to/BiliKit.dmg
xcrun stapler validate /path/to/BiliKit.dmg
```

读取完整 log 后，在 staple 完成的最终 DMG 上计算 SHA-256 和 byte length；之后不得替换同名资产。

### 6. 真实下载与安装 Gate

从受控 HTTPS 页面用浏览器下载最终 DMG，让系统真实附加 quarantine。至少覆盖：

- `/Applications` fresh install、首次和第二次启动、离线 ticket；
- DMG 内直接启动、App Translocation、移动后启动；
- 同签名旧版覆盖升级、duplicate、different-user、Finder 删除和重装；
- Apple Silicon macOS 15／当前 macOS；
- 真实 Intel macOS 15；
- 游客、二维码登录、Keychain 恢复和登出、loopback 播放、seek、字幕、弹幕、退出清理。

Rosetta、Intel CI、arm64 CI、build、截图和旧验证记录都不能替代真实 Intel 发布候选行为。

### 7. GitHub 发布

资产先进入 draft；tag、commit、版本、manifest、DMG、checksums 和 release notes 交叉核对。独立下载
后再次验证 hash、签名、公证、staple 与 Gatekeeper。发布后不覆盖同名资产；坏版本使用更高 build
前向修复。

## 更新器与 Cloudflare 边界

无更新器的 Developer ID 基线成功后，更新器候选为 Sparkle 2，当时重新核对官方最新稳定版本、
安全公告、最低系统与 license。若实施：

- Sparkle 只进入 App target，由进程级唯一 owner 持有，不进入 `BiliApplication` 或 Feature；
- 使用标准 UI、Installer XPC、Developer ID code signing 与 EdDSA，不自研下载替换器；
- EdDSA 私钥只在发布机 Keychain 与加密离线备份，不进入 GitHub、Cloudflare 或仓库；
- 先用两个真实 Developer ID 测试版本完成完整包 v1→v2 和失败矩阵；V1 不以 delta 代替；
- 更新失败不得影响现有 App 启动、认证、播放、设置或 Keychain。

Cloudflare Worker 默认不部署。只有静态 HTTPS appcast 出现已证明的域名稳定性或故障隔离需求时才
重新立项；届时重新读取官方 pricing/limits。它只能原样分发已签名 appcast，零用户凭据、零 EdDSA
私钥、零大文件代理、零 B 站 API／媒体代理。

逐项执行以 [`CHECKLIST.md`](./CHECKLIST.md) 为准。

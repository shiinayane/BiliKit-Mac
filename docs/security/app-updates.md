# App 自动更新信任边界

日期：2026-09-05。范围：Sparkle 2.9.6、完整 DMG 更新及静态 HTTPS appcast。
此文允许实现与本地验证；不表示更新安装、公开发布或 Cloudflare 部署已经验收。

## 资产与 owner

- App 进程唯一 `AppUpdater` 由 SwiftUI App 的 `StateObject` 持有，跨窗口共享；
  Sparkle 拥有更新网络、取消、安装 helper 和重启生命周期，不自建下载替换器。
- 更新器没有 BiliAuth、账户 coordinator、API authorizer 或播放器引用，不访问 B 站 Keychain。
  认证 transport 使用独立 ephemeral session，不向共享 Cookie storage 写入凭据；
  更新网络不能得到 B 站授权头，也不将更新失败送入认证恢复链路。
- 默认更新检查由 Sparkle 第二次启动时询问；自动下载与安装默认关闭，用户可通过菜单更改。
  不收集 Sparkle system profile，不添加账号标识、查询参数或自定义请求头。
- Sparkle 自己管理更新偏好和非秘密更新时间。Cloudflare/GitHub 仍可观察 IP、请求时间、
  标准 User-Agent；关闭 Worker observability 不等同于服务商不记录网络元数据。

## 攻击与控制

| 风险 | 控制 | 证据边界 |
| --- | --- | --- |
| feed 或下载源被篡改 | HTTPS、Ed25519 feed 签名、解包前归档验证、Developer ID、公证 | 本地测试证明 feed/归档篡改被部署校验拒绝；Sparkle 真安装仍需签名版本验证 |
| feed 验签长时间失败后降级 | `SUSignedFeedFailureExpirationInterval=0`，始终拒绝未签名 feed | 失钥后可能必须人工下载可信的签名公证新版恢复，不承诺自动恢复 |
| 未配置公钥、域名未上线 | `BiliKitUpdaterEnabled=false`；完整校验通过才创建 Sparkle controller | 未配置时菜单显示尚未配置；2026-09-05 已填公钥并为内部测试启用，该 URL 已授权上线且匿名验签通过，用户已确认正常升级及登录保留，失败矩阵仍待验收 |
| Sandbox 安装权限扩大 | 只启用 Installer XPC；新增精确 bundle `-spks`/`-spki` mach lookup | Downloader XPC 随官方包保留但不启用；不增加文件权限或 runtime exception |
| 更新源泄露秘密 | Cloudflare 只上传 `public/_headers` 和已签名 `appcast.xml`；拒绝目录和 symlink | 公钥可公开；私钥仅发布机 Keychain 与加密备份，不上云、不进脚本参数/日志 |
| 草稿或可变资产被当更新 | 只允许固定仓库 `/releases/download/<tag>/<file>.dmg`，拒绝草稿 tag、latest 与 query | 本地校验不能证明 tag/资产已公开、不可变或网络可达，发布者必须匿名下载核对 hash |
| 降级或坏版本 | 正整数递增 build；资产不可覆盖；完整包前向修复 | 发布脚本不替代 Sparkle 旧 build/错误架构/签名的真实拒绝测试 |
| 更新失败损坏使用中的 App | 交由 Sparkle 标准安装与错误 UI；失败不调用账户/播放清理 | 离线、断流、磁盘不足、权限拒绝等仍需完整失败矩阵 |

## 依赖与隐私复核

官方稳定版 2.9.6 最低 macOS 10.13，满足本 App macOS 15；包含 2026-08-17 的
安装路径符号链接与 root 清理安全修复。已查看官方 advisories 列表与该版 release notes，
不能将“精确锁版”解释成永远没有漏洞；每次发布重新核对。

固定包未提供独立 `PrivacyInfo.xcprivacy`；App 现有声明包含本 App 偏好使用的 UserDefaults
理由。当前禁用 Sparkle profiling，未引入分析 SDK。最终 Archive 的隐私报告、嵌套签名、
两种架构和实际网络元数据仍需复核，不能由源码或无签名测试替代。

官方依据：
[Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)、
[安全公告](https://github.com/sparkle-project/Sparkle/security/advisories)、
[SwiftUI owner](https://sparkle-project.org/documentation/programmatic-setup/)、
[Sandbox 与签名](https://sparkle-project.org/documentation/sandboxing/)、
[签名与发布](https://sparkle-project.org/documentation/)、
[配置与失钥恢复取舍](https://sparkle-project.org/documentation/customization/)。

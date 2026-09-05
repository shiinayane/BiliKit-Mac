# V1 Developer ID 发布清单

本清单保留 build 1/2/3 的带版本历史证据；未注明版本的正式候选项需重新验证。
1.0.0 (4) 的新候选证据由自动化记录，未取得的项目不勾选。

只有真实取得的证据才能勾选；源码设置、旧 CI、截图和 Accepted 状态不能替代下一层。

## A. 身份、产品与恢复

- [x] 确认 Developer ID 站外 DMG 分发，不走 Mac App Store。
- [ ] Team `2B3LZ256AG` 下注册并核对 explicit App ID `com.shiinayane.BiliKit`。
- [ ] 冻结 AppIdentifierPrefix 与最终 Keychain access group。
- [x] 冻结 `1.0.0 (1)`、macOS 15+ 与 `arm64 + x86_64` Universal。
- [x] 当前发布 Mac 存在有效 Developer ID Application identity。
- [x] `BiliKit-Notary` credential validation/history 成功。
- [ ] Developer ID 私钥加密备份与隔离恢复通过。
- [ ] 冻结发布复核、账号恢复、证书泄漏和坏版本前向修复 owner。
- [ ] 冻结下载页、许可、卸载、隐私和人工恢复说明。

## B. 当前正式发布候选（含 Sparkle）

- [ ] 从 clean commit 运行 App Gate 并复制 manifest。
- [ ] 记录 Xcode、SDK、Swift、依赖锁、版本、build 与 commit。
- [ ] Release archive 是 macOS App Archive，Products 只有预期 App。
- [ ] App 与全部嵌套 Mach-O 都包含 `arm64 + x86_64`。
- [ ] Developer ID identity、Hardened Runtime、secure timestamp 与嵌套签名正确。
- [ ] 有效 entitlement 与 profile（若有）只授权精确 App ID、Keychain 和当前最小能力。
- [ ] 不存在 `get-task-allow`、多余文件权限、App Group 或 Hardened Runtime exception。
- [ ] App／DMG 不含源码、fixture、reference、trace、日志、dSYM、凭据或开发产物。
- [ ] SwiftProtobuf 版本、revision、license 与最终 notice 一致。
- [ ] App notarization Accepted，完整 log 无未裁决 warning/error。
- [ ] App ticket 已 staple/validate，最终使用的 App hash 已记录。
- [ ] 最终只读 DMG 内容符合预期并由 Developer ID Application 签名。
- [ ] DMG notarization Accepted，完整 log 已审查，ticket 已 staple/validate。
- [ ] staple 后最终 DMG SHA-256 与 byte length 已记录。

## C. 真实下载与安装

- [ ] 浏览器 HTTPS 下载产生真实 quarantine，Gatekeeper 首启和二次启动通过。
- [ ] fresh、upgrade、duplicate、different-user、DMG 内启动、移动后启动和离线 ticket 通过。
- [ ] Apple Silicon macOS 15／当前 macOS 的最小产品路径通过。
- [ ] 真实 Intel macOS 15 的同一最小产品路径通过。
- [ ] 隔离凭据下登录、Keychain 恢复、登出、Finder 删除、重装和覆盖升级通过。
- [ ] loopback 播放、seek、字幕、弹幕、媒体替换和退出清理通过。

## D. GitHub 发布

- [ ] draft asset、tag、commit、版本、manifest、release notes 和本机 checksums 一致；公开资产仅 DMG。
- [ ] 独立下载后重验 SHA-256、Apple 签名、公证、staple 与 Gatekeeper。
- [ ] 发布资产不可变；不覆盖同名文件，坏版本只用更高 build 前向修复。
- [ ] 发布 workflow（若有）使用完整 action SHA、最小权限且不提前持有发布秘密。

## E. Sparkle（已授权实现；正式发布仍须完成适用 B–D Gate）

2026-09-05：原 build 1 保持冻结；用户已完成 build 2→3 升级，确认版本 1.0.0 (3) 与登录状态保留。
本机正常路径通过不替代不同用户、真实 Intel/macOS 15、Translocation 或异常恢复验证。
详细证据与来源限制见 [接入与验收记录](SPARKLE-INTEGRATION-2026-09-05.md)。

- [ ] 实施当日重新核对 Sparkle 稳定版、安全公告、最低系统与 license 并精确锁定。
- [x] Sparkle 只进入 App target，进程级 updater owner 唯一。
- [x] 只启用 Installer XPC 和必需沙箱例外，不启用无需求的 Downloader XPC。
- [x] framework、XPC、Autoupdate 与 Updater 的双架构、签名、runtime 和 entitlement 通过。
- [ ] EdDSA key 的 Keychain 保存、离线备份与恢复通过；私钥不进入仓库／CI／Cloudflare。
- [x] `SUPublicEDKey`、HTTPS feed 与签名要求正确，appcast 由官方工具生成。
- [x] 用户确认两个真实 Developer ID 版本完成完整包 build 2→3 升级，版本正确且登录状态保留。
- [ ] 损坏／错误签名／旧 build／错误架构失败矩阵通过。
- [ ] 离线、超时、404/500、中断、磁盘不足、权限拒绝和重启清理不破坏现有 App。
- [ ] 新依赖的 Privacy Manifest、第三方 notice、日志和诊断边界复核通过。

## F. Cloudflare 更新源

- [x] 用户授权独立 Wrangler 目录准备，域名 `shiinayane.com` 已托管。
- [x] 最终 Worker、账户、子域名、公开资产与公钥已确认。
- [x] 本地官方工具生成签名 feed，DMG 与 feed 公钥验证、dry-run 通过。
- [x] 两个带更新器的签名公证版本正常升级通过（用户报告）。
- [ ] 更新失败矩阵通过。
- [x] 部署前重新确认成本、缓存、DNS、停用与零凭据边界，并取得实际部署授权。
- [x] 部署后匿名 HTTPS、原始字节/hash、缓存头和 404 通过；强制验签配置下真实升级成功（用户报告）。

正常升级与登录保留已由用户确认；组合项中的失败矩阵仍未完成，不据此勾选完整正式发布验收。

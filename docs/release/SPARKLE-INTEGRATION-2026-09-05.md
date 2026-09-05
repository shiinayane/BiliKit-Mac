# Sparkle / Cloudflare 接入与验收记录

日期：2026-09-05（Asia/Tokyo）。范围：Sparkle 2.9.6、完整 DMG 更新及静态 HTTPS appcast。

## 当前结果

用户已通过 build 2 的更新器升级到 `1.0.0 (3)`，并确认原登录状态保留。
这是本机正常升级路径的用户验收结果；不是异常恢复、跨用户或跨系统的完整验收。

- [build 2 测试发布](https://github.com/shiinayane/BiliKit-Mac/releases/tag/v1.0.0-sparkle-test.2)
- [build 3 测试发布](https://github.com/shiinayane/BiliKit-Mac/releases/tag/v1.0.0-sparkle-test.3)
- [线上更新源](https://updates.shiinayane.com/appcast.xml)，Worker `bilikit-updates`。

测试二进制来自基于 `b177f05b3f8fda7788a580cfb4f5d22e0481bed7` 的未提交源码快照。
两个测试 tag 指向该基线；GitHub 自动生成源码归档不包含 Sparkle 改动，此限制已写入公开发布说明。
后续源码提交不改变既有二进制来源。正式候选必须从冻结 commit 使用更高 build 重新构建。

## 实现与安全边界

- Sparkle 仅链接 App target，精确固定 2.9.6；App 进程唯一 `AppUpdater` 持有标准 controller。
- 菜单提供检查更新、自动检查、自动下载并安装设置；偏好、调度、下载、安装和重启交由 Sparkle。
- 更新器已启用；公钥与 HTTPS feed 在 App 配置和部署配置中一致。
- 强制 feed 签名与解包前归档验签，签名失败不允许超时降级；不采集 Sparkle system profile。
- 仅启用 Installer XPC 的两个精确 mach lookup；Downloader XPC 随框架打包但不启用，不增加 runtime exception。
- Cloudflare 只分发已签名 appcast；安装包使用 GitHub 独立版本资产，不覆盖旧包，无 B 站或媒体代理。
- 公钥可公开；发布私钥只由官方工具访问 Keychain，未进入聊天、仓库、日志或 Cloudflare。

## 验证证据

| 项目 | 已取得的证据 | 限制 |
| --- | --- | --- |
| 完整 App Gate（build 2） | 666 Package tests / 69 suites，184 App tests passed | 1 signed Keychain smoke skipped；不替代真实安装 |
| build 3 构建 | 仅递增 build 2→3；static Gate、新 Universal Archive 与导出通过 | 不把 build 2 测试计作 build 3 新测试 |
| 更新源校验 | 6 项测试覆盖 feed/归档验签、篡改、错误公钥、无签名/尾随内容、非批准资产、签名空 feed | 本地拒绝测试不替代 Sparkle 客户端失败矩阵 |
| App/DMG 签名与公证 | 两个版本均完成 Developer ID、完整公证日志无问题项、staple；最终包 Gatekeeper 通过 | 仅本次成品 |
| 产物身份 | 六个 Mach-O 双架构、runtime、timestamp、entitlement/profile；DMG 包内 App 哈希及链接一致 | 不证明真实 Intel 运行 |
| 线上分发 | GitHub 匿名下载字节/hash 一致并重验签名、公证；Cloudflare HTTPS、原始字节、签名、缓存头、404 通过 | 未开启 GitHub 仓库级 immutable；后续不可覆盖资产 |
| 正常更新 | 用户先确认 build 2 安装及更新器入口，再报告“已更新，现在显示1.0.0(3)” | 用户报告；未采集屏幕或运行时日志 |
| 登录状态 | 用户明确确认升级后登录状态保留 | 未读取凭据；不等同于完整 Keychain 恢复、登出与重装测试 |

原无更新器 build 1 及其发布资产保持冻结；build 1 不能自行发起 Sparkle 更新。
详细机器证据和源码快照保存在 gitignored `docs/_local/release/sparkle-test-1.0.0-{2,3}-2026-09-05/`，
不随源码提交。最终安装包校验和也随各测试 Release 发布。

## 本次提交前复核

2026-09-05 对最终暂存实现运行一次完整 `sh Scripts/run-quality-gates.sh app`：static、
666 Package tests / 69 suites、App build-for-testing 与 184 App tests 全部通过；
1 项 signed Keychain smoke 因无签名 host 跳过。保留既有 sidebar 测试未使用返回值 warning。
更新源 6 项测试、当前双版本 feed 公钥验证及暂存秘密/差异检查通过。

逐文件核对 App 构建输入与已验收 build 3 快照完全一致。本轮收尾只更新验收文档，以及
为上游许可证原文的既有行尾空格添加单文件 Git 检查例外。未改写已发布 App/DMG 或在线 feed。
DanmakuLab 的 Xcode 锁文件旁支改动保留在提交之外；临时测试产物按 Gate 清理。

## 签名密钥恢复

已核对备份所在磁盘映像处于加密状态，备份文件存在且非空。官方 `generate_keys -f` 将备份
导入 UUID 命名的独立 Keychain 测试条目；丢弃导入输出，只读取公钥并核对与 App 一致。
随后删除临时条目并确认不存在，正式密钥未修改，备份卷已推出。

这证明当前 Mac 的隔离条目恢复可行，不证明异机恢复、离线副本或密码的独立保管。
签名密钥丢失时，当前拒绝降级策略可能需要人工安装恢复。

## 尚未完成

- 从冻结源码 commit 构建正式候选，使源码、tag、版本与二进制来源对应。
- Sparkle 客户端损坏包、错误签名、旧 build、错误架构、断网、超时、404/500、下载中断、磁盘不足与权限拒绝测试。
- 真实 Intel/macOS 15、不同 macOS 用户、DMG 内启动/Translocation、离线票据、重装和签名 Keychain smoke。
- Developer ID 私钥备份恢复、发布与恢复责任人，以及面向用户的人工恢复说明等发布清单剩余项。

步骤见 [更新源 README](../../Updates/cloudflare/README.md)，信任边界见 [更新安全模型](../security/app-updates.md)。

## 推送前 agent 审核修复

独立审核发现部署校验只读取 item build，而 Sparkle 优先读取 enclosure 版本属性。
现要求该可选属性与已验证的 item build 完全一致；冲突、空值与前导零差异均拒绝。
合法临时签名的回归测试在旧实现失败，修复后 8 项更新源测试、现有双版本 feed 验签及 static Gate 通过。
原审核 agent 只读复核确认该 P2 关闭，未发现修复引入的新问题。
改动仅涉及本地发布校验与测试；App、已发布 DMG 和签名 appcast 均未变化，无需重新公证或部署。

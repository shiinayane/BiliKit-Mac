# Developer ID 本机发布流水线

入口为 `python3 Scripts/release/release.py`，在独立 managed worktree 中运行，使用本机 Keychain 中既有
Developer ID、`BiliKit-Notary` 与 Sparkle EdDSA key。GitHub Actions 只跑 macOS 15／26／27 Apple Silicon
检查（27 的 runner 标签为 `xcode-27`），不持有签名私钥。架构与更新安全边界见
[`../ARCHITECTURE.md`](../ARCHITECTURE.md) 的“分发”与 [`../SECURITY-MODEL.md`](../SECURITY-MODEL.md) 的“应用更新”。

## 冻结与前提

- App `BiliKit`，Bundle ID `com.shiinayane.BiliKit`，Team `2B3LZ256AG`，macOS 15+，App 主程序仅 `arm64`；
  build 号全局递增。下一候选为 `1.0.1 (5)`。
- 每个版本只写一份更新日志 `docs/release/<版本>-notes.md`：每行一条面向用户的 `- ` 条目，不写标题或
  过程说明，冻结前随源码合并到 main。`prepare` 把它放在 DMG 旁由 Sparkle 以 Markdown 内嵌进 appcast
  （更新提示）；`draft` 把它填入固定模板 [`release-page.md`](release-page.md) 作为 GitHub Release 正文。
  两个渠道的更新日志因此逐字一致，Release 页只额外提供安装与系统要求。
- 提交、PR、合并和正式发布需当前任务授权；历史授权不延续。
- 先合并源码，等待同一提交的 main push CI 三个环境成功，再冻结干净的最新 main。
- 工具：完整版 Xcode、Python 3、gh、Node **22.22.3**；DMG 工具固定 create-dmg **8.1.0** 及依赖锁，原生
  macos-alias 与 Node ABI 必须一致。Finder 布局保持 660×400、160pt 图标和 Applications 链接。
- `gh` 与 Wrangler 在发布机登录；凭据不写入参数、仓库或聊天。
- 每次检查最终签名身份、profile 允许范围、有效期与精确 Keychain entitlement；wildcard profile 的
  允许范围不等于 App 实际使用 wildcard identity。

## 1. 检查与准备

```sh
python3 Scripts/release/release.py preflight
python3 Scripts/release/release.py prepare --output /private/tmp/bilikit-release-UNIQUE
```

- `preflight` 检查工作树、远端 main/CI、版本、线上已签名 feed 的最大 build、重复 tag/Release、
  Developer ID 与 notary credential。旧同名草稿先人工核对；脚本不删草稿、不移动 tag。
- `prepare` 依次执行 App Gate、Release archive、Developer ID export、App 公证／staple、DMG 制作／签名／
  公证／staple、架构／entitlement／包内文件核对、Sparkle 官方工具签名 appcast 与校验和。仅完整安装包，
  无 delta；新 feed 只列当前候选。候选 feed 必须内嵌本版本更新日志，并带 Sparkle 按仅 arm64 主程序自动
  生成的 `hardwareRequirements arm64`，Intel 客户端因此不会收到更新；不为 Intel 另建 feed。
- 候选目录保存 `release.json`、阶段日志、Archive、export、逐文件哈希、完整公证日志与
  `assets/{DMG,appcast.xml,SHA256SUMS}`。脚本不启动 App、不读 B 站凭据、不发 B 站请求。
- Keychain 弹窗时允许当前 codesign 或 Sparkle 签名工具访问既有条目，不把密码交给助手。notary profile
  不可用时交互运行 `xcrun notarytool store-credentials BiliKit-Notary` 后重试。不得新建或轮换 Sparkle
  key 来绕过访问失败。

候选必须满足，任一不满足即停止：

- Archive 为 macOS App Archive，Products 只有预期 App；App 主程序仅 `arm64`，嵌套 Mach-O 均含 `arm64`。
- Developer ID、Hardened Runtime、secure timestamp 与嵌套签名正确；entitlement 只含最小能力，无
  `get-task-allow`、多余文件权限、App Group 或 runtime exception。
- App／DMG 不含源码、fixture、reference、trace、日志、dSYM、凭据或开发产物。
- SwiftProtobuf 版本、revision、license 与 `THIRD_PARTY_NOTICES.md` 一致。
- App 与 DMG 公证 Accepted、完整 log 无未裁决问题、ticket 已 staple/validate；记录最终 DMG SHA-256 与字节数。

## 2. 草稿与验收

```sh
python3 Scripts/release/release.py draft --output /private/tmp/bilikit-release-UNIQUE
```

草稿绑定冻结 commit，只上传 DMG；appcast 与 SHA256SUMS 留作本机元数据，不标 Latest、不部署 feed。
同名 Release 已存在则拒绝；上传中断时先核对远端 digest，不用 `--clobber`。

维护者根据当前候选的实际验证作出 go / no-go。建议记录（不自动阻止发布）：浏览器下载的 quarantine
与 Gatekeeper 首启、fresh／覆盖升级／不同用户／删除重装、当前 macOS 的最小产品路径（macOS 15
只依赖 CI 的启动冒烟，不做实机验收）、签名 Keychain 登录恢复与登出、loopback 播放／seek／字幕／弹幕／退出清理、Sparkle
失败矩阵（损坏／错误签名／旧 build／离线／中断／磁盘不足）。人工记录模板见 [`MANIFEST.md`](MANIFEST.md)。

验收写入候选目录的 `acceptance.json`：

```json
{
  "commit": "冻结完整 SHA",
  "dmg_sha256": "最终 DMG SHA256",
  "decision": "no-go",
  "reviewer": "复核人",
  "evidence": "当前候选的验收记录路径与未覆盖边界",
  "real_install": false,
  "apple_silicon_macos15": false,
  "signed_keychain": false,
  "sparkle_failure_matrix": false
}
```

只有实际取得的证据才设为 true；`decision` 独立记录维护者裁决。

## 3. 公开与更新源部署

```sh
python3 Scripts/release/release.py publish --output /private/tmp/bilikit-release-UNIQUE \
  --acceptance /private/tmp/bilikit-release-UNIQUE/acceptance.json
```

脚本校验提交、main CI、验收裁决、草稿目标与远端 digest 后公开 Release；再匿名下载 DMG 重验
hash／签名／公证／DMG 内 App，之后才在独立部署副本执行 npm ci、dry-run 与 deploy，最后验证线上
appcast 字节与签名。顺序保证 feed 不指向不可访问的资产。部署目标、费用与停用边界见
[`../../Updates/cloudflare/README.md`](../../Updates/cloudflare/README.md)。

## 停止条件与恢复

- 线上已有更高 build 时不得部署旧候选；任何错误先停 feed，用更高 build 前向修复。
- 签名后任何修改都使候选失效：增加 build，重新 archive、签名、公证、计算哈希。
- 不覆盖同名资产、不移动 tag、不重复创建 Release；公开资产仅 DMG。
- 公证提交 ID 在等待前落盘；中断后在同一 clean commit 重跑 `prepare`，从记录阶段恢复。Archive
  不完整时换新的候选目录。
- 公开后网络或部署失败：保留现有 Release，修复后重跑 `publish`。
- 发布记录与可恢复候选放在 gitignored `docs/_local/release/`；完成后删除本任务的 `work/`、
  `downloads/`、`deployment/`、ZIP 与构建日志，不清理其他任务目录。
- 发布后核对 GitHub Latest、tag、安装包 hash、线上 feed 与 README 版本说明。

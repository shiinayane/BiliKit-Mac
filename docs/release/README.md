# Developer ID 本机发布流水线

当前入口为 `python3 Scripts/release/release.py`。发布工作在独立 managed worktree 进行，
使用本机 Keychain 中既有 Developer ID、`BiliKit-Notary` 和 Sparkle EdDSA key。
GitHub Actions 负责 macOS 15 Intel 与 macOS 26 检查，不托管签名私钥。

## 冻结与前提

- App `BiliKit`，Bundle ID `com.shiinayane.BiliKit`，Team `2B3LZ256AG`，macOS 15+ Universal。
- 当前正式版本 `1.0.0 (4)`；未来修改工程版本/build 与 `check-project-contract.sh`，build 全局递增。
- 本次用户已授权提交、PR、合并和正式发布；授权不把未取得的测试证据变成通过。
- 先合并源码，等待同一提交的 main push CI 两个平台成功，再冻结干净最新 main。
- 使用完整版 Xcode、Python 3、gh、Node **22.22.3**。DMG 工具固定 create-dmg **8.1.0** 及依赖锁；
  原生 macos-alias 与 Node ABI 必须一致。默认 Finder 布局保持 660×400、160pt 图标和 Applications 链接。
- `gh` 与 Wrangler 在发布机完成登录；不把凭据写入参数、仓库或聊天。
- 证书/EdDSA 加密备份、恢复 owner 与实际安装矩阵按 [CHECKLIST](CHECKLIST.md) 复核。

历史 build 1 是无更新器候选，build 2/3 是基于未提交快照的公开测试版。
它们不能替代当前冻结提交的新包；不得移动测试 tag 或覆盖旧资产。
旧 Apple explicit App ID 问题不再按早期状态猜测，逐次检查最终签名身份、profile 允许范围、
有效期及精确 Keychain entitlement。wildcard profile 的允许范围不等于 App 实际使用 wildcard identity。

## 1. 检查与准备

在 PATH 中选择 Node 22.22.3，设置独立候选目录，例如：

```sh
python3 Scripts/release/release.py preflight
python3 Scripts/release/release.py prepare --output /private/tmp/bilikit-release-UNIQUE
```

`preflight` 检查工作树、远端 main/CI、版本、线上已签名 feed 的最大 build、重复 tag/Release、
Developer ID 与 notary credential。旧同名草稿需先人工核对并保留为历史草稿；脚本不自动删草稿或移动 tag。

`prepare` 顺序执行一次 App Gate、Release archive、Developer ID export、App 公证/装订、
DMG 制作/签名/公证/装订、双架构/entitlement/包内文件核对、Sparkle 官方工具签名和校验和生成。
仅完整安装包，无 delta。新 feed 只列当前候选；旧公开 Release/URL 保留，可从 build 2/3 正常前向更新。

候选目录保存 `release.json` 阶段状态、阶段日志、Archive、export、逐文件哈希、完整公证日志和
`assets/{DMG,appcast.xml,SHA256SUMS}`。公开资产不含本机路径或 Apple 账号诊断。
脚本不启动 App、不读取 Bilibili 凭据、不发真实 Bilibili 请求。

如 Keychain 弹窗出现，允许当前 codesign 或 Sparkle 官方签名工具访问既有条目；不要提供密码给助手。
如 notary profile 不可用，在发布机交互运行 `xcrun notarytool store-credentials BiliKit-Notary`，
然后重试 preflight。不要新建/旋转 Sparkle key 来绕过钥匙串访问失败。

## 2. 草稿与真人验收

```sh
python3 Scripts/release/release.py draft --output /private/tmp/bilikit-release-UNIQUE \
  --notes /path/to/release-notes.md
```

草稿绑定冻结 commit，只上传最终 DMG；appcast 与 SHA256SUMS 保留为本机发布元数据，不标记 Latest、不部署 feed。
同名 Release 已存在则拒绝覆盖。上传中断时先核对远端各资产 digest，不能使用 `--clobber`。

维护者根据当前候选的验证记录作出发布裁决。额外跨系统、不同用户、Keychain 与更新失败矩阵作为验证记录，不自动阻止发布，也不要求用户手动核对哈希。完整记录见 [MANIFEST 模板](MANIFEST.md)。

将实际验收记录写入候选目录的 `acceptance.json`，字段示例：

```json
{
  "commit": "冻结完整 SHA",
  "dmg_sha256": "最终 DMG SHA256",
  "decision": "no-go",
  "reviewer": "复核人",
  "evidence": "当前候选的验收记录路径与未覆盖边界",
  "real_install": false,
  "intel_macos15": false,
  "signed_keychain": false,
  "sparkle_failure_matrix": false
}
```

只有实际取得的测试证据才设为 true；`decision` 独立记录维护者的 go / no-go 裁决。脚本仍强制校验候选身份、CI、资产完整性、签名、公证和更新源一致性。

## 3. 公开与更新源部署

```sh
python3 Scripts/release/release.py publish --output /private/tmp/bilikit-release-UNIQUE \
  --acceptance /private/tmp/bilikit-release-UNIQUE/acceptance.json
```

脚本校验当前提交、main CI、绑定候选的验收裁决、草稿目标及所有远端资产 digest 后公开 Release。
随后匿名重新下载 DMG、重验 hash/签名/公证/DMG 内 App，才将本机签名 appcast 放入独立部署副本执行 npm ci、dry-run 和 deploy。
最后验证线上 appcast 字节与公钥签名。顺序保证 feed 不指向不可访问的草稿资产。

Wrangler 会发布到已有 `bilikit-updates` / `updates.shiinayane.com`；费用、缓存、DNS 与停止边界见
[更新源说明](../../Updates/cloudflare/README.md)。仅上传静态签名元数据，无安装包、私钥或用户凭据。

## 恢复与清理

- 公证提交 ID 在等待前落盘；中断后同一 clean commit 重跑 prepare，从记录阶段恢复。
- Archive 不完整时拒绝复用；检查日志，使用新的独立候选目录。已签名 bundle 若改变，使用更高 build 重建。
- 公开后网络/部署失败，保留现有 Release，修复后重跑 publish；不重复创建、覆盖资产或移动 tag。
- 线上较新 build 已出现时不得部署旧候选；任何错误都先停 feed，使用更高 build 前向修复。
- 发布记录与可恢复候选保存在 gitignored `docs/_local/release/`；摘要完成后删除本任务临时
  `work/`、`downloads/`、`deployment/`、ZIP 与构建日志缓存。不要清理其他任务目录。
- 发布完成后核对 GitHub Latest、tag、安装包 hash、线上 feed 与 README 状态，并写入带日期的新记录。

官方依据（2026-09-05 复核）：[Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、
[Sparkle archive/export 与 appcast](https://sparkle-project.org/documentation/)、
[Cloudflare 静态资产费用](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)。

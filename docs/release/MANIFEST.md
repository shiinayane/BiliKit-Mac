# V1 发布候选 Manifest 模板

复制为带版本和日期的记录后填写。任何签名后修改都会使候选失效；修复后必须增加 build number，
重新 archive、导出、签名、公证和计算哈希。不得记录私钥或密码。

## 来源与版本

- Marketing version：`1.0.0`
- Build number：`从冻结工程读取`
- Git commit／tree clean：`待填写`
- Bundle ID：`com.shiinayane.BiliKit`
- Team ID：`2B3LZ256AG`
- AppIdentifierPrefix：`待从最终签名成品读取`
- Keychain access group：`待从签名成品读取`

## 工具链与依赖

- 日期、构建 Mac／macOS：`待填写`
- Xcode version/build、SDK、Swift：`待填写`
- SwiftPM resolved 一致：`待填写`
- SwiftProtobuf：`1.38.1 / 55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`
- 最高适用 quality gate：`待填写`

## Archive 与 Developer ID 导出

- Archive UUID／受控存档位置：`待填写`
- Configuration：`Release`
- App／全部嵌套 Mach-O：`arm64 + x86_64；待从成品读取`
- Developer ID certificate SHA-256／serial／到期：`待填写；禁止记录私钥`
- Hardened Runtime／secure timestamp：`待验证`
- 有效 entitlements／designated requirement：`待验证`
- Embedded profile：`有／无；若有，记录 Team、App ID、到期与 Keychain group`

## 公证与最终 DMG

- App submission ID／状态／log 结论：`待填写`
- App staple／validate／SHA-256：`待填写`
- DMG 文件名／volume／signing identifier／内容：`待填写`
- DMG submission ID／状态／log 结论：`待填写`
- DMG staple／validate：`待填写`
- 最终 DMG SHA-256／byte length：`待 staple 后填写`

## 真实安装与发布裁决

- HTTPS quarantine／Gatekeeper／离线 ticket：`待填写`
- fresh／upgrade／duplicate／different-user／删除重装：`待填写`
- Apple Silicon／真实 Intel macOS 15：`待填写`
- 登录／Keychain／loopback／字幕／弹幕／退出清理：`待填写`
- 未验证边界：`待填写`
- Go／No-Go 与复核人：`待填写`

自动化机器记录为候选目录中的 `release.json`、`app-verification.json`、`app-files.json`、公证日志和 `assets/SHA256SUMS`。公开发布裁决另以绑定 commit 与 DMG hash 的 `acceptance.json` 保存。

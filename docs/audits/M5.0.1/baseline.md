# Gate 0 基线

日期：2026-07-27（Asia/Tokyo）

## Git 与工作树

- `HEAD`／`origin/main`：
  `a00744639f853ffbd7543a56c29a1588d41d93ea`
- 基线提交时间：2026-07-26T23:51:23+09:00
- 基线主题：`docs: 统一提交与 PR 文本规范`
- 审计分支：`codex/m501-external-facts-audit`
- 基线开始时除审计契约外无生产代码修改。
- `/Volumes/Data/Projects/BiliKitMac-documentation-comments` 有未提交修改，不属于本审计
  基线，所有 Agent 禁止读作当前实现、修改、暂存或删除。

PR #18 已合并。WBI 字幕目录迁移属于当前基线，不存在待处理的未提交字幕 diff。

## Apple 工具链

- Apple Silicon（arm64）主机，macOS 26.5.2（25F84）；
- Xcode 26.6（17F113）；
- Apple Swift 6.3.3；
- project：`BiliKitMac.xcodeproj`；
- scheme：`BiliKitMac`；
- App／Tests deployment target：macOS 15.0；
- Swift language version：6.0；
- 产品名：`BiliKit`；
- bundle identifier：`com.shiinayane.BiliKitMac`。

Apple 开发 preflight：0 failures、2 warnings。warning 为系统 `xcode-select` 指向 Command
Line Tools，以及沙箱内不能读取 Xcode process list；任务显式使用
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

沙箱内首次 `xcodebuild -list` 因 ModuleCache／DerivedData 权限失败；在获准的正常 Xcode
缓存环境中，同一命令成功解析以下 targets 和 scheme：

- 当时 targets 包含 App、App tests 和一个后来删除的 UI-test target；
- scheme：`BiliKitMac` 以及本地 Package 的 library／probe schemes。

这组结果只证明工程和 scheme 可解析，不证明 build、签名、运行或行为正确。

## Entitlements 与依赖

App entitlements：

- `com.apple.security.network.client = true`
- `com.apple.security.network.server = true`
- Keychain access group：
  `$(AppIdentifierPrefix)com.shiinayane.BiliKitMac`

外部构建依赖只有 `swift-protobuf` 1.38.1，锁定 revision：
`55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`。

本地 Package 声明 macOS 15，公开 libraries 为 Models、Application、Networking、Auth、
API、Playback、Danmaku、BrowseFeature、AuthFeature、LibraryFeature；另有 `BiliUI` target
和 API／Auth／Playback／Danmaku probes。实际必要性由架构审计线判断，不能从 target
存在本身推导。

## Reference checkout 快照

以下只表示正式审计开始时的本地 checkout，不等于已经证明为远端最新。使用某仓库前必须
重新核对远端当前 commit、活动度和 license。

2026-07-27 已对第一轮会使用的 ATV-Bilibili-demo、wiliwili、BBDown、PiliPlus、
Bilibili-Gate、bilibili-API-collect、AnimacX 与 cilicili 执行只更新远端引用的
`fetch --prune`；八个 `origin/HEAD` 与下表本地 commit 一致。该结果只证明当时远端
默认分支位置，不替代 license 与具体实现取证。

| 仓库 | 本地 commit | commit date | 基线备注 |
| --- | --- | --- | --- |
| ATV-Bilibili-demo | `86ba6f5bb9d6860cb47522a037ef02ab43a4ad55` | 2026-07-05 | clean |
| AnimacX | `e422b05366c6f6f0f64fcd8c10191fc3fe3fa47c` | 2026-07-26 | clean |
| BBDown | `1b2fbd4372d0b9840d28072f7914ae9887508e5d` | 2026-05-14 | checkout 标记 `ARCHIVED` |
| Bili-Swift | `e807ce7e77199fc652f196a8860ee3e1614f9328` | 2025-12-10 | clean |
| Bili.Mac.MenuBar | `9e2124fdb4fa110cd61e665fc077438ae5967a37` | 2022-09-15 | 陈旧候选 |
| Bilibili-Gate | `b3655b95ea18499090e95804bffe1419e10f5c6b` | 2026-07-25 | clean |
| Darock-Bili | `60d66761e34339f7ff1e6d6a2a336f88216c4689` | 2026-06-28 | clean |
| PiliPlus | `f1b79eeafc586b4dab5b4c067f3936b90fef133c` | 2026-07-24 | clean |
| bilibili-API-collect | `4c00347d4f3494318903eeb11fb00d7b9c1f8c68` | 2026-01-30 | deprecated branch |
| bilibili-client-software-collection | `dc06af137d8029241f0abed38b3a61adbf42e415` | 2026-07-25 | 索引，不是实现证据 |
| bilibili-mac-client | `b959abc17b260bcabbacdbbe41a69535deda3062` | 2018-09-30 | 陈旧；缺少 git-lfs，dirty 状态未确认 |
| cilicili | `6f02857c6cac849df3c9f6eecefe483c1b720230` | 2026-07-26 | clean |
| wiliwili | `88e5876bea9502d06f46a8656e3530684d3aaf7d` | 2026-04-25 | clean |

## 现场证据边界

Gate 0 不请求真实服务、不读取 Keychain、不启动签名 App、不记录个人内容。后续每个现场
验证必须先在 finding 中写明假设、最小请求次数、脱敏字段、停止条件和它不能证明的范围。

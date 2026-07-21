# BiliKit macOS 客户端

BiliKit 是一个处于早期阶段、原生且非官方的 macOS B 站客户端。项目优先关注可靠播放、克制的浏览体验，以及符合 Mac 使用习惯的交互方式。

> BiliKit 是第三方项目，与哔哩哔哩不存在隶属、认可或赞助关系。哔哩哔哩相关名称与商标归其权利人所有。

## 当前状态

M1 播放可行性、M2 游客浏览播放闭环和 M2.5 架构整理已经完成。游客功能采用 Feature 级 MVVM：`BiliGuestFeature` 只依赖 Application/Domain，`BiliAPI` 与 `BiliPlayback` 通过 port 接入，App target 只负责依赖组装和 macOS 播放器宿主。M3 已完成 Web QR 契约 Gate，以及版本化 Keychain envelope、精确 endpoint 请求授权和凭据恢复的自动化实现；签名 App 的真实 Data Protection Keychain 往返、登录 Feature 和个性化闭环尚未完成，因此仍不适合日常使用或分发。

- 最低系统版本：macOS 15
- 开发语言：Swift 6
- 界面技术：SwiftUI，按需桥接 AppKit/AVKit
- 播放路线：AVPlayer-first，自有 clean-room DASH→HLS bridge
- 许可证：MIT

当前里程碑和验收门槛见[路线图](docs/ROADMAP.md)，产品与技术证据见[研究基线](docs/RESEARCH-native-macos-client.md)。

## 仓库结构

```text
BiliKitMac/                 App 入口、Composition Root、平台宿主与资源
Packages/BiliKitCore/       包含核心模块的本地 Swift Package
BiliKitMacTests/            App composition 集成测试
BiliKitMacUITests/          关键 UI 流程测试
docs/                       路线图、ADR、验证记录与研究资料
references/                 完全忽略的本地参考项目，不进入 Xcode 工程
```

当前 Package 模块：

- `BiliModels`：Domain entity 与稳定的跨模块值类型。
- `BiliApplication`：游客 Use Case、Repository/Playback port 与应用级错误。
- `BiliNetworking`：传输抽象、无业务语义的请求授权协议、重定向策略、严格 Range 校验、CDN fallback、取消传播和日志脱敏。
- `BiliAuth`：Web QR 状态机、版本化凭据、Data Protection Keychain adapter、精确请求授权器与认证专用 ephemeral transport。
- `BiliAPI`：游客 endpoint、DTO 映射、WBI 签名与 Repository adapter。
- `BiliPlayback`：SIDX、DASH→HLS、loopback 媒体代理和播放 adapter。
- `BiliGuestFeature`：按 Feed、VideoDetail、GuestScene 组织的 SwiftUI View 与 ViewModel。

依赖方向和模型分类见 [ADR 0004](docs/adr/0004-mvvm-clean-architecture.md)。CI 会运行 `Scripts/check-architecture.sh`，阻止 Presentation/Application/Domain 反向依赖具体 adapter。

## 构建

以下命令关闭代码签名，并将 Derived Data 放在仓库之外：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project BiliKitMac.xcodeproj \
  -scheme BiliKitMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/BiliKitMac-derived \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

单独运行 Package 测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/BiliKitCore
```

不同机器的 active developer directory 可能不同。日常开发仍建议直接在 Xcode 中打开 `BiliKitMac.xcodeproj`。

## 显式运行游客 API 探针

`BiliAPIProbe` 会获取匿名 WBI key，对搜索参数签名并解码一页视频结果。它会发起真实网络请求，因此不会自动进入 CI 或 App target：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliAPIProbe \
  --search macOS \
  --page 1
```

探针只输出请求路径、HTTP 状态、响应大小、映射后条数和首条结果摘要，不输出签名查询、响应 body 或凭据。当前边界和运行证据见 [M2 游客 API 验证记录](docs/validation/M2-guest-api-2026-07-21.md)。

## 显式运行 Web QR 契约探针

`BiliAuthProbe` 会在内存窗口显示二维码，并每 2 秒轮询一次，最多运行 180 秒。它用于受控协议回归与必要的现场观察，不会自动进入 CI 或 App target：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliAuthProbe
```

只验证生成 endpoint、主机白名单和内存 QR 渲染，不显示二维码或进入轮询：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliAuthProbe \
  --generate-only
```

不显示二维码，只轮询到服务端过期状态（最长 240 秒）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliAuthProbe \
  --observe-expiry
```

终端只输出安全状态、字段/查询/Cookie 名称、Cookie 属性和二维码主机，不输出 `qrcode_key`、二维码 URL、响应 body、Cookie 或 token 值。当前实现接受已经现场确认的 `86101` 未扫码、`86090` 已扫码待确认、`0` 待凭据校验与 `86038` 过期状态；其他状态会失败关闭。探针仍调用只校验、不持久化的入口；真实 Keychain 提交由后续签名 App 流程显式调用。运行前请先阅读 [M3 威胁模型](docs/security/M3-threat-model.md)。

## 显式运行真实播放探针

`BiliPlaybackProbe` 会解析指定 BVID 的首个分 P，请求游客 AVC/AAC DASH manifest，并检查 `readyToPlay`、初始播放和双向 seek。它会发起真实网络请求，因此不会自动进入 CI 或 App target：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliPlaybackProbe \
  --bvid BV1h4KU66ENd \
  --play-seconds 1 \
  --forward-seek 30 \
  --backward-seek 5 \
  --seek-cycles 1 \
  --replacement-cycles 0
```

游客接口和媒体 URL 都会动态变化。已记录的 BVID 可能失效，或者不再允许请求指定画质，因此一次探针失败本身不能证明播放实现发生回归。探针不会输出带签名的媒体 URL 或响应 body。当前结果见[真实播放验证记录](docs/validation/M1-real-playback-2026-07-21.md)。

M1 收尾矩阵使用 30 秒连续播放、6 轮双向 seek 和 12 次播放项目替换，同时检查视频时间戳相对 AVPlayer timebase 的最大偏差，以及进程最终 RSS 增长。该矩阵已在 GitHub Actions 的 macOS 15 runner 上通过；它只通过手动触发入口运行，不属于 push/PR 必过检查。

## 安全与实现边界

- Cookie 和 token 只能进入 Keychain 与内存。
- 不得将凭据写入 fixture、日志、UserDefaults、SwiftData 或崩溃报告。
- 社区 API 来自逆向分析，必须按可替换、可测试、可能失败的外部依赖处理。
- 可以研究 GPL 项目的公开行为和数据格式，但不得把其源码、注释、fixture 或资产复制进本 MIT 仓库。
- v1 明确不包含下载、直播、投稿、私信、多账号和区域限制绕过。

第三方依赖声明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

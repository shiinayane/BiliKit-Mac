# BiliKit macOS 客户端

BiliKit 是一个处于早期阶段、原生且非官方的 macOS B 站客户端。项目优先关注可靠播放、克制的浏览体验，以及符合 Mac 使用习惯的交互方式。

> BiliKit 是第三方项目，与哔哩哔哩不存在隶属、认可或赞助关系。哔哩哔哩相关名称与商标归其权利人所有。

## 当前状态

仓库目前处于 M1 播放可行性验证阶段。合成及显式运行的真实 AVC/AAC DASH 样本，已经可以通过 loopback HTTP bridge 进入 AVPlayer。真实播放探针属于开发工具，不是产品界面；M1 运行矩阵尚未全部完成，当前版本不适合日常使用或分发。

- 最低系统版本：macOS 15
- 开发语言：Swift 6
- 界面技术：SwiftUI，按需桥接 AppKit/AVKit
- 播放路线：AVPlayer-first，自有 clean-room DASH→HLS bridge
- 许可证：MIT

当前里程碑和验收门槛见[路线图](docs/ROADMAP.md)，产品与技术证据见[研究基线](docs/RESEARCH-native-macos-client.md)。

## 仓库结构

```text
BiliKitMac/                 macOS App shell 与功能界面
Packages/BiliKitCore/       包含核心模块的本地 Swift Package
BiliKitMacTests/            App 集成测试
BiliKitMacUITests/          关键 UI 流程测试
docs/                       路线图、ADR、验证记录与研究资料
references/                 完全忽略的本地参考项目，不进入 Xcode 工程
```

首批 Package 模块：

- `BiliModels`：稳定的跨模块值类型。
- `BiliNetworking`：传输抽象、严格 Range 校验、CDN fallback、取消传播和日志脱敏。
- `BiliPlayback`：SIDX 解析、HLS playlist 生成、loopback 媒体代理和播放器边界。

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
  --backward-seek 5
```

游客接口和媒体 URL 都会动态变化。已记录的 BVID 可能失效，或者不再允许请求指定画质，因此一次探针失败本身不能证明播放实现发生回归。探针不会输出带签名的媒体 URL 或响应 body。当前结果见[真实播放验证记录](docs/validation/M1-real-playback-2026-07-21.md)。

## 安全与实现边界

- Cookie 和 token 只能进入 Keychain 与内存。
- 不得将凭据写入 fixture、日志、UserDefaults、SwiftData 或崩溃报告。
- 社区 API 来自逆向分析，必须按可替换、可测试、可能失败的外部依赖处理。
- 可以研究 GPL 项目的公开行为和数据格式，但不得把其源码、注释、fixture 或资产复制进本 MIT 仓库。
- v1 明确不包含下载、直播、投稿、私信、多账号和区域限制绕过。

第三方依赖声明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

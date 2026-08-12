# BiliKit 仓库说明

## 项目与范围

BiliKit 是原生、macOS-first、非官方 B 站浏览与播放客户端，使用 Swift 6、SwiftUI 和
AVPlayer，最低支持 macOS 15。App 与公开 Swift 模块名为 `BiliKit`；仓库、Xcode 工程和内部
App target 保留 `BiliKitMac`。产品顺序见 `docs/ROADMAP.md`；不要擅自加入下载、转码、导出、
直播、多账号、区域解锁或复杂写操作。

## 架构与安全

```text
Bili*Feature -> BiliApplication -> BiliModels
                       ^ ports
           BiliAPI / BiliAuth / BiliPlayback
                       -> BiliNetworking
```

- Feature 不直接互相 import；跨页面协调留在 App 层，具体 adapter 只在 Composition 可见。
- `BiliApplication` 不出现 endpoint DTO、SwiftUI/AppKit/AVKit、具体 client、Keychain 或
  Cookie。没有真实边界时不增加 Package、target 或 `Common`/`Shared`/`Utils`。
- 依赖方向由 `Scripts/check-architecture.sh` 检查；`references/` 不进入产品或 fixture。
- Cookie、QR key、token、refresh token 与完整认证 URL 只存在于 `BiliAuth` 的短生命周期
  内存和 Keychain，不进入 Feature、UserDefaults、日志、fixture、截图或验证记录。
- 可变网络、认证与播放会话必须有 owner、取消和清理点；旧结果以 identity 或 generation
  隔离。游客、图片、媒体 CDN 与 loopback 请求不得携带认证授权器；loopback 只绑定
  `127.0.0.1`。
- 认证、远端来源、重定向、本地服务器、字幕、弹幕或缓存改动先读取对应 `docs/security/`。

## 测试与 accessibility

- 测试只固定基本产品契约。优先简单 unit/model/ViewModel 测试；XCUI 只用于无法在更低层
  证明的关键系统边界，并保持极少、短且语义化。
- accessibility label、value、trait、grouping 与 focus 只服务 VoiceOver、键盘和真实用户；
  不把 label 当 test ID，不为自动化改变 AX 树。
- 删除依赖 SwiftUI/AppKit 内部层级、固定 index、坐标、任意等待、截图偶然性或 fixture
  自证的测试，不用新 helper、DSL、probe 或 runner 搬运复杂度。
- build、AX tree、截图、真人 VoiceOver/FKA、签名、真实播放和性能是不同证据，不互相替代。

## 工作与验证

- 修改前读取相关代码、测试、ADR、路线图和威胁模型；异步测试用事件、状态或 continuation
  判断完成，固定时长只作超时。
- 默认使用独立 Codex managed worktree；保留已有改动。未经要求不 commit、push、创建 PR、
  改写历史或修改其他 worktree。
- 迭代期间只做最小定向验证；交付前只运行一次覆盖改动的最高适用 Gate：

```sh
sh Scripts/run-quality-gates.sh static
sh Scripts/run-quality-gates.sh package
sh Scripts/run-quality-gates.sh app
```

- 手写 `xcodebuild`、XCUI 和 App 启动统一使用本任务唯一的临时产物根目录，任务结束时清理。
  其他 worktree 或旧共享 DerivedData 不算 fresh closure；若只用于临时运行时诊断，需注明证据边界。
- 仅在明确的性能裁决中运行 Instruments/`xctrace`；事前限定问题、时长、次数和产物目录。
  摘要完成后默认删除 raw trace，并退出 Instruments、确认没有开放 trace、清理临时产物。

## 提交文本

Commit/PR 标题使用 `<type>(可选 scope): <中文动词摘要>`；type 为 `feat`、`fix`、
`refactor`、`test`、`docs`、`build`、`ci` 或 `chore`。PR 与交付说明使用中文并说明变化、
原因、用户影响、实际验证和未覆盖边界。分支名使用 ASCII kebab-case 与当前环境前缀。

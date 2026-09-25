# BiliKit 仓库说明

## 项目与范围

BiliKit 是原生、macOS-first、非官方 B 站浏览与播放客户端：Swift 6、SwiftUI + AppKit、AVPlayer，
最低 macOS 15。App 与 Swift 模块名为 `BiliKit`；仓库、Xcode 工程和内部 App target 保留
`BiliKitMac`。不要擅自加入下载、转码、导出、直播、多账号、区域解锁或写操作。

需要时只读这几份文档，它们描述的是现状：

- `docs/ARCHITECTURE.md`：模块、依赖方向与仍然约束代码的决策。
- `docs/SECURITY-MODEL.md`：认证、远端来源、loopback、缓存、更新与日志规则。
- `docs/ROADMAP.md`：产品目标、当前阶段与非目标。
- `docs/release/README.md`：发布流程。

## 架构与安全

```text
Bili*Feature ──> BiliApplication ──> BiliModels      Browse/Library ──> BiliUI
                        ^ ports
BiliAPI / BiliAuth / BiliPlayback ──> BiliNetworking    BiliDanmaku ──> Application/Models
App（Composition、AppKit/AVKit 宿主）组装以上全部
```

- Feature 不互相 import；跨页面协调在 App 层，具体 adapter 只在 `Composition/`、`Platform/`、`Settings/` 可见。
- `BiliApplication` 不出现 endpoint DTO、UI／播放框架、具体 client、Keychain 或 Cookie。
- 没有真实边界时不新增 Package、target 或 `Common`／`Shared`／`Utils`。依赖方向由
  `Scripts/check-architecture.sh` 检查；`references/` 不进入产品或 fixture。
- Cookie、QR key、token 与完整认证 URL 只存在于 `BiliAuth` 的短生命周期内存和 Keychain。
- 可变网络、认证与播放会话必须有 owner、取消与清理点；旧结果用 identity 或 generation 隔离。
- 认证、远端来源、重定向、本地服务器、字幕、弹幕、图片或缓存改动先对照 `docs/SECURITY-MODEL.md`。

## 代码

- 同一逻辑只写一处。发现第二份副本就合并；已经分叉的副本按 bug 处理。禁止的是没有第二个调用方的
  抽象，不是消除重复的帮手。
- 布局尺寸、时限、容量等数值用具名常量，并放在唯一的几何／策略来源里；测量与布局共用同一计算。
- 单个文件超过约 800 行时，新增代码优先按职责拆到新文件，不再继续堆叠。
- 生产代码不为测试保留恒定参数、计数器或只有测试调用的重载。
- AppKit 只用于有明确理由的地方（见 `docs/ARCHITECTURE.md`）；其余界面默认 SwiftUI。

## 测试与 accessibility

- 测试只固定产品契约。优先 unit／model／ViewModel 测试；XCUI 只用于更低层无法证明的系统边界。
- 同一 port 的测试替身在一个测试 target 内共享一份可配置 stub，不逐个测试复制。
- 不写依赖 SwiftUI/AppKit 内部层级、固定 index、坐标、任意等待或截图偶然性的测试；异步测试用事件、
  状态或 continuation 判断完成，固定时长只作超时。默认不运行的探针不放进测试 target。
- accessibility label、value、trait 与 focus 只服务 VoiceOver、键盘与真实用户；不把 label 当 test ID。
- build、AX tree、截图、真人 VoiceOver/FKA、签名、真实播放和性能是不同证据，不互相替代。

## 文档

- 文档只写现状，改变边界或规则的提交同时更新上面对应文档。不新建 ADR、带日期的验证／证据记录或
  过程叙述；验证结论写进提交说明或 PR。

## 工作与验证

- 修改前读取相关代码与测试。默认在独立 worktree 工作，保留已有改动；未经要求不 commit、push、
  创建 PR、改写历史或修改其他 worktree。
- 迭代时用定向测试。任务临时根由当前任务唯一创建，可在任务内复用，结束时删除：

```sh
sh Scripts/run-targeted-tests.sh "$task_artifact_root" package 'BrowseAndVideoViewModelTests'
sh Scripts/run-targeted-tests.sh "$task_artifact_root" app 'BiliKitMacTests/PlaybackSourceSettingsTests'
```

- 交付前只运行一次覆盖改动的最高适用 Gate（`app` 包含 `package`，`package` 包含 `static`；
  仓库内 Swift 编译警告视为失败）：

```sh
sh Scripts/run-quality-gates.sh static
sh Scripts/run-quality-gates.sh package
sh Scripts/run-quality-gates.sh app
```

- 手写 `xcodebuild`、XCUI 与 App 启动也使用本任务的临时产物根，结束时清理；其他 worktree 或共享
  DerivedData 不算 fresh closure。
- 只在明确的性能裁决中运行 Instruments/`xctrace`，事前限定问题、时长与产物目录，结束后删除 raw trace。

## 提交文本

Commit/PR 标题使用 `<type>(可选 scope): <中文动词摘要>`；type 为 `feat`、`fix`、`refactor`、`test`、
`docs`、`build`、`ci` 或 `chore`。PR 与交付说明使用中文，写明变化、原因、用户影响、实际验证和
未覆盖边界。分支名使用 ASCII kebab-case 与当前环境前缀。

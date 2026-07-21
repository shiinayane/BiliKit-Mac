# ADR 0001：平台、命名与模块边界

- 状态：Accepted
- 日期：2026-07-21

## Context

项目需要在原生 Mac 体验、旧设备覆盖、Swift 6 开发效率和高风险播放链路之间取得平衡。仓库已从 Xcode 模板建立，但产品名、工程名、最低系统版本和模块拆分需要在业务代码出现前固定下来。

## Decision

### 平台

- 最低系统版本为 macOS 14.0。
- 使用 Swift 6。
- SwiftUI 负责 App shell 和普通界面；播放器、窗口和弹幕可按需桥接 AppKit、AVKit 与 Core Animation。
- AVPlayer-first；在 M1 Gate 证明现有路线不能满足核心样本前，不引入 mpv。

### 命名

- 仓库、Xcode project 和内部 app target：`BiliKitMac`。
- 用户可见 App、构建产品、可执行文件和 Swift app module：`BiliKit`。
- bundle identifier：`com.shiinayane.BiliKitMac`。
- 单元测试与 UI 测试 target 保留 `BiliKitMacTests`、`BiliKitMacUITests`。

内部名称保留 `Mac` 是为了与原 BiliKit userscript 仓库区分；这不属于用户可见品牌不一致。

### 模块

- 使用一个仓库内本地 Swift Package：`Packages/BiliKitCore`。
- 通过多个 SwiftPM target 建立编译边界，而不是为每个模块维护独立 `Package.swift`。
- 首批只建立 `BiliModels`、`BiliNetworking`、`BiliPlayback`。
- 后续按里程碑增加 `BiliAPI`、`BiliAuth`、`DanmakuKit`、`BiliPersistence`。
- SwiftUI Feature 初期留在 App target；出现明确复用或编译隔离需求后再通过 ADR 拆包。

依赖必须保持单向：

```text
App / Features → BiliAPI / BiliAuth / BiliPlayback / DanmakuKit / BiliPersistence

BiliAPI ───────┐
BiliAuth ──────┼→ BiliNetworking
BiliPlayback ──┤
DanmakuKit ────┘

BiliAPI / BiliAuth / BiliPlayback / DanmakuKit / BiliPersistence → BiliModels
```

- `BiliPlayback` 不依赖 `BiliAPI`；App 把 API 结果转换为稳定播放模型后交给播放器。
- `BiliAPI` 不依赖具体 `BiliAuth`；认证通过窄协议或请求凭据提供器注入。
- `BiliPersistence` 不保存任何 cookie 或 token。
- 不建立无明确职责的 `Common`、`Shared` 或 `Utils` 底层模块。

## Consequences

### Positive

- macOS 14 可以直接使用 Observation 与 SwiftData，同时仍覆盖 Intel 和 Apple Silicon Mac。
- 播放与网络可以脱离 UI 使用 fixture 测试。
- 单一 package manifest 降低早期工程维护成本，并保留清晰 target 边界。
- 产品品牌与代码仓库关系明确。

### Negative

- 不支持只能运行 macOS 13 或更早版本的设备。
- Package target 之间的 public API 需要更谨慎设计。
- App Feature 暂时没有独立编译边界。

## Validation

- 当前模板已在命令行覆盖 macOS 14 时通过无签名 `build-for-testing`。
- 本地 package 已接入 App target；25 个 package tests 和 App 单元测试通过。
- `BiliKit.app` 的最低系统版本为 14.0，构建产物不包含 `docs/` 或 `references/`。
- 编译成功不等于运行兼容；M1 必须在真实 macOS 14 环境验证 DASH→HLS、loopback HTTP bridge、AVPlayer 与 seek。媒体分段的 Resource Loader 路线已由 ADR 0002 否决。
- CI 已配置为运行 package tests、构建全部 App test targets，并执行 App 单元测试；远程结果待首次推送验证。

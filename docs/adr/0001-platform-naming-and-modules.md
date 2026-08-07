# ADR 0001：平台、命名与模块边界

> 最低系统版本部分已由 [ADR 0003](./0003-raise-minimum-macos-to-15.md) 取代；命名和模块边界决策继续有效。

- 状态：已接受（最低系统版本部分已被取代）
- 日期：2026-07-21
- Bundle Identifier 修订：2026-08-06

## 背景

项目需要在原生 Mac 体验、旧设备覆盖、Swift 6 开发效率和高风险播放链路之间取得平衡。仓库已从 Xcode 模板建立，但产品名、工程名、最低系统版本和模块拆分需要在业务代码出现前固定下来。

## 决策

### 平台

- 最低系统版本为 macOS 14.0。
- 使用 Swift 6。
- SwiftUI 负责 App shell 和普通界面；播放器、窗口和弹幕可按需桥接 AppKit、AVKit 与 Core Animation。
- AVPlayer-first；在 M1 Gate 证明现有路线不能满足核心样本前，不引入 mpv。

### 命名

- 仓库、Xcode project 和内部 app target：`BiliKitMac`。
- 用户可见 App、构建产品、可执行文件和 Swift app module：`BiliKit`。
- 当前开发 bundle identifier：`com.shiinayane.BiliKitMac.dev`。它属于签名环境配置，不是
  用户可见品牌或 Swift 模块名；取得正式开发者账号后允许显式更换。
- 单元测试与 UI 测试 target 保留 `BiliKitMacTests`、`BiliKitMacUITests`。

内部名称保留 `Mac` 是为了与原 BiliKit userscript 仓库区分；这不属于用户可见品牌不一致。

App Debug／Release 必须使用同一个非空、格式合法的 Bundle Identifier。Keychain access
group 固定写成 `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`，由签名身份的 App
Identifier Prefix 与产品标识共同展开；工程契约检查的是两套配置一致和 entitlement 派生
关系。静态契约明确记录当前 `.dev` 值，但不把它视为永久发布标识；将来更换开发者账号时，
工程配置、契约记录与签名验证必须在同一个可 review 的变更中更新。

更换 Bundle Identifier、Team 或 App Identifier Prefix 会形成新的 Keychain access group，
旧签名身份下保存的登录凭据不能视为可迁移状态。开发期更换后应安全回到未登录并重新登录；
不得扩大 access group、绕过 entitlement 或尝试读取旧 Team 的凭据。正式发布标识仍需在
分发准备阶段单独确认，并重跑签名 Keychain smoke 与登录恢复验证。

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

## 影响

### 正面影响

- macOS 14 可以直接使用 Observation 与 SwiftData，同时仍覆盖 Intel 和 Apple Silicon Mac。
- 播放与网络可以脱离 UI 使用 fixture 测试。
- 单一 package manifest 降低早期工程维护成本，并保留清晰 target 边界。
- 产品品牌与代码仓库关系明确。
- 开发签名标识可以随账号准备状态更换，同时保持 Debug／Release 和 Keychain entitlement
  一致。

### 负面影响

- 不支持只能运行 macOS 13 或更早版本的设备。
- Package target 之间的 public API 需要更谨慎设计。
- App Feature 暂时没有独立编译边界。
- 更换签名 Team 或 Bundle Identifier 后，既有 Keychain 登录态不会自动迁移，开发者需要
  重新登录并重新收集签名验证证据。

## 验证

- 当前模板已在命令行覆盖 macOS 14 时通过无签名 `build-for-testing`。
- 本地 package 已接入 App target；25 个 package tests 和 App 单元测试通过。
- `BiliKit.app` 的最低系统版本为 14.0，构建产物不包含 `docs/` 或 `references/`。
- 编译成功不等于运行兼容；M1 必须在真实 macOS 14 环境验证 DASH→HLS、loopback HTTP bridge、AVPlayer 与 seek。媒体分段的 Resource Loader 路线已由 ADR 0002 否决。
- CI 已在 macOS 15 与 macOS 26 上完成 Package 测试、全部 App 测试 target 构建和 App 单元测试。

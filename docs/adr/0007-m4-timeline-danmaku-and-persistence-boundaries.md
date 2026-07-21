# ADR 0007：M4 时间轴、弹幕与持久化边界

- 状态：已接受
- 日期：2026-07-22
- 取代范围：ADR 0001 中关于 `DanmakuKit` 命名，以及 Feature 直接依赖弹幕/持久化实现的早期示意

## 背景

M3 关闭时，BiliKit 已形成 `Feature → BiliApplication → BiliModels` 的内层依赖，以及由 App composition root 注入 `BiliAPI`、`BiliAuth`、`BiliPlayback` 的 adapter 结构。播放器当前只通过 Application port 暴露加载与暂停；AVPlayer 的位置、速率、seek、播放项目替换和结束事件仍只存在于具体 `BiliPlayback` 实现。

字幕与弹幕都必须跟随媒体时间。如果它们各自使用 wall-clock timer，暂停、倍速、seek、卡顿和替换播放项目后会产生漂移、重复喷射或旧视频状态覆盖。弹幕 renderer 还需要 AppKit/Core Animation，而 SwiftData 会引入 schema、迁移和隐私保留边界；这些实现都不能泄漏进 Feature 或 Domain。

ADR 0001 在 Clean Architecture 与产品领域 Feature 整理之前预想了 `DanmakuKit`，并用简化图表示 App/Feature 直接依赖具体弹幕和持久化模块。该部分已不符合当前模块命名与依赖规则，需要由本 ADR 明确取代。

## 决策

### 1. 唯一播放时间轴

- 在 `BiliApplication` 定义平台无关、可取消的播放时间轴 port；快照/事件至少表达播放项目 identity、媒体位置、速率、播放状态和 discontinuity generation。
- `BiliPlayback` 使用 AVPlayer observation 实现该 port，并拥有 observer token、取消、播放项目替换和销毁清理。
- 字幕与弹幕只消费这一时间轴，不创建各自独立的 wall-clock timer，也不把 `AVPlayer`、`CMTime` 或 KVO 类型暴露到 Application/Feature。

### 2. 数据与 API 边界

- `BiliModels` 保存稳定的 `SubtitleTrack`、`SubtitleCue`、`DanmakuEvent` 等值类型，不保存 endpoint DTO、protobuf wire 类型或渲染对象。
- `BiliApplication` 定义字幕目录/正文、弹幕分段、缓存和播放时间轴的窄 port 与 Use Case。
- `BiliAPI` 拥有字幕/弹幕 endpoint、认证要求、Content-Type/大小限制、DTO/wire 解码入口和应用错误映射。

### 3. `BiliDanmaku` target

- 新模块统一命名为 `BiliDanmaku`，不再使用 `DanmakuKit`。
- 它是播放呈现 adapter，不是产品 Feature；只有 decoder → scheduler → renderer 的第一条真实纵向调用链出现时才创建。
- 它可以依赖 `BiliApplication`、`BiliModels` 与必要的系统渲染框架，但不能依赖 `BiliAPI`、`BiliAuth`、其他 Feature 或 `BiliPersistence`。
- scheduler、过滤、去重和 lane allocator 保持可由虚拟时间独立测试；renderer 使用 Core Animation layer 或可复用 NSView 池，并有同屏/排队/复用上限。
- protobuf 实现先经过现场 contract、许可证、Swift 6、构建体积和版本固定审计。若引入第三方库，必须在代码落地前补充本 ADR 或独立依赖 ADR；不能从参考项目复制生成文件或 decoder。

### 4. Overlay 与 Feature

- `BiliBrowseFeature/VideoDetail` 只拥有字幕/弹幕的用户意图、加载状态、轨道选择和平台无关偏好，不 import AVFoundation、AppKit、SwiftData 或具体 adapter。
- App/Platform 在 `AVPlayerView` surface 上组合字幕和弹幕 overlay；composition root 注入时间轴、数据与渲染 adapter。
- 切换视频、分 P 或关闭详情时，以播放项目 identity/generation 同时取消字幕、弹幕、预取和 renderer 状态。

### 5. `BiliPersistence` 延迟创建

- `BiliPersistence` 只有在首个真实字幕/弹幕缓存或播放进度调用方接入时才创建，并实现 Application 定义的 port。
- SwiftData schema 只保存可重建缓存、本机最近播放和播放进度；不镜像服务端观看历史，不保存 Cookie、token、账号身份或远端响应正文。
- BVID 与播放位置属于本机观看行为数据，必须定义版本、容量/期限上限、显式清理和登出规则。首次 schema 变更时再单独决定迁移策略。

## 后果

- 字幕、弹幕和后续 Now Playing 可以共享同一媒体时间事实，暂停、倍速、seek 和替换语义可集中验证。
- Feature 与 Domain 不接触 AVPlayer、protobuf、Core Animation 或 SwiftData，保持 M2.5 建立的依赖方向。
- M4 初期不会立即出现 `BiliDanmaku`/`BiliPersistence` 空 target；字幕纵向切片可以先复用现有模块验证数据和时间轴边界。
- App/Platform 播放 surface 的组合责任增加，需要 App 集成测试固定 overlay 注入和资源清理。
- 未来若要支持另一个播放后端，只需实现相同时间轴 port；字幕和弹幕不依赖 AVPlayer 细节。

## 未采用方案

### Feature 直接观察 AVPlayer

实现短，但会让 SwiftUI/ViewModel 持有平台对象、KVO 与 observer 生命周期，破坏 Application port 并使测试依赖真实播放器。

### 字幕和弹幕各自使用 Timer

无法可靠表达卡顿、暂停、倍速和 seek discontinuity，两个时钟也会产生不同漂移。

### 立即创建多个空 target 与完整 SwiftData schema

会在 contract、调用方和保留策略未确认前固化抽象与迁移成本，违反当前 target 准入规则。

### 把弹幕放进 `BiliBrowseFeature`

会把 protobuf、调度、AppKit/Core Animation 和性能资源生命周期塞进产品 Presentation target，增加 Feature 膨胀并阻止 renderer 独立测试与替换。

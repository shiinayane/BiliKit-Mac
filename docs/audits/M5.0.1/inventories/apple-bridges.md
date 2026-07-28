# Apple bridge 清单

状态：Gate 1 枚举中；由主 Agent 单写。

## Representable 与 AppKit 宿主

| 符号 | 位置 | 当前声称的职责 | 属性 |
| --- | --- | --- | --- |
| `CenteredSearchField` | `BiliKitMac/Platform/CenteredSearchField.swift:4` | toolbar 中居中的 `NSSearchField`、Return 提交和 AX 属性 | production |
| `AVPlayerContainerView` | `BiliKitMac/Platform/PlayerHostView.swift:67` | 把 `AVPlayerView` 与弹幕 overlay 安装到同一原生 surface | production |
| `DanmakuPlayerView` | `BiliKitMac/Platform/PlayerHostView.swift:112` | 使用 `AVPlayerView.contentOverlayView` 承载弹幕 | production |
| `UITestWindowConfigurator` | `BiliKitMac/Composition/UITestContentView.swift:60` | fixture 窗口尺寸配置 | DEBUG fixture |

`PlayerHostLifecycleProbe` 只在注入时记录 host 创建／dismantle，不是系统资源释放证明，必须
与 player、overlay、observer 和 loopback owner 分开审计。

## 手写 Binding

- `AppShellView.swift:142-169`：Tab selection、搜索 draft、按当前 Tab 投影的 playback
  path；
- `SubtitleControlsView.swift:29-32`：Picker selection 到 ViewModel method；
- `DanmakuControlsView.swift:10-38`：四个 Toggle 到 ViewModel methods。

这些 Binding 可能在保持 ViewModel 写入口方面有职责，不能只因语法可改写就判定删除。

## GeometryReader 与布局决策

- `PopularFeedView.swift:87`、`VideoSearchView.swift:131`、
  `WatchHistoryView.swift:106`：根据可用宽度计算视频卡片 Grid 列；
- `GuestVideoDetailView.swift:13`：选择播放页紧凑／宽布局。

## 原生导航与状态入口

- `AppShellView.swift:29`：`TabView(.sidebarAdaptable)`；
- `AppShellView.swift:128`：每 Tab 的类型化 `NavigationStack(path:)`；
- `AppShellView.swift:18-26` 及三个列表 View：以视频 identity 为目标的
  `ScrollPosition`；
- `AppShellView.swift:308`：播放 destination 的 `.onExitCommand`。

## 自定义格式化候选

- `VideoMetadataFormatting`：播放量、相对日期和完整发布日期；
- `WatchHistoryCardFormatting`：进度、相对观看时间和 duration；
- `GuestVideoCard.duration` 与 `GuestVideoDetailView.duration`：重复时长格式化；
- `EndpointPayloads.durationSeconds`：远端 `mm:ss`／`hh:mm:ss` 解析，属于协议解析而非
  UI 格式化。

Gate 1 需要补齐每项的符号位置、调用者、生产／fixture 属性，以及“Apple API 没有提供的
职责”。此表只做枚举，不提前判定 bridge 不合理。

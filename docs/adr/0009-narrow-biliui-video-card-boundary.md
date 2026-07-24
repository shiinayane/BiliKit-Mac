# ADR 0009：建立窄 BiliUI 视频卡片边界

- 状态：已接受
- 日期：2026-07-24
- 关联：ADR 0004、ADR 0006

## 背景

热门／搜索属于 `BiliBrowseFeature`，观看历史属于 `BiliLibraryFeature`。三者需要使用同一视频卡片基础视觉，但 ADR 0006 禁止 Feature 互相依赖；把 SwiftUI 组件放入 Models／Application 也会反转 Clean Architecture 依赖。复制卡片只能获得一次性的相似，后续视觉微调仍会分叉。

## 决策

在现有 `BiliKitCore` Package 内增加内部 target `BiliUI`：

```text
BiliBrowseFeature ─┐
                   ├──> BiliUI ──> SwiftUI / Foundation
BiliLibraryFeature ┘
```

- `BiliUI` 不新增 library product；跨 target 类型与成员使用 Swift `package` 访问级别，不形成外部兼容 API。
- 首个且当前唯一职责是无业务语义的视频卡片外壳与对应网格布局。
- 它只接收图片 URL、已格式化显示文本和选择状态，不 import `BiliModels`、`BiliApplication`、Feature 或具体 adapter。
- B 站主机、图片处理参数、播放量、观看进度、日期和“已看完”等规则继续由拥有语义的 Feature 负责。
- 是否显示头像槽位由调用方明确决定；槽位关闭时折叠，槽位开启但 URL 缺失时只显示非业务占位图。其他元数据缺失时折叠，不伪造内容。
- `BiliUI` 不是 `Common`／`Shared`／`Utils`；新增其他组件必须再次证明至少两个真实调用方与稳定共同语义，不能因 target 已存在而自动准入。

## 不采用

- **Library import Browse**：破坏 Feature 独立边界。
- **复制卡片**：无法持续保证获用户确认的基础视觉一致。
- **放入 Models／Application**：迫使内层模块依赖 SwiftUI。
- **通用设计系统或任意 View registry**：当前只有一个稳定复用点，成本和兼容面高于实际需求。

## 影响

Package 增加一个内部编译边界，两个 Feature 各增加一条指向 `BiliUI` 的依赖。架构脚本必须同时允许该方向并阻止 `BiliUI` 反向依赖业务模块。卡片的业务格式化仍分别测试；真实视觉一致性由同一组件、App Gate 和用户观察共同验证，不新增快照测试框架。

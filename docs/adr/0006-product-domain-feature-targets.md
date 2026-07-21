# ADR 0006：按产品领域组织 Feature target

- 状态：已接受
- 日期：2026-07-21
- 关联：ADR 0004
- 取代：ADR 0004 中以游客状态命名 Presentation target 的部分；其 Clean Architecture 分层与依赖方向继续有效

## 背景

M2.5 以 `BiliGuestFeature` 承载热门、搜索、详情和播放器展示，M3 又为观看历史创建了 `BiliHistoryFeature`。这种命名混合了访问状态、页面和产品领域：游客并不是稳定产品域，历史也只是个人内容库中的一个子功能。若后续每增加页面就增加 target，Package、Xcode product、CI 规则和跨 Feature 协调会同步膨胀；若继续把所有游客能力放进单一 target，又会形成平铺的大 Feature。

当前浏览场景已经包含 Feed、Search、VideoDetail，认证和历史也已有真实 App 调用方，因此现在可以在不改变产品行为的前提下固定领域边界。

## 决策

Feature target 按产品领域划分，target 内按子功能目录组织：

```text
BiliBrowseFeature/
├── BrowseScene/
├── Feed/
├── Search/
└── VideoDetail/

BiliLibraryFeature/
└── History/

BiliAuthFeature/
└── Authentication/
```

- `BiliGuestFeature` 重命名为 `BiliBrowseFeature`；匿名访问策略仍保留在 `Guest*` Application/API 类型中。
- `BiliHistoryFeature` 重命名为 `BiliLibraryFeature`；History 是 Library 域内首个子功能。
- `BiliAuthFeature` 名称保持不变，但实现进入 `Authentication/` 子目录。
- Favorites、WatchLater 等目录只有在真实纵向切片开始时才创建，不增加空 target 或占位目录。
- Feature 之间禁止直接依赖；跨域跳转由 App composition/navigation 层使用类型化 Route 或 Intent 协调。

## 新 target 准入规则

默认在现有产品域 target 内增加子目录。只有存在稳定独立领域、独立状态/导航生命周期、显著不同的安全或性能边界，并且同一变更中有真实 App 调用方和测试时，才考虑新增 Feature target。

单文件约 300 行、子功能约 8 个生产文件或 1,500 行、产品域约 25 个生产文件或 5,000 行是架构审查触发线，不是自动拆分配额。禁止用 `Common`、`Shared`、`Utils` target 转移耦合。

## 实施落点

- `GuestNavigationView` 改为产品域入口 `BrowseNavigationView`。
- 原先混在场景文件中的热门、搜索、详情状态渲染拆到对应子功能目录；ViewModel 和 Application port 行为保持不变。
- Package product、Xcode package product、App imports、测试 target 和架构检查同步使用新 target 名称。
- `BiliApplication` 的认证 port 不再返回 `CGImage`；二维码图像改走 `BiliAuthFeature` 定义的窄 Presentation port，由 composition root 直接注入具体 Auth adapter。

## 影响

产品域 target 数量会随稳定领域增长，而不会随每个页面增长。Browse、Library、Auth 可以在内部继续按纵向功能演进，Package 依赖图仍保持 `Feature → Application → Models`，具体 API/Auth/Playback adapter 从 composition root 注入。

代价是本次需要同步改动 SwiftPM/Xcode product 名称，历史 ADR 与验证记录仍会出现旧名称。它们是当时事实，不批量改写；当前结构以本 ADR、Package manifest 和根 `AGENTS.md` 为准。

当前 App 仍以可选 BVID 字符串协调 History → VideoDetail。这是已知扩展债务：在 M4 增加更多跨域目的地前，应替换为 App 层类型化 Route，避免继续扩展字符串 Binding。

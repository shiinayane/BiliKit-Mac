# Application protocol、UseCase 与 target 清单

状态：Gate 1 全量枚举与第二轮交叉复核完成；由主 Agent 单写。

## 初始 protocol

| Protocol | 生产实现／owner | 当前边界候选 |
| --- | --- | --- |
| `AuthenticationServicing` | `BiliAuthenticationService` | Feature 与 QR／Keychain adapter |
| `AuthenticatedSessionInvalidating` | `BiliAPIClient` | 登出时清理授权 transport 与 WBI key |
| `GuestContentRepository` | `BiliGuestRepository` | Application 与 endpoint／DTO |
| `WatchHistoryRepository` | `BiliWatchHistoryRepository` | 不透明 cursor 与登录 endpoint |
| `SubtitleRepository` | `BiliSubtitleRepository` | 登录目录、正文 URL policy 与 decoder |
| `DanmakuSegmentRepository` | `BiliDanmakuRepository` | protobuf endpoint 与 typed segment |
| `PlaybackTimelineProviding` | `AVPlayerEngine` | 字幕／弹幕共享播放时钟；测试有多个 fake |
| `PlaybackControlling` | `AVPlayerEngine` | Feature 与真实 player／bridge |
| `HTTPRequestAuthorizing` | `BiliCredentialRequestAuthorizer` | Cookie 与 endpoint allowlist |
| `HTTPTransport` | `URLSessionTransport` | 网络 transport；测试和 probes 有 fake |
| `HTTPTransportInvalidating` | `URLSessionTransport` | session 取消和替换 |
| `PlayerEngine` | `AVPlayerEngine` | 更宽的播放控制与 event stream |
| `BiliWatchHistoryService`（已删除） | `BiliAPIClient` | ARCH-004 证实为同 target 一对一转发 |
| `DanmakuPresentationControlling` | `DanmakuPresentationController` | Feature controls 与 renderer/session |
| `DanmakuPresentationSink` | `DanmakuPresentationController` | session 输出与呈现 |
| `DanmakuRenderingBackend` | `CoreAnimationDanmakuRenderer` | 调度／presentation 与 Core Animation |
| `DanmakuRenderingBackendDelegate` | `DanmakuPresentationController` | layer 完成回调 |
| `WebCredentialStoring` | `KeychainWebCredentialStore` | Auth 内部 Keychain 边界 |
| `KeychainOperating` | `SystemKeychainOperations` | Security.framework 调用边界 |
| `AuthenticationQRCodeProviding` | App composition 的 provider | Feature 与不可读 QR payload／Core Image |

## 初始 UseCase

| UseCase | 非转发职责候选 | 生产调用方 |
| --- | --- | --- |
| `GuestFeedUseCase` | query trim、page/pageSize 验证、popular/search sum type | `GuestBrowseViewModel` |
| `GuestVideoUseCase` | 并行详情／分 P、排序、首 P 与播放组合 | `GuestVideoViewModel` |
| `WatchHistoryUseCase` | pageSize、空页跳过上限、cursor 前进检查 | `WatchHistoryViewModel` |
| `SubtitleUseCase` | identity／track 输入验证和 reset 转发 | `SubtitleViewModel` |
| `DanmakuSegmentUseCase` | segment index／identity 与返回 index 验证 | `DanmakuSession` |

初始 20 个手写 protocol 已完成调用者／实现／删除后变化复核；ARCH-004 已删除
`BiliWatchHistoryService`，当前余 19 个。明确删除候选只剩 `PlayerEngine` protocol；
其 event stream 已被 MP-006 证明有失败出口职责，不随 protocol 删除。`SubtitleUseCase`
仍持有 Application 输入 guard，只有 guard 获得等价唯一归属后才是删除候选。测试 fake
数量只能证明可替换点被使用，不能单独证明 production protocol 必要。

## Target 依赖快照

```text
BiliModels
BiliApplication → BiliModels
BiliNetworking
BiliAuth → BiliApplication + BiliNetworking
BiliAPI → BiliApplication + BiliModels + BiliNetworking + SwiftProtobuf
BiliPlayback → BiliApplication + BiliModels + BiliNetworking
BiliDanmaku → BiliApplication + BiliModels
BiliBrowseFeature → BiliApplication + BiliModels + BiliUI
BiliAuthFeature → BiliApplication
BiliLibraryFeature → BiliApplication + BiliModels + BiliUI
BiliUI
```

共 11 个 library target、10 个 library product 与 4 个独立 executable probe target。
11 个 library target 均有 production consumer 和依赖边界；4 个 probe 分别承担不同
现场证据入口，当前保留，但其 transport/output 受隐私 finding 约束。

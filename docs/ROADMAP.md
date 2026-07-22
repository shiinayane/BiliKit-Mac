# BiliKit macOS 路线图

> 状态：M1、M2、M2.5、M3、M4.0–M4.3 和 M4.3.5 已完成；下一步是确认 M4.4 renderer 的不可合入 spike 契约并测量基线。
>
> 基线日期：2026-07-22（Asia/Tokyo）。
>
> 本文描述当前事实、下一阶段和验收门槛；研究依据见
> [`RESEARCH-native-macos-client.md`](./RESEARCH-native-macos-client.md)。计划中的能力在通过对应验收前，不视为已经实现。

## 1. 产品目标

BiliKit 是一个 SwiftUI 驱动、macOS-first、第三方且非官方的 B 站浏览与播放客户端。v1 优先保证：

- 游客可以浏览、搜索并打开视频。
- 用户可以通过 Web QR 安全登录。
- AVC/AAC DASH 可以通过 AVPlayer 可靠播放、seek 和切换 CDN。
- 字幕与弹幕在暂停、倍速和 seek 后保持正确时间轴。
- 窗口、菜单、快捷键和辅助功能符合 Mac 使用习惯。

## 2. 当前仓库基线

截至基线日期，已经存在：

- 独立的 `BiliKitMac` Xcode 工程。
- App 产品名与 Swift 模块名 `BiliKit`；工程和内部 target 保留 `BiliKitMac`。
- Swift 6；App、单元测试、UI 测试和 Package deployment target 为 macOS 15。
- 模板 App、单元测试 target、UI 测试 target。
- `BiliKitCore` 本地 Swift Package，以及 `BiliModels`、`BiliApplication`、`BiliNetworking`、`BiliAuth`、`BiliAuthFeature`、`BiliAPI`、`BiliPlayback`、`BiliDanmaku`、`BiliBrowseFeature`、`BiliLibraryFeature` 十个模块。
- HTTP transport 抽象、基础状态码检查、请求日志脱敏和播放引擎边界。
- README、MIT License、第三方声明、`.gitignore` 和共享 App scheme。
- GitHub Actions 的 Package 测试、App 无签名构建与单元测试工作流。
- 原生 macOS 客户端的竞品、技术和合规研究文档。
- 152 个 Package 测试、28 个测试套件、1 个 App composition 单元测试和 1 个签名 Keychain smoke；原 App 业务测试已迁移到对应 Application/Feature target。
- 以最低 deployment target macOS 15 通过的无签名 `build-for-testing`；构建产物不包含研究文档。
- M0 已在本地提交为 `575879a`。
- 严格 HTTP Range 校验、CDN fallback 与取消传播。
- 自制 H.264/AVC、AAC fMP4 与 SIDX v0/v1 fixture。
- SIDX parser、HLS master/media playlist builder 与 loopback HTTP playback bridge。
- 合成音视频在当前 macOS 开发机通过 AVPlayer 起播、暂停和双向 seek 测试。
- 独立、显式运行的真实播放探针；游客 AVC/AAC 样本已在本地 macOS 26 与 GitHub Actions macOS 15 环境通过连续播放、双向 seek、时间轴采样和连续替换审计。
- GitHub Actions 的 macOS 15 与 macOS 26 构建、Package 测试和 App 单元测试均已通过。
- 首批 `BiliAPI` 游客 endpoint：热门、WBI 签名搜索、视频详情、分 P 和 playurl；每个 endpoint 使用独立解码模型，并映射为公开 API 模型或 `PlaybackManifest`。
- 手写脱敏的热门、nav WBI key、搜索、视频详情、分 P 与 playurl contract fixture，以及 HTML 风控页、API code、字段缺失、输入校验和取消传播测试。
- WBI signer 已固定排序、特殊字符过滤、编码和 MD5 向量；key 按天缓存，签名遭 API 或 HTTP 403 拒绝时只刷新并重试一次。
- `GuestVideoUseCase` 在 Application 层串联详情 → 分 P → 首个分 P 的播放源；`GuestVideoViewModel` 拥有界面 Task 与代次，阻止旧结果覆盖最新状态。
- App target 只链接 Application、Feature 与具体 adapter；`AppEnvironment` 是 composition root，游客 Feed 与视频详情/播放分别由两个 ViewModel 管理。
- playurl 返回的 `Referer` 与 `User-Agent` 会保留到 `PlaybackRequest`，不再在 App 组装边界丢失。
- 真实播放探针已改为复用正式 `BiliAPI`，不再维护第二套临时 endpoint 解码代码。
- App 已接入最小三栏 `NavigationSplitView`，包含热门、WBI 搜索、详情、分 P、系统播放器以及加载、空结果、失败和重试状态。
- 图片模型会把协议相对或 HTTP CDN 地址规范化为 HTTPS；真实热门列表已显示封面。
- 本地真实界面已完成热门与搜索往返、搜索结果 → 详情/首分 P → 播放器起播，以及切换入口时清理详情并暂停播放器的验证。
- `BiliAuth` 已实现认证专用 ephemeral session、重定向拒绝、QR 获取、`86101` 未扫码、`86090` 已扫码待确认、`0` 待凭据校验、`86038` 过期、取消/旧代次隔离、精确二维码主机校验和内存二维码渲染。
- 成功响应以 `Set-Cookie` 为权威来源，只保留五项精确白名单到短生命周期内存；JSON URL 值和 refresh token 不采集。白名单 Cookie 已通过 nav `isLogin=true` 现场验证并立即清空。
- `BiliAuthProbe` 可显式显示内存二维码、观察服务端过期并进行脱敏轮询；未知状态失败关闭，不持久化成功凭据。
- `BiliAuth` 已实现五项 Cookie 的 schema v1 envelope、固定 service/account 的 generic-password store，以及所有操作显式启用 Data Protection Keychain、`WhenUnlockedThisDeviceOnly` 和非同步属性的 SecItem 查询。
- App 已配置由 Team ID 展开的最小 `keychain-access-groups` entitlement；签名测试宿主使用独立测试 service/account 完成真实 add/update/read/delete、属性检查和最终清理，未签名 CI 明确跳过该 smoke。
- `BiliNetworking.HTTPRequestAuthorizing` 保持无业务语义；具体授权器只允许 nav 与参数受限的观看历史 GET endpoint，独立拒绝 HTTP、相似主机、CDN、loopback、错误路径/方法、预置 Cookie 和跨主机重定向。
- Web QR 提供显式的“nav 校验后同步提交 store”入口；缺失、损坏、过期或远端 `isLogin=false` 会回退未登录并按规则清除，暂时网络失败不会误删凭据。
- `BiliApplication` 已定义不含 Cookie、QR URL 或 endpoint DTO 的认证状态与用户意图 port；`BiliAuth` adapter 负责恢复、QR 编排、最终提交和本地登出。
- `BiliAuthFeature` 已接入真实账号 sheet；ViewModel 拥有两秒轮询 Task 与界面代次，二维码只以进程内 `CGImage` 投影进入界面。
- 完整本地登出会先取消请求和清除临时二维码，再删除 Keychain item、失效两类 ephemeral session，最后发布未登录；删除失败不会伪装成已退出。
- `BiliLibraryFeature/History` 已按 MVVM 接入只读观看历史；关闭 sheet 与登出会取消任务并清空个性化列表，条目复用既有浏览详情/播放器链路。
- Feature target 已由访问状态/单页面命名改为产品领域命名；`BiliBrowseFeature` 内按 BrowseScene、Feed、Search、VideoDetail 划分，`BiliLibraryFeature` 当前只包含 History，`BiliAuthFeature` 当前只包含 Authentication。
- `BiliApplication` 的认证 port 已移除 `CGImage`；二维码渲染通过 Auth Feature 定义的 Presentation port，由 composition root 直接注入具体 Auth adapter。
- 当前 macOS 已完成真实扫码、历史读取、详情/播放器跳转、进程重启恢复、恢复后再次授权、界面登出、第二次重启未恢复和游客回退；没有输出或保存账号身份、历史内容或秘密值。
- App Sandbox 已显式配置出站网络与 loopback server entitlement；签名 App 的网络请求和播放桥不再依赖无签名运行的隐含权限。
- CI 已加入已知二维码 key、Cookie 与 refresh token 模式扫描；`qrcode_key` 进入 URL 日志脱敏集合。

尚不存在：

- 弹幕 renderer、产品界面接入与业务持久化实现；观看历史当前只读且只映射普通视频 archive。

当前已知开发环境事项：

- 默认 `xcode-select` 指向 Command Line Tools；命令行构建需显式设置 `DEVELOPER_DIR`，或由开发者自行切换全局配置。

## 3. 执行原则

1. 先处理会影响后续所有工作的基础约束，再做产品 UI。
2. 优先验证 DASH→HLS→AVPlayer 这条最大技术风险，不先扩张页面数量。
3. 使用一个本地 Swift Package、多个 target 建立边界；不创建无实现的占位模块。
4. endpoint 使用独立 Codable 模型和录制 fixture；计划和第三方 README 不是运行证据。
5. Web Cookie、App token 和其他秘密只进入 Keychain 与内存，不进入日志、UserDefaults、SwiftData 或 fixture。
6. GPL 项目只用于研究机制；MIT 仓库中的实现必须来自自有代码、Apple 文档和自制测试材料。
7. 每个阶段必须通过 gate 才进入下一阶段；未通过的计划项不得写成已完成功能。
8. MVVM 只用于 Presentation 层的状态与用户意图；Clean Architecture 用于控制跨层依赖，不能把 ViewModel 当作新的全局业务容器。
9. 架构迁移必须由可运行的纵向功能驱动，不创建没有当前调用方的 Repository、Use Case、DTO 或 `Utils` 占位类型。
10. M2.5 只重构已经通过 Gate 的游客闭环；除修复迁移中暴露的回归外，不同时增加认证、持久化或新页面。

## 4. 里程碑

### M0：工程基线与最小模块骨架（已完成）

目标：让仓库可以在不依赖私人签名的环境中稳定构建、测试和演进。

交付物：

- 将 `docs/`、`references/` 从 App target resources 中移除。
- 统一 App、测试和 package 的 macOS 15 / Swift 6 配置。
- 添加 `.gitignore`、README、MIT License、非官方声明和 `THIRD_PARTY_NOTICES.md`。
- 建立一个本地 package：`Packages/BiliKitCore/Package.swift`。
- 首批只创建并使用三个 target：
  - `BiliModels`：稳定的跨模块领域模型。
  - `BiliNetworking`：HTTP client、Range、取消、错误识别和脱敏日志。
  - `BiliPlayback`：播放协议与后续 Spike 的实现位置。
- 添加 package tests 和最小 CI。

Gate：

- 全新 clone 无需私人证书即可构建 App 和全部测试 target。
- package tests 与 App tests 通过。
- 构建产物不包含研究文档、token、cookie 或本机路径。
- App target 只负责入口、窗口和依赖组装，不承载底层网络或播放算法。

### M1：播放可行性 Spike（已完成）

目标：在投入完整浏览和认证功能前，证明 AVPlayer-first 路线可行。

交付物：

- 使用自制 fMP4/SIDX fixture 实现并测试 SIDX parser。
- 根据视频、音频 representation 生成 HLS master/media playlist。
- 使用仅绑定 `127.0.0.1` 的 loopback HTTP bridge 处理 AVPlayer Range 请求；自定义 scheme 媒体分段路线已由 ADR 0002 的运行验证否决。
- 最小 `AVPlayerView` 宿主，可播放、暂停和双向 seek。
- CDN 候选排序、失败切换、取消和最小诊断事件。
- macOS 15 真实运行测试记录；条件允许时覆盖 Intel。

Gate：

- AVC 视频轨与 AAC 音频轨可以稳定起播并保持同步。
- 从中段向前、向后 seek 后可以继续播放。
- 首选 CDN 返回 403、无效 `Content-Range` 或错误页时会尝试备用线路。
- 取消或替换播放项目后没有悬挂请求和持续增长的资源占用。
- 若 Gate 失败，先通过 ADR 决定修正 Bridge 或引入可选 mpv 后端，不继续堆浏览 UI。

Gate 结论：通过。真实播放收尾矩阵已在 macOS 15.7.7 arm64 runner 上完成 30 秒连续播放、6 轮双向 seek、552 个视频时间轴采样和 12 次播放项目替换，最终 RSS 增量为 0 MiB；受控测试覆盖失败切换、取消与旧 server 资源归零。证据及测量边界见 [`validation/M1-real-playback-2026-07-21.md`](./validation/M1-real-playback-2026-07-21.md)。

### M2：游客浏览到播放的纵向闭环（已完成）

目标：无账号即可完成列表 → 详情 → 分 P → 播放。

交付物：

- 增加 `BiliAPI` target，包含 endpoint 级请求/响应模型、WBI 和 fixture contract tests。
- 热门或 Web 推荐中的一个入口、搜索、视频详情与分 P。
- 最小 `NavigationSplitView`，只实现闭环所需页面。
- 加载、空状态、取消、重试、HTML 风控页和字段缺失处理。
- 将 API 返回的播放描述转换为 `BiliModels.PlaybackManifest` 后交给 `BiliPlayback`。

Gate：

- 无账号从启动进入列表，搜索或选择视频，并成功播放一个分 P。
- 快速切换视频时旧请求被取消，旧结果不会覆盖当前页面。
- endpoint fixture 能发现字段漂移，错误响应不会让 UI 卡死。

Gate 结论：通过。匿名真实界面已完成热门与 WBI 搜索、结果选择、详情/首分 P 和 AVPlayer 起播；统一 feed 状态机以代次隔离旧请求，失败态保留原请求并可重试。43 项 Package 测试固定 endpoint 和错误边界，8 项 App 单元测试固定热门/搜索切换、选择取消、播放器暂停和错误重试。完整记录见 [`validation/M2-guest-api-2026-07-21.md`](./validation/M2-guest-api-2026-07-21.md)。

### M2.5：基于 MVVM 的 Clean Architecture 整理（已完成）

目标：在进入认证与持久化前，把已验证的游客闭环迁移为可持续扩展的分层结构；保持 M2 的产品行为、接口能力和播放链路不变。

#### 目标依赖方向

```text
BiliKit App（Composition Root / macOS Scene）
├── BiliGuestFeature（SwiftUI View + ViewModel）
│   └── BiliApplication（Use Case + Port）
│       └── BiliModels（Domain Entity / Value）
├── BiliAPI（Remote Data Adapter）
│   ├── BiliApplication / BiliModels
│   └── BiliNetworking
└── BiliPlayback（Playback Adapter）
    ├── BiliApplication / BiliModels
    └── BiliNetworking
```

依赖规则：

- `BiliModels` 是最内层 Domain，不依赖 API、网络、播放框架、SwiftUI 或 App target。
- 新增 `BiliApplication`，只放当前已有流程需要的 Use Case、Repository/Service port 和应用级错误；它只依赖 `BiliModels`。
- `BiliAPI` 是远端数据 adapter：endpoint DTO、WBI 和响应解码留在其中，对外实现 `BiliApplication` 定义的 port；API code、HTML 风控页和字段漂移不能泄漏为 Presentation 的直接依赖。
- `BiliPlayback` 是播放 adapter：保留 AVFoundation、loopback bridge 和媒体请求实现，并实现 Application 层的播放 port。
- 新增 `BiliGuestFeature` 作为 Presentation target：按 Feature 放置 SwiftUI View、ViewModel、UI State 和用户可读错误映射；只依赖 `BiliApplication` 与 `BiliModels`，不直接导入 `BiliAPI`、`BiliNetworking` 或 `BiliPlayback`。
- `BiliKit` App target 只保留 `App` 入口、`Composition` 依赖组装、必须留在平台边界的宿主代码和 Assets；具体实现类型只在 Composition Root 出现。
- Probe 属于开发验证入口，可以直接依赖具体 adapter，但不能成为产品 Feature 的反向依赖。

#### 迁移步骤

1. **固定现状并记录决策**
   - 新增 ADR，说明分层、target、依赖方向、命名和不采用的过度抽象方案。
   - 为 M2 现有热门、搜索、详情、分 P、播放、重试、取消和旧结果隔离补齐 characterization tests；先保证迁移失败能被发现。
   - 盘点公开模型，把“领域数据”“远端 DTO”“应用状态”“播放器实现参数”分类，形成迁移清单后再移动代码。
2. **建立 Domain 与 Application 边界**
   - 继续使用 `BiliModels` 承载稳定领域模型，不为改名进行无价值的大规模 churn。
   - 新增 `BiliApplication` target，定义游客浏览/搜索、视频准备和播放控制所需的窄 port。
   - 将 `GuestVideoCoordinator` 的详情 → 分 P → 播放源编排迁入 Application Use Case；Use Case 不持有 SwiftUI 状态，也不导入具体 API/播放器模块。
   - 将 API 专属错误映射为应用级、可测试的失败类型；用户文案仍由 Presentation 决定。
3. **收紧 Data 与 Platform adapter**
   - 将 endpoint request/response DTO 和映射集中到 `BiliAPI` 内部目录；Feature 不再直接消费 endpoint/API 错误类型。
   - 由 `BiliGuestRepository` 包装 `BiliAPIService` 并实现 Application port，同时保留现有 fixture contract tests、WBI 单次刷新与取消语义。
   - 让播放实现适配 Application playback port；保留 `PlaybackManifest`、请求头、CDN fallback、Range 和 loopback server 的既有边界，不重写已经通过 M1 的算法。
4. **迁移为 Feature 级 MVVM**
   - 创建 `BiliGuestFeature`，按 `Feed`、`VideoDetail` 和共享 Presentation 组件组织代码，不按 `View/Model/Utils` 建立跨功能大目录。
   - 将现有大模型拆为游客 Feed ViewModel 与视频详情/播放 ViewModel；ViewModel 负责把用户意图转换为 Use Case 调用、维护 `@MainActor` UI State，以及拥有界面生命周期内的 Task/取消与旧结果隔离。
   - SwiftUI View 只做状态渲染、绑定和发送用户意图；不直接发 API 请求、不组装 `PlaybackRequest`、不解释底层错误。
   - 播放画面通过窄的 Presentation/平台边界注入，避免为了显示 `AVPlayerView` 让整个 Feature 重新依赖具体播放 adapter。
5. **缩薄 App target 与整理测试**
   - 将 App target 整理为 `App/`、`Composition/`、`Platform/` 与 `Resources/`；删除迁移完成后的平铺旧文件，不保留新旧两套实现。
   - 测试按责任落位：Domain 值语义、Application 用例、API/Playback adapter contract、ViewModel 状态迁移；App tests 只保留 composition 与平台集成检查。
   - 在 CI 增加轻量依赖边界检查，阻止 `BiliGuestFeature` 直接导入 Data/Platform adapter，阻止 Domain/Application 导入 SwiftUI、AVKit 或网络实现。
6. **回归、文档与收尾**
   - 运行全部 Package/App 测试与 macOS 15 无签名构建，并重新执行游客热门、搜索、详情、起播、入口切换和取消 smoke test。
   - 更新模块图、目录说明、测试数量和验证记录；删除只描述旧结构的文档内容。
   - M2.5 Gate 关闭后才开始 M3；M3 的 `BiliAuth` 必须按同一 port/adapter 规则接入，不再把认证编排放进 ViewModel 或 API client。

#### 建议目录落点

```text
BiliKitMac/
├── App/
├── Composition/
├── Platform/
└── Assets.xcassets/

Packages/BiliKitCore/Sources/
├── BiliModels/                 # Domain
├── BiliApplication/            # Use Cases + Ports
├── BiliGuestFeature/           # MVVM Presentation，按 Feature 细分
├── BiliAPI/                    # Remote Data Adapter + DTO mapping
├── BiliNetworking/             # HTTP infrastructure
└── BiliPlayback/               # Playback Adapter + AVFoundation/loopback
```

这里仍维持一个仓库内 Swift Package、多个 target；M2.5 不拆成多个 `Package.swift`，也不引入第三方 DI、Coordinator 或 Redux 框架。

Gate：

- M2 已验证的用户行为无回归：游客热门、搜索、详情、首分 P、起播、重试、快速切换与入口切换全部通过。
- `BiliGuestFeature` 不依赖 `BiliAPI`、`BiliNetworking`、`BiliPlayback`；`BiliApplication` 只依赖 `BiliModels`；`BiliModels` 不依赖任何外层 target。
- App target 中不存在 endpoint DTO、业务 Use Case、WBI、HTTP、播放请求组装或跨页面业务状态机。
- View 不直接调用 API/播放器；ViewModel 不解码 DTO、不访问 Keychain、不创建具体 client，并且每个 ViewModel 的状态与取消行为有独立测试。
- 迁移后不存在新旧双轨实现、无调用方占位抽象或 `Common`/`Shared`/`Utils` 杂物模块。
- 现有 Package/App 测试、macOS 15 build-for-testing 和真实游客 UI smoke test 全部通过，并新增一份 M2.5 架构验证记录。

Gate 结论：通过。游客功能已迁入 `BiliApplication` 与 `BiliGuestFeature`，App target 缩为入口、composition root 和平台播放器宿主；CI 依赖检查固定 Domain/Application/Presentation 的单向边界。54 项 Package 测试、1 项 App composition 测试、macOS 15 deployment build-for-testing 和 macOS 26.5.2 arm64 真实游客 UI 回归均通过。完整记录见 [`validation/M2.5-clean-architecture-2026-07-21.md`](./validation/M2.5-clean-architecture-2026-07-21.md)。

### M3：Web QR 登录与安全凭据

目标：建立不泄露凭据的登录闭环，并解锁一个个性化功能。

#### 目标依赖方向

```text
BiliKit App（Composition Root）
├── BiliAuthFeature（SwiftUI View + ViewModel）
│   └── BiliApplication（非秘密认证 Use Case + Port）
│       └── BiliModels
├── BiliAuth（Web QR + Keychain + Request Authorizer）
│   └── BiliApplication / BiliNetworking
└── BiliAPI（匿名与登录 endpoint）
    └── BiliApplication / BiliModels / BiliNetworking
```

- QR key、完整二维码 URL、Cookie 和 refresh token 只能存在于 `BiliAuth` 内部，不进入 Domain、Application、Feature 或 App 恢复状态。
- `BiliApplication` 只暴露非秘密的登录状态、身份投影和用户意图 port；ViewModel 不取得 Cookie，也不读写 Keychain。
- `BiliNetworking` 提供无业务语义的窄请求授权协议；`BiliAPI` 可选注入授权器，但不依赖具体 `BiliAuth`。
- Cookie 只按 endpoint 显式附加到精确允许的 HTTPS 主机，不能进入图片/视频 CDN、loopback bridge 或跨主机重定向。
- 使用专用 ephemeral session 与 Data Protection Keychain；本地登出不依赖网络成功。

#### 实施步骤

1. **安全设计与现场基线（已完成）**
   - 现场验证匿名 QR 生成和“未扫码”轮询的最小响应结构，不记录任何秘密值。
   - 接受 ADR 0005，固定 Auth/Application/Networking/Feature 边界、Keychain 策略和不采用方案。
   - 建立 [`security/M3-threat-model.md`](./security/M3-threat-model.md)，覆盖 QR 泄漏、Cookie 误发、旧任务覆盖、部分持久化、登出残留和 fixture 泄密。
2. **基础状态机与脱敏契约（已完成）**
   - 创建实际被探针调用的 `BiliAuth` target；实现生成、未扫码、取消、网络失败和未知状态的 actor 状态机。
   - 使用全假值手写 fixture；扩充日志脱敏和源码/fixture/test output 秘密扫描。
   - 增加显式运行的人工扫码探针，只输出状态序列、字段名、Cookie 名称/属性与主机。
3. **成功/过期协议 Gate（已完成）**
   - 由开发者扫码，确认已扫码未确认、成功、过期状态、二维码有效期、成功凭据来源和 Cookie allowlist。
   - 以手写假值补齐成功/过期 fixture；确认登录态校验 endpoint 与凭据失效语义。
   - 在此 Gate 前不保存真实 Cookie，不实现 refresh token 流程。
4. **Keychain 与请求授权（已完成）**
   - 实现版本化 generic-password credential envelope、原子 add/update/read/delete、内存清理和 Keychain 错误映射。
   - 实现 endpoint 级请求授权器、HTTPS/精确主机白名单与重定向拒绝；游客 endpoint 默认不带 Cookie。
   - 成功结果必须先通过登录态验证，再一次性提交 Keychain；损坏或失效凭据回退游客模式。
5. **Feature MVVM 与完整登出（已完成）**
   - 有真实 UI 调用方时创建 `BiliAuthFeature`；二维码、等待确认、过期、取消、重试和错误状态分别可见。
   - ViewModel 拥有轮询 Task 与代次；旧二维码结果不能覆盖新意图。
   - 登出依次取消请求、清内存、删除 Keychain item、失效 session，再更新 UI；离线时也必须完成。
6. **个性化纵向闭环与跨环境验证（已完成）**
   - 在历史、收藏或登录推荐中只选一个闭环，使用登录 endpoint → Application Use Case → Feature MVVM 接入。
   - 完成重启恢复、凭据失效、无 Keychain item、游客回退和真实 UI smoke test。
   - 记录 macOS 15/26 CI 与当前 macOS 的 M3 验证证据。
7. **独立审查整改（本地已完成，等待当前变更集远程 CI）**
   - 为 playurl 产生的媒体 URL 建立可审计来源策略：默认 HTTPS，拒绝 userinfo、异常端口、loopback/private/link-local 主机；Range transport 的每次重定向重复校验同一策略，并加入负向测试。
   - 恢复登录失败页同时提供“重试恢复”和“清除本机登录状态”，避免坏凭据使用户无法重新登录。
   - QR 轮询增加可注入的本地总时限；超时必须取消 challenge、清空内存二维码并进入可重新生成状态。
   - 观看历史首批 archive 过滤后为空但仍有 cursor 时，Use Case 有上限地继续翻页，或至少保留明确的加载更多入口。
   - 将观看历史 wire cursor 收回 API adapter，Application 只持有不透明 continuation token；为 entitlement/PBX 增加静态契约检查，并把真实签名 Keychain smoke 明确保留为发布 Gate。

交付物：

- 增加 `BiliAuth` target；有真实界面调用方时增加 `BiliAuthFeature` target。
- Web QR 获取、轮询、过期、取消、重试和登录态验证状态机。
- Keychain credential store、内存副本清理与完整登出。
- 历史、收藏或登录推荐中的一个完整闭环。
- 凭据威胁模型、日志脱敏与秘密扫描测试。

Gate：

- 登录、重启 App、校验登录态和登出流程可重复完成。
- 日志、UserDefaults、SwiftData、fixture 和测试失败输出中不存在 cookie/token。
- 游客模式在没有 Keychain item 或凭据失效时仍然可用。
- Cookie 没有发送到未授权 endpoint、CDN、loopback 或跨主机重定向。
- 未知 QR 状态、旧轮询结果与部分成功响应均不能提交凭据。

Gate 结论：通过。观看历史已完成登录 endpoint → Application Use Case → Feature MVVM → 既有详情/播放器的纵向闭环；真实扫码、进程重启恢复、恢复后历史授权、界面登出、第二次重启未恢复和游客回退均已有受控证据。2026-07-21 独立审查提出的四项阻断，以及不透明 continuation、entitlement/PBX 静态契约两项结构清理，已于 2026-07-22 完成本地实现和回归；真实游客播放探针同时确认新媒体来源策略兼容当前 CDN。提交 `6236753` 的 GitHub Actions run `29843186800` 已在 macOS 15/26 完成 Package、App、架构、秘密与工程静态契约矩阵，M3 正式关闭。整改与关闭记录见 [`validation/M3-audit-remediation-2026-07-22.md`](./validation/M3-audit-remediation-2026-07-22.md)。

### M4：字幕、弹幕与本地状态

目标：补齐 B 站观看体验，同时保持时间轴和性能正确。

#### 当前缺口与目标依赖方向

当前 `PlaybackControlling` 只提供加载与暂停，Feature 不知道播放位置、速率、seek 代次或播放项目身份；仓库也没有字幕/弹幕 contract、overlay 宿主或业务持久化。M4 不能直接从“画几条弹幕”开始，必须先建立唯一时间轴和数据边界。

```text
BiliBrowseFeature/VideoDetail
        ├──> BiliApplication（字幕/弹幕 Use Case、时间轴与缓存 port）
        │        └──> BiliModels（SubtitleTrack/Cue、DanmakuEvent）
        └──> App/Platform 播放与 overlay 宿主

BiliAPI ───────────────> 字幕与弹幕远端 adapter
BiliPlayback ──────────> AVPlayer 时间轴 adapter
BiliDanmaku ───────────> 调度、过滤、轨道分配与 AppKit/Core Animation renderer
BiliPersistence ───────> 可重建缓存与本地播放状态 adapter（出现真实调用方后才创建）
```

- Feature 不直接 import `BiliAPI`、`BiliPlayback`、`BiliDanmaku`、SwiftData、AVFoundation 或 AppKit。
- `BiliPlayback` 是播放时间的唯一事实源；字幕和弹幕不得各自启动独立 wall-clock timer。
- `BiliDanmaku` 是播放呈现 adapter，不是新的 Feature；第一条真实 `BiliAPI wire decoder → BiliDanmaku scheduler → renderer` 链路出现时才创建 target。
- `BiliPersistence` 只有在首个缓存/播放进度纵向切片接入时才创建，不预建空 schema、Repository 或迁移层。
- 播放 surface 与 overlay 仍由 App/Platform 组装；`BiliBrowseFeature` 只持有用户意图和平台无关状态。

#### 实施步骤

1. **M4.0：协议、隐私与架构 Gate（已完成）**
   - 用显式探针确认字幕目录/正文与点播弹幕分段的最小请求和响应结构、认证要求、主机、Content-Type、大小上限及错误形态；输出只保留结构、计数和状态，不保存真实字幕/弹幕内容或内容标识。
   - 用全假值手写字幕目录、字幕正文、弹幕分段、空响应、截断/超大二进制、HTML/JSON 错误 fixture；现场观察不能替代 deterministic contract test。
   - 接受 ADR 0007，固定时间轴 port、`BiliDanmaku` target、overlay composition 与延迟创建 `BiliPersistence`。ADR 0008 已完成 SwiftProtobuf 的许可证、版本固定、构建体积与 Swift 6 审计；runtime 仍延迟到 M4.3 首个真实调用方再引入。
   - 增加 M4 数据与隐私说明：字幕/弹幕缓存、BVID、播放位置均可反映观看行为，明确保留期限、容量上限、登出/手动清理和禁止写入日志/诊断的字段。
2. **M4.1：统一播放时间轴（已完成）**
   - 在 Application 定义平台无关、可取消的播放时间轴快照/事件 port，至少表达播放项目 identity、位置、速率、播放/暂停/结束和 discontinuity generation。
   - `BiliPlayback` 通过 AVPlayer periodic time observer 与状态观察实现该 port；替换播放项目、seek、暂停、倍速和销毁都有明确重置/移除观察点。
   - 使用虚拟时间和假的 timeline adapter 固定暂停、倍速、前后 seek、旧项目事件隔离与订阅取消；不把 `AVPlayer`、`CMTime` 或 observer token 暴露给 Feature。
3. **M4.2：字幕优先的第一条纵向切片（已完成）**
   - 在 Models/Application 定义字幕轨、cue 与目录/正文 port，由 `BiliAPI` 使用 endpoint DTO 和脱敏 fixture 实现；未知格式、非单调时间与越界 cue 失败关闭或按明确规则丢弃。
   - 在 `BiliBrowseFeature/VideoDetail/Subtitle` 增加字幕 ViewModel、关闭/轨道选择和当前 cue 状态；切换视频/分 P/字幕轨时取消旧请求并用 identity 阻止旧 cue 覆盖。
   - App/Platform 在播放器 surface 上组合轻量字幕 overlay。字幕同屏数量很小，可以使用 SwiftUI 文本；其显示只消费统一播放时间轴。
   - 先完成无字幕、单/多轨、切轨、暂停、倍速、前后 seek 和真实样本 smoke，再进入弹幕实现。
4. **M4.3：弹幕数据与调度内核（已完成）**
   - `BiliAPI` 使用精确固定的 SwiftProtobuf runtime 将 protobuf 映射为 typed event；创建有真实调用方的 `BiliDanmaku` target，实现分段索引、预取窗口、去重、基础类型/关键词过滤和 seek 后游标重建。protobuf wire 类型不进入 `BiliDanmaku`、Application 或 Feature。
   - scheduler 只消费统一时间轴与 Application 弹幕分段 port；同一视频/分 P 使用 generation 隔离，网络、解码与预取 Task 有单实例、并发数和缓存上限。
   - 用虚拟时间覆盖正向播放、暂停、2×、大幅前后 seek、分段边界、重复事件、乱序/截断输入和取消，不先依赖真实 renderer 判断正确性。
5. **M4.3.5：工程治理 Gate（已完成）**
   - 固化红黄绿风险分级、Goal/Context/Constraints/Done when 任务契约、独立上下文只读审查和 branch/worktree 隔离；风险等级只追加验证，不降低现有 Package/App 基线。
   - 固化项目级 Agent 路由：Sol Medium 负责主决策，Luna Low 负责窄范围只读探索，Terra Medium 负责契约明确的实现，Terra High 负责黄区审查，Sol High 负责红区与重要 Gate 终审；按歧义、边界、失败和返工自动升级。
   - 用 `Scripts/run-quality-gates.sh` 统一 static/package/app 命令，并让普通 CI 调用同一 App Gate；任务专用真实探针和长时测量继续显式运行。
   - 用本阶段自身完成第一次试运行：在短分支修改治理文件，三路不继承主对话的 Agent 只读审查，按 blocker/improvement/reject 记录结论并整改。
   - `docs/validation/` 只保存难以自动化且需要复查的证据；普通测试结果保留在 CI，不建立逐函数 Changelog 或人工调用链台账。

   Gate：统一脚本在当前环境通过 App 全矩阵；CI 不再维护另一套重复命令；隔离审查发现的基线降级、Git 授权等冲突已整改；治理规则、PR 模板和试运行证据可以指导下一项红区任务。
6. **M4.4：有界 renderer 与播放 surface 集成**
   - M4.4 是红区任务。先由用户确认 [`development/M4.4-renderer-spike-contract.md`](./development/M4.4-renderer-spike-contract.md) 的假设、合成输入、测量项和退出条件，再在独立 `codex/spike-*` 分支做不可合入的 Core Animation/AppKit 实验，测量可承受密度、活动对象、文字资源、帧率和 RSS 基线；关闭 spike 后再由用户确认生产契约。
   - 使用 Core Animation layer 或可复用 NSView 池实现滚动/顶部/底部基础类型、lane allocator、碰撞预测和对象复用；不把每条弹幕建成长生命周期 SwiftUI `Text`。
   - 根据 spike 结果明确最大同屏数、排队深度、对象池、丢弃/降级顺序、字号/透明度/密度和帧率/RSS 阈值；resize、全屏和容器替换时重新计算轨道而不重复喷射。
   - 动画速度由媒体时间与播放速率推导；暂停冻结，seek/discontinuity 清空并按新时间窗重建，旧 generation 的动画和 Task 必须释放。
   - 独立上下文分别补失败/过载场景和只读审查线程、所有权、surface 清理；快速合成 probe 进入普通 CI，30 分钟 soak 与真实 UI 保持显式 Gate。
7. **本地持久化纵向切片**
   - 首个真实缓存/最近播放调用方出现后创建 `BiliPersistence`，由 Application port 隔离 SwiftData；schema 只保存可重建字幕/弹幕缓存、本机最近播放和播放进度。
   - 不镜像服务端观看历史，不保存 Cookie/token/账号身份；缓存设置版本、过期时间、容量上限和显式清理，登出按隐私规则清除账号会话关联状态。
   - 增加 schema round-trip、损坏/未知版本、容量淘汰、取消、登出清理和全新 store 测试；迁移策略在首次 schema 变更时再立 ADR。
8. **M4 收口：性能与真实 Gate**
   - 增加显式 `BiliDanmakuProbe` 或等价受控入口，记录事件/分段/同屏/复用计数、时间轴偏差与 RSS，不输出正文、用户标识或内容标识。
   - 用自制 fixture 完成可重复的 30 分钟时间轴、连续 seek、resize 和播放器替换矩阵；再用真实点播样本做最小兼容性 smoke。
   - Package/App/架构/秘密/工程静态契约、macOS 15/26 CI、当前 macOS 真实播放和无个人数据 UI 验证全部通过后关闭 M4。

交付物：

- 增加有真实调用方的 `BiliDanmaku` 与 `BiliPersistence` target。
- 字幕轨选择与展示。
- protobuf 弹幕解码、分段加载、预取、过滤、去重和 lane allocator。
- Core Animation 或可复用 NSView 渲染，不使用大量长期存在的 SwiftUI `Text`。
- SwiftData 只保存本机生成的弹幕/字幕缓存、shown-BVID、最近播放与播放进度；服务端观看历史继续按需读取，不建立含远端标题或账号行为的长期镜像，秘密仍只在 Keychain。

明确不做：

- 不在 M4 增加评论、收藏、稍后再看、直播/直播弹幕、独立播放器窗口、PiP 或复杂设置中心。
- 不支持高级弹幕、互动弹幕、ASS 导出、下载/离线媒体或跨设备同步。
- 不因为“以后可能使用”创建第二个 Package、公共 `Utils`、空 Feature target 或预留持久化 schema。

Gate：

- 30 分钟连续播放、暂停、倍速和双向 seek 后无明显漂移或重复喷射。
- resize、全屏和播放器容器尺寸切换后弹幕轨道能恢复。
- 内存不随弹幕段数单调增长，并有最大同屏数量与降级策略。
- 字幕和弹幕的旧视频/旧分 P/旧 generation 数据不会覆盖当前播放项目，关闭页面后网络、时间轴观察和 renderer 对象均可归零。
- 缓存有容量/期限/删除边界，UserDefaults、SwiftData、日志、fixture 和验证记录中不存在凭据或真实个人观看内容。

M4.0 Gate 结论：通过。匿名探针已确认字幕目录 JSON 与点播弹幕二进制边界；签名 App 测试宿主通过现有 Keychain 授权完成字幕目录 → 用途专属来源校验 → 字幕正文解析，并只记录字段、类型、计数和大小。全假值 fixture、数据保留规则、ADR 0007 架构边界及 ADR 0008 SwiftProtobuf 依赖决策均已落地。该结论允许进入 M4.1，但不代表字幕/弹幕 decoder 已实现；M4.2/M4.3 必须将现有负向 fixture 接入生产 decoder 测试后才能分别关闭。完整记录见 [`validation/M4-protocol-contract-2026-07-22.md`](./validation/M4-protocol-contract-2026-07-22.md)。

M4.1 Gate 结论：通过。`BiliApplication` 已提供不暴露 AVFoundation 的播放项目 identity、位置、时长、速率、状态与 discontinuity generation；`BiliPlayback` 通过独立 AVPlayer 时间线适配器实现 30 Hz 有界快照流，并在替换、取消、失败、结束、seek 与 stop 时清理或推进代次。虚拟状态测试固定暂停、2×、前后 seek、旧 token 隔离和订阅取消；自制 AVC/AAC 经 loopback HLS 驱动真实 AVPlayer，验证位置推进、倍速、暂停、seek 与资源归零。完整记录见 [`validation/M4-playback-timeline-2026-07-22.md`](./validation/M4-playback-timeline-2026-07-22.md)。

M4.2 Gate 结论：通过。字幕轨/cue、Application port、`BiliAPI` 目录与正文 adapter、VideoDetail ViewModel、播放器 overlay 和 composition 已接通；负向 fixture、来源策略、大小/格式/时间边界、取消、切轨、旧 identity 隔离、暂停、倍速和双向 seek 已由 138 项 Package 测试固定。签名 App 测试宿主使用真实已登录样本取得 3 条可用字幕轨和 76 条 cue，并通过生产 composition 到达 `decoder=ready`；日志只保留脱敏结构、计数和状态。完整记录见 [`validation/M4-subtitle-vertical-slice-2026-07-22.md`](./validation/M4-subtitle-vertical-slice-2026-07-22.md)。

M4.3 Gate 结论：通过。SwiftProtobuf 1.38.1 仅由 `BiliAPI` 依赖，生产 decoder 将匿名分段映射为不含发送者信息的 typed event；`BiliDanmaku` 以统一媒体时间轴实现两段预取、双请求上限、三段缓存、过滤、去重和 discontinuity 隔离。确定性负向测试与真实匿名首段探针均通过，现场样本解码并调度 224 条基础弹幕，日志只保留阶段和计数。完整记录见 [`validation/M4-danmaku-data-scheduler-2026-07-22.md`](./validation/M4-danmaku-data-scheduler-2026-07-22.md)。

M4.3.5 Gate 结论：通过。风险分级、任务契约、隔离上下文审查、branch/worktree 规则、分层模型路由、统一 static/package/app Gate 和 PR 模板已落地；独立审查提出的基线降级、Git 授权、diff 范围、工具链选择、两阶段契约、红区升级和配置生效证据问题均已整改。首次统一 App Gate 发现并修复一个既有字幕测试等待竞态，目标测试连续 10 次及完整 152 项 Package 测试最终通过。Luna/Terra/Sol 对同一自包含竞态题均给出正确结论，但它不是路由试运行且单样本 token 数据不足以证明成本下降；实际角色路由继续在后续真实任务留痕。提交 `4f70632` 的 GitHub Actions run `29916529806` 已在 macOS 15/26 完成提交范围 whitespace 与统一 App Gate，M4.3.5 正式关闭。完整记录见 [`validation/M4.3.5-engineering-governance-2026-07-22.md`](./validation/M4.3.5-engineering-governance-2026-07-22.md)。

### M4.5：UI/UX 精修

目标：在 M4 已经形成完整浏览、登录、Library、详情、播放、字幕和弹幕能力后，统一视觉语言、交互反馈和无障碍体验；只精修已有闭环，不用“体验优化”名义扩张业务范围。

前置条件：

- M4 Gate 已通过，Feature target 与类型化 App 路由稳定。
- 游客与全假值/无个人数据状态可以覆盖截图和 UI 自动化基线。
- M4 的播放、字幕、弹幕性能测量可重复，能识别精修造成的回归。

交付物：

- 审计 Browse、Library、Auth、VideoDetail、Player、字幕和弹幕的完整主流程、返回路径与窗口状态，清理死路、重复入口和状态残留。
- 建立最小的颜色、间距、圆角、排版、图标和动画 token；只有出现真实复用后才提取组件，不提前创建空 `DesignSystem` target。
- 统一 loading、empty、error、retry、offline、expired、signed-out、destructive confirmation，以及 hover、selection、focus、progress、cancel、success 反馈。
- 覆盖 1080×680、1320×820、自由缩放和全屏；覆盖浅色/深色、Increase Contrast、Reduce Transparency、Reduce Motion 与文字放大。
- 补齐可理解的辅助功能标签、焦点顺序和核心键盘操作；使用无个人数据的 preview、XCUI smoke、人工截图矩阵与性能对照记录。

明确不做：

- 不新增收藏、稍后再看、推荐写操作、endpoint、业务状态或持久化 schema；发现功能缺口应回到对应里程碑单独立项。
- 不提前实现 M5 的独立播放器窗口、mini player、PiP、系统分享、媒体键或完整 Commands。
- 不以样式复用为由创建没有第二个真实调用方的公共 target、组件层或主题框架。

Gate：

- 核心流程没有死路、重复 sheet 或关闭后残留状态；错误、空、过期和登出路径均可恢复。
- 目标窗口与系统辅助显示矩阵无截断、遮挡、不可辨识选中态或不可达操作。
- 核心流程可用键盘完成，主要控件有可理解标签和可见焦点。
- M4 的播放、字幕、弹幕帧率、内存和时间轴指标无可测回归；Package/App 测试、CI 与无个人数据 UI 验证记录通过。

### M5：Mac 产品完成度

目标：从“能播放的原型”变成遵循 Mac 习惯的日常客户端。

交付物：

- Commands、可发现快捷键和完整键盘导航。
- 独立播放器窗口、mini player、全屏和能力允许时的 PiP。
- 窗口恢复、拖入 B 站 URL、系统分享和媒体键集成。
- 在 M4.5 基线之上补齐完整 VoiceOver 导航和系统级 Mac 交互。
- 服务端 Library 能力（历史、稍后再看）与本地播放进度形成清晰、可撤销的闭环。

Gate：

- 核心流程无需鼠标即可完成。
- 主要控件具备可理解的辅助功能标签。
- 窗口与播放状态在关闭、重开和模式切换后保持一致。

### M6：v1 发布准备

目标：形成可重复构建、可诊断、可直接分发的首个版本。

交付物：

- API、播放、凭据和 UI 的回归矩阵。
- 隐私说明、第三方 notice、非官方与风险声明。
- Developer ID 签名、notarization 和 GitHub Releases 流程。
- 崩溃与诊断信息的秘密扫描和用户可读导出。
- 更新策略和回滚说明；是否引入自动更新单独通过 ADR 决定。

Gate：

- 在干净环境完成 Release 构建、测试、签名和 notarization。
- macOS 15 与当前 macOS 上完成游客、登录、播放、seek、弹幕和登出 smoke test。
- 发布包不包含开发 fixture、研究资料、私人证书或敏感日志。

## 5. v1 明确不做

- 下载、转码和媒体导出。
- 直播与直播弹幕。
- 投稿、发动态、私信和复杂评论写操作。
- 多账号。
- 区域解锁或绕过地区限制。
- Dolby Vision、8K、互动视频和课程等长尾格式。
- 完整复刻官方客户端的全部首页入口。
- Mac App Store 上架承诺。

任何非目标若要提前进入 v1，必须说明对现有 Gate 的影响并新增 ADR。

## 6. 近期执行队列

以下顺序是当前唯一近期待办，完成前不展开后续页面：

已经完成：

- M0 已提交并推送；首次 macOS 15/26 远程 CI 已通过。
- `BiliNetworking` Range、错误 `Content-Range`、CDN fallback 与取消测试。
- 自有 fMP4/SIDX fixture、SIDX v0/v1 parser 与边界测试。
- HLS master/media playlist、loopback HTTP bridge 和离线 AVPlayer 播放/seek 验证。
- 以运行失败证据否决自定义 scheme 媒体分段，并由 ADR 0002 记录替代方案。
- 最小 `AVPlayerEngine`、`AVPlayerView` 宿主和播放项目替换取消验证。
- 使用不含凭据的真实 AVC/AAC 样本完成 Apple Silicon/macOS 26 本地环境与 macOS 15 runner 的 CDN、连续播放、双向 seek、时间轴和连续替换验证。
- 使用受控响应完成 403、无效 `Content-Range`、HTML 错误页、CDN fallback 和取消传播矩阵。
- 使用 server 诊断快照确认连续替换后旧实例的 route、连接和上游 Task 全部归零，并完成 RSS 增长审计。
- M1 Gate 已关闭；完整记录见 [`validation/M1-real-playback-2026-07-21.md`](./validation/M1-real-playback-2026-07-21.md)。
- 创建 `BiliAPI` target，并保持 `BiliAPI → BiliModels/BiliNetworking`、`BiliPlayback ↛ BiliAPI` 的单向依赖。
- 使用手写脱敏 fixture 完成热门、`pagelist`、`playurl` contract tests；覆盖 JSON/HTML、非零 API code、字段缺失、无效输入和取消。
- 将 playurl AVC/AAC representation 映射为 `PlaybackManifest`，并由真实播放探针再次验证 API → 播放链路。
- 增加视频详情 endpoint 与脱敏 fixture，固定热门条目 → 详情的最小模型边界。
- 增加可取消的 `GuestVideoCoordinator`，完成详情 → 分 P → `PlaybackManifest` 的无 UI 编排，并验证旧结果隔离。
- 实现 WBI signer、同日 key 缓存与单次刷新重试，接入匿名视频搜索并完成脱敏 contract tests。
- 新增显式运行的 `BiliAPIProbe`，在本地真实网络中完成 nav → WBI 签名 → 搜索解码验证；记录见 [`validation/M2-guest-api-2026-07-21.md`](./validation/M2-guest-api-2026-07-21.md)。
- 将 `BiliAPI` 与 `BiliPlayback` 接入 App composition root，建立可测试的游客主流程状态模型，并固定媒体请求头传递与快速切换边界。
- 接入最小三栏 `NavigationSplitView`，完成游客热门 → 详情/分 P → 首个分 P 播放的可操作闭环，并通过真实界面验证封面、起播和暂停。
- 在同一 feed 状态机接入 WBI 搜索入口，完成关键词规范化、结果/空状态、错误重试和热门/搜索切换。
- 以统一 `task(id:)` 表达最后一次界面意图；入口切换会清理旧详情并暂停播放器，旧搜索结果不会覆盖后发热门请求。
- 使用真实 `macOS` 关键词完成搜索 → 详情/首分 P → AVPlayer 起播，并完成热门/搜索往返验证；M2 Gate 已关闭。
- 接受 ADR 0004，以 `BiliModels ← BiliApplication ← BiliGuestFeature` 为内层依赖方向，并让 API/Playback 通过 port 从 composition root 注入。
- 将游客 endpoint 组合迁为无 UI 状态的 `GuestFeedUseCase`、`GuestVideoUseCase`，把远端错误在 `BiliGuestRepository` 边界映射为应用错误。
- 将 `GuestAppModel` 拆为 Feed 与视频详情/播放两个 Feature ViewModel，保持取消、重试和旧结果隔离；SwiftUI View 不再导入具体 API/播放 adapter。
- 将 App、Domain、Application、API、Networking、Playback 与 Guest Feature 文件按职责整理目录；删除旧平铺实现，不保留双轨。
- 增加 CI 架构边界检查；54 项 Package 测试、1 项 App composition 测试、macOS 15 deployment build 和真实游客 UI smoke test 通过，M2.5 Gate 已关闭。
- 以不输出 key、完整 URL、Cookie 或 token 的现场探针确认 Web QR 生成与 `86101` 未扫码响应结构。
- 接受 ADR 0005 并建立 M3 威胁模型，固定认证分层、精确主机授权、ephemeral session、Data Protection Keychain 和本地登出边界。
- 将尚未确认的扫码成功/过期状态、凭据来源、Cookie 白名单与刷新协议保留为 M3 实现前 Gate，不用第三方实现替代现场证据。
- 创建实际由 `BiliAuthProbe` 调用的 `BiliAuth` target；使用专用 ephemeral session 获取二维码，并只把原始 URL 封装为不可直接读取、可在内存渲染的 `WebQRCode`。
- 通过脱敏人工扫码确认 `86090`、`0`、`86038`、Set-Cookie 五项白名单和 nav 登录态校验，成功/过期协议 Gate 已关闭；真实值未写入仓库或持久化。
- 以 16 项全假值测试固定生成、`86101`、`86090`、`0`、`86038`、取消、网络/HTML、安全结构观察、Set-Cookie 白名单、nav 登录态校验、未知状态、精确主机白名单与生成/轮询/登录态校验旧代次隔离；其他业务状态一律失败关闭。
- 把 `qrcode_key` 纳入日志脱敏，并在 macOS 15/26 CI 增加二维码 key、Cookie 和 refresh token 的已知模式扫描。
- 实现 schema v1 五 Cookie envelope 与固定 generic-password store；自动测试固定 Data Protection、`WhenUnlockedThisDeviceOnly`、非同步、add/update/read/delete 和安全错误映射。
- 实现无业务语义的 `HTTPRequestAuthorizing` port、BiliAuth 精确 nav allowlist 和可复用重定向拒绝 transport；负向测试覆盖 HTTP、相似主机、CDN、loopback、错误 endpoint/方法、预置 Cookie 与跨主机跳转。
- Web QR 仅在最新 generation 的 nav 校验成功后同步提交 store；恢复路径覆盖缺失、损坏、过期、远端失效、清理失败和暂时网络失败。完整 Package 为 87 项测试、16 个套件。
- 为 App 配置最小 Keychain access group；签名 arm64 测试宿主使用独立 service/account 实际完成 Data Protection Keychain add、duplicate→update、read、属性检查、delete 与无残留确认。未签名 CI 路径明确跳过，不把 mock 结果冒充真实往返。
- 本阶段自动化、签名 smoke 与 CI 边界见 [`validation/M3-keychain-authorization-2026-07-21.md`](./validation/M3-keychain-authorization-2026-07-21.md)。
- 在 `BiliApplication` 增加非秘密认证状态和用户意图 port，由 `BiliAuthenticationService` 适配 Web QR、凭据恢复、最终提交与登出；Feature 与 App 均不取得 Cookie 或完整 QR URL。
- 创建有真实账号 sheet 调用方的 `BiliAuthFeature`；ViewModel 管理轮询 Task、代次、取消、重试与登出，旧登录意图不能覆盖新状态。
- 本地登出固定取消、清内存、删除 Keychain、失效两类 session、再发布状态的顺序；删除失败保持安全错误，不能经取消操作伪装成已退出。
- 97 项 Package 测试、18 个套件、macOS 15 无签名 build-for-testing、App composition 测试和当前 macOS 未登录/二维码/取消 UI smoke 均通过；详见 [`validation/M3-auth-feature-2026-07-21.md`](./validation/M3-auth-feature-2026-07-21.md)。
- 选择只读观看历史作为首个个性化纵向闭环；新增 Domain/Application/History Feature、精确授权的 cursor endpoint、分页去重、旧请求隔离和关闭/登出内存清理。
- 游客 endpoint 不请求授权；历史 endpoint 缺少授权器时在 transport 前失败，授权器严格限制主机、路径、方法与四项 query。
- 签名 App 实测发现并补齐 App Sandbox 的 `network.client` 与 `network.server`；前者服务 API/CDN，后者只供 loopback 播放桥监听。
- 107 项 Package 测试、20 个套件、App build-for-testing/composition、签名 Keychain smoke、架构与秘密扫描通过。
- 当前 macOS 已完成真实扫码、历史读取、详情/播放器跳转、进程重启恢复、恢复后再次读取、界面登出、第二次重启未恢复和游客回退；详见 [`validation/M3-watch-history-2026-07-21.md`](./validation/M3-watch-history-2026-07-21.md)。
- 完成产品领域 Feature target 整理、根 `AGENTS.md`、ADR 0006 与 M4.5 UI/UX 里程碑；三路独立审查提出的 M3 阻断和结构债已全部整改。
- 提交 `6236753` 已推送；GitHub Actions run `29843186800` 的 macOS 15/26 Package、App、架构、秘密和工程静态契约矩阵通过，M3 Gate 正式关闭。
- M4.0 已关闭：匿名现场观察确认字幕目录 JSON 与点播弹幕二进制边界；签名 App 探针完成已登录字幕目录与正文链路；全假值 fixture、精确授权/字幕来源 allowlist、数据隐私规则及 SwiftProtobuf 依赖审计已经落地。字幕、弹幕和持久化 target 仍未创建，生产 decoder 负向测试保留给对应纵向切片。
- M4.1 已关闭：Application 唯一时间轴 port 与 AVPlayer adapter 已落地，播放器 identity、位置、时长、速率、状态和 discontinuity generation 均有平台无关快照；替换、取消、seek、结束和关闭具有明确隔离/清理点，Feature 关闭详情时执行 stop 而非只暂停。
- M4.2 已关闭：字幕 URL 只保留在 `BiliAPI`，正文使用无 Cookie、无缓存、拒绝重定向的专用 transport；Feature 只消费 typed track/cue 与统一时间轴，App/Platform 负责 overlay 组装。真实签名样本已通过生产 decoder/repository，探针日志未包含内容标识、正文、完整 URL 或凭据。
- M4.3 已关闭：SwiftProtobuf 1.38.1 精确固定且只由 `BiliAPI` 依赖，clean-room schema 与同版本 generator 生成物已提交；typed event、分段 port、两段预取、最多 2 个并发请求、3 段缓存、去重/过滤和 discontinuity 重建已落地。真实匿名首段经生产 decoder 解码并调度 224 条基础弹幕，探针日志保持脱敏。
- M4.3.5 已关闭：短分支已引入风险分级、任务契约、隔离审查、分层模型路由、统一 Gate 命令和 PR 模板；独立只读终审与远程 macOS 15/26 CI 均通过。

接下来按顺序：

1. 由用户确认 M4.4 spike 契约，再在不可合入分支测量 Core Animation/AppKit renderer 基线。
2. 根据 spike 数据确认 M4.4 生产契约，再开始最小纵向实现。

M4 期间不开始复杂导航和视觉精修；`BiliPersistence` 只在首个真实缓存/播放进度调用方出现后创建。更多真实样本与 Intel 覆盖属于兼容性扩展，但发现可重复回归时必须回到对应的 M1/M2 测试层修复。

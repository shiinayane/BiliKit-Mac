# BiliKit 协作指南

本文件适用于整个仓库。子目录如需更严格的约束，可以增加自己的 `AGENTS.md`；子文件只补充局部规则，不重复或放宽本文件。

## 项目定位

BiliKit 是原生、macOS-first、第三方且非官方的 B 站浏览与播放客户端，采用 Swift 6、SwiftUI 和 AVPlayer-first 路线，最低支持 macOS 15。App 产品与公开 Swift 模块名为 `BiliKit`；仓库、Xcode 工程和内部 App target 保留 `BiliKitMac`。

仓库文档使用中文，Swift 标识符、测试名和 API 名使用清晰的英文。用户可见文案应简洁自然，不暴露 endpoint、状态码、Cookie 名称或底层错误正文。

v1 的范围和非目标以 `docs/ROADMAP.md` 为准。不要擅自加入下载、转码、媒体导出、直播、多账号、区域解锁或复杂写操作。

## 事实来源

发生冲突时按以下顺序判断：

1. 当前代码、`Package.swift`、Xcode 工程、entitlement 和 CI 工作流。
2. 已接受 ADR；若新 ADR 明确写明“取代”某项旧决策，以新 ADR 为准。
3. `docs/ROADMAP.md` 的当前计划与 Gate。计划不是完成证据。
4. `docs/validation/` 的带日期历史证据。它记录当时环境，不应被改写成当前事实。
5. `docs/security/` 的威胁模型和隐私边界。
6. `references/` 仅供本地研究，不是依赖、规范或可复制源码。

修改前先查找相关 ADR、测试和验证记录。不要为了让文档“看起来一致”而改写历史验证数据或旧 ADR 的背景；用新 ADR 或当前状态段说明后续变化。

## 仓库边界

```text
BiliKitMac/
├── App/               # App/Scene 入口与产品级导航外壳
├── Composition/       # 唯一依赖组装位置，可见具体 adapter
├── Platform/          # 必须留在 App target 的 macOS 宿主
└── Assets.xcassets/

Packages/BiliKitCore/
├── Sources/
├── Tests/
└── Package.swift
```

继续使用一个本地 Swift Package、多个 target。除非 ADR 证明独立发布、版本或工具链边界确有必要，不新增第二个 `Package.swift`。

`references/` 整体由 Git 忽略，也不得加入 Xcode target、SwiftPM resource、fixture 或发布包。第三方代码只能用于理解机制；实现必须来自自有代码、公开文档和自制测试材料，并检查许可证。

## Clean Architecture 依赖方向

核心方向是：

```text
BiliBrowseFeature ─┐
BiliLibraryFeature ├──> BiliApplication ──> BiliModels
BiliAuthFeature ───┘             ↑
                                 │ ports
BiliAPI / BiliAuth / BiliPlayback
          └──> BiliNetworking（无业务语义的传输基础设施）

BiliKit App = App/ + Composition/ + Platform/
```

- `BiliModels`：稳定领域实体和值类型；不依赖外层 Bili 模块或 UI、网络、播放框架。
- `BiliApplication`：Use Case、port、应用错误和平台无关值；只依赖 `BiliModels`。不能出现 endpoint DTO、SwiftUI/AppKit/AVKit、具体 client、Keychain 或 Cookie。
- `BiliNetworking`：无 Bilibili 业务语义的 HTTP/Range、取消、重定向与日志脱敏基础设施；不保存秘密。
- `BiliAPI`：endpoint DTO、WBI、响应映射和 Repository adapter。
- `BiliAuth`：Web QR、凭据 envelope、Keychain 和请求授权 adapter；是认证秘密的唯一业务 owner。
- `BiliPlayback`：AVFoundation、DASH→HLS、Range、CDN fallback 与 loopback bridge adapter。
- `Bili*Feature`：SwiftUI View、`@MainActor` ViewModel、UI State 和用户文案；只通过 Application port 工作，Feature 之间禁止直接 import。
- `BiliKitMac/App`：入口、场景和产品级路由；不直接 import Data/Application/Platform 实现。
- `BiliKitMac/Composition`：唯一可同时看见 Feature、Application port 和具体 adapter 的 composition root。
- Probe 是显式开发验证入口，可以依赖具体 adapter，但不得成为产品代码的反向依赖。

依赖边界由 `Scripts/check-architecture.sh` 固定。若脚本与规则不一致，修正脚本和代码，不能用注释、别名或动态查找绕过。

## Feature target 与目录准入

Feature target 按产品领域划分，不按页面、登录状态或技术角色划分：

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

Favorites、WatchLater 等能力只有在出现真实调用方和纵向链路时才创建目录；不创建空 target、空 Repository 或占位 Use Case。

默认先在现有产品域 target 内增加子功能目录。只有同时满足以下大部分条件，才提议新 Feature target，并通过 ADR 记录：

- 有稳定、清晰且长期独立的产品领域语言。
- 有独立导航或状态生命周期，而不是单个 sheet/页面。
- 有不同的依赖、安全、隐私或性能边界。
- 同一变更中存在真实 App 调用方和对应测试。
- 拆分能减少跨域耦合，而不是只缩短文件列表。

Feature target 不互相 import。跨 Feature 导航由 App 层的类型化 Route/Intent 协调，不传递具体 ViewModel、Repository、Cookie 或任意字符串字典。

不要创建 `Common`、`Shared`、`Utils` 大目录或 target。先把代码放在拥有其业务语义的子功能；至少出现两个真实调用方且语义稳定后，再提取最窄公共类型。

以下是审查触发线，不是自动拆 target 的配额：

- 单个生产 Swift 文件超过约 300 行时，检查是否混合了多个职责。
- 子功能超过约 8 个生产文件或 1,500 行时，检查其状态与依赖是否仍内聚。
- 产品域超过约 25 个生产文件或 5,000 行时，必须记录一次 target 拆分评估。

## 风险分级与隔离审查

风险等级只追加验证，不降低本文件的基线要求；行数和文件数只触发职责检查，不自动决定风险：

- **绿区**：文案、Preview、局部布局、仅限私有实现的机械重命名、明确的 DTO 映射和小型测试补充。公开 API、target 或工程变更不属于绿区。
- **黄区**：普通 Feature/Use Case、缓存策略、跨文件重构和新增跨模块公共 API。实现前写明 Goal、Context、Constraints、Done when；实现后由未参与实现、且不继承实现推理的新上下文做只读审查。
- **红区**：认证、授权、Keychain、来源策略、重定向、本地服务器、播放/媒体、线程与资源生命周期、弹幕 renderer、持久化迁移、文件删除和不可逆数据变化。实验前由用户确认 spike 契约；未知性能路线在独立 `codex/spike-*` 分支用合成数据测量，spike 不合入生产分支。实验结束后再由用户确认生产契约；实现后分别审查失败场景，以及线程、所有权、安全和清理路径，并增加真实探针或长时测量。

黄区中的未知路线、全部红区和重要 Gate 必须先通过决策价值 Gate并写明复杂度预算，再按“价值与简化 → 可理解性 → 技术正确性”使用三个互不继承结论的独立上下文审查。技术审查若要求显著扩大候选、矩阵、harness 或证据协议，必须返回决策价值 Gate，不能继续累加条款。用户确认只检查决策层的知情授权：最多三个授权问题，只有明确的重大误解阻断，不得要求背诵技术规格。绿区和边界清晰的普通黄区不机械启动全部三种视角；完整流程和预算见 `docs/development/QUALITY-GATES.md`。

独立审查只接收任务契约、事实来源和待审文件，不接收实现者结论；输出按 blocker、improvement、reject 分类。只读 Agent 可以共享工作树，多个写入 Agent 不得同时修改同一工作树；确需并行写入时使用独立 branch/worktree，一次只审查和合入一个重要变更。完整流程和模板见 `docs/development/QUALITY-GATES.md`。

项目级 Agent 定义位于 `.codex/agents/`，默认按认知难度分工，而不是按“写代码/写测试”机械分工：

- 主 Agent 使用 Sol Medium，负责理解需求、任务契约、架构与最终整合。
- `explorer` 使用 Luna Low，只做边界明确的只读定位、调用链和事实清单。
- `worker` 使用 Terra Medium，只按已确认契约实现窄切片。
- `reviewer` 使用 Terra High，负责黄区独立只读审查。
- `red_reviewer` 使用 Sol High，负责红区和重要 Gate 的线程、生命周期、安全与资源终审。

出现两种以上合理解释、无法明确不变量或 owner、跨越两个以上 target 边界、涉及红区、测试失败原因不清晰、连续两次修复失败、reviewer 结论冲突或准备关闭重要 Gate 时必须升级，不能为节省成本降低终审等级。绿区不强制启动全部角色；模型路由只是默认值，自动 Gate、真实探针和用户确认仍是完成证据。

## 状态、并发与取消

- ViewModel 使用 `@MainActor`，拥有界面生命周期内的 Task、代次和用户意图；View 不直接发 API 请求或解释 DTO。
- 可变的网络、认证、播放会话优先由 actor 隔离。跨 actor 类型必须满足 Swift 6 `Sendable` 约束，不用 `@unchecked Sendable` 掩盖设计问题。
- 新请求替换旧请求时必须传播取消，并用 generation/identity 阻止旧结果覆盖新状态。
- 页面关闭、登出、切换视频或替换播放项目时，相关 Task 和内存中的个性化数据必须有明确清理点。
- 轮询、重试和预取必须有单实例、最小间隔、总时限和上限；不能只依赖远端返回终止状态。

## 安全与隐私

- Cookie、QR key、完整二维码 URL、token 和未来的 refresh token 只能存在于 `BiliAuth` 的短生命周期内存与 Keychain；不得进入 Feature、Domain、Application、UserDefaults、SwiftData、日志、fixture、截图或验证记录。
- Keychain 使用固定 namespace、Data Protection Keychain、`WhenUnlockedThisDeviceOnly` 和非同步 item。登出必须能在离线时清除本机状态。
- 认证请求采用专用 ephemeral session、精确 HTTPS host/path/method/query allowlist、禁用 Cookie jar/cache，并拒绝或重新校验每次重定向。
- 游客 API、图片、媒体 CDN 和 loopback 请求不得持有认证授权器。
- 所有远端 URL 在进入 transport 前都要执行与用途匹配的来源策略。媒体 URL 和每次重定向至少检查 HTTPS、userinfo、端口、主机族以及 loopback/private/link-local 边界。
- loopback playback server 只能绑定 `127.0.0.1`，使用不可预测的会话路由，并严格验证方法、路径和 Range。
- 不打印原始响应 body。错误只暴露阶段与安全分类；新增敏感字段时同步更新 `Scripts/check-secrets.sh` 和脱敏测试。

触碰认证、授权、Keychain、媒体来源、重定向或本地服务器时，必须先读相应威胁模型，并增加负向测试；仅有成功路径不算完成。

## API、fixture 与探针

- 每个 endpoint 使用独立 DTO，在 adapter 边界映射为 Domain/Application 类型；wire 字段和 API code 不泄漏到 Feature。
- Fixture 只能使用手写假值或自制媒体。禁止提交真实 Cookie、token、QR、账号身份、观看历史或完整现场响应。
- 未公开 API 可能漂移；未知状态、HTML 风控页、字段缺失和重定向默认失败关闭。
- Probe 必须显式运行，不自动进入普通 CI；输出只包含验证所需的脱敏结构、计数和状态。
- 网络现场观察不能替代 deterministic contract test，反之亦然。二者适用边界都要写入验证记录。

## 工作方式

1. 先阅读相关代码、测试、ADR、路线图和威胁模型，确认当前行为与范围。
2. 对修复先写或定位能失败的测试；对结构迁移先固定已有行为。
3. 保持纵向小步：Domain/Application port、adapter、Feature、composition 与测试在同一可验证切片内完成。
4. 不混入无关格式化、重命名或未来模块占位。工作树已有改动默认属于用户，必须保留。
5. 移动文件后重新检查 SwiftPM target、Xcode package product、imports、脚本路径和文档链接。
6. 没有用户明确要求时，不提交、不推送、不改写 Git 历史，也不创建 PR。

## 验证矩阵

文档、脚本和纯静态变更至少运行：

```sh
sh Scripts/run-quality-gates.sh static
```

所有代码变更至少运行（内部包含 static）：

```sh
sh Scripts/run-quality-gates.sh package
```

涉及 App composition、Xcode 工程、Package product 或资源时运行（内部包含 package）：

```sh
sh Scripts/run-quality-gates.sh app
```

按风险追加验证：

- ViewModel/Feature：状态迁移、取消、旧结果隔离、空/错/重试状态。
- API/认证：fixture contract、未知状态、重定向、allowlist 与秘密扫描。
- 播放：Range、CDN fallback、取消、seek、资源归零；算法或 transport 变化需运行受控播放验证。
- Xcode/entitlement/Keychain：无签名 CI 不能证明签名能力；需要静态 entitlement 契约和受控签名 smoke。
- UI：自动化目前只保证 smoke 骨架；关键交互、窗口尺寸、辅助功能和视觉结论必须记录真实运行环境。

若环境使测试跳过或失败，必须准确说明“未验证”，不能把编译成功、mock 或 skip 写成运行通过。

## 文档与 Gate

- 改变架构、依赖、平台版本、安全边界或不可逆技术路线时新增 ADR。
- `docs/ROADMAP.md` 同时维护当前事实、下一步和 Gate；只有证据满足 Gate 后才标记完成。
- `docs/validation/` 记录日期、OS/架构、命令、结果和适用边界，不保存账号、内容标题、BVID、二维码或秘密。
- README 只描述当前用户可见能力和稳定入口，不复制完整路线图，也不写易漂移的测试数量、CI run ID 或提交 SHA。
- 移动或重命名模块时更新当前 README、路线图、ADR 索引和架构脚本；历史 ADR/验证记录保留当时名称，并由新 ADR说明取代关系。

完成回复应先给出结果，再列出重要风险、验证和仍未覆盖的边界。不要把“现有测试全部通过”等同于功能、安全或真实设备 Gate 全部通过。

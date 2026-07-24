# BiliKit 协作指南

本文件适用于整个仓库。子目录可以增加更严格的 `AGENTS.md`，但只补充局部规则，不重复或放宽本文件。详细工程流程见 [`docs/development/QUALITY-GATES.md`](docs/development/QUALITY-GATES.md)。

## 项目定位

BiliKit 是原生、macOS-first、第三方且非官方的 B 站浏览与播放客户端，采用 Swift 6、SwiftUI 和 AVPlayer-first 路线，最低支持 macOS 15。App 产品与公开 Swift 模块名为 `BiliKit`；仓库、Xcode 工程和内部 App target 保留 `BiliKitMac`。

仓库文档使用中文，Swift 标识符、测试名和 API 名使用清晰的英文。用户可见文案应简洁自然，不暴露 endpoint、状态码、Cookie 名称或底层错误正文。

v1 的范围和非目标以 [`docs/ROADMAP.md`](docs/ROADMAP.md) 为准。不要擅自加入下载、转码、媒体导出、直播、多账号、区域解锁或复杂写操作。

## 事实来源

发生冲突时按以下顺序判断：

1. 当前代码、`Package.swift`、Xcode 工程、entitlement 和 CI 工作流。
2. 已接受 ADR；新 ADR 只有明确写明“取代”时才覆盖旧决策。
3. `docs/ROADMAP.md` 的当前计划与 Gate；计划不是完成证据。
4. `docs/validation/` 的带日期历史证据；它记录当时环境，不应被改写成当前事实。
5. `docs/security/` 的威胁模型和隐私边界。
6. `references/` 仅供本地研究，不是依赖、规范或可复制源码。

修改前先查找相关 ADR、测试和验证记录。后续变化通过新 ADR 或当前状态说明，不改写历史验证数据或旧 ADR 的背景。

## 仓库与依赖边界

```text
BiliKitMac/
├── App/               # Scene、产品级路由和导航外壳
├── Composition/       # 唯一可见具体 adapter 的依赖组装位置
├── Platform/          # 必须留在 App target 的 macOS 宿主
└── Assets.xcassets/

Packages/BiliKitCore/
├── Sources/
├── Tests/
└── Package.swift
```

继续使用一个本地 Swift Package、多个 target；除非 ADR 证明独立发布、版本或工具链边界确有必要，不新增第二个 `Package.swift`。

核心依赖方向是：

```text
Bili*Feature ──> BiliApplication ──> BiliModels
                         ↑ ports
             BiliAPI / BiliAuth / BiliPlayback
                         └──> BiliNetworking

BiliKit App = App/ + Composition/ + Platform/
```

- `BiliModels` 只放稳定领域实体和值类型。
- `BiliApplication` 只放 Use Case、port、应用错误和平台无关值；不得出现 endpoint DTO、SwiftUI/AppKit/AVKit、具体 client、Keychain 或 Cookie。
- `BiliNetworking` 是无 Bilibili 业务语义的传输基础设施，不保存秘密。
- `BiliAPI`、`BiliAuth`、`BiliPlayback` 分别拥有 endpoint adapter、认证秘密与授权 adapter、AVFoundation/媒体 bridge。
- `Bili*Feature` 只通过 Application port 工作，Feature 之间禁止直接 import；跨域导航由 App 层类型化 Route/Intent 协调。
- Probe 可以依赖具体 adapter，但不得成为产品代码的反向依赖。

Feature target 按产品领域划分，默认先在现有领域内增加纵向子功能；只有出现稳定独立领域、真实 App 调用方和测试时才评估新 target。禁止创建空 target、占位 Repository 或 `Common`、`Shared`、`Utils` 大仓库。具体准入与规模审查触发线见 [`docs/adr/0006-product-domain-feature-targets.md`](docs/adr/0006-product-domain-feature-targets.md)。

依赖边界由 `Scripts/check-architecture.sh` 固定。若脚本与规则不一致，修正脚本和代码，不能用注释、别名或动态查找绕过。

`references/` 整体由 Git 忽略，也不得加入 Xcode target、SwiftPM resource、fixture 或发布包。第三方代码只能用于理解机制；实现必须来自自有代码、公开文档和自制测试材料，并检查许可证。

## 风险与审查路由

风险等级只追加验证，不降低基线；按后果、不确定性、可逆性和证据需求分类，不按改动行数分类：

- **绿区**：文案、Preview、局部布局、私有机械重命名、明确 DTO 映射和小型测试补充。主 Agent 可以直接完成并检查 diff；公开 API、target 或工程变更不属于绿区。
- **黄区**：普通 Feature/Use Case、缓存策略、跨文件重构和跨模块公共 API。实现前写明 Goal、Context、Constraints、Done when；非机械改动完成后由不继承实现推理的新上下文做只读审查。
- **红区**：认证、授权、Keychain、来源与重定向、本地服务器、播放/媒体、线程与资源生命周期、renderer、持久化迁移、文件删除和不可逆变化。新决策或新生产契约必须先通过决策价值 Gate、复杂度预算和用户确认；实现后由 `red_reviewer` 检查失败、安全、所有权、取消、资源上限、清理和 rollback，并增加任务所需的真实证据。

已绑定用户确认的红区生产契约可以承载语义不变的维护切片；只要 Goal、候选、范围、安全/隐私边界、资源 owner、复杂度预算、停止条件或下一步发生变化，就必须返回完整前置流程。详细的决策 Gate、维护例外、证据包、工作树隔离和 reviewer 输出格式以 [`docs/development/QUALITY-GATES.md`](docs/development/QUALITY-GATES.md) 为准。

项目 Agent 定义及模型配置以 [`.codex/config.toml`](.codex/config.toml) 和 [`.codex/agents/`](.codex/agents/) 为准。出现两种以上合理解释、无法明确不变量/owner/清理点、跨越两个以上 target、涉及红区、测试失败原因不清晰、连续两次修复失败、reviewer 冲突或准备关闭重要 Gate 时必须升级；模型选择、自动测试或用户确认不能互相替代。

## 状态、安全与数据

- ViewModel 使用 `@MainActor` 并拥有界面生命周期内的 Task、generation 和用户意图；View 不直接请求 API 或解释 DTO。
- 可变网络、认证和播放会话优先由 actor 隔离；跨 actor 类型必须满足 Swift 6 `Sendable`，不得用 `@unchecked Sendable` 掩盖设计问题。取消必须向下传播，旧结果用 generation/identity 隔离；页面关闭、登出、切换视频和替换播放项必须有明确清理点与资源上限。
- 轮询、重试和预取必须有单实例、最小间隔、总时限与次数/并发/缓存上限；不能只依赖远端返回终止状态。
- Cookie、QR key、完整二维码 URL、token 和 refresh token 只能存在于 `BiliAuth` 的短生命周期内存与 Keychain；不得进入 Feature、Domain、Application、UserDefaults、SwiftData、日志、fixture、截图或验证记录。
- Keychain 使用固定 namespace、Data Protection Keychain、`WhenUnlockedThisDeviceOnly` 和非同步 item；登出必须能在离线时清除本机状态。
- 认证请求使用专用 ephemeral session 和精确 allowlist，并重新校验每次重定向。游客 API、图片、媒体 CDN 和 loopback 请求不得携带认证授权器。
- 远端 URL 必须在进入 transport 前执行用途匹配的来源策略。媒体 URL 和每次重定向至少检查 HTTPS、userinfo、端口、主机族及 loopback/private/link-local 边界。loopback playback server 只能绑定 `127.0.0.1`，使用不可预测的会话路由，并严格验证方法、路径和 Range。
- 每个 endpoint 使用独立 DTO，并在 adapter 边界映射为 Domain/Application 类型。未知状态、HTML 风控页、字段缺失和异常重定向默认失败关闭。
- Fixture 只使用手写假值或自制媒体；Probe 必须显式运行且只输出脱敏结构、计数和状态。不打印原始响应 body，不把现场观察当作 deterministic contract test。新增敏感字段时同步更新 `Scripts/check-secrets.sh` 和脱敏测试。

触碰认证、授权、Keychain、媒体来源、重定向或本地服务器时，先读对应威胁模型并增加负向测试；仅有成功路径不算完成。

## 工作方式与 Skill 路由

1. 先阅读相关代码、测试、ADR、路线图和威胁模型，确认当前行为与范围。
2. 对修复先写或定位能失败的测试；对结构迁移先固定已有行为。
3. 保持一个纵向目的；不混入无关格式化、重命名或未来模块占位。已有工作树改动默认属于用户。
4. 移动文件后重新检查 SwiftPM target、Xcode package product、imports、脚本路径和文档链接。
5. 没有用户明确要求时，不提交、不推送、不改写 Git 历史，也不创建 PR。

外部 CLI 在受限网络沙箱中报告 token 无效、未认证、DNS/TLS 或远端不可达时，不得立即要求用户重新登录或修改凭据。先在获准联网的只读上下文使用同一 CLI、账号、认证方式和远端协议/目标复核；只有等价复核仍失败时，才按真实认证问题处理。

修改 `AGENTS.md`、质量 Gate、风险分级或 Agent 路由时，自动使用 `project-governance-bootstrap`，只读检查使用 `audit`，写入使用 `upgrade`，无需等待用户显式点名。如果 Skill 不可用，则直接按其最小等价流程读取本文件、`QUALITY-GATES.md`、相关 ADR 与现有验证入口，审计比例性和事实来源，运行最高适用 Gate，并明确报告能力缺口。

任务涉及以下任一能力时，自动使用 `apple-dev-loop`，无需等待用户显式点名：

- Xcode 工程、scheme、target、资源、Package product 或 App composition；
- Xcode MCP、`xcodebuild`、`.xcresult`、XCTest/XCUI、Simulator 或真实设备；
- 签名、entitlement、Keychain、系统权限或真实登录链路；
- SwiftUI/AppKit 真实 UI、窗口、焦点、辅助功能或视觉验收；
- 播放、媒体、并发、资源生命周期，或 CPU、内存、泄漏、卡顿和 Instruments 测量。

纯解释、只读源码定位、纯文档/静态变更，以及不触及上述能力、不改变 Xcode 工程、Package product 或 App composition、且只需现有 Package Gate 的边界明确窄修改不加载 `apple-dev-loop`。Skill 负责工具选择与证据层级；本文件、ADR、威胁模型和仓库 Gate 仍是项目事实来源。如果 Skill 在当前环境不可用，继续运行可复现的仓库 Gate，并明确报告缺失的 Xcode、UI、签名、设备或性能证据。

## 验证与完成

每次只运行最高适用模式，不顺序重复运行低层 Gate：

```sh
sh Scripts/run-quality-gates.sh static   # 文档、脚本和纯静态变更
sh Scripts/run-quality-gates.sh package  # Package 代码；包含 static
sh Scripts/run-quality-gates.sh app      # App/Xcode/composition；包含 package
```

本地 Agent 默认设置 `BILIKIT_COMPACT_LOGS=1`；CI 保留完整输出。风险会追加状态迁移、取消、负向契约、受控播放、签名 Keychain、真实 UI 或性能证据，具体选择见 `QUALITY-GATES.md` 和 `apple-dev-loop`。无签名 CI、mock、MCP 连接、编译成功、截图、一次 trace 或一次设备观察都不能证明更高层 Gate。

若环境使检查跳过或失败，准确标记“未验证”。只有代码、测试、文档、CI 和所需真实证据一致时才能关闭 Gate；完成回复先给结果，再列风险、验证和未覆盖边界。

## 文档维护

- 改变架构、依赖、平台版本、安全边界或不可逆技术路线时新增 ADR。
- `docs/ROADMAP.md` 只在证据满足 Gate 后标记完成。
- `docs/validation/` 记录日期、OS/架构、命令、结果和适用边界，不保存账号、内容标题、BVID、二维码或秘密。
- README 只描述当前用户可见能力和稳定入口，不复制完整路线图，也不写测试数量、CI run ID 或提交 SHA。
- 移动或重命名模块时更新当前 README、路线图、ADR 索引和架构脚本；历史 ADR/验证记录保留当时名称，由新 ADR 说明取代关系。

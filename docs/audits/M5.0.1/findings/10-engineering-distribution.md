# 10 工程与分发

状态：第二轮事实审计与独立交叉复核完成；尚未修改工程、生产代码或分发配置。

本文件 owner：第二轮工程与分发 Agent。取证日期：2026-07-27。审计基线：
`a00744639f853ffbd7543a56c29a1588d41d93ea`。本轮只读取工程、CI、Apple 文档、
GitHub-hosted runner 的实际日志、依赖 checkout 与 `references/`；没有访问签名身份、
provisioning profile、真实 Keychain item，没有执行 Archive、Export、notarization、
staple、安装或卸载。

## 证据层级总表

| 层级 | 当前证据 | 本轮结论 |
| --- | --- | --- |
| SwiftPM / Xcode 工程解析 | `Package.swift`、两份 `Package.resolved`、shared scheme、项目静态门禁 | 已确认配置可解析且依赖锁一致 |
| Debug build / test | 基线 GitHub Actions run `30206958978` 的 macOS 15/26 两个 job | 两个 arm64 环境均成功；仅无签名 Debug |
| Release build | 只有 Release build settings 与 scheme Profile/Archive 配置 | 未执行当前 App Release build |
| 签名运行 | 2026-07-21 的 Apple Development Keychain smoke | 历史单机证据；不是当前 Release/Developer ID 成品证据 |
| Archive / Export | scheme 允许 Archive；仓库没有 archive/export 记录 | 尚未执行 |
| notarization / staple | Apple 要求与工具链已知；仓库没有流程或 ticket | 尚未执行 |
| 安装 / 升级 / 卸载 | 路线图明确留到 M6 | 尚未执行 |

## M501-ENG-001：macOS 15/26 CI 是有效双环境证据，但 runner 标签不是固定工具链

- **finding_id**：`M501-ENG-001`
- **审计线 / 能力**：Xcode、SwiftPM、macOS 15/26、CI 工具链可重复性。
- **当前实现（文件 / 符号 / 调用链）**：
  - `.github/workflows/ci.yml:31-69` 在 `macos-15`、`macos-26` 两个 matrix job
    中打印 OS/Xcode/Swift/Swift Format 版本，然后执行统一 `app` gate。
  - `Scripts/run-quality-gates.sh:106-144` 先运行 Swift Package 测试，再执行 Debug
    `build-for-testing` 与 App 单元测试；Xcode 两步都传
    `CODE_SIGNING_ALLOWED=NO`。
  - `Packages/BiliKitCore/Package.swift:1-9` 固定 Swift tools 6.0 与 macOS 15；
    `BiliKitMac.xcodeproj/project.pbxproj:468-478,502-512` 固定 App deployment target
    15.0 与 Swift language version 6.0。
- **声称承担的职责**：最低系统与当前系统都能解析依赖、以 Swift 6 编译并通过确定性测试。
- **外部事实来源**：
  - GitHub runner-images 的
    [label 与软件更新策略](https://github.com/actions/runner-images)说明 runner image
    会更新，同一 macOS image 只支持一个 Xcode major、minor 可并存且 patch 会被替换；
    每次运行的 `Set up job` 日志才是该次实际 image/toolchain 证据。
  - Swift 官方
    [Migrating to Swift 6](https://www.swift.org/migration/)说明 Swift 6 language mode
    把数据竞争检查提升为必须满足的编译约束。
  - **证据强度**：服务提供方当前规则 + 基线真实 CI 日志 + 本地工程配置，已确认。
- **OSS 对照及 commit/date**：不适用；CI runner 与编译器事实由服务提供方日志及 Swift
  规范决定，第三方 App 的 workflow 不能替代当前仓库实际运行。
- **真实行为证据**：GitHub Actions
  [run 30206958978](https://github.com/shiinayane/BiliKit-Mac/actions/runs/30206958978)
  对基线 SHA 成功：
  - macOS 15 job：macOS 15.7.7、Xcode 16.4（16F6）、Swift 6.1.2、arm64；
  - macOS 26 job：macOS 26.4、Xcode 26.5（17F42）、Swift 6.3.2、arm64。
  两个 job 均成功；条件性的“真实播放验证（macOS 15）”在 push run 中跳过。
- **本地测试实际覆盖范围**：CI 证明上述两个具体 image 上的 Package 测试、Debug
  无签名 App build-for-testing 与 App unit tests 成功；不证明未来同名 runner 的
  Xcode 版本、Release 优化、签名、Keychain、UI、真实播放、Archive 或分发。
- **判断**：双 OS matrix 与版本打印 **保留**；“标签等于固定 Xcode/SDK”这一隐含假设
  **替换**为逐 run 记录的工具链事实。是否需要额外固定一个最低 Xcode 版本，
  **尚不能判断**，取决于 v1 支持的开发/发布工具链政策。
- **风险**：中。runner 更新可能在未改代码时改变编译器诊断或 SDK 行为；反过来，把一次
  成功日志写成永久兼容承诺也会制造虚假 Gate。
- **下一步最小验证**：M6 选择最低受支持 Xcode 后，用显式 `DEVELOPER_DIR` 或 runner
  已安装版本选择运行一次 Release compile；每次发布候选记录 image version、Xcode build、
  Swift version 与 SDK，不把 YAML label 当版本号。
- **依赖 / 冲突**：与 `M501-CONC-*` 互补；Swift 6 编译成功不能替代 Task/owner 的运行时
  生命周期验证。

## M501-ENG-002：最低 macOS 已明确，v1 CPU 架构支持仍未裁决

- **finding_id**：`M501-ENG-002`
- **审计线 / 能力**：macOS 15 支持边界、Apple Silicon/Intel 架构与最终 archive。
- **当前实现（文件 / 符号 / 调用链）**：
  - `README.md:14-18` 对外只声明最低 macOS 15，没有声明 Apple Silicon-only 或
    universal。
  - Xcode 工程没有显式覆盖 `ARCHS`/`EXCLUDED_ARCHS`；
    shared scheme `BiliKitMac.xcscheme:5-23,125-128` 使用 Automatic architecture，
    App 可参与 Archive。
  - 当前本机验证、签名 Keychain smoke 与 CI 两个 runner 都是 arm64；
    `docs/validation/M1-real-playback-2026-07-21.md:24-28` 已明确 Intel 尚未覆盖。
- **声称承担的职责**：最低系统声明与最终可安装硬件范围一致。
- **外部事实来源**：
  - Apple
    [Build Settings Reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
    说明 `ARCHS` 决定产物包含的架构；多架构设置才生成 universal binary。
  - GitHub runner-images 当前把 `macos-15`、`macos-26` 标为 arm64，把 Intel runner
    暴露为另外的 `-intel`/`-large` label。
  - **证据强度**：Apple build setting 规范 + 当前 runner 规格 + 实际日志，多源印证。
- **OSS 对照及 commit/date**：不适用；产品支持哪些 CPU 是 BiliKit 的发布决策，不由
  其他客户端决定。
- **真实行为证据**：基线 CI 与历史真实播放/Keychain smoke 只运行 arm64；本轮没有
  Intel Mac、Rosetta 或 universal archive。
- **本地测试实际覆盖范围**：源代码在 arm64 的 macOS 15/26 编译通过，不证明 x86_64
  slice 能编译、归档、签名或实际播放。
- **判断**：**尚不能判断**。最低 macOS 15 可以保留，但必须在 M6 明确
  “Apple Silicon-only”或“同时支持 Intel”；当前证据不能静默选择后者。
- **风险**：中。若对外只写 macOS 15，Intel 用户可能合理预期兼容；若临近发布才发现
  x86_64 编译或媒体路径问题，修复成本与发布承诺都会上升。
- **下一步最小验证**：先由产品裁决目标硬件。若支持 Intel，先做一次无签名
  `ARCHS=x86_64` Release build，再在真实 Intel macOS 15 上跑最小启动/播放路径；最终
  archive 用 `lipo -info` 核对 slice。若不支持，在下载页、README 与包元数据明确标注。
- **依赖 / 冲突**：依赖性能线对目标硬件的实际测量；不能用 arm64 CI 的 deployment
  target 替代 Intel 行为证据。

## M501-ENG-003：Swift 6 编译边界成立，显式并发兼容机制需分别审计

- **finding_id**：`M501-ENG-003`
- **审计线 / 能力**：Swift 6 language mode、编译期 data-race safety 与平台导入边界。
- **当前实现（文件 / 符号 / 调用链）**：
  - App Debug/Release 均设置
    `SWIFT_VERSION = 6.0`、`SWIFT_APPROACHABLE_CONCURRENCY = YES`、
    `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`
    （`project.pbxproj:474-478,508-512`）。
  - Package 以 `// swift-tools-version: 6.0` 构建。
  - 播放、Network 与 URLSession 边界仍有多个 `@preconcurrency import` 与
    `@unchecked Sendable`，例如
    `AVPlayerItemReadiness.swift:1,43`、`DASHToHLSBridge.swift:10`、
    `LoopbackPlaybackServer.swift:3,71,567`、
    `HTTPClient.swift:76,142`。
- **声称承担的职责**：利用 Swift 6 编译器隔离规则排除普通 Swift 代码的数据竞争。
- **外部事实来源**：
  - Swift 官方
    [Data Race Safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)
    说明 Swift 6 language mode 通过编译器检查可见的可变状态。
  - Swift 官方
    [Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
    同时说明部分竞争只能在运行期暴露；Swift compiler 的
    [NonSendableSuperclass diagnostic](https://docs.swift.org/compiler/documentation/diagnostics/non-sendable-superclass)
    明确 `@unchecked Sendable` 要求实现者自行保证安全。
  - **证据强度**：Swift 规范 + 编译配置 + 两个实际编译器版本，已确认。
- **OSS 对照及 commit/date**：不适用；逃生口是否安全必须回到本仓库 owner/同步实现，
  不能以其他项目也使用 `@unchecked` 作为证明。
- **真实行为证据**：没有 Thread Sanitizer、Swift Concurrency Instruments 或专门的
  并发运行时验证；基线 CI 只说明编译器接受这些声明。
- **本地测试实际覆盖范围**：Package/App tests 覆盖部分取消、generation 与资源计数；
  它们不证明所有 `@unchecked Sendable` 的内部可变状态均同步。
- **判断**：Swift 6 mode **保留**。`@unchecked Sendable` 明确把线程安全责任交给实现者，
  必须记录其锁、actor、串行 queue 或不可变 owner；`@preconcurrency import` 是导入
  兼容性／诊断抑制机制，需记录为何仍必要，不能与前者概括成同强度逃生口，也不能仅凭存在
  推断竞态。两类都不能从编译通过推导安全或批量删除。
- **风险**：中到高，取决于具体 escape hatch。错误的 `@unchecked Sendable` 可绕过
  Swift 6 的主要保证；仅在 CI 增加另一编译器不会自动发现运行期竞态。
- **下一步最小验证**：把所有生产 `@preconcurrency`/`@unchecked Sendable` 建成审查清单，
  逐项记录锁、actor、串行 queue 或 immutable owner；只对剩余争议运行一条针对性
  Thread Sanitizer/Concurrency trace，不跑泛化矩阵。
- **依赖 / 冲突**：依赖 `M501-CONC-003`、`M501-CONC-005` 的 owner 结论以及性能资源线；
  本 finding 不重复判定各类型实现。

## M501-ENG-004：源码 entitlement 门禁不能证明成品，另有未使用文件权限与冗余注册设置

- **finding_id**：`M501-ENG-004`
- **审计线 / 能力**：App Sandbox、Hardened Runtime、network client/server、
  Keychain access group 与有效签名权限。
- **当前实现（文件 / 符号 / 调用链）**：
  - `BiliKitMac/BiliKitMac.entitlements:5-12` 声明 network client、network server 与
    单一 Keychain access group。
  - App Debug/Release 设置
    `ENABLE_APP_SANDBOX = YES`、`ENABLE_HARDENED_RUNTIME = YES`，并引用同一 entitlement
    文件（`project.pbxproj:453-461,487-495`）。
  - 两套配置曾设置 `ENABLE_USER_SELECTED_FILES = readonly`
    与 `REGISTER_APP_GROUPS = YES`，但全仓没有 `NSOpenPanel`、`NSSavePanel`、
    `fileImporter`、security-scoped bookmark、App Group entitlement 或 group container
    调用；2026-07-28 经用户授权已从 Debug/Release 删除。
  - `Scripts/check-project-contract.sh:53-84` 只检查源 entitlement 文件与若干 build
    setting 的文本出现次数；它不读取已签名二进制的 entitlement、code directory flags
    或 provisioning profile。
- **声称承担的职责**：最小权限的 sandboxed App 能出站请求、只为 loopback bridge 监听，
  并访问唯一的 Data Protection Keychain group。
- **外部事实来源**：
  - Apple
    [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
    说明 sandbox 权限表达访问意图，Incoming Connections 允许监听入站连接，且实际运行时
    应检查进程 Sandbox 状态。
  - Apple
    [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)
    说明 Xcode 签名时会把 entitlement 文件、开发者账号和工程信息合成为最终 entitlement；
    源 plist 不是最终权威。
  - Apple
    [`com.apple.security.files.user-selected.read-only`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-only)
    说明 `User Selected File = Read Only` 对应打开/保存面板选择文件的只读权限。
  - Apple notarization 文档说明 Hardened Runtime 是 Developer ID notarization 的必要条件，
    但 build setting 存在不等于最终签名已携带 runtime flag。
  - **证据强度**：Apple 规范 + 完整调用搜索 + Apple Development 签名成品检查。
- **OSS 对照及 commit/date**：不适用；最小权限必须由 BiliKit 的实际调用者决定。
- **真实行为证据**：2026-07-28 分别构建 Apple Development 签名 Debug test host 与
  普通 App。普通 App 的有效 entitlement 明确包含 app sandbox、network client/server、
  单一 Keychain access group、Debug `get-task-allow`，并额外包含
  `com.apple.security.files.user-selected.read-only = true`；code directory 带 runtime
  flag。未出现 App Group entitlement。删除两项配置后的第二次普通签名构建确认
  user-selected files 与 App Group 权限均不存在，其他上述权限、Team/Bundle identity
  与 runtime flag 保持不变。签名 Keychain smoke 使用隔离 service 通过。
- **本地测试实际覆盖范围**：这证明当前 Development Debug 成品权限和 runtime flag，
  不证明 Release/Developer ID/notarized 成品；也不证明 network server 只监听 loopback。
- **判断**：network client/server、sandbox、hardened runtime 与单一 Keychain group
  按当前职责 **保留**；静态门禁作为“有效权限已经正确”的完成标准应 **替换**为
  “源码配置检查 + 发布候选成品检查”两层。无调用者的 user-selected read-only 有效权限
  与冗余 App Group 注册设置均已 **删除**，签名成品对照通过。
- **风险**：高。缺失必要 entitlement 会让签名 App 在未签名 CI 通过后运行失败；多余的
  文件/App Group 能力扩大权限或 provisioning 表面积。`network.server` 只允许入站，
  不会替应用保证只绑定 `127.0.0.1`，绑定约束仍由播放实现承担。
- **下一步最小验证**：若制作 Developer ID 候选，在 M6 重做 Release 成品 entitlement、
  runtime、签名 identity 与 notarization 检查；Debug 成品不能代替发布候选。
- **依赖 / 冲突**：依赖 `M501-PRIV-001` 的 Keychain 策略、媒体线的 loopback bind
  结论；不建议为通过签名而放宽 entitlement。

## M501-ENG-005：Keychain 同一安装身份的升级可推断，换签名与卸载结果未验证

- **finding_id**：`M501-ENG-005`
- **审计线 / 能力**：Keychain access group、升级、换签名、迁移、登出与卸载数据边界。
- **当前实现（文件 / 符号 / 调用链）**：
  - access group 为
    `$(AppIdentifierPrefix)com.shiinayane.BiliKitMac`
    （entitlements `:9-12`），生产 service/account 固定为
    `com.shiinayane.BiliKitMac.web-auth` / `web-credential`
    （`WebCredentialStore.swift:17-30`）。
  - item 使用 Data Protection Keychain、非同步、
    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    （`WebCredentialStore.swift:53-81,90-97`）。
    SecItem query 没有显式 `kSecAttrAccessGroup`，依赖最终签名身份提供的默认 access
    group。
  - 仓库没有 UserDefaults、SwiftData 或文件型生产业务持久化；当前显式业务凭据持久层
    只有该 Keychain item。登出会显式删除，Finder 删除 App 没有项目自有 uninstaller。
- **声称承担的职责**：重启/正常升级后恢复登录；登出删除；不迁移到另一台设备。
- **外部事实来源**：
  - Apple
    [Sharing access to keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
    说明 macOS Data Protection Keychain 的 access group 来自签名 entitlement，
    application identifier 由 team ID + bundle ID 形成。
  - Apple
    [`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
    明确 item 不迁移到新设备。
  - Apple Support
    [Delete or uninstall apps on Mac](https://support.apple.com/en-us/102610)说明 Finder
    删除与应用自带 uninstaller 的清理边界不同；它没有承诺替第三方 App 清除所有外部数据。
  - **证据强度**：Apple access-group/迁移规范 + 静态存储枚举；升级/卸载为未知。
- **OSS 对照及 commit/date**：不适用；本地凭据保留策略是产品与安全决策。
- **真实行为证据**：历史签名 Debug smoke 只对独立测试 item 完成 add/update/read/delete；
  没有覆盖生产 item、覆盖安装、Developer ID/App Store 签名迁移、换 Team ID、删除 App
  或重新安装。
- **本地测试实际覆盖范围**：mock 与签名 smoke 证明查询/属性和单次 SecItem 往返；
  不证明发布包升级后仍可读，也不证明卸载后凭据存在或消失。
- **判断**：最终签名的 application identifier/access-group prefix、bundle ID 与有效
  Keychain access group 均保持一致时的升级恢复设计 **保留**；`AppIdentifierPrefix`
  在历史账号/App ID 场景不应无条件等同 Team ID。换分发渠道/签名前缀、降级、卸载、
  重新安装后的结果 **尚不能判断**。不得把“登出可删除”写成“卸载会删除”。
- **风险**：高。签名身份或 bundle ID 改变可造成旧凭据不可读并让用户意外退出；卸载后
  若凭据保留，重新安装可能恢复登录，与用户对“删除 App”的预期冲突。
- **下一步最小验证**：使用纯测试 service/account 和空测试账号，按同一候选签名执行
  v1→v2 覆盖安装、启动恢复、显式登出、Finder 删除、重新安装矩阵；每步只记录 item
  是否存在/可读，不导出 value。若产品要求卸载即清理，需要用户可执行的应用内清除入口
  或明确说明，不能假设 Finder 会运行 App 代码。
- **依赖 / 冲突**：依赖分发渠道和最终 access group 冻结；与隐私线的 Keychain finding
  一致。

## M501-ENG-006：工程具备 Archive 入口，但没有任何当前可分发候选证据

- **finding_id**：`M501-ENG-006`
- **审计线 / 能力**：Release、Archive、Export、Developer ID/Mac App Store、
  notarization、staple、Gatekeeper 与真实安装。
- **当前实现（文件 / 符号 / 调用链）**：
  - shared scheme `BiliKitMac.xcscheme:125-128` 的 ArchiveAction 使用 Release；
    Release 配置启用 App Sandbox/Hardened Runtime 与自动签名。
  - 仓库没有 ExportOptions plist、archive/export/notary/staple 脚本、发行 workflow、
    notarization ticket、安装包或发布检查记录。
  - `README.md:9-12` 明确“可分发版本尚未实现，项目仍不适合分发”；
    `docs/ROADMAP.md:150-158` 把签名、权限、许可、Archive、升级/卸载与发布候选留在 M6。
- **声称承担的职责**：当前工程只支持开发验证，不宣称已有发布包。
- **外部事实来源**：
  - Apple
    [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
    明确先创建 archive，再按渠道 export 或上传；Archive 是后续分发输入，不等于成品。
  - Apple
    [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
    明确 Developer ID 外部分发需要有效签名、Hardened Runtime、secure timestamp，
    notary service 通过后还可 staple ticket；Mac App Store 使用另一条等效审查链路。
  - Apple
    [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
    建议检查 code signature 与 `spctl`，且只有 Developer ID 签名可用于该 notarization
    路径。
  - **证据强度**：Apple 规范 + 仓库完整搜索，已确认“尚无分发证据”。
- **OSS 对照及 commit/date**：不适用；其他 App 的 release automation 不能证明
  BiliKit 的签名、entitlement、内容政策或 Gatekeeper 结果。
- **真实行为证据**：无当前 Release archive、Developer ID/App Store export、
  notarization、staple、隔离安装或首启行为。本轮按约束未执行这些操作。
- **本地测试实际覆盖范围**：Debug build/test 与历史 Apple Development smoke 都低于
  Release/Archive 层；scheme 可 Archive 只证明入口配置存在。
- **判断**：当前“不适合分发”的声明 **保留**；可分发性 **尚不能判断**，并且在用户选定
  Mac App Store 或 Developer ID 外部分发渠道之前不能关闭。
- **风险**：高但当前不构成已发布事故。Release 优化、签名合并、sandbox、Keychain、
  loopback server、许可或 Gatekeeper 中任一差异都可能只在成品链路暴露。
- **下一步最小验证**：先裁决分发渠道；创建一个不上传的 Release archive 并 validate，
  检查 Info.plist、版本、架构、嵌入库、签名与有效 entitlement。若走 Developer ID，
  再对隔离候选执行 notarization、staple、`spctl`、下载隔离属性下首启和核心播放；
  若走 App Store，改走对应 archive validation/TestFlight/Review 边界。各层结果分开记录。
- **依赖 / 冲突**：依赖 API/内容合规、许可、隐私、真实 UI/播放与性能线；不能在这些
  finding 未冻结时提前把 Archive 成功写成发布完成。

## M501-ENG-007：版本号配置适合未发布基线，但还不是发布版本策略

- **finding_id**：`M501-ENG-007`
- **审计线 / 能力**：bundle identity、marketing/build version、升级顺序与发布可追踪性。
- **当前实现（文件 / 符号 / 调用链）**：
  - App Debug/Release 都使用
    `MARKETING_VERSION = 1.0`、`CURRENT_PROJECT_VERSION = 1` 与固定 bundle ID
    `com.shiinayane.BiliKitMac`
    （`project.pbxproj:456-470,490-504`）。
  - CI 不生成发布 build number，不把 commit SHA 与 archive 对应；仓库没有 release tag/
    archive manifest 约束。
- **声称承担的职责**：开发期保持稳定 bundle identity，并为未来 v1 提供初始版本。
- **外部事实来源**：
  - Apple
    [Build Settings Reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
    说明 `MARKETING_VERSION` 生成 `CFBundleShortVersionString`，
    `CURRENT_PROJECT_VERSION` 生成 `CFBundleVersion`。
  - Apple
    [Setting the next build number for Xcode Cloud builds](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds/)
    说明 macOS App Store build number 必须跨 app version 持续增加。
  - **证据强度**：Apple 规范 + 工程配置；分发渠道未定。
- **OSS 对照及 commit/date**：不适用；版本策略由发布渠道与本项目历史决定。
- **真实行为证据**：尚未发布，无已安装旧版本与新 archive 可比较。
- **本地测试实际覆盖范围**：工程静态门禁只验证 bundle ID 一致，没有检查 marketing/build
  version 单调性、archive 元数据或升级识别。
- **判断**：当前 `1.0 (1)` 作为未发布开发值 **保留**；在首个候选前
  **替换**为明确的版本递增与 archive→commit 可追踪策略。具体实现
  **尚不能判断**，取决于 Developer ID/App Store 与是否采用自动更新。
- **风险**：中。重复 build number 会阻塞 App Store 提交或破坏升级/诊断关联；过早引入
  自动版本工具又会在渠道未定时增加无用复杂度。
- **下一步最小验证**：M6 定义唯一版本来源、递增规则和 tag/archive 映射；对两个连续
  测试 archive 检查 Info.plist 中 short version/build number 与预期一致，再做升级安装。
- **依赖 / 冲突**：依赖 `M501-ENG-005/006` 的渠道与升级矩阵。

## M501-ENG-008：SwiftProtobuf 依赖锁与许可识别正确，分发物中的许可呈现尚未验证

- **finding_id**：`M501-ENG-008`
- **审计线 / 能力**：SwiftPM supply chain、锁定 revision、第三方 license 与二进制分发。
- **当前实现（文件 / 符号 / 调用链）**：
  - 唯一 App/SwiftPM 远端源码依赖是 SwiftProtobuf 1.38.1，
    `Package.swift:26-30` 使用 exact requirement；Package 与 Xcode 两份
    `Package.resolved` 都锁定
    `55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`。
  - 当前 checkout HEAD 与锁定 SHA 一致；上游 `LICENSE.txt:89-128` 是 Apache 2.0
    redistribution 条款，`:205-211` 带 Runtime Library Exception。
  - `THIRD_PARTY_NOTICES.md:5-11` 正确记录版本、SHA、来源、许可与全文链接；
    根目录 notice 是位于 App target synchronized root group 之外的普通 PBX file
    reference，也没有显式 target/resource membership，因此没有证据显示会随最终
    App、DMG/PKG 或下载页交付。
- **声称承担的职责**：依赖可重复解析，许可与来源可审计，分发时满足上游条款。
- **外部事实来源**：
  - SwiftProtobuf
    [1.38.1 LICENSE](https://github.com/apple/swift-protobuf/blob/1.38.1/LICENSE.txt)
    是该 revision 的直接许可文本；Runtime Library Exception 对编译进二进制的部分放宽
    Apache 4(a)、4(b)、4(d) attribution。
  - SwiftPM resolved revision 与本地 checkout 是供应链身份事实；许可是否需要在特定
    分发载体呈现仍应按最终打包形态复核。
  - **证据强度**：上游直接许可 + 锁文件 + checkout，多源已确认；成品分发未知。
- **OSS 对照及 commit/date**：上游自身即依赖权威来源，commit
  `55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`，tag 1.38.1；不需要两个客户端对照。
- **真实行为证据**：基线 CI 实际解析 1.38.1 并成功编译；没有最终 archive/installer
  可检查 third-party notice。
- **本地测试实际覆盖范围**：静态门禁验证 exact version 与两份 lock 一致；不能证明
  下载页、App 内 acknowledgements 或安装包包含所需许可文本，也不能代替依赖漏洞/发布
  资格审查。
- **判断**：依赖锁与 `THIRD_PARTY_NOTICES.md` **保留**；是否还需把许可全文或 notice
  打入最终载体 **尚不能判断**，必须对照最终链接/打包方式和上游 exception，不在本审计中
  作法律结论。
- **风险**：中。供应链漂移当前受控；主要剩余风险是发布物与仓库 notice 脱节，或者未来
  升级后许可/最低工具链变化却仍沿用旧声明。
- **下一步最小验证**：M6 对实际 archive 与分发载体列文件清单，记录 SwiftProtobuf
  是静态链接、动态嵌入还是仅生成代码，并据 1.38.1 许可核定呈现方式；发布前核对
  `THIRD_PARTY_NOTICES` 的 SHA/URL 与 archive resolved graph。
- **依赖 / 冲突**：依赖 `M501-ENG-006` 的最终载体；与 ADR 0008 的升级门槛一致。

## M501-ENG-009：`references/` 隔离成立，但无许可证/限制性项目只能作为行为线索

- **finding_id**：`M501-ENG-009`
- **审计线 / 能力**：研究 checkout、license、clean-room 边界与误打包风险。
- **当前实现（文件 / 符号 / 调用链）**：
  - `.gitignore:20-23` 忽略整个 `/references/`；Xcode 工程和 Package manifest 均不引用
    该目录，App Resources phase 为空。`README.md:169-175` 与
    `THIRD_PARTY_NOTICES.md:15` 禁止复制参考代码、注释、fixture 与资产。
  - 基线 SHA/license 清点：

    | reference | commit / date | 根目录许可事实 |
    | --- | --- | --- |
    | ATV-Bilibili-demo | `86ba6f5` / 2026-07-05 | GPL-2.0 |
    | AnimacX | `e422b05` / 2026-07-26 | 自定义许可；禁止未经授权的修改/合并/再发布与收费 |
    | BBDown | `1b2fbd4` / 2026-05-14 | MIT |
    | Bili-Swift | `e807ce7` / 2025-12-10 | 未发现根目录 license |
    | Bili.Mac.MenuBar | `9e2124f` / 2022-09-15 | MIT |
    | Bilibili-Gate | `b3655b9` / 2026-07-25 | MIT |
    | Darock-Bili | `60d6676` / 2026-06-28 | GPL-3.0 |
    | PiliPlus | `f1b79ee` / 2026-07-24 | GPL-3.0 |
    | bilibili-API-collect | `4c00347` / 2026-01-30 | 未发现根目录 license |
    | bilibili-client-software-collection | `dc06af1` / 2026-07-25 | 未发现根目录 license |
    | bilibili-mac-client | `b959abc` / 2018-09-30 | GPL-3.0 |
    | cilicili | `6f02857` / 2026-07-26 | GPL-3.0 |
    | wiliwili | `88e5876` / 2026-04-25 | GPL-3.0 |
- **声称承担的职责**：参考项目只用于交叉观察公开行为、协议形状和提交历史，不成为
  BiliKit 源码、fixture、资源、依赖或发布输入。
- **外部事实来源**：
  - 每个 checkout 在上述 commit 的根目录许可文本是直接证据；未发现 license 不能被
    推断为 MIT/开源授权。
  - GitHub
    [Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
    说明公开仓库的默认可查看/fork 权限不等于一般性的复制、修改和再分发许可。
  - **证据强度**：checkout 许可原文 + Git 忽略/target 调用图，已确认。
- **OSS 对照及 commit/date**：本 finding 本身就是完整 reference 对照；license 不能由
  两个项目互相证明，必须逐仓读取。
- **真实行为证据**：当前 `git ls-files references` 为空，Xcode/SwiftPM 无引用；
  没有发现 reference 被编译或复制进 App。此次没有做源码相似度/历史法证，因此
  “从未复制过任何片段”不能仅凭当前 target 图证明。
- **本地测试实际覆盖范围**：静态架构/工程 gate 没有专门扫描 reference 内容与生产源码
  相似度；`.gitignore` 只阻止默认跟踪，不是版权合规证明，也不能阻止人工复制。
- **判断**：整个 `references/` 隔离与 clean-room 规则 **保留**。GPL、自定义限制性许可
  以及无 license 项目只能作为行为/协议线索；未经逐项法律与 clean-room 裁决，
  **不得复制或链接**。MIT reference 也不能省略 attribution 或自动进入产品。
- **风险**：高影响、当前低触发。误复制 GPL/限制性/无许可内容可能污染 MIT 仓库与未来
  分发；误把“忽略目录”写成“已证明独立创作”同样会夸大证据。
- **下一步最小验证**：每个实施 finding 记录采用的是规范/现场结构事实而非第三方表达；
  修复审查时对新增 schema、算法常量、注释、fixture 与资产做针对性来源复核。M6 archive
  文件清单必须确认没有 `references/`、`.git`、trace 或 checkout 文件。
- **依赖 / 冲突**：与 API、媒体各 finding 的 OSS 证据相关；OSS 可以印证事实，不能成为
  代码复制许可。

## M501-ENG-010：CI action 使用可移动 tag，未固定不可变 revision

- **finding_id**：`M501-ENG-010`
- **审计线 / 能力**：CI supply chain、workflow 完整性与未来发布凭据。
- **当前实现（文件 / 符号 / 调用链）**：
  `.github/workflows/ci.yml:33` 使用一次 `actions/checkout@v6`；基线 run 当次实际解析为
  `d23441a48e516b6c34aea4fa41551a30e30af803`，但 YAML 没有固定该不可变 SHA。
  workflow 当前 `permissions: contents: read`，降低了 token 权限，却不能阻止 action
  修改工作区并影响 build/test 结果。
- **它声称提供的职责**：以可审计、可重复的第三方 action 检出当前 commit，再执行质量门禁。
- **外部事实来源**：GitHub
  [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions)
  明确完整 commit SHA 是引用 action 不可变版本的唯一方式；访问日期 2026-07-27。
- **OSS 对照及 commit/date**：不适用；GitHub 是该执行平台的一方规范。
- **真实行为证据**：
  - 基线 run 成功且可查到当次解析 SHA；这不保证未来同一 `@v6` tag 仍解析到同一代码；
  - 2026-07-28 对官方 repository 执行只读 `ls-remote`，`refs/tags/v6` 指向
    `d23441a48e516b6c34aea4fa41551a30e30af803`，而最新编号 release `v6.0.2` 指向
    `de0fac2e4500dabe0009e67214ff5f5447ce83dd`。前者是官方 `releases-v6` 的后续
    backport，包含 fork PR checkout guard 等修复，因此不能机械地把“最新编号 release”
    当作“当前 major tag 的等价代码”。
- **本地测试实际证明的范围**：static gate 不校验第三方 action pin；CI 成功只证明当次
  解析结果运行成功。
- **判断**：**替换**为当前已经过基线验证且仍由官方 `v6` 指向的完整 SHA
  `d23441a48e516b6c34aea4fa41551a30e30af803`，并保留 `# v6` 注释；由依赖更新工具或
  显式 PR 提交可审查升级。这里锁定的是已审阅代码身份，不是追逐编号最大的 tag。
- **风险**：当前权限有限时影响中；未来发布 workflow 若携带签名或发布秘密，移动 tag
  的供应链风险显著升高。
- **下一步最小验证**：实施时只替换 action reference，先以 YAML/文本检查确认所有
  `uses:` 均为完整 SHA，再运行同一 CI matrix；发布 workflow 建立前重新核对 action
  SHA、runner image revision 与发布凭据最小权限。
- **依赖 / 冲突**：与 SwiftPM lock 同属供应链，但不能由 `Package.resolved` 代替。

## 需真实分发环境验证的最小清单

以下项目不能由本轮 static gate 关闭：

1. 选定 Developer ID 外部分发或 Mac App Store 渠道；
2. 明确 Apple Silicon-only 或 Intel + Apple Silicon；
3. 生成当前 Release archive，核对架构、版本、依赖、Info.plist、签名与有效 entitlement；
4. 在签名候选中验证 App Sandbox、Hardened Runtime、network client/server 与
   Keychain access group；
5. 用隔离测试 item 完成覆盖升级、登出、Finder 删除与重新安装；
6. 按选定渠道完成 notarization/staple/Gatekeeper 或 App Store validation/TestFlight；
7. 在下载隔离属性与真实安装位置首启，执行登录恢复、loopback 播放和退出清理；
8. 核对最终 App/DMG/PKG/下载页中的第三方许可与无 `references/` 内容。
9. 固定并核对 workflow action SHA、runner image revision 与发布凭据最小权限。

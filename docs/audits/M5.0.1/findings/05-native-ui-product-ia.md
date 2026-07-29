# 05 Apple 原生 UI 与产品信息架构

状态：第二轮取证与独立交叉复核完成；未修改生产代码。

审计基线：`origin/main`
`a00744639f853ffbd7543a56c29a1588d41d93ea`（2026-07-26）。
SDK 取证环境为 Xcode 26.6（17F113）的 macOS 26.5 SDK interface；其中每项
availability 都同时核对了项目最低 macOS 15，而不是用当前系统版本代替最低版本。
Apple App 观察发生于 2026-07-27、macOS 26.5.2（25F84），界面语言为日文；观察只记录
脱敏结构与数值，不保存账号、媒体标题、搜索词、资料库内容或截图。

## UI-001：平级来源使用 `TabView`，播放层级使用每 Tab 的 `NavigationStack`

- **finding_id**：UI-001
- **审计线与涉及能力**：Apple 原生 UI／产品信息架构；Tab、侧栏、层级导航和返回。
- **当前实现（文件、符号、调用链）**：
  `BiliKitMac/App/AppShellView.swift:29-80,124-140` 以搜索、热门、历史三个
  `Tab` 构成 `.sidebarAdaptable` `TabView`，每个 Tab 内建立 `NavigationStack`；
  `BiliKitMac/App/AppNavigationCoordinator.swift:15-70` 保存选中 Tab、轻量
  `PlaybackDestination` path，并在 path identity 变化时调用播放启停 owner。
  `selectedTab` 改变时会清空 `playbackPath`（`:16-20`），非当前 Tab 也被
  `AppShellView.swift:156-170` 投影为空 path，因此不会保留不可见 Tab 的深层播放页。
- **它声称提供的职责**：系统负责 Tab／sidebar 呈现和栈式 back；App 只负责跨 Feature
  播放副作用，不再自行绘制 route 或 back。
- **外部事实来源**：
  - 当前 SDK interface
    `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:7516-7534` 明确
    `SidebarAdaptableTabViewStyle` 从 macOS 15 可用；
  - Apple [sidebarAdaptable 文档](https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable)
    说明 macOS 始终以 sidebar 表达；
  - Apple HIG [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
    将 sidebar 定义为多个平级内容区域的入口；
  - Apple [Understanding the navigation stack](https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack)
    明确 `NavigationStack(path:)` 是应用观察和控制栈状态的原生表达。
  以上在线来源访问于 2026-07-27。
- **OSS 对照及 commit/date**：不使用 OSS 裁决 Apple 导航语义；第三方源码既不能证明
  Apple 私有 App 的实现，也不高于 SDK／HIG。
- **真实行为证据**：Music 1.6.5 中，侧栏“搜索”保持 selected 时可以在栏目内
  逐级 back；切到“首页”再回“搜索”，仍回到同一深层 destination，toolbar back
  仍存在。TV 1.6.5 与 Podcasts 1.1.0 也把搜索和主要内容区放在同一级侧栏。此观察
  印证“平级栏目 + 栏目内层级”的产品模式，但不能证明这些 App 使用 SwiftUI。
- **本地测试实际证明的范围**：
  `AppNavigationCoordinatorTests` 证明 path pop、Tab 切换和关窗只触发预期的启停
  次数；`PlayerHostLifecycleProbeTests` 证明测试宿主的挂载／dismantle 事件。
  它们不证明系统 back 的视觉、真实焦点或 Apple App 的内部实现。
- **判断**：**保留** `TabView + 每 Tab NavigationStack + 单 player owner`。平级栏目
  语义与 Apple 模式一致，但深层状态策略不同：Music 的单机观察会保留栏目内 destination，
  BiliKit 切 Tab 主动退出播放并释放唯一 player。这是当前产品/资源取舍，不能写成行为一致；
  `AppNavigationCoordinator` 仍有跨 Feature 播放清理职责。
- **风险**：影响中；若把三个来源重新解释为一个层级树，会破坏各来源的独立上下文。
  当前单一共享播放 path 刻意保证不可见 Tab 不保留第二个 player，恢复性高。
- **下一步最小验证**：在当前签名 BiliKit build 中用鼠标和键盘各走一次
  热门／搜索／历史 → 播放 → toolbar back／Escape，并确认来源、标题、焦点和 player
  host 数量；不需要再做自定义 route spike。
- **与其他 finding 的依赖或冲突**：滚动上下文见 UI-004；键盘 back 见 AX-002；
  player owner 依赖并发生命周期审计。

## UI-002：`CenteredSearchField` 重复了 macOS 15 已有的 SwiftUI 搜索能力

- **finding_id**：UI-002
- **审计线与涉及能力**：Apple 原生 UI；`NSViewRepresentable`、搜索、焦点和 Return。
- **当前实现（文件、符号、调用链）**：
  `SearchTabRoot` 已在实际导航内容上使用
  `.searchable`、编译期选择的原生 toolbar placement 与
  `.onSubmit(of:.search)`；`CenteredSearchField` AppKit bridge、固定 340 pt
  宽度和专用 test-only native searchable spike 已删除。
- **它声称提供的职责**：在 toolbar 中居中搜索框、双向绑定搜索 draft、按 Return
  提交，并补充搜索字段辅助语义。
- **外部事实来源**：
  - 当前 SDK interface
    `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:5660-5705,9098-9132`
    显示 `.searchable` 早于最低版本；`SearchFieldPlacement.toolbarPrincipal`
    在 Xcode 26 SDK 中标注 macOS 12+，但 Xcode 16.4/macOS 15.5 SDK 没有该成员。
    CI 的真实编译失败证明 availability 不能替代旧 SDK 声明可见性；
  - Apple [Adding a search interface](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app)
    规定在 `NavigationStack`／导航容器上使用 `.searchable`；
  - Apple [toolbarPrincipal](https://developer.apple.com/documentation/swiftui/searchfieldplacement/toolbarprincipal)
    与 [ToolbarItemPlacement.principal](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/principal)
    明确 principal 在 macOS toolbar 中居中；
  - Apple [Managing search interface activation](https://developer.apple.com/documentation/swiftui/managing-search-interface-activation)
    说明 SwiftUI 在 macOS 管理搜索焦点，并以 `.onSubmit(of: .search)` 处理 Return。
  以上访问于 2026-07-27。
- **OSS 对照及 commit/date**：不需要；Apple API 与当前真实 App 探针足以验证该
  平台行为，OSS 不能替代当前 SDK／系统的 toolbar 布局事实。
- **真实行为证据**：
  - 2026-07-28 在 Xcode 26.6、macOS 26.5.2、1320 pt 宽的签名 Debug App 中，
    test-only `.toolbarPrincipal` fixture 生成真正的 AX `SearchField`，宽 544 pt，
    相对窗口中心偏移 0 pt；`.toolbar` 对照则宽 327 pt、向右偏移 490 pt；
  - `.searchable` 必须挂到 `NavigationStack` 内实际内容视图才生成 toolbar 字段；
    同一 fixture 把 modifier 挂到栈外层时未生成字段；
  - 输入“示例”后 Return 会触发 `.onSubmit(of: .search)`；输入“临时”后 Escape
    将 binding 清空；
  - 原生字段的 AX placeholder 为“搜索 B 站视频”，但 `label` 与 `identifier`
    为空；内容取得焦点后按 Command-F 不会把焦点移到该搜索字段；
  - 保留截图只证明布局，未运行熟练 VoiceOver 朗读。
- **本地测试实际证明的范围**：
  既有 UI-F008 签名 probe 证明原生字段在 1320 pt 的布局、Return 和 Escape；当前完整
  app gate 证明 production 迁移可编译并通过现有 unit tests。更新后的核心 XCUI 已按
  SearchField role 覆盖 Escape、Return 与 Tab 往返，但本机 test worker 未
  materialize，本轮没有执行这些断言。
- **判断**：**替换已实施，但不是逐属性等价**。
  `.searchable` + `.onSubmit(of:.search)` 已取代 AppKit bridge。Xcode 26+ 构建使用
  `.toolbarPrincipal`；Xcode 16.4 构建使用同样原生但不保证居中的 `.toolbar`。
  V1 不应把现有 340 pt 固定宽度、`search.field` identifier 或 Command-F 当成原生 API
  自动保留的契约。若产品要求进入 Tab 后立即聚焦，仍需另行采用并验证
  `isPresented`/`.searchFocused`，不能由 TV 私有 App 观察推断。
- **风险**：影响中、恢复容易；原生 principal 宽度由系统决定，本机由 340 pt 变为
  544 pt，现有 UI 测试不能继续依赖 `search.field`。原生字段已有 SearchField role
  与 prompt，但 VoiceOver 朗读、窄窗口 toolbar 压缩和 Tab 往返仍未验证。
- **下一步最小验证**：本机 UI runner 恢复后运行已更新的核心 fixture，补验 1080 pt
  窄窗口、Tab 往返、清除按钮和一次熟练 VoiceOver 任务。Command-F 若成为产品要求，
  需单独增加菜单命令，不属于 bridge 删除的阻塞项。
- **与其他 finding 的依赖或冲突**：依赖 AX-001、AX-002；搜索请求与工作集属于
  状态／缓存审计，不由本 finding 改变。

## UI-003：侧栏底部账户入口已经使用公开的原生容器，但位置不是跨 App 统一规则

- **finding_id**：UI-003
- **审计线与涉及能力**：Apple 原生 UI／产品信息架构；账户入口和 sidebar bottom bar。
- **当前实现（文件、符号、调用链）**：
  `BiliKitMac/App/AppShellView.swift:77-121` 使用
  `.tabViewSidebarBottomBar`，内容为 `.plain` Button，打开认证 sheet。
- **它声称提供的职责**：让登录／账户入口固定在 Tab sidebar 底部，独立于可滚动栏目。
- **外部事实来源**：
  当前 SDK interface
  `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:14116-14129` 明确
  `tabViewSidebarBottomBar` 从 macOS 15 可用；HIG
  [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
  只规定 sidebar 的导航语义，没有规定账户必须位于底部。访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；OSS 无法证明 Apple 一方账户入口规范。
- **真实行为证据**：Music 1.6.5 的 sidebar outline 下方有独立 account button；
  TV 1.6.5 也在 sidebar 底部暴露 account settings；Podcasts 1.1.0 的完整 AX 树未见
  同类底部按钮，只在 menu bar 暴露账户组。故底部账户是成立的一方模式，但不是统一
  强制规则；私有实现 API 未知。
- **本地测试实际证明的范围**：fixture XCUI 只证明按 identifier 点击可打开认证 sheet；
  辅助树只证明系统生成 sidebar 与一个 button。没有当前键盘 focus、pressed appearance、
  VoiceOver 或分割线来源证据。
- **判断**：**保留** `.tabViewSidebarBottomBar` 与当前产品位置。它正是最低版本公开
  API，不应为了模仿某一个 Apple App 改回自制 sidebar overlay。`.plain` Button 的输入
  反馈另由 AX-007 裁决。
- **风险**：影响低；主要风险是把系统容器自带的材质／边界误判成业务 Divider，
  或为了消除外观差异重新手写布局。可恢复性高。
- **下一步最小验证**：在 macOS 15 与 26 各运行一次当前签名 App，记录 bottom bar
  在窗口缩放、sidebar 隐藏／显示、键盘 focus 和 increased contrast 下的系统行为；
  不通过私有 view tree 推断 API。
- **与其他 finding 的依赖或冲突**：账户按钮反馈见 AX-007；认证 sheet 内容不属于
  导航容器裁决。

## UI-004：每 Tab 的语义 `ScrollPosition` 是正确 owner，但不是“精确像素恢复”契约

- **finding_id**：UI-004
- **审计线与涉及能力**：原生滚动状态、Tab 往返和来源返回上下文。
- **当前实现（文件、符号、调用链）**：
  `BiliKitMac/App/AppShellView.swift:18-26,85-94` 为三个 Tab 分别保存
  `ScrollPosition(idType:String.self)`；三个 grid 在
  `PopularFeedView.swift:87-111`、`VideoSearchView.swift:131-155`、
  `WatchHistoryView.swift:106-152` 配对 `.scrollTargetLayout()` 与
  `.scrollPosition`；搜索 identity 或登录身份改变时显式重置相应位置。
- **它声称提供的职责**：以内容 identity 表达窗口内来源上下文，避免保存数值 offset
  或卡片 selected snapshot。
- **外部事实来源**：
  Apple [ScrollPosition](https://developer.apple.com/documentation/swiftui/scrollposition)
  明确该类型表示语义位置，并以 scroll target 中最上方可见 view 的 identity 更新；
  [scrollTargetLayout](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout%28isenabled:%29)
  定义 target layout。WWDC24
  [What’s new in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10144/)
  展示 `ScrollPosition(idType:)`。这些 API 在当前 SDK 标注 macOS 15 可用；访问于
  2026-07-27。文档没有承诺跨数据／布局变化恢复完全相同的像素 offset。
- **OSS 对照及 commit/date**：不适用；Apple API 与真实一方行为的证据等级更高。
- **真实行为证据**：
  - 当前 Music 1.6.5 从“搜索”切到“首页”再返回，保留同一深层页面、back 和内容
    scrollbar 值 `0.734982332155477`；
  - BiliKit 旧验证记录在配置 identity target 后，两次热门往返分别为
    `0.195066 → 0.194867`、`0.389877 → 0.389447`；它是 2026-07-26 的单机观察，
    不是跨版本保证。
- **本地测试实际证明的范围**：ViewModel 测试证明成功工作集可复用；导航测试证明
  source/path identity。没有确定性测试能证明真实 lazy grid 的像素位置；M5.0 当前
  fixture XCUI 未成功进入产品路径。
- **判断**：**保留**。这是 Apple 提供的单一语义 owner；不能重新加入数值 offset
  fallback，也不能把近似 scrollbar 比例写成“精确像素契约”。
- **风险**：影响中；数据 identity、列数、窗口宽度、Dynamic Type 或图片尺寸变化时，
  同一 item 的可见几何可能变化。普通同布局往返可恢复，布局变化后只能要求可识别上下文。
- **下一步最小验证**：当前签名 build 分别验证热门、搜索、历史的 Tab 往返和
  来源→播放→返回，再对每条路径增加一次窗口 resize；记录首个可见 item 与相对行位置，
  不用 scrollbar 小数单独宣称通过。
- **与其他 finding 的依赖或冲突**：数据工作集 identity 依赖状态／缓存审计；
  窗口布局依赖 UI-005。

## UI-005：`GeometryReader` 有真实布局职责，但 1080 pt 硬最小宽度缺少产品证据

- **finding_id**：UI-005
- **审计线与涉及能力**：原生布局、窗口 resize、grid 列数和播放页宽／紧凑模式。
- **当前实现（文件、符号、调用链）**：
  三个列表用 `GeometryReader` 把可用宽度交给
  `VideoCardGridLayout.columns(for:)`，强制 2–5 列；
  `GuestVideoDetailView.swift:13-28,221-235` 在 1000 pt 阈值切换分 P rail／disclosure；
  `AppShellView.swift:81` 同时把整个窗口内容最小尺寸固定为 `1080 × 680`。
- **它声称提供的职责**：控制卡片最小密度和播放页侧 rail，避免内容在紧凑宽度挤压。
- **外部事实来源**：Apple HIG
  [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
  要求让人调整、隐藏、显示和移动窗口，并支持全屏；它不规定本产品的最小宽度。
  SwiftUI 的 adaptive `GridItem`、`ViewThatFits` 和自定义 `Layout` 可表达部分策略，
  但没有一个 API 自动等价于“2–5 列 + 1000 pt rail”这一产品规则。访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；窗口密度是产品约束，不以播放器 OSS 投票决定。
- **真实行为证据**：旧 fixture 只检查 1080 pt 与 1320 pt 两个尺寸和一个全屏路径；
  本轮没有把 BiliKit 窗口缩到更窄。Music／TV／Podcasts 都允许系统窗口 resize，
  但其内容密度和最小尺寸不是 BiliKit 的规范。
- **本地测试实际证明的范围**：
  `PlaybackPageLayoutTests` 只证明 870／1100 输入会选择预设 enum；
  compact XCUI 只证明 1080 pt 下 disclosure 存在。二者都不证明 1080 是合理最低值、
  大文字不截断或 resize 没有跳动。
- **判断**：**尚不能判断**。`GeometryReader` 当前有独立职责，不能仅因存在原生
  adaptive layout 就删除；但 1080 pt 硬下限没有外部需求或真实可用性证据。
- **风险**：影响中；硬下限限制分屏与小屏使用，阈值切换可能改变滚动上下文；
  直接换 adaptive grid 又可能破坏 2–5 列上限和卡片可读性。均可通过单一布局 revision
  恢复。
- **下一步最小验证**：先在 1080、900、760 pt 的原型或临时测试宿主中，用默认与
  accessibility text size 检查 sidebar、grid、toolbar、播放器和分 P；再裁决是降低
  最小宽度、用 `ViewThatFits`，还是保留现状。
- **与其他 finding 的依赖或冲突**：与 UI-004 的 resize 恢复、AX-005 的大文字直接
  相依；不要在审计阶段改阈值。

## UI-006：三份手写 duration formatter 是 Foundation format style 已有能力

- **finding_id**：UI-006
- **审计线与涉及能力**：Apple／Swift 原生格式化；视频时长和历史进度。
- **当前实现（文件、符号、调用链）**：已实施共享
  `BiliUI.VideoDurationFormatting`，以 `Duration.TimeFormatStyle` 输出卡片、分 P、
  AX label 与观看进度；三份手写秒数拆分已删除。搜索 duration parser 拒绝负分量。
- **它声称提供的职责**：把非负秒数显示成 `m:ss` 或 `h:mm:ss`。
- **外部事实来源**：
  当前 Foundation SDK interface
  `Foundation.swiftmodule/arm64e-apple-macos.swiftinterface:14591-14630`
  显示 `Duration.TimeFormatStyle` 从 macOS 13 可用；
  Apple [Duration.TimeFormatStyle](https://developer.apple.com/documentation/swift/duration/timeformatstyle)
  与 [Pattern](https://developer.apple.com/documentation/swift/duration/timeformatstyle/pattern-swift.struct)
  原生提供 localized `minuteSecond`／`hourMinuteSecond` pattern。访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；Foundation format style 直接覆盖格式化机制。
- **真实行为证据**：2026-07-28 使用 Xcode 26.6 Foundation 运行候选 style，对
  0、1、9、59、60、61、599、3599、3600、3661、359999、360000 秒逐项比较；
  `zh_CN`、`ja_JP`、`en_US` 三种 locale 均与旧实现逐字相等，覆盖 `0:00`、
  `59:59`、`1:00:00` 与 `100:00:00`。静态 `.minuteSecond`／
  `.hourMinuteSecond` 与显式 padding 在这些样本中也相等；实现仍应显式写出
  `padMinuteToLength: 1`／`padHourToLength: 1` 以表达产品契约。
- **本地测试实际证明的范围**：
  `VideoDurationFormattingTests` 固定 12 个非负边界和三种 locale；
  `WatchHistoryCardFormattingTests` 保留完成态／progress clamp 回归；
  `BiliAPIClientTests.searchRejectsNegativeDuration` 证明搜索负值映射为 nil。package gate
  237 项通过；这些证据不证明其他数字系统或未来 Foundation 版本。
- **判断**：**替换已实施**。共享 helper 按 `< 3600` 选择显式 padding 的
  `.minuteSecond`，否则选择 `.hourMinuteSecond`，再使用最低 macOS 13 可用的
  `Duration.TimeFormatStyle`；
  format style 删除重复整数拆分，但不会自动消除产品对两种 pattern 的选择。保留“已看完”
  和 progress clamp 等领域语义，不把协议时长解析混进 UI formatter。搜索 parser
  已让负值返回 nil，使共享 helper 的非负输入契约在 production 调用链成立。
- **风险**：影响低。列举的 locale、边界与超长小时完全等价；剩余风险是搜索异常负值、
  未列举数字系统和未来 Foundation 行为。替换可逐调用点回退。
- **下一步最小验证**：本项实施已关闭；无需为逐字等价的替换另做截图 Gate。未来
  Foundation／最低系统版本变更时复跑 locale 边界测试。
- **与其他 finding 的依赖或冲突**：日期和“万／亿”压缩包含 B 站中文产品语义，
  本 finding 不主张一并删除。

## UI-007：两个直接属性 Binding 可由 `@Bindable` 表达，回调型 Binding 仍有边界职责

- **finding_id**：UI-007
- **审计线与涉及能力**：SwiftUI Observation、手写 `Binding(get:set:)`。
- **当前实现（文件、符号、调用链）**：
  `AppShellView.body` 的局部 `@Bindable navigationCoordinator` 已直接投影 Tab
  selection、search draft 和三个 NavigationStack path；两个无附加逻辑的 computed
  Binding 已删除。字幕和弹幕 Binding 仍把写入路由到 ViewModel method。
- **它声称提供的职责**：把 `@Observable` reference 属性或只读 ViewModel 状态投影成
  SwiftUI control binding。
- **外部事实来源**：
  当前 SDK interface
  `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface:12412-12440`
  显示 `@Bindable` 从 macOS 14 可用，能由 `ReferenceWritableKeyPath` 生成 Binding，
  满足最低 macOS 15。
- **OSS 对照及 commit/date**：不适用；这是标准 Observation 语义。
- **真实行为证据**：2026-07-28 使用 Xcode 26.6 运行最小 Observation probe：
  `@Bindable` 生成的两个 Binding 写入后，源对象的值分别更新为新 selection 和 draft，
  两个属性的 `didSet` 各触发一次。当前 App 同一个局部 `@Bindable` 已承载三个原生
  NavigationStack path，并通过 UI-008 的搜索／热门／系统 Back 回归。
- **本地测试实际证明的范围**：导航测试证明赋值后的副作用；不依赖 Binding helper
  的具体拼写；最小 probe 证明 setter／didSet 语义，不渲染真实 TabView 或搜索控件。
  字幕／弹幕测试依赖 method 约束，不证明可直接开放 setter。
- **判断**：**替换已实施**。`selectedTabBinding` 与 `searchDraftBinding` 两个纯转发
  helper 已由 `$navigationCoordinator.selectedTab` 与
  `$navigationCoordinator.searchDraft` 取代；**保留**字幕／弹幕 method Binding，
  因为它们收口副作用，不是纯语法转发。
- **风险**：影响低；误把所有手写 Binding 一起机械删除会扩大 ViewModel 可写面，
  所以必须按职责拆分。纯转发替换可轻易恢复。
- **下一步最小验证**：完整 app gate 已通过。定点搜索 Return／Tab XCUI 的临时产物完成
  构建签名，但本机 test worker 未 materialize，fixture 未执行；未来签名／Automation
  环境恢复时补跑即可，不把本次启动记为行为通过。
- **与其他 finding 的依赖或冲突**：UI-001 要求继续保留单一播放副作用 owner；
  UI-002 若先采用 `.searchable`，可与 search draft 的 `@Bindable` 一起验证，但应分
  commit。

## UI-008：搜索结果按钮在当前 TabView 容器中不进入播放 destination

- **finding_id**：UI-008
- **审计线与涉及能力**：原生 TabView／NavigationStack、搜索结果激活、键盘与鼠标输入。
- **当前实现（文件、符号、调用链）**：
  `VideoSearchView.SearchResultsGrid` 与 `PopularFeedView.PopularGrid` 都以
  `Button { onSelect(video.bvid) }` 调用 `AppNavigationCoordinator.openPlayback`；
  修复前 `AppShellView.tabNavigation(for:)` 为三个 `NavigationStack` 投影同一个共享
  path。修复后 coordinator 为三个 Tab 分别持有 path，`AppShellView` 用局部
  `@Bindable` 把各 path 直接交给对应原生栈；切换 Tab 仍清空来源 path。
- **外部事实来源**：Apple `NavigationStack(path:)` 与 `TabView(selection:)` 的公开
  绑定语义；本 finding 的发生事实以当前真实 App 和离线 fixture 为主，不用 OSS 投票
  替代。
- **OSS 对照及 commit/date**：不适用；这是 BiliKit 当前容器与绑定组合的本地行为。
- **真实行为证据**：
  - 离线 UI fixture 中，提交搜索后结果按钮存在且可命中；移开搜索框焦点后，以 AX
    press、元素 click 和卡片中心坐标 click 均不改变 AX 树，窗口仍停留“搜索”；
  - 同一 fixture 切到热门后点击首张卡片，立即进入
    `playback.layout.wide`，证明 player destination 与通用卡片 style 本身可用；
  - 修复前，当前签名 App 使用普通匿名关键词得到真实搜索结果后，点击首项同样不改变
    AX 树；
  - 修复后，当前 Apple Development 签名 Debug App 完成一次真实匿名
    搜索→播放→系统 Back 往返，返回后搜索词、结果计数与结果列表仍保留；未把关键词、
    结果标题、BVID 或 URL 写入验证记录。
- **本地测试实际证明的范围**：
  test-only recorder 证明搜索 Button 已触发播放副作用且 coordinator path 持续非空，
  但共享条件 Binding 没有驱动 Search NavigationStack。改为每 Tab 独立 path 与直接
  `@Bindable` 投影后，`testFixtureCoreKeyboardAndRecoveryPath` 普通通过：搜索与热门
  都能进入播放，系统 Back 都回到各自来源；9 项 coordinator 测试与 app gate 普通通过。
- **判断**：**替换已实施并验收**。根因是共享条件 Binding 的 Observation
  投影，不是搜索 Button、数据模型或 player destination。
- **风险**：修复保留“切 Tab 退出播放”的现有产品语义，没有顺带实现 UI-001 的每 Tab
  深层 destination 保留。真实匿名搜索只在当前机器复核一次，不能证明远端长期稳定。
- **下一步最小验证**：UI-008 无追加关闭条件；Return/Space 卡片激活另按 AX 组验证，
  不能由鼠标 click 推断。
- **与其他 finding 的依赖或冲突**：直接阻塞 UI-004 的搜索来源→播放→返回验证；
  与 UI-001 的每 Tab destination owner、UI-002 的搜索控件替换和 UI-007 的 Binding
  cleanup 相交，修复时不得顺带实施这些待定重构。

## UI-009：播放页没有已验证的键盘返回路径

- **finding_id**：UI-009
- **审计线与涉及能力**：原生 NavigationStack、键盘输入、Full Keyboard Access。
- **当前实现（文件、符号、调用链）**：
  系统 NavigationStack 生成 Back 按钮；用户裁决后已删除实测无效的
  `.onExitCommand { dismiss() }`，没有 BiliKit 自定义全局返回命令。
- **外部事实来源**：Xcode 26.6 SwiftUI interface 中的 `onExitCommand`、
  `onKeyPress`、`keyboardShortcut` 与 NavigationStack API。
- **OSS 对照及 commit/date**：不适用；应先裁决 macOS 产品键盘语义。
- **真实行为证据**：离线签名 fixture 进入搜索播放后，窗口／系统导航焦点下发送 Escape
  不返回；把 handler 上移到 NavigationStack、改用 `onKeyPress(.escape)`，以及发送
  Command-[ 均不返回。失败时 AX 树仍有播放布局与系统 Back；点击 Back 稳定回到搜索。
- **本地测试实际证明的范围**：证明当前 XCUI 焦点状态下四条键盘尝试都未弹栈；不证明
  熟练 Full Keyboard Access 用户在所有焦点位置都无法操作系统 Back。
- **判断**：**删除／已裁决**。V1 接受系统 Back，不要求 Escape 或其他直接键盘返回；
  无效的原 handler、handler 上移与 `onKeyPress` 实验均不保留。
- **风险**：鼠标系统 Back 可用，但纯键盘用户没有已验证的直接返回路径。若强制 Escape，
  可能需要显式命令或焦点策略，影响全窗口输入路由。
- **下一步最小验证**：第三组不再为直接键盘返回增加实现；Full Keyboard Access／
  VoiceOver 对系统 Back 的可达性继续登记在 AX-001，不作为 UI-009 的关闭条件。
- **与其他 finding 的依赖或冲突**：属于 AX-001／AX-003；不再阻塞 UI-008 或第三组，
  但不能据此宣称系统 Back 已通过 VoiceOver／Full Keyboard Access 验证。

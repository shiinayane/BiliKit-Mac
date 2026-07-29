# 07 Accessibility 与输入

状态：第二轮取证与独立交叉复核完成；未修改生产代码。

本文件严格区分以下证据：源码／测试能说明静态语义和被编码的事件路径；XCUI 能说明
它实际执行的键鼠动作；Accessibility Inspector 能说明检查时的 AX 属性和线性顺序；
只有熟练使用 VoiceOver 的真实路径才能证明朗读、导航和操作体验。本轮没有开启
VoiceOver、Accessibility Inspector、Full Keyboard Access 或系统 Reduce Motion 来操作
当前 BiliKit，因此相应结论均保持未知。

## AX-001：现有测试不能证明 VoiceOver 可用

- **finding_id**：AX-001
- **审计线与涉及能力**：Accessibility；VoiceOver、AX 顺序、标签、状态与操作。
- **当前实现（文件、符号、调用链）**：
  视频卡片合并 children，封面／avatar 隐藏；分 P 手写 label 与 selected trait；
  搜索、认证、历史和播放状态广泛添加 identifier／hint。测试位于
  `BiliKitMacTests/SliceCAccessibilityTests.swift:42-70` 与
  `BiliKitMacUITests/BiliKitMacUITests.swift:15-113`。
- **它声称提供的职责**：让系统和 UI 测试识别元素，并向辅助技术暴露内容、状态与操作。
- **外部事实来源**：
  - Apple [VoiceOver evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria)
    要求用 VoiceOver 熟练测试所有常见任务，且自定义元素应达到原生元素的等效能力；
  - Apple [Performing accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
    明确 Inspector 零问题也不保证完整可访问，仍须 VoiceOver 等实际测试；
  - Apple [Inspecting accessibility screens](https://developer.apple.com/documentation/accessibility/inspecting-the-accessibility-of-screens)
    说明 Inspector 的导航顺序用于检查辅助技术的线性路径。
  以上访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；第三方测试不能代替本 App 的实际 VoiceOver 路径。
- **真实行为证据**：本轮只读取 Apple App 的 AX 树，未开启 VoiceOver；Apple App
  的 AX 树也不能证明 BiliKit。当前 BiliKit 的真实朗读、rotor、焦点恢复和 sheet
  关闭后焦点均未知。
- **本地测试实际证明的范围**：
  `SliceCAccessibilityTests` 只断言 `NSSearchField` 的 label/help/identifier；
  XCUI 断言分 P label/selected、元素存在和鼠标／键盘合成路径。identifier 主要服务
  自动化，截图不包含朗读证据。
- **判断**：**尚不能判断**。不能把已有 “Accessibility” 测试名、AX 树或截图升级成
  “支持 VoiceOver”的完成声明。
- **风险**：影响高；可能出现重复朗读、顺序跳跃、不可操作元素或状态不播报，用户无法
  绕过。修复通常局部，但只有真实路径能定位。
- **下一步最小验证**：对当前签名 build 运行一次 Inspector audit，再由熟练操作者用
  VoiceOver 完成：选择 Tab、搜索、打开／返回视频、控制播放器、切字幕／弹幕、打开／
  关闭登录 sheet、触发失败并重试。逐屏记录元素、朗读、role/value、顺序与 action，
  不保存个人媒体内容。
- **与其他 finding 的依赖或冲突**：AX-003、AX-006、AX-007 都需此真实路径解锁；
  UI-002 的原生搜索替换应在同一路径复验。

## AX-002：Return 与 Escape 使用原生事件，但核心命令和菜单覆盖尚未验证

- **finding_id**：AX-002
- **审计线与涉及能力**：键盘、Return、Escape、菜单命令、全屏和播放器输入。
- **当前实现（文件、符号、调用链）**：
  `SearchTabRoot` 用原生 `.searchable` 与 `.onSubmit(of: .search)` 接收 Return，
  Escape 由系统搜索字段处理；播放页不再保留已证无效的 `.onExitCommand`，V1 只依赖
  系统 Back。全仓未发现 production `.commands`、`CommandGroup`、
  `.keyboardShortcut` 或 `.onKeyPress`。`WindowGroup` 与 `AVPlayerView` 仍可能提供
  系统默认菜单／全屏／播放输入。
- **它声称提供的职责**：Return 提交搜索、系统 Back 返回；其余输入交给系统控件。
- **外部事实来源**：
  - 当前 SDK interface
    `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:12814-12831` 说明
    `.onExitCommand` 在 macOS 10.15 起可用；
  - Apple [onExitCommand](https://developer.apple.com/documentation/swiftui/view/onexitcommand%28perform:%29)
    明确 macOS Escape 生成 exit command；
  - HIG [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
    要求尊重标准快捷键并支持仅键盘操作；
  - HIG [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
    要求菜单栏提供所需命令、支持快捷键和 full-screen。
  以上访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；命令是否完整取决于本产品任务，不按 OSS 数量
  决定。
- **真实行为证据**：当前 BiliKit 未在本轮运行。系统能否通过 menu bar 进入全屏、
  AVPlayerView 的 Space／方向键语义、Escape 在搜索或 sheet 中的优先级、焦点位于
  搜索框时的返回均未知。
- **本地测试实际证明的范围**：
  fixture XCUI 编码了点击搜索框后 Return，以及播放页上向 app 发送 Escape；
  旧 Slice C 曾通过，M5.0 当前 revision 的 XCUI runner 没有进入产品路径。
  没有测试读取 menu bar、全屏、快捷键 discoverability 或输入冲突。
- **判断**：搜索 Return／Escape 已原生化；播放直接键盘返回按产品裁决不属于 V1
  承诺，不引入全局 key monitor。是否需要搜索、刷新、播放等菜单命令，仍要由真实键盘
  任务和产品频率决定。
- **风险**：影响中；缺少菜单会降低可发现性，错误全局拦截 Escape／Space 又可能破坏
  搜索输入、sheet 或 AVPlayerView 的原生行为。通常可恢复。
- **下一步最小验证**：签名 App 仅键盘走完整核心路径，逐项检查 Tab／Shift-Tab、
  Return、Space、Escape、Command-F、标准 full-screen shortcut 和 menu bar；
  记录哪个 owner 消费事件，再决定是否添加 SwiftUI `Commands` 或快捷键。
- **与其他 finding 的依赖或冲突**：UI-002 原生 `.searchable` 会改变 Return／Escape
  owner；播放器命令与媒体审计的 AVPlayerView 能力相依。

## AX-003：视频卡片的自绘焦点 ring 有历史可达证据，但仍未证明等价于系统焦点

- **finding_id**：AX-003
- **审计线与涉及能力**：keyboard focus、hover、press、increased contrast。
- **当前实现（文件、符号、调用链）**：
  三个 grid 把卡片放入 `Button` 并应用 `VideoCardButtonStyle`；
  `VideoCardButtonStyle.swift:58-100` 读取 `Environment.isFocused`，自绘
  accent／secondary stroke，同时自制 hover surface、pressed opacity 和 scale。
- **它声称提供的职责**：`.plain` 风格卡片仍显示 hover、按压和键盘焦点，并在 increased
  contrast 下加粗。
- **外部事实来源**：
  HIG [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/)
  建议依赖系统 focus effect；集合通常使用整行／整项 highlight，只有绝对必要才自制。
  HIG [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
  要求用 Full Keyboard Access 实测。访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；视觉样式不能代替当前 App 的焦点树证据。
- **真实行为证据**：2026-07-25 的旧签名 fixture 记录称 Tab 能到首张卡片、accent
  outline 可见、Space 可打开播放；本轮未复验 current baseline，也没有
  active／inactive window、increased contrast 或 Full Keyboard Access 观察。
- **本地测试实际证明的范围**：
  `VideoCardInteractionTests` 只测试纯数值 policy；它没有挂载真实 Button，也不证明
  `Environment.isFocused` 始终对应外层按钮焦点。XCUI 核心路径用鼠标 click 卡片。
- **判断**：**尚不能判断**。hover／press 是产品外观职责；焦点 ring 是否保留或换回
  系统 effect，必须先证明 `.plain` Button 在当前 grid 的真实系统反馈和自绘反馈是否
  重叠／缺失。
- **风险**：影响中；错误 ring 可能在 inactive window 仍用 accent、与系统 ring 重叠，
  或焦点存在却不显示。按键仍可能可操作，因此部分可恢复但不易发现。
- **下一步最小验证**：默认键盘导航与 Full Keyboard Access 下逐卡片移动焦点，
  同时检查 active／inactive window、浅／深色和 increased contrast；对比临时使用
  系统 button style 的最小样例后再裁决，不先删除 hover／press。
- **与其他 finding 的依赖或冲突**：Reduce Motion 的 pressed scale 见 AX-004；
  selected 视频高亮已删除，不得借焦点审计重新引入。

## AX-004：Reduce Motion 只覆盖卡片按压，默认开启的滚动弹幕未读取系统设置

- **finding_id**：AX-004
- **审计线与涉及能力**：Reduce Motion、自定义 Core Animation 和弹幕。
- **当前实现（文件、符号、调用链）**：
  `VideoCardButtonStyle.swift:61-97` 在 Reduce Motion 时移除 0.985 pressed scale；
  全仓只有这一处读取 `accessibilityReduceMotion`。
  `DanmakuControlsViewModel.swift:7-10` 默认开启弹幕和 scrolling；
  `CoreAnimationDanmakuRenderer.swift:83-121,227-244` 对 scrolling 事件持续建立
  从右向左的线性 `CABasicAnimation`，没有系统设置输入。
- **它声称提供的职责**：卡片减少短促缩放；弹幕按用户手动 Toggle 控制显示类型。
- **外部事实来源**：
  - 当前 SDK interface
    `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface:18061-18077`
    显示 `accessibilityReduceMotion` 从 macOS 10.15 可用；
  - HIG [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
    要求 Reduce Motion 开启时减少自动、重复和 peripheral motion；
  - Apple [Reduced Motion evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria)
    建议读取系统设置，尤其处理 scaling、spinning 等 motion trigger。
  访问于 2026-07-27。
- **OSS 对照及 commit/date**：未找到能高于 Apple 指南的必要对照；弹幕产品通常存在
  不代表可以忽略系统设置。
- **真实行为证据**：本轮未以系统 Reduce Motion 运行真实弹幕。静态调用图能确认
  BiliKit 没有把该环境值传入弹幕 policy；Core Animation 不应被假定会自动替产品决定
  隐藏哪种弹幕。
- **本地测试实际证明的范围**：
  卡片单元测试只证明 scale policy；danmaku renderer／scheduler 测试没有 Reduce Motion
  环境。没有真实视觉或系统设置切换证据。
- **判断**：缺少系统设置输入的事实成立，但是否必须自动绑定
  `accessibilityReduceMotion` **尚不能判断／需要产品裁决**。Apple 建议检测系统设置并
  减少 ongoing motion，同时允许 App 内等效或更细粒度控制；BiliKit 已有总开关和三种
  mode 开关。需裁决自动禁 scrolling、保留 top/bottom 与用户 override 的优先级。
- **风险**：影响高；motion-sensitive 用户一进入播放就可能看到持续横向运动。关闭设置
  或手动关弹幕可恢复，但要求用户先承受触发。实现错误也可能违背已有弹幕偏好。
- **下一步最小验证**：用无个人数据 fixture 生成 scrolling、top、bottom 三种事件，
  在系统 Reduce Motion 开／关时分别观察 layer movement；让用户裁决期望 fallback，
  再为 policy 添加确定性测试和一次真实设置验证。
- **与其他 finding 的依赖或冲突**：与性能审计的弹幕负载相交；不得通过降低帧率冒充
  Reduce Motion 语义。

## AX-005：语义字体已采用，但“大文字可用”声明缺少 200% 与真实布局证据

- **finding_id**：AX-005
- **审计线与涉及能力**：文字放大、Dynamic Type、窗口 resize 和截断。
- **当前实现（文件、符号、调用链）**：
  主要文本使用 `.body`、`.title3`、`.title` 等语义字体；
  但 `AppShellView.swift:81` 最小窗口为 1080 pt，搜索框固定 340 pt，
  `AuthenticationView.swift:18-20` sheet 固定 420 pt，卡片标题最多两行，
  播放 metadata 使用单行 `HStack`。DEBUG fixture
  `UITestContentView.swift:51-56` 只注入 `.accessibility1`。
- **它声称提供的职责**：系统字体随环境调整，compact fixture 检查大字下基本布局。
- **外部事实来源**：
  HIG [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)
  建议文字至少可放大 200%，并采用 Dynamic Type；当前 SDK interface
  `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface:11725-11743`
  显示 `dynamicTypeSize` 从 macOS 12 可用。访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用；需要本 App 的布局实测。
- **真实行为证据**：本轮未在当前 BiliKit 上切换系统文字大小。旧 fixture 的单张截图
  和元素存在不能证明标题、metadata、subtitle picker、认证错误或 toolbar 未截断。
- **本地测试实际证明的范围**：
  compact XCUI 断言窗口尺寸、首卡存在、播放 layout enum 和分 P label；
  没有断言文本 frame、截断、横向溢出、控制可达或 200%。
- **判断**：**尚不能判断**。语义字体应保留；固定宽度／lineLimit 是否替换需以实际
  文字放大与本地化样本裁决。200% 是 HIG 设计建议；Larger Text 的 App Store
  accessibility label 不适用于 Mac，不能据此宣称标签支持。
- **风险**：影响中到高；长标题、错误文案和字幕轨道名可能被截断或挤掉操作控件。
  resize 或降低文字可暂时恢复，但不是合格替代。
- **下一步最小验证**：在 1080 pt 和候选更窄窗口，使用至少 100%、150%、200% 文字
  样本检查所有一级页、登录所有状态和播放控制；断言可读文本与可达控件，而非只留截图。
- **与其他 finding 的依赖或冲突**：依赖 UI-005 的窗口下限裁决；格式化长度受 UI-006
  影响。

## AX-006：自定义字幕 overlay 可见，但没有进入 AVFoundation legible track 语义

- **finding_id**：AX-006
- **审计线与涉及能力**：字幕、听觉可访问性、播放器系统字幕选择和 VoiceOver。
- **当前实现（文件、符号、调用链）**：
  `SubtitleControlsView.swift:24-47` 用自定义 Picker 选择远端字幕；
  `SubtitleOverlayView.swift:10-29` 在播放器上叠加随时间变化的 SwiftUI `Text`，
  `.accessibilityElement(children:.contain)`，但播放 asset 本身没有
  `AVMediaSelectionOption` legible track。
- **它声称提供的职责**：给对白提供同步字幕文字，并允许关闭／选择轨道；当前没有证据
  证明还提供听障 captions 所需的非对白声音描述。
- **外部事实来源**：
  - Apple HIG [Accessibility — Hearing](https://developer.apple.com/design/human-interface-guidelines/accessibility)
    要求为音视频提供 captions／subtitles 等文字路径；
  - Apple [Selecting subtitles and alternative audio tracks](https://developer.apple.com/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks)
    说明 AVKit／AVFoundation 原生支持 `AVMediaSelectionGroup` legible tracks、
    系统选择和用户语言偏好。
  访问于 2026-07-27。
- **OSS 对照及 commit/date**：字幕 endpoint／时间语义由媒体审计对照；本 finding
  不用 OSS 推断 macOS accessibility。
- **真实行为证据**：2026-07-27 的本地无网络 spike 用同一份 HLS master 暴露两个
  video variant、独立 audio rendition 与一个 WebVTT subtitle rendition；
  `AVURLAsset` 读取到两个 bitrate variant 及其 resolution/frame-rate，
  `.legible` group 有一项，默认未选择，显式选择后成为当前 option。它证明 bridge
  方向可行；AVPlayerView 菜单样式、系统字幕样式与 VoiceOver 仍未实测。
- **本地测试实际证明的范围**：
  `unifiedMasterExposesAdaptiveVariantsAndNativeSubtitles` 证明 AVFoundation
  media-selection 和默认关闭语义；两个 synthetic variant 当前共用同一 128×72
  媒体，只证明 variant 模型，不证明不同真实清晰度切换。也没有证明偏好语言、
  AVPlayerView 菜单、字幕样式或 VoiceOver 朗读。
- **判断**：原生 `.legible` **替换方向可行**，不再因 bridge 能力待定；生产替换仍取决于
  字幕正文能否在有界起播等待内冻结、真实清晰度 master 以及 VoiceOver/系统菜单验证。
  在这些 Gate 关闭前保留当前 overlay。
- **风险**：影响高；听障用户仍能看见文字，但可能无法沿用系统字幕偏好、样式和选择；
  视障用户可能遭遇不断变化的 AX 内容。错误迁移又可能重新引入字幕错配，恢复成本中等。
- **下一步最小验证**：用两个不同分辨率的合成或脱敏真实 representation 验证切换；
  再用 AVPlayerView 验证菜单、系统样式和 identity，并对当前 overlay 做 VoiceOver
  对照。任何 production 迁移须受媒体 red-zone 契约约束。
- **与其他 finding 的依赖或冲突**：依赖媒体 finding 的 DASH→HLS、字幕 identity 和
  seek 裁决；不能为了 UI 原生化牺牲已修复的字幕正确性。

## AX-007：侧栏账户 `.plain` Button 的鼠标可点击已证明，键盘焦点与反馈未知

- **finding_id**：AX-007
- **审计线与涉及能力**：账户入口、plain button、焦点、Return／Space 与非颜色反馈。
- **当前实现（文件、符号、调用链）**：
  `AppShellView.swift:97-121` 在原生 bottom bar 中放置填满宽度的 `Button`，
  `.buttonStyle(.plain)`，只有 label、hint 和 identifier；没有自绘 focus／pressed
  state，也没有显式 `.focusable`。
- **它声称提供的职责**：整行点击打开登录／账户 sheet，同时不显示普通 bordered
  button 外观。
- **外部事实来源**：
  HIG [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/)
  建议优先依赖系统 focus effect；HIG
  [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
  要求 Full Keyboard Access。Apple VoiceOver criteria 要求鼠标可执行的操作也能由
  VoiceOver 完成。访问于 2026-07-27。
- **OSS 对照及 commit/date**：不适用。
- **真实行为证据**：Music 1.6.5 与 TV 1.6.5 的 sidebar 底部账户元素在 AX 树中是
  button；其私有样式和 pressed implementation 不可见。BiliKit 本轮未实际 Tab 到该
  按钮，也未观察 focus ring、Space／Return 或 sheet 关闭后的焦点。
- **本地测试实际证明的范围**：fixture XCUI 以 identifier 直接 `.click()` 并看到
  `auth.start`；这绕过键盘焦点顺序，不证明 plain style 的视觉反馈或辅助操作。
- **判断**：**尚不能判断**。保留原生 `Button` 与 bottom bar，不因“点击时不变暗”
  猜测 Apple 使用了另一私有 API；只在真实 focus/press 证据显示缺陷时调整 style。
- **风险**：影响中；按钮可能可操作但没有可见焦点，也可能系统已经提供恰当反馈而重复
  自绘会造成双重强调。sheet 可关闭，恢复性高。
- **下一步最小验证**：在默认键盘导航和 Full Keyboard Access 下从 sidebar Tab 项
  移到账户按钮，用 Space 与 Return 分别激活；检查 active／inactive window、
  increased contrast、VoiceOver action 和 sheet 关闭后的 focus return。
- **与其他 finding 的依赖或冲突**：UI-003 已裁决保留 bottom bar 容器；本 finding
  只裁决其交互样式，不重新讨论账户位置。

# BiliKit 仓库说明

## 项目与范围

BiliKit 是原生、macOS-first、非官方 B 站浏览与播放客户端：Swift 6、SwiftUI + AppKit、AVPlayer，
最低 macOS 15。App 与 Swift 模块名为 `BiliKit`；仓库、Xcode 工程和内部 App target 保留
`BiliKitMac`。不要擅自加入下载、转码、导出、直播、多账号、区域解锁，或 `docs/ROADMAP.md` 已列出之外的
账户写操作。

需要时只读这几份文档，它们描述的是现状：

- `docs/ARCHITECTURE.md`：模块、依赖方向与仍然约束代码的决策。
- `docs/SECURITY-MODEL.md`：认证、远端来源、loopback、缓存、更新与日志规则。
- `docs/ROADMAP.md`：产品目标、当前阶段与非目标。
- `docs/release/README.md`：发布流程。

## 架构与安全

- 模块与依赖方向见 `docs/ARCHITECTURE.md`，由 `Scripts/check-architecture.py` 按目录白名单检查。
- Feature 不互相 import；跨页面协调在 App 层，具体 adapter 只在 `Composition/`、`Platform/`、`Settings/` 可见。
- `BiliApplication` 不出现 endpoint DTO、UI／播放框架、具体 client、Keychain 或 Cookie。
- 没有真实边界时不新增 Package、target 或 `Common`／`Shared`／`Utils`；新增 target 或 App 目录先在
  `check-architecture.py` 里登记。`references/` 不进入产品或 fixture。
- Cookie、QR key、token 与完整认证 URL 只存在于 `BiliAuth` 的短生命周期内存和 Keychain。
- 可变网络、认证与播放会话必须有 owner、取消与清理点；旧结果用 identity 或 generation 隔离。
- 认证、远端来源、重定向、本地服务器、字幕、弹幕、图片或缓存改动先对照 `docs/SECURITY-MODEL.md`。

## 代码

- 同一逻辑只写一处。发现第二份副本就合并；已经分叉的副本按 bug 处理。禁止的是没有第二个调用方的
  抽象，不是消除重复的帮手。
- 布局尺寸、时限、容量等数值用具名常量，并放在唯一的几何／策略来源里；测量与布局共用同一计算。
- Swift 文件不超过 800 行，新增代码按职责拆到新文件；已经超长的文件只能缩短（`Scripts/check-file-length.py`）。
- 生产代码不为测试保留恒定参数、计数器或只有测试调用的重载。
- AppKit 只用于有明确理由的地方（见 `docs/ARCHITECTURE.md`）；其余界面默认 SwiftUI。

## 注释

- 注释用中文，写现状与理由。声明文档用 `///`，放在 `@MainActor` 等属性之上；第一句单独成段（swift-format
  把中文句号也当句末，后面要空一行 `///`）。函数体内的理由用 `//`。不写文件头，不用 `MARK` 分段代替拆文件。
- 必须写：
  - 每个非 private 类型，以及拥有可变状态的 private 类型：一句职责，加上它拥有什么、不拥有什么（交给谁）。
  - 持有 Task、连接、server 或 observer 的类型：owner、取消与清理点及其顺序要求、隔离方式；
    `@unchecked Sendable` 写明由哪把锁或哪个队列保证。
  - generation、epoch、token 与 in-flight 计数：何时递增、谁比对、不匹配时丢弃什么。
  - 跨文件契约：由谁调用，调用方必须或不得做什么。
  - 安全相关检查（来源、Host、重定向、Cookie 路径、响应校验）：一句理由，加 `见 SECURITY-MODEL §N`。
  - 策略类具名常量：为什么是这个值、改变它影响什么；名字已能说明的几何常量可以省略。
  - 反直觉写法（顺序依赖、刻意不做的事、绕过系统行为）：不这样做会出什么问题。
  - 用 AppKit 而不用 SwiftUI 的类型：一句理由，或指向 `docs/ARCHITECTURE.md` 的对应小节。
- 不写：复述代码、PR／issue 编号、日期、“以前／改为／删除了……”、未来计划、没有 owner 的 TODO、
  只为测试存在的说明。
- 修改行为的提交同步修改周围注释与 port 文档；注释与 ARCHITECTURE／SECURITY-MODEL 冲突按 bug 处理。

## 测试与 accessibility

- 测试只固定产品契约：它失败时要能说出哪个用户可见行为或跨文件规则坏了。优先 unit／model／ViewModel
  测试；XCUI 只用于更低层无法证明的系统边界。
- 值得写：修 bug 的回归测试（必须先在修复前看到它失败）；port 语义与跨文件契约；读代码难以确认的逻辑
  （generation、取消顺序、分页去重、锚点恢复）；安全检查；我们依赖、但文档没写的系统行为（注释写明依赖）。
- 不写：复述实现的测试（常量取值、setter／getter 往返、“调用了 X”）；测系统框架本身；同一契约在多层
  重复；只录下一次排查步骤、说不出守护什么的用例。
- 加测试前先找覆盖同一契约的 Suite，能加参数或断言就不新开；修 bug 通常一个回归测试，新功能一到三个
  固定核心契约；有了更好的测试就删掉旧的。测试失败先查产品代码，改测试时在提交说明里写明是契约变了
  还是原测试测错了对象。
- 每个 Suite 或测试类型用一句话写清它固定的产品契约，不逐个测试写。
- 同一 port 的测试替身在一个测试 target 内共享一份可配置 stub，不逐个测试复制；跨 target 的副本可以
  接受，不为此新建共享测试 target。
- 不写依赖 SwiftUI/AppKit 内部层级、固定 index、坐标、任意等待或截图偶然性的测试；异步测试用事件、
  状态或 continuation 判断完成，固定时长只作超时。默认不运行的探针不放进测试 target。
- accessibility label、value、trait 与 focus 只服务 VoiceOver、键盘与真实用户；不把 label 当 test ID。
- build、AX tree、截图、真人 VoiceOver/FKA、签名、真实播放和性能是不同证据，不互相替代。

## 文档

- 文档只写现状，改变边界或规则的提交同时更新上面对应文档。不新建 ADR、带日期的验证／证据记录或
  过程叙述；验证结论写进提交说明或 PR。
- 各文档只收自己那一类：ARCHITECTURE 收模块边界、仍约束代码的决定（连同不采用的替代）与跨文件不变量；
  SECURITY-MODEL 收安全与隐私规则，每节写明防什么；ROADMAP 收目标、阶段、候选与非目标，能力每项一行。
  跨文件的规则在文档里写一次，代码里只留一句并指向文档；只改单个类型的行为、取值或实测数据的提交
  不改这些文档，改该类型的注释与测试。
- `README.md` 是中文原文，`README.en.md` 与 `README.ja.md` 是它的译文，界面用词取 App 本地化里的对应译名；
  改 README 的提交同时改三份，其余文档只有中文。

## 工作与验证

- 默认在独立 worktree 工作，保留已有改动；未经要求不 commit、push、创建 PR、改写历史或修改其他
  worktree。
- 迭代时用定向测试。任务临时根由当前任务新建的空目录，日志等其他文件放在根外（脚本拒绝没有 owner
  marker 的非空目录），可在任务内复用，结束时删除：

```sh
sh Scripts/run-targeted-tests.sh "$task_artifact_root" package 'FeedPagingTests'
sh Scripts/run-targeted-tests.sh "$task_artifact_root" app 'BiliKitMacTests/PlaybackSourceSettingsTests'
```

- 交付前在最终代码上运行一次覆盖改动的最高适用 Gate（`app` 包含 `package`，`package` 包含 `static`；
  仓库内 Swift 编译警告视为失败）：

```sh
sh Scripts/run-quality-gates.sh static
sh Scripts/run-quality-gates.sh package
sh Scripts/run-quality-gates.sh app
```

- 手写 `xcodebuild`、XCUI 与 App 启动也使用本任务的临时产物根，结束时清理；其他 worktree 或共享
  DerivedData 不算 fresh closure。
- 真实 App 实测：开发构建与安装版共用 bundle id、偏好域和登录状态，用的是用户的真实账号。没有用户逐次
  同意不做真实写操作，不进与任务无关的播放页（会留观看记录），结束时删掉写入的偏好键；用户自己的
  BiliKit 开着时会改写同一偏好域。探针、自动驾驶等临时代码不进提交。
- 只在明确的性能裁决中运行 Instruments/`xctrace`，事前限定问题、时长与产物目录，结束后删除 raw trace。

## 提交文本

Commit/PR 标题使用 `<type>(可选 scope): <中文动词摘要>`；type 为 `feat`、`fix`、`refactor`、`test`、
`docs`、`build`、`ci` 或 `chore`。PR 与交付说明使用中文，写明变化、原因、用户影响、实际验证和
未覆盖边界。分支名使用 ASCII kebab-case 与当前环境前缀。不提交 `BiliKitMac.xcscheme` 的改动（用户实机
测试会把 Run 切到 Release）。互相依赖的多个 PR 用 `gh stack` 提交与合并。

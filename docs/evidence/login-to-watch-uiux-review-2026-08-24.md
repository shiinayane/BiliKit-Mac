# 从登录到观看 UI/UX 审查（2026-08-24）

## 结论

本轮未发现阻断“游客浏览并开始播放”的严重或高严重度问题。发现 2 项中等、1 项低严重度风险：评论图片预览的辅助功能模态隔离仍需真人确认；超长合集使用单个平铺菜单；系统 Back 后没有把键盘焦点直接还给来源卡片。除账号 sheet 的关闭入口外，本轮未修改这些问题。

账号 sheet 参照当前 Apple Music 的账号 sheet，在底部右侧提供“完成”按钮；macOS 26 使用系统 Liquid Glass prominent 样式，macOS 15 使用原生 prominent fallback，不引入产品品牌色或伪装成导航返回。`Escape` 触发同一关闭动作。按钮位于状态内容之外，因此 signedOut、restoring、扫码等待、确认、finalizing、signedIn、signingOut、过期与失败状态均可发现。扫码请求、等待扫码、等待确认及登录失败在 sheet 消失时复用现有 owner 取消登录挑战；restoring、finalizing 与 signingOut 继续由窗口级 owner 在后台完成。这样避免 finalizing 已提交凭据、但认证 service 尚未发布 signedIn 时又被关闭动作并发取消。

## 范围、基线与证据口径

- 基线：`27c0121f59304c8ce5cd7400d8c03f0a010d0006`，独立 managed worktree，修改前工作树干净。
- 环境：Apple Silicon，macOS 26.6.2，Xcode 26.6；fresh unsigned Debug App 使用本任务唯一临时 DerivedData 构建。
- 先读材料：`PRODUCT-VISION`、`UIUX-VISION`、`ROADMAP`、M3 认证威胁模型、Web QR ADR，以及 Keychain/授权、认证播放、播放器输入/全屏/PiP、字幕、试看、M4 closeout 与 M5.0.1 审查记录。
- 代码检查证明结构、状态覆盖和生命周期边界；自动测试证明确定性的状态契约；截图只证明当时视觉；AX tree 只证明语义暴露；真人 VoiceOver/FKA 才能证明实际朗读、焦点顺序与完整操作。本报告不以任一种证据替代另一种。
- fresh App 使用游客真实远端数据检查了首次启动、账号 sheet、真实二维码生成与取消、首页、热门、搜索、历史未登录入口、详情、播放准备与 ready、系统播放器控制、快捷键、弹幕开关、相关视频替换、分 P/合集、评论图片预览、系统 Back 和深色外观。未记录或输出二维码、认证 URL、Cookie、token、内容标识符等敏感数据。
- fresh 签名构建因 `com.shiinayane.BiliKit` 缺少 provisioning profile 而停止；未启用自动签名或修改外部服务。因此真实恢复登录、手机确认、已登录退出、Keychain、会员清晰度与认证播放只采用代码/测试/既有带日期记录，不标为本轮 fresh 证据。

## 发现

### UX-01 中：评论图片预览的 AX 模态隔离证据不闭合

- 用户路径：详情 → 评论 → 打开评论图片预览。
- 复现条件：fresh App 中打开一张评论图片；读取窗口 AX tree。
- 证据：视觉上为全窗遮罩，焦点进入“关闭”；`Escape` 关闭后焦点回到原图片按钮。预览视图声明 `accessibilityModal(true)`，但 AppShell 以 overlay 叠加且未把底层 split view 从 AX 暂时隐藏；本轮 AX tree 同时列出预览控件和底层播放器、评论、相关视频控件。
- 用户影响：实际 VoiceOver 若仍可游走到底层，会遇到视觉上不可操作的内容并失去模态边界。AX tree 暴露本身不能证明 VoiceOver 一定会穿透，因此这是中等风险，而非已确认的阻断缺陷。
- 建议：预览展示期间只对底层内容应用临时 AX 隐藏或等价的原生模态隔离，保留现有关闭焦点恢复；用真人 VoiceOver 和 FKA 分别验证正向/反向遍历、Escape、图片切换及关闭后的焦点。
- 未验证边界：未开启真人 VoiceOver/FKA；未覆盖多图、加载失败与重试时的实际朗读顺序。

### UX-02 中：超长合集仍是单个平铺选集菜单

- 用户路径：详情 → 相关推荐连续观看 → 合集/选集侧栏。
- 复现条件：进入含 124 集的公开合集；当前项位于 120/124；展开“选集”。
- 证据：fresh AX tree 显示一个原生 pop-up button，菜单中平铺 124 项且当前项被选中。代码中的 `configureEpisode` 逐集创建 `NSMenuItem`，无数量阈值、搜索或局部分段。
- 用户影响：鼠标滚动、键盘定位和 VoiceOver 浏览成本随集数线性增加，用户接近尾部或只记得标题片段时尤其明显；当前项标记避免了完全迷失，但不能降低检索成本。
- 建议：小合集继续使用原生菜单；超过阈值时改用可搜索、可分段的原生 list/popover，并保留当前集、合集分区、不可用项和页状态语义。
- 未验证边界：未用真人 VoiceOver/FKA 完整遍历 124 项，也未测更大的合集。

### UX-03 低：系统 Back 恢复了来源状态，但未直接恢复来源卡片焦点

- 用户路径：首页卡片 → 详情 → 系统 Back。
- 复现条件：从首页进入详情后使用工具栏系统 Back，再检查焦点与下一次 Tab。
- 证据：fresh App 返回首页后，原卡片保持 selected，来源列表与本次滚动位置保持；但立即焦点在窗口，下一次 Tab 落到 collection，而非原卡片。
- 用户影响：纯键盘/FKA 用户需多一步重新进入列表；长列表中仍可能需要确认当前选择。鼠标用户不受影响，来源与滚动数据没有丢失。
- 建议：以内容 identity 恢复来源 collection/原卡片的键盘焦点，不把 accessibility label 当测试 ID；保留系统 Back 与现有来源/滚动快照。
- 未验证边界：本次来源滚动位置为顶部；未用真人 FKA 验证深滚动、搜索/热门/历史四类来源。

## 用户路径覆盖

| 路径 | 本轮结论 | 证据与边界 |
| --- | --- | --- |
| 首次启动 / 恢复登录 | 游客首次启动能加载首页；恢复任务由窗口 owner 持有，关闭账号 sheet 不取消恢复 | fresh App + 代码 + 单元测试；真实 Keychain 恢复未 fresh 验证 |
| 打开 / 关闭账号 sheet | 侧栏账号入口可发现；右下角“完成”为 Liquid Glass action；AX 为“完成”按钮并有状态提示；Escape 可关闭 | fresh 截图与 AX + 代码；真人 VoiceOver/FKA 未做 |
| 扫码 / 确认 / finalizing / 失败 / 重试 | 真实二维码能生成且关闭后重新打开为 signedOut；扫码等待与确认关闭时取消，finalizing 关闭后由窗口 owner 继续；状态机有确认、过期、失败与重试内容 | fresh 只到扫码等待与取消；确认、finalizing、失败依赖代码/测试 |
| 退出登录 | signingOut 期间关闭 sheet 后后台继续；不会创建第二套认证状态 | 事件驱动单元测试；真实已登录退出未 fresh 验证 |
| 首页 / 热门 / 搜索 / 历史 | 首页、热门、公开搜索均加载语义化卡片；未登录历史给出账号入口 | fresh App + AX；远端失败、尾页与登录后历史未 fresh 验证 |
| 卡片 / 分页 | 卡片具标题、作者、播放、弹幕、时长语义；模型以 generation 隔离旧结果并有分页/重试契约 | 代码/测试 + fresh 首屏；未 fresh 走到分页尾部 |
| 详情 / 播放准备 / 失败 / 试看 | 观察到准备态到系统 AVPlayer ready；试看与播放失败/重试边界存在并有定向记录 | fresh 游客普通视频；本轮未触发失败、会员试看或已登录清晰度 |
| 播放器 / 快捷键 | 原生控制语义完整；本轮验证 Space 暂停、`D` 切换弹幕、全屏进入与退出 | fresh App + AX；长按、PiP、所有快捷键与真人键盘流程未全量重跑 |
| 字幕 / 弹幕 | 字幕/音轨菜单可发现，弹幕开关与设置可发现，`D` 状态反馈可见 | fresh App + 代码/测试/既有字幕记录；实际字幕 cue 同步和真人朗读未重验 |
| 侧栏 / 分 P / 合集 / 评论 | 元数据、简介、评论排序/回复、分 P/合集选择均存在；超长合集见 UX-02 | fresh App + AX + 代码；评论失败/重试和多页回复未全走 |
| 图片预览 | 关闭、前后图、计数、重试语义存在；Escape 与焦点恢复有效；模态隔离见 UX-01 | fresh 单图 + AX；真人辅助功能未做 |
| 相关推荐连续观看 | 相关卡片可替换当前播放并刷新详情/侧栏，没有新开窗口 | fresh App + AX；旧请求竞态主要由模型测试证明 |
| 系统 Back / 来源与滚动恢复 | Back 返回来源，保留 selection 与本次滚动状态；键盘焦点见 UX-03 | fresh 首页顶部 + 代码；深滚动及其他来源未 fresh 验证 |
| resize / 窄宽布局 | 代码限定窗口最小 760×560，播放侧栏 440–520；既有 M4 记录覆盖窄/宽 resize 不重载 | 本轮自动拖拽坐标结果不可信，未作为 fresh 证据 |
| 深色 / 大字体 | fresh 日文深色外观可读，系统控件与内容层级清楚 | 大字体、200% 缩放、减少动态效果、不同对比度未真人验证 |
| 键盘 / VoiceOver / FKA | 语义按钮、label/hint、系统 Back、Escape 与部分快捷键存在；没有为测试改变 AX 树 | 键盘与 AX tree 证据；未运行真人 VoiceOver/FKA，不宣称通过 |

## 关闭行为的最低层契约

- 二维码图片仍在生成时关闭：取消任务、调用现有认证 service 的 `cancelLogin`、清除图片，旧完成结果不能回写。
- finalizing 期间关闭：不并发取消提交；窗口 owner 在后台完成，成功后统一发布 signedIn，失败则发布原有失败状态。
- signingOut 期间关闭：不取消退出；后台完成后统一落到 signedOut。
- restoring 期间关闭：既有启动恢复继续；只有窗口生命周期结束才由 `cancelTransientWork` 清理。
- 测试使用事件/continuation 判断开始与释放，没有固定等待、坐标、XCUI helper 或为自动化添加的 accessibility 标识。

## 实际验证

- `AuthenticationViewModelTests`：17 个测试通过，覆盖既有恢复/退出契约，以及二维码生成取消、finalizing 后台完成和 signingOut 后台完成等 sheet 消失场景。
- fresh unsigned App：构建成功；右下角“完成”Liquid Glass action、日文 AX label/hint、Escape 关闭、真实二维码取消及上述游客观看路径已观察。
- fresh signed App：因缺少 provisioning profile 构建失败；未启用自动签名，未将其记为产品失败。
- 唯一一次 `sh Scripts/run-quality-gates.sh app`：架构、秘密模式、工程/安全能力/最低系统版本检查通过，随后 strict Swift format 因 extension 访问级别写法停止；已按诊断修正，改动文件的定向 strict lint 通过。按照“交付前只运行一次最高适用 Gate”约束，没有重复整套 app Gate，因此 package/app 部分本轮未形成完整 Gate 闭环。

## 本轮未覆盖的交付边界

- 缺 provisioning profile，未取得本轮 fresh 的签名 App、真实扫码确认、Keychain 恢复、退出登录、认证播放或会员/试看证据。
- 未运行真人 VoiceOver、Full Keyboard Access、大字体/缩放、macOS 15、不同语言/地区、网络断连/慢网、PiP 和长时间播放。
- 没有用截图替代 AX/真人证据，也没有用自动测试替代真实播放、签名或远端可用性。

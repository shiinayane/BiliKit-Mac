# 08 性能与资源

状态：静态证据、历史测量审计与独立交叉复核完成；当前基线已补真实 App 的
Allocations/RSS/端口短测和跨段 renderer 长测，Memory Graph 边界另行注明。

取证日期：2026-07-27。当前机器为 Apple Silicon `arm64`、macOS 26.5.2（25F84）、
Xcode 26.6（17F113）。Apple 文档访问日期同上。

## M501-PERF-001：M4 长测是有效历史快照，不是当前基线的性能保证

- **finding_id**：`M501-PERF-001`
- **审计线与涉及能力**：弹幕完整链路、RSS、对象上界、资源回落。
- **当前实现（文件、符号、调用链）**：`docs/validation/M4-closeout-2026-07-23.md:29-78`
  记录 M4 最终树 `988bbe2…` 所对应候选上 80 events/s、30 分钟完整
  `DanmakuSession → scheduler → presentation controller → renderer` probe：跨 6 段，
  active/layer/root attachment 在 stop 后归零，32 个离散 RSS 样本没有随第四至第六段继续
  单调增长。当前生产基线为 `a007446…`，其后还包含 M4.5/M5 的 UI、导航与播放器 owner
  变化。
- **它声称提供的职责**：证明弹幕工作集有界、长播不随分段持续增长，并为后续回归提供
  baseline。
- **外部事实来源**：Apple
  [Gathering information about memory use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)
  要求结合 Xcode/Allocations 观察随交互增加和减少的内存；一次离散 RSS 序列不是对象图或
  allocation lifetime。
- **OSS 对照及 commit/date**：不适用；第三方性能数字无法替代同一 App、硬件、构建和
  workload。
- **真实行为证据**：历史记录的环境、commit、输入速率、持续时间、计数和边界完整，可作为
  当时事实；它明确不覆盖 Intel、多窗口、所有视频或采样间峰值。当前工作树另执行
  80 events/s × 3 秒 smoke 和 1081.004 秒跨段长测：长测请求 4 段，发出 86480 条，
  admitted 23075、无安全 lane 丢弃 63405、capacity 丢弃 0，计数守恒；peak 140，
  stop 后 active/layer/root attachment/timeline subscriber 均为 0，session idle。
  20 个 RSS 样本约 61.4–120.8 MiB，后段样本有升有降而非持续单调增长，stop 后即时
  约 82.3 MiB。
- **本地测试实际证明的范围**：scheduler/renderer 测试证明内部上界与 stop 规则，不能证明
  当前签名 App 的 physical footprint、系统 layer/AVPlayer 资源或关窗释放。
- **判断**：历史记录 **保留**；当前树的同类合成 workload 也形成一份新的可比较快照；
  把任一快照当作全产品、真实 AVPlayer 长播或“无泄漏”证明的完成声明仍应 **删除**。
- **风险**：中。过度解释会让 M5 导航／owner 回归绕过实测；直接丢弃又失去可比较基线。
- **下一步最小验证**：本轮同一 workload 的 short smoke 与跨 4 段长测已完成。若
  scheduler/renderer/session 的 owner、上限或事件路径改变，复跑同一参数并只比较相同
  指标；真实 AVPlayer 长播继续作为另一条验证，不能由本 probe 代替。
- **与其他 finding 的依赖或冲突**：依赖工程线确认构建配置；与 `M501-CONC-003/005`
  的真实关窗资源验证共同执行。

## M501-PERF-002：RSS 回落与内部计数不能证明没有 retain cycle 或闲置可达内存

- **finding_id**：`M501-PERF-002`
- **审计线与涉及能力**：播放器、observer、URLSession、loopback、renderer 的释放。
- **当前实现（文件、符号、调用链）**：历史真实 App 记录从播放约 250 MiB 回落至退出详情
  约 224 MiB，`lsof` 不再见 listener；合成 probe 的 session/layer/attachment 计数归零。
  `PlayerTimelineObserverBag`、`AVPlayerEngine`、`LoopbackPlaybackServer` 有显式 stop，
  但 ViewModel task 与部分 owned URLSession 的释放仍有 `M501-CONC-001/005` 所列缺口。
- **它声称提供的职责**：证明返回来源页、关窗和替换播放项后不再占用不可接受资源。
- **外部事实来源**：Apple
  [Making changes to reduce memory use](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use)
  明确 Leaks 检测不可达泄漏，而仍可达但已闲置的内存可能不会被 Leaks 报告；因此还需
  Allocations 趋势和对象图。Apple sanitizer 文档也明确 ASan 不检测 memory leak。
- **OSS 对照及 commit/date**：不适用；这是本进程对象所有权和 Apple 工具语义。
- **真实行为证据**：当前 Debug App 连续 10 次播放进入/返回：播放时 RSS 约
  261 MiB，返回后约 240 MiB；随后三次关闭/新建窗口后约 209 MiB。每个返回检查点及
  窗口循环结束均无 BiliKit TCP listener。一次 30.925 秒 Allocations trace 覆盖播放与
  返回：heap + anonymous VM persistent 约 69.3 MiB，transient 约 360.2 MiB；已识别的
  弹幕数组、Task 数组、listener pair、AVAssetImageGenerator、AVMetadataItem 与
  Core Animation image queue 均为 0 persistent。数值只代表该进程/设备/交互。
- **本地测试实际证明的范围**：测试诊断量证明项目已登记的内部对象到零，不枚举
  URLSession delegate、系统 AVPlayer graph、SwiftUI 缓存 view 或未登记 Task。
- **判断**：清理路径 **保留**；当前路径“未观察到持续累积”已获得 RSS、Allocations 与
  端口的组合支持；“关窗后所有仍可达对象已经充分释放”因没有 Memory Graph 仍
  **尚不能判断**。
- **风险**：高影响、发生率未知。反复打开播放页／窗口时可能累积仍可达 owner，即使 RSS
  偶尔因 allocator 回收而下降。
- **下一步最小验证**：本轮规定的 10 次播放往返、3 次窗口循环、Allocations 与端口复核
  已完成。若实施阶段触及 owner/session/player，再补 Memory Graph 的精确对象代际比较；
  trace 不保存 URL/标识。
- **与其他 finding 的依赖或冲突**：必须遵守 `M501-PRIV-003/004/005` 的 trace 脱敏；
  不以 Memory Graph 单独替代真实端口或 Task 完成信号。

## M501-PERF-003：弹幕失败路径存在可静态确认的无界工作量

- **finding_id**：`M501-PERF-003`
- **审计线与涉及能力**：弹幕网络重试、CPU、网络、日志与电量。
- **当前实现（文件、符号、调用链）**：
  `DanmakuSession.handle` 在 load failure 清除 in-flight task；下一次收到 timeline
  update 后会再次启动同一缺失 segment，没有 attempt 上限、backoff 或 terminal marker。
  详见 `MP-009`。
- **它声称提供的职责**：临时失败后自动恢复弹幕。
- **外部事实来源**：AVPlayer periodic callback 是播放时间观察接口，不是网络 retry
  scheduler，且不保证严格频率；重试次数是产品策略，没有 Apple API 要求无限重试。
- **OSS 对照及 commit/date**：ATV `86ba6f5` 与 cilicili `6f02857` 交叉支持 360 秒分段，
  但不支持把每次 timeline 更新当重试触发器。
- **真实行为证据**：没有恒失败现场 trace；因此真实请求频率未知。
- **本地测试实际证明的范围**：现有正常路径长测不制造 5xx、offline 或 decoder failure；
  无法覆盖此路径。静态调用链足以证明：只要 update 继续到达，每次失败后都可再尝试，次数
  无上限。
- **判断**：**替换**为与 timeline 解耦的有界失败策略；不需要先用真实服务制造请求风暴
  才确认控制流问题。
- **风险**：高。快速确定性失败可带来高频请求和主线程状态更新；超时失败速率较低，但总次数
  仍无界。
- **下一步最小验证**：用恒失败 repository 与确定性 clock 推进数千次 update，记录 attempt、
  task、CPU signpost 总数；修改阶段的合格条件是停止/切 identity 后归零且同一失败有界。
- **与其他 finding 的依赖或冲突**：与 `MP-008` 的 HTTP 空 body 语义分开；即使远端确属
  错误响应，retry 也必须有界。

## M501-PERF-004：当前播放器性能证据缺少网络与错误维度

- **finding_id**：`M501-PERF-004`
- **审计线与涉及能力**：首帧、stall、seek、CDN fallback、音画同步与诊断。
- **当前实现（文件、符号、调用链）**：既有验证记录正常网络下 ready、seek 与替换；
  `AVPlayerEngine` 关闭 `automaticallyWaitsToMinimizeStalling`，且当前不读取
  `AVPlayerItemAccessLog`/`ErrorLog`。zero-tolerance seek 没有与默认 tolerance 做对照。
- **它声称提供的职责**：快速启动、精确 seek、弱网仍可恢复且不泄露媒体诊断。
- **外部事实来源**：Apple
  [AVPlayerItemAccessLog](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslog)
  提供网络播放期间的累计指标并按连续播放阶段形成 event；Apple Instruments 的 Hangs/
  Time Profiler 用于区分主线程忙与阻塞。extended log 可能含敏感 URL，不能直接归档。
- **OSS 对照及 commit/date**：ATV `86ba6f5` 对 VOD 使用系统自动等待；cilicili
  `6f02857` 关闭时另有恢复状态机。它们只说明可选设计必须成套，不提供 BiliKit 性能数字。
- **真实行为证据**：没有受控延迟/断 Range、stall 次数、自动恢复、首帧分布、seek latency、
  落点误差或 access/error event 摘要。
- **本地测试实际证明的范围**：synthetic fMP4 与 mock timeline 不产生真实 buffer
  starvation、CDN failover 或 decoder stall。
- **判断**：当前“性能足够／弱网可恢复”**尚不能判断**；`MP-005/006/007` 的修改方向应先
  用可控 loopback 对照，不发真实服务故障流量。
- **风险**：高。系统等待策略、ready 后错误出口和 seek tolerance 同时影响用户感知，单看
  ready 成功可能掩盖冻结或假暂停。
- **下一步最小验证**：在本地可控媒体源注入延迟、断 Range 和错误终态，记录首帧、stall、
  自动恢复、seek 完成时间/落点误差、主线程 hang；AVPlayer log 只在内存投影为计数、时长、
  host 分类和 error domain/code，立即丢弃原始 URI/header/session ID。
- **与其他 finding 的依赖或冲突**：依赖 `MP-003/005/006/007` 与
  `M501-PRIV-005`，不得为了测量放宽 redirect/Cookie 或保存 extended log。

## M501-PERF-005：高刷新滚动结论只适用于旧实现现场，当前没有回归阈值

- **finding_id**：`M501-PERF-005`
- **审计线与涉及能力**：热门/搜索/历史卡片、图片合成、滚动与 resize。
- **当前实现（文件、符号、调用链）**：
  `docs/validation/M4.5-high-refresh-card-scroll-2026-07-24.md` 记录 4K/240 Hz 外接屏的
  受控观察：60 Hz 预算充足、120 Hz 大体可用、真实纹理不足以稳定填满 240 Hz；移除视觉
  效果与降低插值质量无收益，占位色对照指向图片纹理合成成本。记录没有 commit SHA、逐帧
  分布、内存上限或可执行回归阈值。
- **它声称提供的职责**：在不牺牲视觉的前提下判断卡片滚动是否需要自定义图片 pipeline。
- **外部事实来源**：Apple WWDC23
  [Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/)
  建议用 Hangs 与 Time Profiler 分析主线程忙／阻塞；一次主观流畅观察不能定位或量化
  regression。
- **OSS 对照及 commit/date**：其他 App 的硬件 workload 不可直接比较，但实现历史可用于
  界定触发条件。ATV-Bilibili-demo 的 Kingfisher 路径先在 `fdff13b`（2025-12-21）加入
  500 MB 磁盘上限，又在 `8f10032`（2026-01-20）因超大头像崩溃加入 CDN 尺寸约束和
  下采样；Darock-Bili 主动关闭 SDWebImage 强内存缓存。两者说明引入库之后仍必须以真实
  输入尺寸、decoded image 成本和容量预算验证，不能把第三方默认值当性能结论。
- **真实行为证据**：2026-07-28 当前 Apple Development 签名 Debug App 在热门／搜索
  各多页往返滚动的 10 秒保留窗口中没有 `potential-hangs`（阈值 250 ms）。RSS 从启动
  约 69 MiB 升至约 138 MiB，空闲 30 秒及关窗 5 秒后均未下降；该单次样本未区分 decoded
  image cache、SwiftUI 工作集与 transport cache。原 `Animation Hitches` 采样工具异常
  膨胀，已丢弃，不计证据；可用 Time Profiler trace 约 20 MB，仅存 `/private/tmp`。
- **确定性归因补充**：同日签名 test-only 宿主用 50 个 640×360 loopback 合成封面复现：
  整棵 AsyncImage 子树重建后 50/50 URL 再请求；LazyVGrid 六个成功独立样本滚至底部
  请求 24–50 个，回到已 disappear/reappear 的顶部五次新增 0、一次新增 6。完整重建时
  RSS 高水位约增加 42 MiB，清空后即时不回落。它证明完整重建缺少复用，但否决了
  “普通离屏回滚稳定重下载”；RSS 仍不能区分缓存与 allocator。
- **本地测试实际证明的范围**：UI 测试和截图能证明元素出现，不证明 frame time、hitch、
  GPU 合成或图片 cache memory。
- **判断：V1 保留现状**。产品已裁决 V1 全系统统一使用 `AsyncImage`，不引入第三方或
  自建图片框架。完整重建会重复请求，但列表离屏回滚没有稳定复现，当前也无 250 ms hang；
  以触发条件重开。内存预算、真实 Tab 和 macOS 15 行为仍是未覆盖边界，不是 V1 blocker。
- **风险**：中。过早自建图片缓存会扩大状态/隐私/内存；完全不设当前基线又无法识别
  TabView 或图片回归。
- **下一步最小验证**：V1 无需继续。Xcode 27 可用后先验证系统缓存，再决定是否需要系统
  版本分层；若此前出现稳定重复请求、可见闪烁、流量或解码预算超限，再以当前 loopback
  请求计数作回归基线，比较候选方案的 50 图首次/回滚请求、decoded image 峰值、容量
  淘汰、resize 与窗口关闭；若进入实施，Release 和 macOS 15 仍必须补测。
- **与其他 finding 的依赖或冲突**：依赖状态缓存与原生 UI finding；不能把性能优化当作
  未经产品授权的持久图片缓存需求。

## 当前最小实测矩阵

| 操作 | 主要工具／信号 | 当前证明状态 |
| --- | --- | --- |
| 启动、热门／搜索／历史冷热滚动 | Hangs、Time Profiler、frame-time、memory | 当前基线未知 |
| 首次播放、受控 stall、前后 seek | AVPlayer 脱敏 event、Hangs、signpost | 正常样本历史成功；错误路径未知 |
| 字幕／弹幕跨至少 4 段 | Allocations、内部上界、RSS 趋势 | 旧基线通过；当前需回归 |
| 连续切视频、返回来源页、关窗 | Allocations generation、Memory Graph、Task/端口计数 | 静态清理存在；真实释放未知 |
| resize／全屏／多窗口 | Hangs、Core Animation、对象与内存峰值 | 单窗口旧现场；当前基线未知 |

上表的 UI/trace 计划只适用于本机 arm64 macOS 26；macOS 15 CI 当前只证明 build/tests，
不构成 macOS 15 性能或真实 UI 证据。Intel 是否属于支持范围仍待工程线裁决；若继续支持，
至少增加 Intel smoke/资源观察，或在结论中明确未覆盖。

本轮不立即执行这些真实检查：必须先由其他审计线冻结最小操作与脱敏字段，避免一次 trace
同时改变网络、账号、UI 和资源条件而失去可比较基线。

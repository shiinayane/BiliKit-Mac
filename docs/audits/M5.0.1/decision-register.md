# 审计判断与争议登记表

状态：十条审计线、交叉复核与五组最小验证已完成；部分判断已由用户冻结或授权实施，
其余待定项保留给 Gate 5 路线裁决或未来触发条件，不因验证阶段结束自动实施。

| Finding ID | 候选判断 | 交叉复核 | 争议／缺失证据 | 用户裁决 |
| --- | --- | --- | --- | --- |
| M501-API-001 | 保留 WBI signer 与字幕 WBI path；bounded 403 refresh 暂可继续，但必要性与 TTL 尚不能判断 | 独立复核完成并收紧 | 无真实 403/key 漂移记录 | 不作永久拒绝；以后按真实 403/key 漂移行为裁决 |
| M501-API-002 | 尚不能判断匿名设备 Cookie | 独立复核完成并收紧 | 缺长期无 Cookie 对照；具体拒绝 code 未确认 | 不作永久拒绝；以后按长期真实匿名行为裁决 |
| M501-API-003 | 保留 QR 精确 path/status/host；额外参数尚不能判断 | 独立复核完成并收紧 | 当前 OSS 均使用更宽匿名设备请求，但必要性未知 | 不作永久拒绝；以后按真实 QR 请求行为裁决 |
| M501-API-004 | 保留五项 Keychain 凭据；refresh 属于新产品／威胁模型 | 独立复核完成并收紧 | 当前 refresh 协议事实不足 | v1 不做 refresh token；后续可按真实协议和产品需求实施 |
| M501-API-005 | 保留 endpoint 级 Cookie allowlist 与 production redirect reject | 独立复核完成；已限定 production composition | 公开 API client 默认 transport 不自动具备同一边界 | 待定 |
| M501-API-006 | 当前 endpoints 保留；WBI playurl 尚不能判断 | API／媒体交叉复核通过 | 非 WBI/WBI playurl 的当前响应差异 | 待定 |
| MP-001 | 按 Apple 设备 profile 替换 master 元数据模型，并以同 item 原生 ABR 提供自动画质 | synthetic 同 item 自动降档 6/6；真实 quality 16/32 同 item 自动降档已现场观察；补齐且确认识别尺寸／帧率后结果不变 | 当前 production 仍只生成单 variant；validator 与 HLS peak bandwidth 仍未验证；恢复升档时机无公开控制契约 | V1 只提供自动画质，不提供手动档位；不为恢复升档设置 peak cap、首档或额外 buffer 参数，使用 AVPlayer 默认策略 |
| MP-002 | 当前 direct SIDX v0 子集保留；完整时间线正确性尚不能判断 | 主 Agent 已完成一个公开匿名样本的音视频结构 probe | 单样本均为 v0/direct/EPT 0；仍缺不同内容与 representation 形态 | 待定 |
| MP-003 | representation 固定到索引来源；失败时整体重准备 | 独立复核完成；确定性 loopback 已复现 A、A、B 请求序列和跨对象 206 拼接 | 真实 CDN 内容不一致发生率未知，但不再影响机制裁决 | 待定 |
| MP-004 | 替换统一 502；按 range 类型分别制定 HTTP 策略 | 已实施：single closed/open/suffix 返回 206，不可满足返回 416＋完整长度，in-memory 忽略 multi/未知 unit，HEAD 忽略 Range；remote 语法错误不触发 upstream；2 项定点测试及 package gate（230 tests，8 个既有 known issues）通过 | AVPlayer 是否实际发送边界 Range 只影响发生率，不影响已完成的 HTTP 机制裁决 | 实施完成 |
| MP-005 | 恢复 AVPlayer 默认等待；不保留无 recovery owner 的 `false` | 已删除生产覆盖值；starvation 回归验证默认 waiting 后自动恢复，MP-006 故障注入显式隔离其测试开关；定点测试及 package gate（230 tests，4 个其他 known issues）通过 | 真实弱网发生率与体验仍未知，但不再影响 owner 裁决 | 实施完成 |
| MP-006 | 增加 item-identity scoped 的持续失败出口 | ready 后 Range 失败十秒无终态；显式当前 item failed-to-end 通知被 engine 漏接 | 真实错误类型与发生率未知；旧 item 隔离和 observer 清理待实施验收 | 待定 |
| MP-007 | 保留共享播放器时间线；zero-tolerance seek 尚不能判断 | 主 Agent 复核，待性能线 | 缺 seek latency/落点误差测量 | 待定 |
| MP-008 | wire-level 空 message 合法；endpoint 空 body 语义尚不能判断 | 独立复核推翻原“替换”判断 | 缺脱敏 HTTP 现场样本 | 待定 |
| MP-009 | 将失败重试从 timeline update 解耦并设有界策略 | 恒失败对照确认 128 次 update 产生 256 次同 identity 请求 | 真实错误类型、callback 频率和具体重试上限未定 | 待定 |
| MP-010 | 保留基础时间源；字幕 overlap/location 尚不能判断 | 主 Agent 复核，待产品／无障碍线 | 缺不含文本的结构分布证据 | 待定 |
| MP-011 | 服务端 4K 可用性按内容与身份现场验证；当前客户端不宣称覆盖 | 代码、四个 OSS 与匿名最小现场请求已交叉核对 | 匿名目录有 120 但无 120 representation；登录/会员态仍受 playurl Cookie allowlist 裁决阻塞 | V1 自动模式可在服务实际返回且设备可播放时把 4K 纳入 ABR；不提供 4K 手动选择 |
| MP-012 | 否决单 player item 替换为“用户无感”；双 player/surface 与 snapshot 遮罩降为后续候选 | Apple SDK、B 站 Web 当前脚本、三个活跃 OSS、一次失败反证与五次 synthetic AVPlayer 对照已完成 | Web 普通画质为单 video/MSE fast switch；OSS 未证明真正双 surface/audio；本地双 player 尚未测真实交接与资源峰值 | V1 不做精确手动画质，因此不继续投入双 player；有实际需求后再重新验证 |
| MP-013 | 只对 trim 后空白弹幕逐条跳过；其他字段失败语义与全部资源上限保持不变 | 真实中段定位、四个 OSS 对照、定点回归与同一中段 production probe 均通过 | 其他无效字段的真实发生率与安全分类仍未知，不预先扩大容错 | 用户授权最小定点修复，已实施并验证 |
| MP-014 | decoder 边界保留事件并取 `colorRgb & 0x00FFFFFF`；普通彩色与会员渐变未来以独立模型字段扩展 | 三个 protobuf OSS 对照；宽色值定点回归；同一真实第 6 段成功解码／调度 843 条 | 非公开协议仍未知高位服务语义；当前 renderer 尚未显示普通彩色或会员渐变 | 用户授权最小定点修复，已实施并通过真实复核 |
| MP-015 | 删除产品 blocker 判断；修正 test-only 探针按 duration 选择最后三个合法段，不改 production 304 映射 | 时长 2327 秒、末段 7；越界段 8 返回 304 空 body；scheduler 已知 duration 时只请求 7 | duration 未知阶段是否短暂越界未测；不能把一次 304 泛化为空段协议 | 用户授权扩大诊断后已关闭，属于探针错误 |
| M501-CONC-001 | 保留 cancellation + generation；精确 Task 计数作为 owner 修改时的回归 gate | 真实 App 10 次播放往返与 3 次窗口循环未见旧状态写回 | ViewModel 无 deinit cancel；未逐 Task 证明归零 | 保留现状；实施 owner 修改时补 signpost |
| M501-CONC-002 | 保留字幕 A→B→A 串行 reset worker | 独立复核通过 | 需避免把它误作 endpoint 正确性保障 | 待定 |
| M501-CONC-003 | 保留 observer bag；真实返回清理成立，完整对象图释放不作过度声明 | STATE-001 修复后 suite 2/2；10 次返回、3 次窗口循环无 listener；已识别 trace 类型 0 persistent | 缺 Memory Graph 精确对象代际 | 保留；owner/player 改动时补 Memory Graph |
| M501-CONC-004 | 仓库内为死 API；删除须先裁决 public product 兼容承诺 | 独立复核将“删除”降级 | `BiliDanmaku` 是否对外发布未知 | 待定 |
| M501-CONC-005 | 显式区分/管理 owned session；loopback start 必须接入 task cancellation | 005a 已实施：取消会以 `CancellationError` 恢复 exactly-once continuation、清理本次 listener，且随后可重新启动；定点测试及 package gate（230 tests，6 个其他 known issues）通过 | 005b owned URLSession 仍缺直接计数；正常上层显式 stop 的累积风险未测 | 005a 实施完成；005b 待实施 |
| M501-CONC-006 | 当前 scope 无分 P 选择，生命周期不适用 | 独立复核完成 | 未来纳入时需复用唯一 identity 入口 | 待定 |
| M501-PRIV-001 | 保留当前 Keychain 策略 | Apple Development 签名 test host 的隔离 service add/update/read/属性/delete 全通过 | 不证明 Developer ID、升级或卸载 | 当前验证完成 |
| M501-PRIV-002 | 保留 live composition 与专用 transport 的 ephemeral/no-cookie/redirect reject | 独立复核并限定构造范围 | public defaults/probes 不同 | 待定 |
| M501-PRIV-003 | 真实远端播放/字幕/弹幕 probe 移出 GitHub-hosted CI，只允许本机显式、脱敏、自动清理运行 | 用户裁决；当前树已删除 hosted job/input，改为 mode 600 临时 plist、仅路径注入、脱敏输出、mktemp 全目录清理；app gate 通过 | 未运行真实远端 probe；已提交验证文档和 Git 历史未处理 | 已实施，解除第五组本项暂停 |
| M501-PRIV-004 | 保留执行数据，替换跨边界诊断投影 | 独立复核通过并补 sourceURL | 未发现当前 production logger 泄漏 | 待定 |
| M501-PRIV-005 | 保留生产不读取/导出原始 AVPlayer log；未来只允许安全投影 | 合成 HLS access log 在内存确认 URI/server 字段非空；新哨兵一次 unified-log 扫描未命中 | 未覆盖 error log、崩溃诊断、真实 CDN与其他系统 | 当前验证完成，发布诊断仍需重验 |
| M501-PRIV-006 | fixture 未见明显违规；不能用 secret scan 关闭整体隐私 | 独立复核并降低 provenance 强度 | 二进制 fixture 来源仍是仓库自述 | 待定 |
| M501-PRIV-007 | 保留 loopback bind/token/path；严格 Host 校验已实施 | 独立 nc 子进程确认合法 authority 200，错误 token/path 404，任意、缺失、重复、异常 Host 400，断连清零且 stop 后端口关闭；package gate 224 项通过 | 不提供本机进程身份认证；listener cancel 到端口拒绝连接是异步传播 | 当前验证完成，重大安全暂停解除 |
| UI-001 | 保留 TabView/NavigationStack/单 player owner | 独立复核并校正与 Music 的差异 | BiliKit 切 Tab 主动退出深层播放 | 理想行为为保留每 Tab 深层 destination；实现复杂时允许推迟到 v1 之后 |
| UI-002 | 用挂在实际导航内容上的 `.searchable(..., placement: .toolbarPrincipal)` 与 `.onSubmit(of: .search)` 替换 `CenteredSearchField` | 签名 XCUI 证明 1320 pt 窗口下精确居中、Return 提交、Escape 清空；`.toolbar` 右置对照与栈外 modifier 失败进一步限定实现结构 | 系统宽度由 340 pt 变为本机 544 pt；原生字段无现有 AX identifier，Command-F 不自动聚焦；窄窗口与 VoiceOver 未验 | 验证完成，可进入独立实施；不承诺固定宽度／Command-F |
| UI-003 | 保留 tabViewSidebarBottomBar 与账户位置 | 独立复核通过 | 键盘焦点/反馈见 AX-007 | 待定 |
| UI-004 | 保留每 Tab 语义 ScrollPosition | 独立复核通过 | 搜索/历史/resize 真实路径未测 | 待定 |
| UI-005 | 保留 GeometryReader 职责；1080 pt 下限未决 | 独立复核通过 | 缺窄窗口与大文字证据 | 待定 |
| UI-006 | 用共享 Duration.TimeFormatStyle helper 替换三份 formatter；实现前让搜索 decoder 拒绝负 duration | 12 个非负边界与超长小时在中／日／英 locale 下逐字等价；显式双 pattern padding 已冻结 | 搜索字符串 parser 当前可产生负值；未列举其他数字系统与未来 Foundation 版本 | 验证完成；进入实施时先补负输入 guard 与共享 helper 回归，无需截图 Gate |
| UI-007 | 两个直接属性 Binding 改用现有局部 @Bindable；字幕／弹幕 method Binding 保留 | 当前三个 path 已使用同一投影；最小 Observation probe 证明写入与 didSet 语义；UI-008 回归覆盖既有投影 | 尚未在真实 TabView/TextField 中应用这两处替换；不得与 searchable 或 path owner 同改 | 验证完成，可作为独立低风险 cleanup |
| UI-008 | 每个 NavigationStack 使用独立 path 与局部 `@Bindable` 投影；切 Tab 仍清空来源 path | test-only probe 隔离出 Button 已调用、path 已写入而条件 Binding 未被栈消费；离线搜索/热门/System Back 回归、app gate 与一次脱敏真实匿名往返通过 | 真实 App 只覆盖当前机器与一次样本 | 用户已授权并验收，已实施 |
| UI-009 | V1 接受系统 Back，不要求 Escape 或其他直接键盘返回；删除无效 `onExitCommand` | Escape、`onExitCommand`、`onKeyPress` 与 Command-[ 在当前窗口焦点下均未弹栈；系统 Back 正常 | Full Keyboard Access／VoiceOver 对 Back 的可达性仍属于 AX-001，不作为 V1 直接快捷键承诺 | 用户已裁决，已实施 |
| STATE-001 | 保留 State owner 模式；以单一 `AppWindowOwner` 保证完整 owner 同代且稳定 | 修复后 root re-init 与 host dismantle 2/2 普通通过 | 真实 WindowGroup 触发频率与修正后 Memory Graph 尚未测 | 用户同意修复，已实施 |
| STATE-002 | 保留热门＋最后搜索两份有界工作集 | 独立复核通过并收紧关窗声明 | 搜索完整往返与 onDisappear 未验证 | 待定 |
| STATE-003 | 保留语义 ScrollPosition | 独立复核通过 | 同 UI-004 | 待定 |
| STATE-004 | V1 保留认证、媒体、热门与搜索 no-cache；不新增 URLCache | 热门与 WBI 匿名搜索均连续两次 200、声明 no-cache、完整重复传输；搜索无 validator/条件请求/304 | 单时点样本，不外推详情、图片或未来服务行为 | 验证完成；出现真实 validator 或重复请求成本时按 endpoint 重开 |
| STATE-005 | V1 全系统统一保留 AsyncImage；不引入第三方或自建图片管线；Xcode 27 后再裁决是否按系统版本分层采用新 API | 完整重建 50/50 重请求；LazyVGrid 六个有效样本中五次回顶部新增 0、一次新增 6；OSS/上游对照支持按明确需求升级；macOS 27 已原生补标准 HTTP image-data cache 和 request/session 控制 | macOS 15、真实 Tab 请求数、decoded image 归因未决；27 beta 不能反推旧系统 | 用户已裁决；V1 关闭，Xcode 27 后以实测重开 |
| STATE-006 | 保留 WBI memoization；in-flight coalescing 未决 | 独立复核通过 | 缺并发首次请求测试 | 待定 |
| STATE-007 | 保留弹幕三段结构工作集；不因一次 RSS 不回落改变容量 | 同一进程最后三合法段共 2,047 条，cache 3→0；RSS 高水位约 +34.7 MiB | reset 后即时 RSS 未下降，未用对象图区分 allocator retained pages；单视频 Debug 样本 | 验证完成；owner/event 结构改变时复跑并补 Allocations/Memory Graph |
| STATE-008 | 保留无 App-managed 内容持久化 | 独立复核并限定系统行为未知 | 缺签名安装后的 container 检查 | 待定 |
| AX-001 | VoiceOver 可用性尚不能判断 | 独立复核通过 | 未跑熟练 VoiceOver 路径 | 待定 |
| AX-002 | 保留 onExitCommand；菜单/完整键盘未决 | 独立复核通过 | 未跑菜单、Command-F、全屏、输入冲突 | 待定 |
| AX-003 | 卡片自绘焦点 ring 尚不能判断 | 独立复核通过 | 缺 Full Keyboard Access/对照 | 待定 |
| AX-004 | Reduce Motion 与弹幕策略需产品裁决 | 独立复核将强制替换降级 | 已有 App 内细粒度控制 | 不让 Reduce Motion 自动删减弹幕功能；弹幕作为标志性功能保留全部模式与用户控制 |
| AX-005 | 保留语义字体；200% 布局未决 | 独立复核并限定 Mac 标签语义 | 缺真实多尺寸/本地化验证 | 待定 |
| AX-006 | 暂保留 overlay；legible track 联合 spike | 独立复核通过并区分 subtitles/captions | 系统偏好、非对白 captions、VoiceOver 未证 | 接受有限起播等待换取原生字幕；字幕默认关闭；具体等待预算与按需正文路径仍需 spike |
| AX-007 | 保留原生账户 Button；焦点/反馈未决 | 独立复核通过 | 缺键盘/VoiceOver/contrast 路径 | 待定 |
| M501-PERF-001 | 保留 M4 历史快照及当前树同类快照；均不当全产品无泄漏保证 | 当前树 80 events/s × 1081 秒跨 4 段 PASS，stop 后计数归零、RSS 回落 | 合成长测不含真实 AVPlayer/CDN，单机 Debug | 保留可比较快照；禁止过度声明 |
| M501-PERF-002 | 清理路径保留；当前重复路径未观察到持续累积 | 10 次播放往返、3 次窗口循环、Allocations/RSS/lsof 组合完成 | 无 Memory Graph，不能宣称零 retain cycle | 保留；不作全局无泄漏声明 |
| M501-PERF-003 | 弹幕失败改为与 timeline 解耦的有界策略 | 独立复核通过 | 无需先制造真实服务风暴 | 待定 |
| M501-PERF-004 | 播放器弱网/错误性能未决 | 独立复核通过 | 缺本地可控 stall/seek/error trace | 待定 |
| M501-PERF-005 | V1 不造图片框架并统一使用 AsyncImage；完整重建缺少复用作为后续基线 | 真实 App 短样本无 250 ms hang；完整重建 50/50 重请求，LazyVGrid 回滚 5/6 样本无新增请求 | resize、真实 Tab、Release/macOS15、内存类别未覆盖 | 用户已裁决；V1 关闭，Xcode 27 后与 STATE-005 共同重评 |
| ARCH-001 | 保留有平台/网络/安全边界的 Application ports | 独立复核通过 | 无 | 待定 |
| ARCH-002 | 五个 UseCase 均保留；SubtitleUseCase 不进入当前清理 | 非法 identity/track 的 6 个定点 case 均在 repository 前失败 | guard 尚无更安全且更简单的唯一归属 | 已验证，保留 |
| ARCH-003 | 只删除零调用者 PlayerEngine protocol/conformance；保留 event stream | 调用图仍无 protocol-typed 使用；MP-006 测试已实际消费 events 并定义持续失败出口 | PlayerState 合并与 production 失败消费由 MP-006 裁决 | 已验证，待实施 |
| ARCH-004 | 删除 BiliWatchHistoryService，repository 直持 concrete client | 当前仍是一实现／一 production 调用者；9 个 error/cancellation mapping case 已冻结 | 实施时测试须改由可控 transport 驱动，不能为 fake 保留 protocol | 已验证，待实施 |
| ARCH-005 | 保留 Networking/Auth/Danmaku 平台协议 | 独立复核通过 | invalidation 是否强制见 CONC-005 | 待定 |
| ARCH-006 | 保留 11 个 library target | 独立复核通过并修正计数 | 10 个 library product 的发布面见工程线 | 待定 |
| ARCH-007 | 保留 4 个不同权限/证据 probe | 独立复核通过 | output/transport 必须按隐私 finding 整改 | 待定 |
| ARCH-008 | 保留转换 wrappers；AnyView 形式未决 | 独立复核收紧同 target/identity 事实 | 依赖 STATE-001 root 修正 | 待定 |
| M501-ENG-001 | 保留双 OS CI；逐 run 记录实际工具链/image | 独立复核通过并补 image revision | 不证明 macOS15真实 UI/未来 runner | 待定 |
| M501-ENG-002 | CPU 架构支持尚不能判断 | 独立复核通过 | Intel 未构建/运行 | 明确不主动支持 Intel；不为 Intel 建立 v1 验证或性能承诺 |
| M501-ENG-003 | 保留 Swift6；分别审计 unchecked/preconcurrency | 独立复核并拆分语义 | 缺针对性 runtime race 证据 | 待定 |
| M501-ENG-004 | 保留 sandbox/network/Keychain/runtime；删除 user-selected files 与冗余 App Group 注册设置 | 用户授权后删除 Debug/Release 两套配置；普通签名 Debug App 前后对照确认多余权限消失且必要权限、identity、runtime 不变；app gate 通过 | Release/Developer ID 尚未检查 | 当前验证与修复完成 |
| M501-ENG-005 | 稳定签名 identity 下升级设计保留；卸载等未决 | 独立复核并收紧 prefix 条件 | 缺覆盖安装/换签名/卸载矩阵 | 待定 |
| M501-ENG-006 | 当前不可分发声明保留 | 独立复核通过 | 未执行 Release/archive/notarization/install | 明确不走 Mac App Store；后续在 Developer ID 公证打包与 v1 不打包之间裁决 |
| M501-ENG-007 | 1.0(1) 仅作开发值；发布版本策略待定 | 独立复核通过 | 是否制作 v1 分发包尚未决定 | 若制作公证包再建立版本递增与 archive→commit 策略；不打包时不提前建设发布流程 |
| M501-ENG-008 | 保留 SwiftProtobuf lock/notice；成品许可呈现未决 | 独立复核并收紧 target membership | 缺最终载体 | 待定 |
| M501-ENG-009 | 保留 references clean-room 隔离 | 独立复核通过 | 当前 tree 不证明历史独立创作 | 待定 |
| M501-ENG-010 | checkout action 固定当前已验证的 `d23441a…` 完整 SHA，并保留 `# v6` 注释 | `d961197` 已实施；工作流唯一 `uses:` 固定完整 SHA，可移动 tag 检查、空白检查与 static gate 通过 | CI matrix 尚未在远端执行；`v6.0.2` 落后于当前 major tag 的后续 backport，不能按编号机械选取 | 实施完成，待远端 CI |

只有完成外部取证和交叉复核的 finding 才能进入本表。审计阶段不把判断直接转成生产修改。

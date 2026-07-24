# M4 原生字幕生产技术实施计划

> Revision：NT6。状态：实施草案，不代表用户逐项确认；N5 已由用户于 2026-07-23 授权不可合入预检，不授权生产实现。可在不改变 N5 的范围、失败策略、安全边界和复杂度预算时调整。

## 事实输入

- `BiliAPI` 已把字幕目录和正文解析为 `SubtitleTrack` / `SubtitleCue`，并固定授权、来源、大小、时间、取消和 identity 边界。目录将 `ai_type > 0` 映射为 `.automatic`，AI 与普通轨道共用正文 decoder；当前 API fixture 只有 `ai_type: 0`，尚缺 wire 层自动字幕映射证据。
- 当前 `SubtitleViewModel` 另行加载目录/正文、观察播放时间轴并查找 cue；controls 与 overlay 承担选择和显示。
- `DASHToHLSBridge` 已用一个 `LoopbackPlaybackServer` 注册 video/audio 清单与内存资源，master 尚无字幕组。
- 2026-07-23 的不可合入 Phase 0 证明预制 WebVTT 可进入 AVPlayer 的 `.legible` 组；用户确认中、日字幕菜单和 seek/倍速/全屏正常。它尚未证明真实字幕能早于媒体组装完成。

## 前置时序预检

- 在独立不可合入 worktree 复用现有签名宿主、`SubtitleUseCase` 和媒体 bridge；不修改 `Package.swift` 或生产代码。
- 使用一条用户确认带 AI 字幕的关键真实样本。字幕侧按下文的首个 AI 保留规则，在 8 轨／16 MiB 预算内加载候选正文；媒体侧完成当前 video/audio HLS 准备。
- 只记录目录中的 standard/automatic 计数、媒体截止点两类完整可提交轨道数和最终清理，不记录 BVID/CID、名称、正文、URL、Cookie、精确时长或账号信息。
- 只运行一次 sanity。未发现 automatic、截止时 automatic 为 0，或全部可提交轨道为 0 时淘汰静态路线；通过只允许进入生产确认，不宣称网络稳定。
- 不开发 schema、benchmark framework、动态 server、watchdog 或重复矩阵。

## 数据、冻结与所有权

- 增加一个最窄的 `SubtitlePlaybackPreparation`（暂名）接口，输出“轨道 + 已验证 cue”纯值；不包含 URL、认证、远端响应或 AVFoundation 类型。
- 加载器最多选择 8 条候选并使用小型固定并发：先保留服务端顺序的前 8 条；若完整目录存在 automatic 而候选中没有，则用目录中的第一条 automatic 替换第 8 条。既有逐轨边界为 2 MiB HTTP body、20,000 cue 和 1,000,000 字符；另限制待提交 WebVTT Data 总和不超过 16 MiB。
- identity 已知后启动唯一一次字幕准备，并与 playback manifest、DASH index 和 HLS 准备重叠。旧 `SubtitleViewModel` 的生产加载必须先停用，不能让两个 loader 争用同一个 repository generation。
- 字幕 worker 只产生纯值，不能注册 server。单一 load session 在 video/audio 达到 HLS 组装条件时冻结已经完整成功、符合上限的有序轨道集合，取消未完成项。若存在已完成 automatic，提交选择先为第一条 automatic 保留一个轨道槽和其实际 WebVTT 字节，再按服务端顺序填充其余预算。
- bridge 随后一次性注册所有 WebVTT、字幕 playlist 和 master；master 对 AVPlayer 可见前，其引用 route 必须全部存在。冻结后任务不得写入 server。
- `AVPlayerEngine` 仍是 player item、load generation、字幕准备和 `PreparedPlaybackAsset` 的 owner。旧 load、stop 或 deinit 会取消字幕工作、移除 item、停止 server 并释放字幕 Data。
- 登录后不重建当前 item，重新选择视频才启动带字幕的新 load。登出必须 stop 当前播放并与字幕 reset 一起清理 item/server。

不得让 `BiliPlayback` 回调 `BiliAPI`、持有 repository 或解释认证错误。若实现需要反向依赖、第二 repository/server 或长期 feature flag，返回契约审查。

## WebVTT 与 HLS

- `WebVTTBuilder` 使用 `HH:MM:SS.mmm`、UTF-8，并拒绝非法时间。cue 文本移除控制字符，对可能成为 WebVTT 标记的内容做文本化转义。
- WebVTT 包含 HLS 所需 `X-TIMESTAMP-MAP`。具体映射由非零媒体起点 fixture 和真实样本开头/中段/尾部 seek 固定，不从 Phase 0 外推。
- 轨道使用生成的本地序号路径；不把 track ID、语言名或显示名放进 URL。
- 字幕 media playlist 覆盖 video index 推导的完整时长，引用一个内存 WebVTT。
- master 为可用轨道输出同一个 `SUBTITLES` group。第一轨 `DEFAULT=YES` 仅作提示；真实 Gate 读取 item ready 后实际 selected option，接受系统语言偏好覆盖。
- master 的 `NAME` 复用当前产品语义：`.automatic` 必须显示一次“自动生成”标识。用纯函数和固定词形 fixture 处理服务端名称已经含“自动生成／自动／AI”标识的情况，避免重复追加。
- `LANGUAGE` / `NAME` 独立转义；没有安全完整轨道时保持当前 video/audio master。

## 并发、失败与取消

- 认证不足、无字幕、格式/来源错误、网络失败、超限和取消都 fail open，不映射为播放错误。
- “不阻塞播放”定义为：video/audio 达到本地 master 组装条件后，不额外等待字幕；不用固定 sleep 冒充同步。
- 只提交冻结点前完整成功的轨道；单轨失败不污染其他轨道，顺序按目录而非完成时间。
- 冻结点与最后一轨同时完成时，由单一 load session 串行决定一次。旧 generation 结果只能丢弃，不能注册进新 server 或触发 reload。
- AVPlayer 创建后不追加字幕；不为迟到字幕替换 item，以免重置位置、速率、缓冲和选择。

## Feature 与 Composition 迁移

- 播放入口接收类型化、可取消的字幕准备能力；具体 `SubtitleUseCase` 仍由 Composition 注入，Feature 不接触 repository。
- 先实现但不启动 native 纯值准备；停用旧 ViewModel 的生产 `.task`、controls 和 overlay 后，才首次启动 native HLS 并运行签名验证。
- Git 分支提供回滚；生产 surface 不允许 native/custom 同时显示，也不允许两个 loader 同时请求。
- 真实样本通过后，在同一 PR 删除 overlay、controls、cue 查找和字幕 timeline Task；保留 Application contract、BiliAPI adapter 与负向 fixture。
- 若仍需“登录后可用”等非交互说明，由 M4.5 决定；不得恢复第二轨道选择器或 renderer。

## 实施切片

0. 不可合入预检：真实字幕正文与媒体 HLS 准备先后；失败即停止。
1. 纯格式：WebVTT、字幕 playlist、master group 与注入/时间测试。
2. 播放生命周期：唯一准备输入、冻结/单次提交、fail-open、generation、注册与清理。
3. 纵向替换：停用旧 loader/surface，再启用 native；真实验证后删除旧文件。
4. 收口：App Gate、双系统 CI、真实时间同步、认证切换和清理记录。

若真实验证失败，回滚生产分支，不把双实现留在 main。

## 测试与 Gate

- API/模型：自制目录 fixture 同时包含 `ai_type: 0` 与正值，证明 standard/automatic 都保留并共用正文 decoder；另以一个合成用例固定 automatic 位于第 9 条时替换第 8 条，以及聚合预算竞争时仍保留已完成 automatic。
- WebVTT：时间边界、一个混合 Unicode/多行/标记 fixture、控制字符、空 cue、非法时间和聚合字节上限。
- HLS：零/单/多轨、默认提示、稳定顺序、安全属性/路径、完整时长、非零媒体起点和无字幕保持当前 master。
- 生命周期：字幕先/媒体先、部分/全部失败、取消、旧 generation、连续替换、登录中播放、播放中登出、冻结竞态，以及 legacy/native 不会同时调用 repository；长期未完成用可控 latch，不用 sleep。
- 资源：超轨道/聚合上限仍起播；master 引用完整；失败不留半套 route；stop 后 task、server、route、connection 和字幕字节释放。
- 架构/秘密：BiliPlayback/Feature 无远端字幕 URL、Cookie、授权器或 DTO；日志无 track ID、cue、BVID/CID 或完整本地会话 URL。
- 自动化：代码变更运行 `sh Scripts/run-quality-gates.sh app`，CI 要求 macOS 15/26 App Gate。
- 签名真实样本：复用同一已知 AI 样本，验证冻结集合 `automatic >= 1`，生产 item 中存在且可选择 automatic option，“自动生成”语义只出现一次，并检查默认项与清理；只记录类型计数、布尔值和状态。
- 用户验证：原生关闭/切轨、pause、一个非 1× 倍速、前后 seek、全屏、切换、登录后重新打开、登出停止和关闭页面。
- 启动边界：用可控输入证明媒体完成后不等字幕；只做少量有/无字幕配对观察，不建设性能矩阵。

## 仍待数据决定

- 真实 fMP4 的 timestamp map 公式。
- 已知 AI 字幕样本能否发现 automatic 轨，并在媒体截止时至少提交 1 条 automatic；否则 N5 要求停止。
- 原生菜单无字幕时是否需要非交互说明；它不影响 renderer 路线，留给 M4.5。

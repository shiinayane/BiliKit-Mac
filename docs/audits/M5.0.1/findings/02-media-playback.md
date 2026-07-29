# 02 媒体播放、字幕与弹幕

状态：第一轮取证完成，尚未修改生产代码。

本文件 owner：第一轮 Agent B。

## 取证边界

- 本轮只读取仓库、Apple SDK interface、公开标准、公开 OSS 当前源码与既有验证记录；没有发起
  B 站账号请求，也没有保存媒体 URL、响应正文、字幕文本或视频标识。
- Apple SDK interface 来自当前安装的 Xcode：
  `AVFoundation.framework/Versions/A/Headers/AVPlayer.h`。公开规范均于
  2026-07-27 查阅。
- 既有“真实行为证据”只是历史验证记录，不被提升为当前协议事实。特别是一次
  `readyToPlay`、一次 seek 或一个 fixture 通过，都不能证明 CDN 切换、弱网恢复或远端数据
  形态长期稳定。

## OSS 对照快照

| 项目 | 本轮核对 commit | commit date | license | 用途 |
|---|---|---|---|---|
| ATV-Bilibili-demo | `86ba6f5bb9d6860cb47522a037ef02ab43a4ad55` | 2026-07-05 | GPL-2.0 | Apple 平台 DASH→HLS、SIDX、播放器状态、弹幕 |
| wiliwili | `88e5876bea9502d06f46a8656e3530684d3aaf7d` | 2026-04-25 | GPL-3.0 | 完整媒体源 fallback、播放器错误与时间线 |
| cilicili | `6f02857c6cac849df3c9f6eecefe483c1b720230` | 2026-07-26 | GPL-3.0 | Apple 平台 HLS bridge、播放器失败、SIDX、空弹幕段 |

BBDown 本地参考快照 `1b2fbd…`（2026-05-14）已在仓库中声明 archived/branch
deleted，因此只可作为历史线索，不计入“两份活跃 OSS”的当前交叉证据。上述 GPL 源码只用于
行为对照，不构成复制实现的许可。

## 发现

### MP-001 生成的 Multivariant Playlist 不满足 Apple 设备 authoring profile

- **finding_id**：`MP-001`
- **审计线与涉及能力**：媒体播放；DASH→HLS、HLS Multivariant Playlist。
- **当前实现**：8A/8B 已实施。`DASHToHLSBridge.prepare` 并行准备服务返回的全部 AVC
  视频 representation 与共享音频；`HLSPlaylistBuilder` 从 SIDX byte range 与 duration
  计算 peak／average segment bit rate，生成含 `BANDWIDTH`、`AVERAGE-BANDWIDTH`、
  `RESOLUTION`、`FRAME-RATE`、`CODECS` 和 `AUDIO` 的多 variant master。生产
  `AVPlayerEngine` 把它交给单一 `AVPlayerItem`；显式 representation 选择仅保留给探针。
- **它声称提供职责**：把 DASH representation 暴露为 AVPlayer 可识别的 HLS master。
- **外部事实来源**：[HLS Authoring Specification for Apple Devices](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/)
  对 Apple 设备 profile 要求含视频 variant 提供 `RESOLUTION`、`FRAME-RATE`、
  `AVERAGE-BANDWIDTH`，并把 `BANDWIDTH` 定义为所有可播放 rendition 组合的峰值 segment
  bit rate 最大和；它还要求提供多个视频码率 variant。
  [RFC 8216 §4.3.4.2](https://datatracker.ietf.org/doc/html/rfc8216#section-4.3.4.2)
  本身只强制 `BANDWIDTH`，`CODECS` 是 SHOULD，`RESOLUTION`/`FRAME-RATE` 不是 RFC
  层面的必填项，不能把 Apple profile 与 RFC 混写。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo
  `86ba6f5`（2026-07-05）在 `BilibiliVideoResourceLoaderDelegate.swift`
  生成 master 时同时写入 `RESOLUTION`、`FRAME-RATE`、`BANDWIDTH`、`CODECS`。
  cilicili `6f02857`（2026-07-26）也保留视频尺寸/帧率进入 HLS 描述。
- **真实行为证据**：`docs/validation/M3-keychain-authorization-2026-07-21.md`
  只记录一个真实样本进入 `readyToPlay` 并完成前后 seek，证明该样本被当前 AVPlayer
  接受；它不能证明 playlist 符合 authoring spec，也不能覆盖其他编码/分辨率。
  2026-07-27 的真实脱敏时序 probe 另证明当前单 representation bridge 可在
  `250–499ms` 桶内组装完成。随后同一匿名样本实际返回 quality 16/32 两个 AVC
  representation；两者 SIDX 均为 466 个 direct SAP reference、EPT 相同，总时长差和
  最大累计 segment boundary 差都小于 1 ms。这支持把它们作为一个 switching set
  继续验证，但还没有真的把远端两档放进同一 master 播放。
- **本地测试实际证明范围**：2026-07-27 新增的 test-only 统一 master 写入两个
  `EXT-X-STREAM-INF` 及 `AVERAGE-BANDWIDTH`、`RESOLUTION`、`FRAME-RATE`；
  `AVURLAsset` 确实读取到两个不同分辨率的 bitrate variant 和声明的视频属性，并同时
  读取独立音频和 `.legible` 字幕组。另一个四秒 synthetic runtime test 在同一
  `AVPlayerItem` 先观察到 132 kbps 高档，再限制交付并观察到 82 kbps 低档，连续
  6/6 通过，且 item identity 不变。这证明原生自动降档机制曾穿过当前 loopback/HLS
  形态；人工恢复后未观察到升档，因为 transport 对高档单独施加了失败/延迟惩罚，不能
  把该结果外推为均匀网络恢复行为。后续 CI run `30427865650` 中，同一探针在 macOS 15
  只请求高档并超时、macOS 26 通过，进一步证明网络诱发的切换时机不是跨系统确定性
  契约。该探针改为通过 `BILIKIT_RUN_ABR_POLICY_PROBE=1` 显式启用，不再阻塞 Gate；
  Gate 只固定多档 variant、默认自动参数和同一 item 的项目自有契约。
  后续签名 test-only probe 又把同一真实样本的 quality 16/32 与共享 AAC 实际组成两个
  variant。AVPlayer 识别为两个 variant，从高档启动；对全部音视频 Range 使用动态共享
  总吞吐限制后自动降到低档，`currentItem` 未替换。恢复到高档声明带宽的 4 倍后，最后
  一个有效 `indicatedBitrate` 在 45 秒观察窗内仍未回到高档。观测器不依赖 access-log
  event 数量，带宽恢复也会加速已在途响应，因此这不再是前一模型的单档惩罚或日志裁剪
  假象。随后从同一次 playurl 响应只在 test transport 内存提取两档实际
  width/height/frameRate，写入 master 后由 `AVAssetVariant.videoAttributes` 确认识别；
  相同路径仍是高档启动、自动降档、恢复 45 秒未升档。因此尺寸/帧率不是本样本恢复升档
  的缺失开关；但单样本、未证实的 HLS bandwidth 值和 AVPlayer 不公开的 hysteresis
  仍不足以否决其他条件或更长窗口升档。
- **判断**：**替换已实施**。V1 只提供“自动”画质，不提供手动档位；master 已按
  Apple 设备 profile 表达多个可用 variant，把运行时选择交给 AVPlayer ABR。V1 不需要
  为精确手动画质设计 item/player 切换。
- **风险**：中。AVPlayer 当前可能宽容接受，但错误属性会影响兼容性、轨道选择和诊断；
  增加多 variant 又会扩大播放策略范围，不能顺手进行。
- **下一步最小验证**：当前 Xcode 未提供 Apple `mediastreamvalidator`，因此该项记录为
  工具边界；未来工具可用时以脱敏 production playlist 补跑。真实最终 master 的多内容
  switching set、稳态选择与 stall 作为后续现场验证。恢复升档不阻塞 V1；V1 不承诺固定
  秒数回到最高档，也不设置 `preferredPeakBitRate`、`startsOnFirstEligibleVariant`、
  额外 buffer 参数或自制强制升档。
- **依赖/冲突**：依赖 API 审计确认 width/height/frameRate/bandwidth 的远端语义；
  V1 自动画质要求本轮实现自适应码率，但不要求任何手动清晰度 UI。

### MP-002 SIDX 子集可解析，但音视频时间线一致性没有证据

- **finding_id**：`MP-002`
- **审计线与涉及能力**：媒体播放；ISO BMFF SIDX、fMP4 初始化段、音视频同步。
- **当前实现**：`SIDXParser.parse` 支持 version 0/1、32-bit box size 和 direct
  reference，用 `boxStart + declaredSize + firstOffset` 计算首段偏移；遇到 indirect
  reference 会失败。它要求输入恰好是一个完整 box，不支持 large-size、size 0 或给定
  range 内的多 box。解析出的 `earliestPresentationTime` 没有进入
  `HLSPlaylistBuilder`；`DASHToHLSBridge` 也没有检查音频、视频首个 decode time
  或 segment boundary 是否对齐。
- **它声称提供职责**：把 DASH 的 `index_range` 精确转换为 HLS
  `EXT-X-MAP`、`EXTINF` 与 `EXT-X-BYTERANGE`，并让独立音视频轨在同一 HLS 时间线上播放。
- **外部事实来源**：[ISO/IEC 14496-12](https://www.iso.org/standard/83102.html)
  定义 SIDX 的 earliest presentation time、first offset、reference type 与 duration；
  [RFC 8216 §3、§4.3.2.5](https://datatracker.ietf.org/doc/html/rfc8216#section-3)
  要求媒体段和 initialization section 形成连续媒体时间线；Apple HLS Authoring
  Specification 进一步要求音视频 rendition 的边界对齐。按 direct-reference 标准形态，
  当前 byte offset 公式正确，但“远端永远是当前子集”和“音视频天然同起点”尚无外部事实。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）的
  `SidxParseUtil` 会扫描 box，并处理 large size，支持 SIDX v0/v1；cilicili
  `6f02857`（2026-07-26）的解析结果保留由 `earliestPresentationTime` 导出的
  `startTime`。两者不能单独证明 B 站当前所有响应形态，但表明这些字段不是可无条件丢弃的
  结构噪音。
- **真实行为证据**：2026-07-27 对一个公开匿名样本的当前 AVC 视频与 AAC 音频
  representation 各取一次 endpoint 声明的 index range，两个 CDN 请求均返回 206。
  两者都是 declared size 等于响应长度的单一 `sidx` box、version 0、61 个 direct
  reference、61 个 `startsWithSAP` 且 SAP type 均为 1，`earliestPresentationTime`
  均为 0。视频 timescale 16000、首段 5.005 s、索引总时长 304.704 s；音频 timescale
  48000、首段 4.992 s、索引总时长约 304.768 s，总时长差约 64 ms。未记录视频身份、
  CID、URL、媒体字节或原始响应。
- **本地测试实际证明范围**：测试覆盖自建 v0 SIDX 与 synthetic fMP4 v1，以及相同假数据
  上的 CDN fallback。它证明 parser 对这些 fixture 的算术，不证明远端结构集合，也没有
  检测真实音视频起点差或长期 drift。
- **判断**：**保留已确认的 direct v0 子集；完整时间线正确性仍尚不能判断**。当前 parser
  覆盖了这一份真实结构，但单样本不能证明所有响应形态或所有音视频边界；也不应仅因 OSS
  支持更多 box 形态就先扩写通用 BMFF parser。
- **风险**：中到高。遇到未支持 box framing 会显式失败；更危险的是两个合法但起点不一致
  的轨道仍生成 playlist，可能表现为固定音画偏移或 seek 后错位。
- **下一步最小验证**：当前单样本已建立结构基线；只在能覆盖不同发布时间、时长或
  representation 形态时追加少量公开样本，继续只记录 SIDX version、box size、
  timescale、earliest time、reference type、SAP 和音视频边界差。样本集合有代表性后，
  再对生成物运行 `mediastreamvalidator` 并测首播、前后 seek 后的音画偏移。
- **依赖/冲突**：依赖 API/安全审计批准 probe 的 endpoint、header、重定向与脱敏字段；
  若发现 edit list 或额外 initialization box，需要重新划定 bridge 范围。

### MP-003 Range 级 CDN fallback 可能混合不同媒体对象

- **finding_id**：`MP-003`
- **审计线与涉及能力**：媒体播放；HTTP Range、CDN fallback、媒体身份。
- **当前实现**：`RepresentationIndexLoader` 用第一个成功候选的 SIDX 和完整长度建表；
  `DASHToHLSBridge` 随后把该 representation 的全部 base/backup URL 注册为候选。
  `HTTPRangeClient.fetch` 对每一次 Range 请求独立遍历候选，但没有把当前 CDN 绑定到媒体
  会话，也没有在切换时重新验证 SIDX、总长度或对象身份。于是初始化段可以来自 A，后续
  fragment 来自 B，而 `Content-Range` 只与当次请求自洽。
- **它声称提供职责**：某个 CDN Range 失败时透明切换到 backup，保持同一播放项连续。
- **外部事实来源**：[RFC 9110 §14.4、§15.3.7](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-range)
  只定义单个 selected representation 的 Range/Content-Range；它不保证两个 URL
  指向逐字节相同的 representation。ISO BMFF segment offset 又以同一个文件布局为前提。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）在 SIDX
  请求成功后把该成功 URL 用于此 representation 的全部 segment，源码注释明确把整个
  representation 移到成功 CDN；wiliwili `88e5876`（2026-04-25）把 base/backup 当作
  mpv 的完整播放 URL playlist，在完整文件入口失败后切换，而非逐 Range 混合。
- **真实行为证据**：现有真实验证没有制造“首选 CDN 在若干 Range 后失败”的情况，也没有
  比较 backup 的长度/索引/字节身份。
- **本地测试实际证明范围**：2026-07-27 新增确定性 loopback reproduction：同一 remote
  route 的 `bytes=0-1` 由 A 返回 `AA`；下一次 `bytes=2-3` 先由 A 返回 503，再由同长度
  但内容不同的 B 返回 `BB`，loopback 对两个请求都返回 206。请求序列明确为 A、A、B，
  证明当前不是只有理论路径，而会在合法 Content-Range 下跨 URL 拼接媒体。目标断言以
  known issue 记录，避免把当前错误固化为正确预期。
- **判断**：**替换**。representation 播放会话固定到生成索引时成功的 URL；该 URL
  失败后终止并重新准备整个 representation。只有获得服务端明确的不可变媒体身份契约或
  可验证的全对象内容身份，才允许从同一 byte offset 在另一 URL 继续。SIDX、长度和
  initialization section 一致只能筛查布局，不能单独证明对象逐字节相同。
- **风险**：潜在影响高、真实 CDN 候选不一致的发生率未知。混合对象可能返回合法 206，
  却产生错误媒体字节、解码失败、seek 异常或音画错位，且问题具有偶发性。
- **下一步最小验证**：风险机制已经由确定性 reproduction 建立，不再需要真实 CDN 故障来
  决定方向。实施时把媒体 route 固定到 `RepresentationIndexLoader` 选中的 source URL，
  将 known issue 转为“不会请求 B”的普通断言，并补 A 中途失败导致整个 representation
  重新准备／失败的测试。真实候选长度与 SIDX hash 只作发生率观测，不作为允许跨 URL
  继续的身份契约。
- **依赖/冲突**：依赖安全审计确定 CDN host/redirect 策略；实现时需要与播放 session
  identity 和取消语义共同设计。

### MP-004 loopback Range 错误响应不符合 HTTP 语义

- **finding_id**：`MP-004`
- **审计线与涉及能力**：媒体播放；本地 HTTP server、Range/HEAD。
- **当前实现**：`LoopbackPlaybackServer` 只绑定 `127.0.0.1`，远端媒体 GET 必须携带
  Range；支持 `bytes=start-end` 和 `bytes=start-`，不支持 suffix 或 multi-range。
  合法范围返回 206/`Content-Range`。但非法或超出长度的范围抛到统一错误处理后成为 502，
  即使响应仍宣告 `Accept-Ranges: bytes`。
- **它声称提供职责**：为 AVPlayer 提供行为自洽的本地 HLS 与 byte-range 媒体端点。
- **外部事实来源**：[RFC 9110 §14.2、§14.4、§15.5.17](https://www.rfc-editor.org/rfc/rfc9110.html#name-416-range-not-satisfiable)
  定义 byte range、Content-Range，以及不可满足范围的 416 与
  `Content-Range: bytes */complete-length`。服务器可忽略不支持的 Range，但不能把
  client 范围错误伪装成 upstream 502。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）和 cilicili
  `6f02857`（2026-07-26）都把 HLS byte-range 适配视为播放器输入协议的一部分；两者未提供
  足以替当前实现豁免 RFC 错误码的证据。
- **真实行为证据**：既有 AVPlayer 样本只走过播放器实际发出的合法 Range；没有观察到
  AVPlayer 发送 suffix、unsatisfiable 或 multi-range，因此不能用播放器当前请求形态
  豁免 server 的 HTTP 语义。
- **本地测试实际证明范围**：2026-07-27 表驱动 loopback 矩阵确认：完整 GET 返回
  200/5 bytes；closed `1-3` 与 open `2-` 返回正确 206、长度、`Content-Range` 和 body；
  HEAD 无 Range 或带 closed Range 均以 200、完整长度、空 body 忽略 Range。suffix
  `bytes=-2`、不可满足 `bytes=5-`、multi-range 和未知 `items` unit 则全部返回
  502/空 body；不可满足响应没有 `Content-Range: bytes */5`。十二个目标差异以 known
  issue 记录，正常路径没有 unexpected failure。
- **判断**：**替换**。当前统一 502 与实际错误来源不符。对语法合法但不可满足的范围采用
  416，并按 RFC SHOULD 附 `Content-Range: bytes */length`；对 malformed、suffix 和
  multi-range 分别制定明确的 ignore/reject/支持策略，不能把它们都概括为 416。suffix
  本身是合法 byte-range 语法，multi-range 也不是天然错误。
- **风险**：中。主要影响 AVPlayer 重试、seek 边界和错误诊断；错误的 502 还可能触发错误的
  CDN fallback。
- **下一步最小验证**：响应矩阵已经建立，机制裁决不再等待 AVPlayer 偶然发出错误 Range。
  实施时区分 parser 结果：支持 single closed/open/suffix；合法但不可满足返回
  416＋`Content-Range: bytes */length`；不支持的 multi-range 与未知 unit 对
  in-memory GET 明确忽略并返回完整 200。remote route 仍要求可转换为单一 Range，不得
  把 client 语法错误转成 upstream 502。将对应 known issue 转为普通断言。
- **依赖/冲突**：依赖 loopback 安全约束继续保持 `127.0.0.1` 与无认证；与 MP-003 的
  upstream/fallback 错误分类直接相关。

### MP-005 关闭 AVPlayer 自动等待却没有对应 stall 恢复

- **finding_id**：`MP-005`
- **审计线与涉及能力**：媒体播放；AVPlayer buffering、stall、播放状态。
- **当前实现**：`AVPlayerEngine` 无条件设置
  `automaticallyWaitsToMinimizeStalling = false`。`AVPlayerTimelineAdapter`
  观察 rate/timeControl/time-jumped 和 30 Hz periodic time；当缓冲耗尽导致 rate 为 0
  时，除 loading/ended 外会映射为 paused。代码没有自定义 buffer 目标或完整的 stall
  恢复状态机。
- **它声称提供职责**：让播放立即开始，避免 AVPlayer 自己等待造成的延迟。
- **外部事实来源**：当前 SDK `AVPlayer.h` 声明该属性默认是 `YES`；设为 `NO` 会让播放器
  尽快开始，而缓冲耗尽时 `timeControlStatus` 变为 paused、rate 变为 0。header 特别说明
  对通过 `AVAssetResourceLoader` media-data delegate 加载的数据应为 `NO`，但 BiliKit
  使用普通 loopback HLS URL，并没有该 delegate。公开接口见
  [`automaticallyWaitsToMinimizeStalling`](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling)。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）对 VOD 设置自动
  等待，并另有 access log/stall 调试；cilicili `6f02857`（2026-07-26）虽在其 bridge
  关闭自动等待，但同时实现了明确的 buffering/stall 恢复状态机。不能只复制前半个开关。
- **真实行为证据**：`docs/validation/M4-closeout-2026-07-23.md` 覆盖正常网络下播放、
  seek、替换与窗口操作，没有 Network Link Conditioner/真实 CDN 抖动或
  `AVPlayerItemAccessLog`。真实服务发生率仍未知。
- **本地测试实际证明范围**：2026-07-27 使用同一四秒 fragmented AVC/AAC、loopback HLS、
  AVPlayerLayer 和可恢复 Range starvation，只改变
  `automaticallyWaitsToMinimizeStalling`。系统默认在约 0.91 秒耗尽后进入
  `.waitingToPlayAtSpecifiedRate`，释放阻塞后时间线自动继续；设为 `false` 时进入
  `.paused`，释放阻塞后五秒内仍停在同一位置。两次均确认至少一个媒体 Range 正在被
  transport 阻塞；目标差异以两个 known issue 记录。
- **判断**：**替换**。优先回到 AVPlayer 的原生默认等待策略；只有可重复测量证明产品需要时，
  才保留关闭开关并补齐显式 stall recovery。
- **风险**：高。瞬时弱网可能被误判为用户暂停，播放不自动恢复；同时 UI/字幕/弹幕都随错误的
  paused 状态停住。
- **下一步最小验证**：默认等待的恢复职责已经由可控 starvation 对照建立，不再需要真实
  弱网才能决定方向。实施时删除 engine 的 `false` 赋值，把对照中的默认恢复断言保留为
  回归，并验证 timeline/UI 在 waiting 时表达 buffering、恢复后回到 playing。真实网络
  只用于测发生率和体验，不用于重新裁决系统默认 owner。
- **依赖/冲突**：与 MP-006 的持续失败观察、并发生命周期审计的 observer 清理，以及
  性能审计的真实硬件测量相关。

### MP-006 播放项 ready 后的失败没有持续观察

- **finding_id**：`MP-006`
- **审计线与涉及能力**：媒体播放、并发生命周期；AVPlayerItem status 和失败终态。
- **当前实现**：`AVPlayerEngine` 的 readiness observer 在 `.readyToPlay` 后结束；
  后续没有持续观察同一 item 的 `.failed`，也没有订阅
  `AVPlayerItemFailedToPlayToEndTime`。access/error log 没有被用于诊断。结果由旧 item
  产生时虽有 identity/generation 隔离，但当前 item 的 ready 后失败可能没有明确状态出口。
- **它声称提供职责**：把 AVPlayer 的准备、播放、结束、失败转换成应用可消费的确定状态。
- **外部事实来源**：[AVPlayerItem.Status](https://developer.apple.com/documentation/avfoundation/avplayeritem/status-swift.enum)
  可持续 KVO，`.failed` 表示 item 已不可播放；
  [`AVPlayerItemFailedToPlayToEndTime`](https://developer.apple.com/documentation/avfoundation/avplayeritemfailedtoplaytoendtimenotification)
  提供未能播放到结尾的通知；`AVPlayerItem` 另有 access/error log API。它们均早于最低
  macOS 15，无可用性障碍。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）持续观察
  item status 并处理 ready 后 failed；cilicili `6f02857`（2026-07-26）同时监听 item
  status 与 failed-to-end；wiliwili `88e5876`（2026-04-25）监听 mpv file-error 并切换
  完整备选源。
- **真实行为证据**：尚无真实 CDN/解码错误的 domain/code、发生率或终态记录。
- **本地测试实际证明范围**：
  `LoopbackPlaybackServerTests.engineReportsFailureAfterItemWasReady` 使用 production
  `AVPlayerEngine` 和 loopback HLS，让 item 先 ready/播放，再把后续 Range 固定为 503。
  十秒内 item 仍为 ready、engine timeline 停在 paused，没有原生终态通知；这证明不能把
  “持续 Range 失败必然很快转成 item.failed”作为恢复策略。测试随后对当前 item 显式发送
  documented failed-to-end notification，独立 observer 恰好收到一次，但 engine 没有
  发出 `.failed` event，timeline 也没有进入 failed。两个目标断言以 known issue 登记。
  synthetic 通知不证明 AVPlayer 在何种真实错误下发送它，也尚未证明换视频后的旧 item
  隔离和 observer 成对释放。
- **判断**：**替换**。readiness KVO 在 ready 后释放；当前既不再观察 item 的终态 status，
  也不监听独立的 failed-to-end 通知，因此 ready 后错误缺少可靠出口。应增加
  item-identity scoped 的持续失败观察；对用户只暴露稳定错误类别，
  详细 access/error log 仅用于短生命周期脱敏诊断，不写入常驻日志。
- **风险**：高。播放器可能冻结或停止而页面仍认为可播放，fallback/重试也无法基于真实终态
  决策。
- **下一步最小验证**：机制缺口已确定。实施时同时持续观察当前 item status，并订阅
  failed-to-end；同一 item 的失败只发送一次，旧 item 通知必须忽略，替换/关窗必须移除
  observer，再把两个 known issue 转为普通断言。真实硬件只用于采集实际错误类型、发生率
  和诊断信息，不再作为是否需要失败出口的前置条件。
- **依赖/冲突**：依赖并发 owner/取消审计；错误类别与 MP-003 fallback 决策相连，不能在
  observer 内直接形成无限重试。

### MP-007 使用 AVPlayer 时间线同步是正确边界，零容差 seek 尚未获证

- **finding_id**：`MP-007`
- **审计线与涉及能力**：媒体播放、字幕、弹幕；时间源、seek、generation。
- **当前实现**：`AVPlayerTimelineAdapter` 用 AVPlayer periodic time observer 和
  time-jumped 生成 `PlaybackTimeline.Snapshot`；字幕和弹幕共同消费 item identity、
  position、rate、state、generation。切视频/向后 seek 会清理旧调度状态。
  `AVPlayerEngine.seek` 始终使用 before/after tolerance 均为 zero 的精确 seek。
- **它声称提供职责**：避免字幕/弹幕各自计时，保证暂停、倍速、seek 和切视频后共同跟随实际
  播放时钟；同时提供帧级精确 seek。
- **外部事实来源**：Apple
  [`addPeriodicTimeObserver`](https://developer.apple.com/documentation/avfoundation/avplayer/addperiodictimeobserver(forinterval:queue:using:))
  是观察播放时间的原生接口，SDK interface 要求 observer 与 remove 成对；
  [`seek(to:toleranceBefore:toleranceAfter:completionHandler:)`](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:))
  支持零容差，但 SDK 同时说明更大 tolerance 可提高 seek 性能。两者均远早于 macOS 15。
- **OSS 对照及 commit/date**：wiliwili `88e5876`（2026-04-25）的 subtitle core 也从
  播放器 playback time 驱动字幕；ATV-Bilibili-demo `86ba6f5`（2026-07-05）和 cilicili
  `6f02857`（2026-07-26）均以底层播放器时间而非 wall clock 同步外围媒体状态。
- **真实行为证据**：M4 closeout 记录真实播放中前后 seek、字幕/弹幕、A→B→A 替换可工作；
  这支持“同一播放器时钟 + identity 隔离”的方向，但没有测量 seek latency、落点误差或
  音画 drift。
- **本地测试实际证明范围**：虚拟 timeline 测试证明暂停、倍速、后退和 generation 的调度
  规则；不证明 30 Hz 在真实负载下无抖动，也不证明所有 seek 必须 zero tolerance。
- **判断**：共享播放器时间线和 generation **保留**；全局零容差 seek 策略
  **尚不能判断**。
- **风险**：保留部分风险低；未经测量坚持零容差可能增加 seek 延迟和 I/O，放宽又可能影响
  字幕/弹幕落点。
- **下一步最小验证**：在真实媒体上分别测默认 tolerance 与 zero tolerance 的完成延迟、
  实际落点误差、seek 后音画/字幕偏移；同时确认替换/关窗后 periodic observer 已移除。
- **依赖/冲突**：依赖性能审计提供测量方法，并发生命周期审计确认 observer owner；不应为
  seek 再引入第二套 wall-clock scheduler。

### MP-008 空弹幕 protobuf 的 wire 语义已知，HTTP endpoint 语义未知

- **finding_id**：`MP-008`
- **审计线与涉及能力**：弹幕协议；Protocol Buffers、空分段语义。
- **当前实现**：`BiliAPIClient.danmakuSegmentData` 在 protobuf 解码前拒绝空 body；
  `BiliDanmakuRepositoryTests` 也把空响应写成失败预期。这样无法区分“合法但没有元素的
  message”和“错误返回”。
- **它声称提供职责**：避免 HTML 错误页、截断响应或异常空 body 被误解码成成功。
- **外部事实来源**：[Protocol Buffers Encoding Guide — Message Structure](https://protobuf.dev/programming-guides/encoding/#structure)
  将 message 定义为零个或多个 tag-value pair，因此零字节是全默认字段 message 的合法
  wire encoding。HTTP status/content type 仍应独立验证，不能用 body 非空代替。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）的通用
  `requestPB` 直接交给 SwiftProtobuf 解码，不先拒绝空 body；cilicili
  `6f02857`（2026-07-26）的 `DanmakuSegmentProtobufParser` 明确把 empty data 返回
  `[]`，其 API 层也不在解析前拒绝。
- **真实行为证据**：本轮没有请求真实空弹幕段；因此只能确认 wire format 允许，不能宣称
  当前 B 站 endpoint 一定会用空 body 表达“无弹幕”。
- **本地测试实际证明范围**：测试只证明实现符合自己写下的“空即错误”预期，没有远端协议
  证据；非空 fixture 只证明已知字段可解码。
- **判断**：**尚不能判断**。已确认 wire-level 零字节 message 合法，decoder 层应单独有
  “零字节 → 空 elements”测试；但没有证据证明远端 `seg.so` 用 HTTP 2xx 零长度 body
  表示合法空分段，也可能是上游或代理异常，因此不能据此改变 transport policy。
- **风险**：中、触发概率未知。若 endpoint 确实用零 body 表示空段，当前会误判并触发
  MP-009；若直接放宽，又可能吞掉网关异常。
- **下一步最小验证**：先增加 wire-level 空 message 与“200 HTML/非预期 MIME”的分离测试；
  若安全审计允许，再做一次只记录 status、content-type、body length 和解码元素数的脱敏
  现场 probe。
- **依赖/冲突**：endpoint/header/status 事实归 API 与安全审计；本项只裁决 protobuf
  wire semantics，不为任意空 HTTP 响应背书。

### MP-009 持续 timeline 更新会在每次弹幕加载失败后无上限重试

- **finding_id**：`MP-009`
- **审计线与涉及能力**：弹幕、并发与生命周期；重试、prefetch、失败状态。
- **当前实现**：`DanmakuScheduler` 按 360 秒分段，缓存当前/下一段，最多保留三段；
  `DanmakuSession.handle` 每次 timeline tick 为缺失分段创建加载任务，最多两个并发。
  失败后任务从 in-flight 移除且状态标记 failed，但下一次被 session 接收的 timeline
  update 又把同一段视为缺失并重建任务；没有 attempt 上限、backoff 或本次 identity 的
  terminal marker。请求速率受单次失败耗时、timeline callback/coalescing 与最多两个并发
  限制，并非“每个 30 Hz tick 无条件创建一个新请求”。
- **它声称提供职责**：临时网络错误后自动恢复当前/预取弹幕段。
- **外部事实来源**：这里没有 Apple/协议 API 要求自动重试；是否重试是产品策略。外部事实只
  能确认播放器 periodic callback 可高频触发，不能把它当网络 retry timer。当前 SDK
  对 periodic observer 也不保证每次 interval 都严格回调，因此请求策略更不应隐含绑定它。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）同样使用
  360 秒分段并把 progress 毫秒转换为秒，确认分段边界方向；cilicili
  `6f02857`（2026-07-26）使用同一分段 endpoint。两者没有为“每个视频 tick 重试网络”
  提供支持。
- **真实行为证据**：M4 性能记录覆盖正常播放弹幕、滚动/resize 与 RSS，没有制造持续 5xx、
  offline 或解析失败，也没有统计同一 segment 的请求次数。
- **本地测试实际证明范围**：
  `DanmakuSessionTests.failedSegmentsAreNotRetriedByEveryLaterTimelineUpdate` 使用恒失败
  repository，每轮等待当前/下一段两个 load task 完整失败并清除后，再发送下一次相同
  timeline update。128 次 update 产生 256 次同 identity 请求，呈严格线性增长；目标
  `attempts <= 4` 以一个 known issue 登记。这排除了 AsyncStream coalescing 和并发中
  in-flight 去重造成的假象，证明“失败完成后的下一 tick”会重建请求。它不证明真实
  periodic callback 频率、网络错误分布或固定重试上限应取多少，也尚未覆盖切 identity
  后允许重新尝试及 stop 后零请求。
- **判断**：**替换**。把失败策略从 timeline tick 解耦：每 segment/identity 使用有上限的
  重试与 backoff，或保留失败直到用户/网络事件显式重试；切视频必须清除状态。
- **风险**：高。快速确定性失败时可能接近 timeline update 速率；网络超时失败则低得多。
  持续失败仍会产生无界请求、CPU/网络开销、服务压力和日志噪声，也会掩盖 MP-008 这类
  确定性协议错误。
- **下一步最小验证**：无界机制已由 128 轮／256 次请求确定。实施时把失败记忆按
  segment/identity 放入明确 owner，使 timeline tick 不直接重试；选定有界策略后把 known
  issue 转为普通断言，并补 stop 后零请求、切 identity 可重新尝试及失败后恢复成功路径。
  不以固定 timeout 或真实播放频率替代策略裁决。
- **依赖/冲突**：依赖并发审计统一 Task owner/generation；重试次数属于后续产品决定，本轮
  不建议先拍固定 timeout。

### MP-010 字幕/弹幕基础时间语义有交叉证据，呈现语义仍缺样本

- **finding_id**：`MP-010`
- **审计线与涉及能力**：字幕与弹幕；远端时间单位、cue overlap、位置/样式。
- **当前实现**：弹幕使用 360 秒 segment，并把 protobuf progress 毫秒转换为播放器秒；
  字幕 payload 解码 `from`/`to`/`content`，也解码但不使用 `location`。`SubtitleViewModel`
  通过二分查找只提供一个 `currentCueText`，因此重叠 cue、位置或多行布局语义未建模。
- **它声称提供职责**：以 AVPlayer 当前时间显示当前字幕，并按远端弹幕进度调度。
- **外部事实来源**：[RFC 8216 WebVTT Media Segments](https://datatracker.ietf.org/doc/html/rfc8216#section-3.5)
  说明分段字幕 cue 与媒体时间线的映射要求；但 B 站 JSON subtitle 的 `location` 和重叠
  规则不是 RFC WebVTT 事实，必须来自当前协议/真实样本，不能由字段名猜测。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）与 cilicili
  `6f02857`（2026-07-26）交叉确认当前弹幕 endpoint 的 360 秒分段及毫秒 progress；
  ATV 还把字幕转换成原生 WebVTT。ATV、wiliwili 虽也读取 `location`，当前所见实现没有
  提供足以证明其呈现语义的使用证据。
- **真实行为证据**：既有 M4.6 记录证明正确 WBI catalog endpoint 和 A→B→A identity
  隔离修复了曾经的串字幕症状；它没有记录重叠 cue、非默认 location、多行或变速下的偏移
  分布。
- **本地测试实际证明范围**：fixture 证明已知 JSON/protobuf 字段解码与单 cue 查找；
  fixture 中出现 `location = 2` 只证明字段存在，不证明值的 UI 含义。虚拟 timeline
  也不能替代真实播放器 jitter/seek。
- **判断**：共享 AVPlayer 时间源、弹幕 360 秒与毫秒换算 **保留**；字幕 overlap、
  location 和样式语义 **尚不能判断**。
- **风险**：基础同步风险低；若真实内容存在重叠/位置语义，当前单字符串模型会丢 cue 或显示
  在错误位置。贸然实现猜测规则则会制造新的错误协议事实。
- **下一步最小验证**：经安全审计批准后，对多个公开样本只记录 cue 数、重叠数量、
  `location` 值分布、最大行数和时间范围，不记录文字、URL 或视频 ID；针对确认存在的形态
  再做暂停、倍速、前后 seek 的真实 UI 验证。
- **依赖/冲突**：字幕 catalog endpoint/WBI 归 API 审计；呈现决策归产品与 accessibility
  审计。本项不建议恢复基于内容文本的“合理性判断” workaround。

### MP-011 B 站是否向当前请求身份返回 4K 必须与本地 HLS 能力分开验证

- **finding_id**：`MP-011`
- **审计线与涉及能力**：播放 API、画质能力、codec 选择与 HLS variant 建模。
- **当前实现**：`BiliAPIClient.playback` 默认请求 `qn=120`、`fnval=976`、
  `fourk=1`，解码后仍只保留 AVC 视频；`AVPlayerEngine` 把返回的全部 AVC
  representation 交给多 variant bridge，由单一 item 自动选择。Application／Feature
  不暴露固定 quality；显式 quality 仅留在 BiliAPI 诊断边界。
- **它声称提供职责**：按请求质量取得一组可播放 DASH representation，并转换为
  AVPlayer 可消费的媒体。
- **外部事实来源**：B 站没有供第三方客户端依赖的公开稳定 playurl 契约；因此
  `quality=120`、`fourk=1` 只能作为待现场核对的客户端约定，不能单独证明匿名或登录用户
  当前能取得 4K。
- **OSS 对照及 commit/date**：wiliwili `88e5876`（2026-04-25）的当前 WBI playurl
  请求带 `fourk=1`、调用方传入 `qn`；ATV-Bilibili-demo `86ba6f5`（2026-07-05）
  以 `qn=127`、`fnval=976` 请求完整可用集合；PiliPlus `f1b79ee`（2026-07-24）与
  cilicili `6f02857`（2026-07-26）均把 `120` 建模为 4K。它们交叉支持参数和编号语义，
  但不证明服务端会对某一身份、内容或 codec 返回该档。
- **真实行为证据**：2026-07-27 对一个由当前 OSS 标注为 4K 的公开普通视频完成匿名最小
  请求，共一次 view 与两次非 WBI playurl。当前参数形态返回 HTTP 200／业务 code 0，
  `accept_quality=[112,80,64,32,16]`，实际 DASH 只有 quality 32/16 的 AVC 与 HEVC。
  改用 `qn=120/fnval=976/fourk=1` 后仍为 HTTP 200／业务 code 0，能力目录扩展为
  `[125,120,112,80,64,32,16]`，但 selected quality 降为 64，实际 DASH 仍只有
  32/16，未返回 quality 120 representation。记录未包含视频身份、CID、URL、Cookie、
  文本或原始响应。
- **本地测试实际证明范围**：synthetic 3840×2160 fixture 或 master 测试最多证明
  bridge/AVFoundation 能表达 4K variant，不证明 B 站实际返回 4K，也不证明当前 Mac
  对返回 codec 的硬件解码与性能满足产品要求。
- **判断**：B 站当前 endpoint 和该内容的能力目录明确支持 quality 120（4K），但
  **匿名身份不能取得 4K 媒体 representation**。普通登录与会员身份能否实际取得 4K
  **尚不能判断**。BiliKit 已能在服务实际返回 AVC 4K 且设备可播放时把它纳入自动 ABR，
  但这不等于产品保证 4K。
- **风险**：若 UI 仅依据固定编号宣称 4K，会把内容能力、账户权限和 codec 支持混为一谈；
  若继续只保留 AVC，也可能在服务端主要返回 HEVC/AV1 高画质时错误降档。
- **下一步最小验证**：匿名矩阵已完成。登录态仍有产品决策价值，但现有 authorizer
  精确 allowlist 不允许 playurl，审计阶段不得为探针临时放宽；应在未来正式裁决
  authenticated playurl endpoint、query 与安全边界后，再分别验证普通登录和会员身份。
  不绕过会员/DRM/区域限制，也不保存完整响应。
- **依赖/冲突**：与 API-006 的 WBI playurl 裁决、MP-001 的多 variant master、
  登录 Cookie allowlist 和 codec/性能验证共同决定最终产品能力；其中任一项不能由另外
  一项替代。

### MP-012 精确清晰度的单 player item 替换不能视为用户无感

- **finding_id**：`MP-012`
- **审计线与涉及能力**：AVPlayer item 生命周期、精确清晰度切换、原生字幕状态和播放
  surface。
- **当前实现**：`AVPlayerEngine.performLoad` 在新 bridge asset 准备前就停止旧 server、
  清空 `preparedAsset` 并执行 `replaceCurrentItem(with: nil)`；新 item ready 后也没有恢复
  原位置、播放速率或 legible selection。因此当前 production load 本身不具备清晰度切换
  的无缝语义。
- **它声称提供职责**：未来若“手动清晰度”表示精确指定某 representation，需要在保持
  内容 identity 的情况下切换到新 asset/item，同时尽量不让用户感知停顿、黑帧、位置跳变、
  字幕丢失或音频异常。
- **外部事实来源**：Xcode 26.6 `AVPlayer.h` 明确规定，使用已关联到另一个 `AVPlayer`
  的 `AVPlayerItem` 会抛异常；`AVQueuePlayer` 只承诺在媒体及时可用时尽可能 gapless 地
  顺序播放队列，并不提供把下一 item 精确 seek 到当前内容位置的契约。
- **当前 B 站 Web 行为**：2026-07-27 匿名公开页面只有一个 `<video>`。当前
  `core.a846b5dd.js` 的普通 DASH 手动画质路径对同一 dash player 调用
  `setQualityFor("video", ...)`，启用 fast switch，并以
  `QUALITY_CHANGE_RENDERED` 作为 UI 已切换信号；这属于浏览器 MSE representation
  切换，不是双 `<video>`。另一条 whole-source 路径会把旧帧画进绝对定位的 `<canvas>`、
  隐藏 video，等新源 `canplay` 后再移除 canvas。因此“旧画面保持到新画面准备好”的观感
  不能直接证明后台运行着第二个 player。
- **OSS 对照及 commit/date**：
  - cilicili `6f02857`（2026-07-26）优先在同一多 variant HLS item 内调整 peak bitrate；
    若必须换源，先 warm 新 variant，再截取旧帧、静音并停用旧 player，新 player 首帧后
    淡出 snapshot。它保留旧 player 对象用于过渡和释放，但不是两个 player 同时有声播放。
  - ATV-Bilibili-demo `86ba6f5`（2026-07-05）手动画质只保留精确 stream，建立新的
    `AVPlayer`，立即替换 `AVPlayerViewController.player`，随后 seek/play；没有旧 surface
    保持或双 player 首帧交接。
  - wiliwili `88e5876`（2026-04-25）从已有 DASH 列表选中 representation 后，以 mpv
    `loadfile ... replace` 在旧进度重载；也不是双 player。
  三者都只能说明当前客户端的工程选择，不能把未获系统保证的 surface/audio 交接升级为
  Apple 契约。
- **真实行为证据**：test-only synthetic HLS 使用 128×72 与 256×144 两个 AVC variant、
  共享 AAC 和默认关闭的 WebVTT，Range transport 每次固定增加 150 ms。最终连续五次：
  单 `AVPlayer` 预加载 asset 元数据后替换 item，首个新视频帧为 625–638 ms，时间线重新
  推进为 743–757 ms，位置误差 58–62 ms；字幕可在新 item 上显式恢复。尝试在独立
  staging player 中 preroll 后把同一 item 转交原 player，稳定触发
  `NSInvalidArgumentException`，与 SDK 的单 player 关联约束一致。
- **本地测试实际证明范围**：同一 test 的双 player 对照能在旧 player 继续显示时，用
  484–509 ms 在后台准备新 item；交接候选点两条时间线相差 75–82 ms，新 item 已提供
  decoded frame，legible selection 也已恢复。它没有真的切换两个 `AVPlayerLayer` /
  `AVPlayerView`，也没有测扬声器输出，因此不证明 surface 无闪烁、音频无中断或真实
  CDN/4K 下仍满足该区间。
- **判断**：当前 engine 路径 **替换**；“单 player 直接 replace item 可以用户无感”
  **否决**。B 站 Web 不能作为双 player 先例；当前三个活跃 OSS 也未提供真正双
  surface/audio 原子交接的证明。双 player／双 surface 后台准备与交接仍
  **尚不能判断**，只作为 V1 之后出现精确手动画质需求时的候选；
  snapshot 遮罩则已有 Web 与 cilicili 的独立实现先例，但只能隐藏黑帧，不能等同连续播放。
- **风险**：继续单 player 会产生稳定可感知停顿；采用双 player 则引入临时双份解码、
  网络、buffer、subtitle selection、控制绑定、失败回滚和音频交接复杂度。若只测时间线
  而不测 surface/audio，会把后台 ready 误报成用户无感。
- **下一步最小验证**：V1 不继续投入双 player 验证；先完成 MP-001 的同 item 原生 ABR。
  后续若出现明确的精确手动画质需求，再建立 test-only AppKit host，让两个
  `AVPlayerLayer` 或等价 surface
  重叠。这里的“加载完成”不是下载完整视频，也不只是 item `readyToPlay`，而是 staging
  player 已完成目标 seek/preroll、`AVPlayerLayer.isReadyForDisplay == true`、时间线进入
  容差、字幕 selection 已恢复；新 player 在交接前静音。随后在一个显示 transaction 内
  交换 surface/audio owner，并保留旧 player 做短暂失败回滚。记录最后旧帧到首个新帧
  间隔、黑帧、音频 discontinuity、峰值内存、快速连续选择的取消和失败回滚；同时以
  snapshot 遮罩作为成本较低的对照组。没有真实 rendered-frame/audio 证据前不进入生产。
- **依赖/冲突**：依赖 MP-001 的 master/手动画质语义、AX-006 的 legible track、
  CONC-005 的资源 owner 与 PERF-004 的播放器性能。V1 已裁决为仅自动画质，因此本项不再
  阻塞 V1；未来若恢复手动精确档位，再重新打开这些依赖。

### MP-013 单条空白弹幕会使整个正常分段失败

- **finding_id**：`MP-013`
- **审计线与涉及能力**：弹幕 protobuf 解码、坏记录隔离、分段失败与重试。
- **当前实现**：`DanmakuPayloadDecoder.events(from:)` 会逐条跳过不支持的 mode 和经
  Unicode whitespace trimming 后为空的正文；缺失 ID、越界时间／颜色等其他字段异常仍
  直接抛 `invalidDanmakuData`，`BiliDanmakuRepository` 随后把整个分段映射为
  `DanmakuApplicationError.invalidResponse`。总事件数、总文本量、单条长度和响应体上限
  均未放宽。
- **外部事实来源**：本项是当前服务真实数据与本地 decoder 行为的直接冲突；单条记录是否
  应丢弃属于本地容错策略，不由 protobuf wire format 自动决定。
- **OSS 对照及 commit/date**：
  - wiliwili `1af41ff`（2023-04-06）的提交标题即 `Ignore empty danmaku`，在旧 XML
    弹幕路径中遇到无正文 element 时 `continue`，保留其余记录；它证明空 element 并非
    BiliKit 独有，但不是当前 protobuf endpoint 的同协议对照；
  - cilicili `6f02857`（2026-07-26）对当前分段 protobuf 逐 element 解析，正文按
    `.whitespacesAndNewlines` trim 后为空或缺少进度时返回 `nil`，调用方继续解析同段其余
    element；这是与本现场最直接的独立实现对照；
  - ATV-Bilibili-demo `86ba6f5`（2026-07-05）在 protobuf reply 成功后仅按 mode 过滤并
    逐项映射，不因空正文抛整段错误；
  - PiliPlus `f1b79ee`（2026-07-24）把 `DmSegMobileReply.elems` 逐项加入时间桶，空正文
    没有触发整段失败的 guard。它可能继续产生空显示项，不等于 cilicili 的显式丢弃策略。
  对四仓库的 Issue、PR 与 commit 关键词检索未找到同 endpoint 的公开故障报告；只找到
  wiliwili 上述明确修复提交。没有报告不能反证问题不存在，尤其当当前实现已容忍该输入。
- **真实行为证据**：一条当前公开高弹幕长视频的首段与末段分别由 production decoder
  解出约一千和八百条事件；中段返回 HTTP 200、`application/octet-stream`、约 43 KB，
  但 production probe 稳定报 `invalid-response`。不落盘的 wire 形状统计在约八百条
  element 中找到一条经 Unicode whitespace trimming 后为空的正文；其余已列校验条件均
  未命中。响应与记录未保存，登记不含 BVID、CID、URL 或弹幕文本。
- **本地测试实际证明范围**：定点测试证明混合分段会丢弃 Unicode 空白记录并保留有效
  记录、全空白分段可解为零事件，同时缺失 ID 仍失败关闭；原有 truncated protobuf、
  错误 Content-Type、空／超大响应等负向测试继续通过。它不证明空白记录在所有视频中的
  发生率，也没有放宽其他字段的容错语义。
- **判断**：**已最小替换并通过真实复核**。服务数据中的空 element 和“逐条隔离”都不是
  BiliKit 独有；实现只把 trim 后空白正文改为逐条丢弃，没有把所有字段校验宽泛改成
  `compactMap`，资源与安全上限保持不变。
- **风险**：本次已消除该空白记录导致整段丢失并触发 MP-009 重试的已知路径；其他非法字段
  仍可能使整段失败，其服务发生率和安全分类尚未形成完整容错矩阵。
- **下一步最小验证**：恢复 STATE-007 的同 session 三段高密度峰值与回落测量；若之后发现
  其他真实单条异常，再以同样的“真实样本＋字段级定点测试”方式单独裁决，不预先放宽。
- **依赖/冲突**：MP-013 不再阻塞 STATE-007；MP-009 的有界重试仍是独立待修问题。

### MP-014 单条高位色值会使整个正常弹幕分段失败

- **finding_id**：`MP-014`
- **审计线与涉及能力**：弹幕分段 HTTP 响应、protobuf 解码、字段级失败分类与三段工作集。
- **当前实现**：production decoder 已在 API 边界把 protobuf field 5 规范化为基础
  `RRGGBB` 的低 24 位，不再因高位色值拒绝记录或整段。原 production probe 只输出映射后的安全错误名；
  显式 test-only 分类探针可在内存中统计 HTTP/body/wire/字段类别后立即清理。仓库调用图
  还显示 `DanmakuEvent.colorRGB` 目前只由 API decoder 写入，现有 scheduler/renderer
  没有读取；当前直接后果是整段丢失，而不是渲染器接受宽值后发生颜色转换错误。
- **外部事实来源**：同一公开长视频的相邻真实分段、production transport/repository/
  decoder、显式配置才运行的签名测试探针，以及三个当前活跃 OSS 的 protobuf 映射和颜色
  转换。非公开服务没有可依赖的官方字段契约，因此不把任一 OSS 单独提升为规范。
- **OSS 对照及 commit/date**：
  - cilicili `6f02857`（2026-07-26）从 protobuf field 5 读取 `UInt32`，不做 24-bit
    range reject；渲染时分别取 `(rgb >> 16) & 0xFF`、`(rgb >> 8) & 0xFF` 和
    `rgb & 0xFF`，即高位不参与 RGB。该 reference 是 shallow snapshot，无法据此声称
    更早提交历史；
  - ATV-Bilibili-demo 在 `b694935`（2023-07-16）由 XML 切到当前分段 protobuf，
    `DanmakuElem.color` 原样进入模型，再由 `UIColor(hex:)` 用
    `0x00FF0000`/`0x0000FF00`/`0x000000FF` 取低 24 位；该颜色 helper 自
    `765865a`/`bae8097`（2022-10）起已有同一位掩码语义；
  - PiliPlus `f1b79ee`（2026-07-24）把 protobuf `e.color` 直接交给
    `decimalToColor`。`e85c8b3`（2025-11-02）把逐通道低 24 位转换简化为
    `Color(decimalColor | 0xFF000000)`；它不拒绝记录，且低 24 位仍是 RGB，但若输入
    已有高位，其 alpha 行为与前两者并不完全相同；
  - wiliwili `88e5876`（2026-04-25）的点播路径仍是旧 XML，不是同协议证据；其
    `e8e2de2`（2023-01-12）以来也以移位加 `& 0xff` 取低 24 位，可作为历史渲染语义
    旁证。`cb83585`（2023-11-04）主要拆分直播弹幕，并不是本次点播高位色值修复。
  三个 protobuf 实现都没有因 `color > 0xFFFFFF` 拒绝单条或整段，其中两个当前实现明确
  只用低 24 位。生成的 protobuf 对照还把普通 `color: UInt32` 与 field 24 的
  `colorful`/会员渐变类型分开，故目前没有证据把 `color` 高位解释成渐变标志；这只能限定
  本地处理边界，不能证明高位的服务端含义。
- **真实行为证据**：MP-013 修复后，第 7 段可重复成功并解码／调度 440 条事件；第 6 段用
  相同 production probe 连续两次稳定返回 `invalid-response`。用户授权的脱敏分类确认：
  HTTP 200、octet-stream、107,624 字节、wire 正常解出 852 条；unsupported mode、空白、
  缺失／超长 ID、时间、超长正文、事件／总文本上限均为 0，只有 1 条 `colorRgb` 超过
  `0xFFFFFF`。第 8 段另有一次 `unavailable`，尚未分类。所有探针未保存 BVID、CID、URL、
  正文、body 或 xcresult。
- **本地测试实际证明范围**：证明第 6 段的整段失败由唯一颜色越界记录触发，并排除当前
  已列的其他 decoder guard；静态调用图证明当前渲染路径没有消费 `colorRGB`。它仍没有
  证明具体高位值的服务端含义或发生率。第 8 段的 `unavailable` 也不能与颜色问题合并。
- **判断**：**已按用户授权最小替换并通过真实复核**。删除整段失败 guard，并在 decoder
  边界把事件颜色规范化为 `element.colorRgb & 0x00FF_FFFF`：保留
  记录与低 24 位视觉信息，匹配两个当前 protobuf 渲染实现和一个历史实现，不把未知高位
  泄漏到语义明确为 RGB 的 domain model。clamp 会把无关高位值压成白色，默认白色会丢掉
  已知低位信息，跳过记录或继续整段失败则与三个当前 protobuf 客户端行为相反。
- **风险**：该已知 360 秒区间不再因颜色触发整段失败。低 24 位规范化的剩余风险是未来若
  业务确实定义 `color` 高位语义，本地会
  忽略它；但现有模型只承诺 RGB，渐变另有独立字段，且当前 renderer 尚不显示颜色，因此
  风险小于继续丢整段。
- **下一步最小验证**：定点测试已证明 `0xAB123456` 保留事件并得到基础 RGB
  `0x123456`，缺失 ID 等原非法字段继续失败；同一真实第 6 段 production probe 已成功
  解码并调度 843 条。普通彩色与会员渐变的真实显示属于后续独立功能，届时把 `colorful`
  作为独立字段进入 domain model，不向 `colorRGB` 回填打包语义。
- **依赖/冲突**：MP-014 不再阻塞 STATE-007；新的第 8 段 `unavailable` 由 MP-015
  单独阻塞。不推翻 synthetic M501-PERF-001，也不改变已关闭的 MP-013 窄修复。

### MP-015 固定请求第 8 段把合法末段之外的 304 误报为产品故障

- **finding_id**：`MP-015`
- **审计线与涉及能力**：弹幕分段 HTTP 状态、远端错误映射与三段工作集。
- **当前实现**：production scheduler 已在 timeline 有已知 duration 时避免预取合法末段
  之后的 segment；原 test-only 工作集探针却固定请求 `6...8`，没有依据视频时长计算末段。
  `BiliDanmakuRepository` 会把 304 映射为 `DanmakuApplicationError.unavailable`。
- **外部事实来源**：同一公开长视频的 production transport/repository 路径与显式签名
  三段工作集探针。
- **OSS 对照及 commit/date**：ATV-Bilibili-demo `86ba6f5`（2026-07-05）按实际播放
  time 计算当前/相邻 360 秒段，而不是为任意视频固定请求第 8 段；本项最终由 BiliKit
  自己的页面 duration 与 scheduler 调用图直接裁决，不需要用 OSS 推断 304 的普遍语义。
- **真实行为证据**：MP-014 修复后，第 6 段 production probe 成功解码／调度 843 条；
  签名同会话第 6–8 段探针仍在进入内存断言前失败。随后单独对第 8 段复核，production
  probe 再次只返回 `unavailable`。临时输入和原始产物均已清理。
- **本地测试实际证明范围**：扩展后的脱敏分类记录页面 duration 为 2327 秒、合法末段为
  7、第 8 段 `within-duration=0`，远端响应为 HTTP 304、缺少 Content-Type、零字节 body。
  新增 scheduler 定点测试证明 position 2200／duration 2327 时只要求 `[7]`，不会预取 8。
- **判断**：原“产品 blocker”判断 **删除**；根因是审计探针越界。test-only 工作集探针
  已改为按页面 duration 选择最后三个合法段，不修改 production 304 映射，也不把 304
  泛化为所有 endpoint 的空段契约。
- **风险**：production 已有 duration 时不存在该越界请求路径；duration 暂时未知时
  scheduler 仍会预取下一段，但这与固定第 8 段的反证不同，真实触发与 304 策略未由本项
  测量。
- **下一步最小验证**：修正后的真实最后三段工作集已通过。若未来观察到 production 在
  duration 未知阶段请求合法末段之外，再单独记录 timeline duration 状态和请求次数；
  不预先把 304 吞成空段。
- **依赖/冲突**：不再阻塞 STATE-007；MP-009 的失败重试仍是独立已确认问题。

## 第一轮结论

当前 bridge 不是“完全错误”：direct SIDX byte offset、`EXT-X-MAP`/byte-range、
loopback 限本机、共享 AVPlayer 时间线、identity/generation，以及弹幕 360 秒/毫秒换算均有
标准或多源支持。优先级最高的可操作风险是：

1. representation 内按 Range 混用 CDN，且未验证内容身份（MP-003）；
2. 关闭 AVPlayer 原生自动等待却没有完整 stall recovery（MP-005）；
3. ready 后失败无持续出口（MP-006）；
4. 弹幕确定性失败被 timeline 驱动成无界重试（MP-009）；
5. 精确清晰度若直接单 player 替换 item，会产生稳定可感知停顿（MP-012）。

SIDX 时间线形态、真实音视频边界、字幕 overlap/location，以及 B 站按身份返回的 4K
能力都缺合规的现场结构证据，应先做最小脱敏验证，再决定扩 parser 或 UI；不能用仓库
fixture 把这些项目改写成“已确认”。

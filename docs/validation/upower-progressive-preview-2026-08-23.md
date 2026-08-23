# 充电专属 durl 试看播放验证记录

- 日期：2026-08-23
- 基线：`31e115d97ebfde2b42dbfcd02b77adaf15fbff29`
- 范围：单段 progressive MP4；不含多段拼接、充电操作、权益绕过或 WBI playurl

## 生产合同

- `PlaybackMedia` 以互斥 case 表达 DASH 或 progressive；DASH + durl 优先 DASH。
- progressive 只接受 playurl 明确声明 `format=mp4`、正时长、正字节数、至少一个安全 URL
  的单段 durl。空、多段、非法时长/大小、非 MP4 和无安全 URL 都有稳定失败语义。
- 权益保留 true/false/unknown 三态。只有 exclusive + preview + 无 DASH + 单段 durl 明确短于当前
  分 P 时长才显示试看时间；普通 durl 不误标。
- 唯一 `AVPlayerEngine`、player host、timeline、identity/generation 和 loopback owner 继续生效。
- 片尾不新增 NotificationCenter owner；只投影已验证 timeline 的当前 identity `.ended`。任何 replay、
  seek away、replace、stop 或旧 identity 快照都清除提示。
- MP4 结束边界取 asset 音视频 track 的最后可观察 `timeRange` 结束，不使用单样本
  `durl.length - 250 ms`。

## 自动验证

- API/Application 定向套件：DASH 回归、单段 durl、DASH 优先、非法 shape、权益三态、
  普通 durl 不误标、试看时长与完整 DASH 分类。
- Range/loopback 定向套件：严格 206、Content-Range、Content-Length、总长度、类型、
  200/redirect 拒绝、短/过长流、206 后失败只断开连接、慢下游的一块有界待转发队列、逐 chunk
  回调、取消、Cookie 剥离、原始开放末尾 Range 和 `sourceURL` stickiness。
- UI/model 定向套件：充电/试看提示紧跟发布时间，loaded/skeleton 共用第四个 metadata slot，
  片尾投影拒绝旧 identity 与非 ended 快照；同一 item 的 seek 不会被排队的 ended 回调覆盖。
- 粉色调整与三路聚焦审查修正完成后，只运行一次收尾最高适用
  `sh Scripts/run-quality-gates.sh app`：static 通过；package 的 631 个测试、
  65 个 suite 通过；App `build-for-testing` 与 `BiliKitMacTests` 通过。签名 Keychain smoke 因该 gate
  明确使用 `CODE_SIGNING_ALLOWED=NO` 而按合同跳过。gate 的唯一临时产物根已自动清理。

## 公开响应与结束边界

- 2026-08-23 以无 Cookie 的生产精确 query 复核目标响应：详情为
  `exclusive=true / preview=true / play=false`，完整分 P 为 2255 秒；playurl 为单段 MP4、无 DASH，
  durl 为 884983 ms、133978058 bytes。只记录非敏感摘要，没有保存或记录签名 URL。
- 另用两个公开普通视频的低清单段 durl 做有界容器探测；该 `fnval=0` 仅用于结束边界验证，
  不改变生产 `fnval=976` 合同，也没有保存媒体：
  - 199333 ms / 6948762 bytes：容器与视频轨结束为 199.400 秒，音轨结束为 199.319433 秒；
  - 6000 ms / 56808 bytes：容器与视频轨结束均为 6.000 秒。
- 第一个普通样本证明通用 `durl.length - 250 ms` 会在真实视频轨结束前约 317 ms 停止；因此生产
  只使用 AVAsset 音视频轨可观察的最晚 `timeRange` 结束，且对两个仓库 MP4 fixture 的契约测试
  也验证没有减去固定 tolerance。

## fresh App 运行时边界

- 最初在受限命令沙箱内读取 Keychain 得到 `0 valid identities found`，该结果不能代表主机状态。
  沙箱外复核实际有两份有效 Apple Development identity；新的唯一 DerivedData 产物通过
  `codesign --verify --deep --strict`，Authority 为 Apple Development，TeamIdentifier 为
  `2B3LZ256AG`，并含 App Sandbox、network client/server 与预期 Keychain group。
- 该 fresh 签名 App 成功恢复既有账户、搜索目标 BV，并在打开详情约 7 秒内进入实际播放；检查时
  已播放至 00:08，AVPlayer 时间长度为 14:45，而详情同一 metadata 行显示
  `充电专属 · 可试看至 14:44 / 完整视频 37:35`。最终视觉调整后，该 access notice 使用系统粉色，
  其它元数据仍为 secondary，skeleton 仍为灰色；定向 layout 测试 2/2 通过。聚焦审查修正和最终
  App Gate 后又从当前源码建立并严格验签一份 fresh Apple Development App，当前运行实例来自该
  最终产物根，而不是 `/Applications`、旧 DerivedData 或先前构建。
- 上述事实证明当前生产路径没有在播放器前因 durl 解码失败；结合逐 chunk 实现与测试，App 没有
  “先收集完整 `Data` 再创建 item”的代码路径。但本轮没有抓取网络 trace 或运行 Instruments，
  因此不声称实际峰值 RSS、精确首帧流量或播放开始时的累计下载字节数。
- 尚未完成目标随机/片尾 seek、自然结束、replay、replace/close、普通 DASH 对照、匿名差异、
  四种系统 App 语言及真人 VoiceOver/FKA；这些仍是人工验收边界。
- 实际系统为 macOS 26.6.2。macOS 15 未实机验证，保持人工边界，不以 macOS 26 代替。

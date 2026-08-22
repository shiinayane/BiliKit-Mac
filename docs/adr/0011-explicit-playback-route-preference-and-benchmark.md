# ADR 0011：显式播放线路偏好与有界测速参考

- 状态：已接受
- 日期：2026-08-22
- 关联：ADR 0002、ADR 0005、`security/M3-threat-model.md`、`security/M4-data-privacy.md`

## 背景

playurl 会返回多个完整媒体候选。不同网络下某一来源可能不可用或持续吞吐不足，但一次样本不能代表
未来所有视频，播放中自动换源还会破坏同一 fMP4 的字节一致性、时间线和现有单一播放器 owner。
因此本能力只允许用户为之后的新播放手动选择线路，并提供一次显式、有界、临时的测速参考。

## 决策

### 手动偏好

- 原生 Settings scene 提供服务端默认、服务端原始 Akamai、服务端原始 bilivideo，以及固定的 18 条
  实验性 bilivideo 镜像线路；默认永远是服务端顺序。
- UserDefaults 只保存 schema version 与稳定 route identifier。未知、损坏或已删除值回退服务端默认。
- 每次新 `AVPlayerEngine.load` 只读取一次偏好。只变换视频 representation；音频和 AI 音轨保持服务端
  顺序。改选不重建当前 item，也不改变 timeline、seek、字幕、弹幕或 Now Playing。
- 原始类别只稳定重排 playurl 返回的完整候选。实验线路只从原始 bilivideo 候选生成：保留 scheme、
  path、query 与签名，只替换为 catalog 中的 bilivideo host；不从 Akamai 派生或迁移 `hdnts`。
- 缺少所选类别或 bilivideo 模板时保持服务端顺序。实验候选 SIDX 失败后仍可回退原始完整候选；SIDX
  成功的 `sourceURL` 继续固定给 init、media 与 loopback Range，不跨来源拼接字节。

### 显式测速

- 只有已登录用户在 Settings 点击后才开始。用户选择 1–3 个不同样本；匿名且有界地扫描固定分区近期
  投稿，最多读取 40 条元数据、8 个详情和 8 个 playurl 候选，并限定不同分区与投稿者。样本必须低播放
  量、足时长、含可消费 AVC，且同时有原始 Akamai/bilivideo；达到所需数量立即停止。测速 playurl
  capability 只映射视频，不要求或测试音频；同一设置窗口内不重复使用已经测过的稿件。
- Cookie 只由现有 authorizer 注入精确 `GET https://api.bilibili.com:443/x/player/playurl`；样本发现
  元数据匿名。映射后的媒体 headers 会去除 Cookie/Authorization，媒体 client 使用 ephemeral、无
  credential、无缓存、拒绝 redirect 的专用 session。
- 每个样本的原始 bilivideo 先由独立 client 建立 SIDX、完整长度与可测区间基准。测试池固定为一条服务端
  原始 Akamai 与 18 条实验 bilivideo 路线，全部共享另一个无凭据 ephemeral session；样本和路线严格
  串行，并在不同样本轮换路线起点，避免固定顺序偏差。
- 每条路线先读取最多 256 KiB SIDX，验证布局与完整长度，再读取 init 与至少两个完整、连续且分散选取的
  SIDX references；单路线每个样本的 init 与媒体正文合计最多 10 MiB。每段吞吐都从请求开始计时，单个
  样本采用最慢媒体段作为该路线的保守值。
- 正文前必须是 206、精确 Content-Range 与精确 Content-Length。200、redirect、越界、过长、断流、
  超时、布局漂移或取消立即停止当前请求。媒体正文只计数并立即丢弃。
- 每个样本的硬上限为 `256 KiB + 19 × (256 KiB + 10 MiB) = 195 MiB`，UI 显示约
  195/390/585 MiB。
  持续吞吐使用从请求开始到精确正文完成的总耗时，因此包含连接、回源、TTFB 与传输。
- 每条线路按完整样本成功率优先排序，再以成功样本保守值的调和平均吞吐、最低值排序；同时展示中位数、
  匿名样本分布与成功次数/总数，吞吐保留一位小数。结果只存在于当前设置窗口；关闭、取消、登出或
  owner 销毁会取消请求并隔离旧 generation。

## 不采用

- 不自动写入测速最快线路，不排序成推荐，也不做后台、定时或播放中学习。
- 不用固定 BVID、热门样本、用户输入 BVID、无限扫描或一次样本推断未来视频。
- 不测试音频/AI 音轨，不保存样本身份、完整 URL、query、host/IP 诊断、原始 metrics 或媒体字节。
- 不在缓冲中重建 item，不修改 loopback 单来源契约，不增加播放器、seek/rate、Now Playing 或队列 owner。
- 不加入实验性的持续大流量对比模式；生产测速只使用上述可证明的 195/390/585 MiB 上限。

## 验证边界

自动测试固定 route 存储回退、URL 变换、候选顺序、单来源固定、认证/匿名边界、19 路串行、流量上限、
SIDX/init/分散完整 reference、严格 Range 协议、取消/generation、成功率与聚合排序及不自动改选。一次真实 19 路大流量
验收、完成态视觉、VoiceOver/FKA 及不同网络/时间/内容温度仍须用户另行批准后执行。

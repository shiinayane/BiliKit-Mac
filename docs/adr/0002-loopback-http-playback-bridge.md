# ADR 0002：使用 loopback HTTP bridge 向 AVPlayer 提供 HLS 媒体

- 状态：已接受
- 日期：2026-07-21

## 背景

M1 原计划通过自定义 URL scheme 和 `AVAssetResourceLoaderDelegate` 同时提供动态 HLS playlist 与 fMP4 媒体分段。自有 AVC/AAC fixture 的实测结果是：

- 自定义 scheme 的 master playlist 可被 `AVURLAsset` 识别，`isPlayable` 为 `true`。
- 当媒体分段也通过 Resource Loader 直接返回数据时，`AVPlayerItem` 以 `CoreMediaErrorDomain -12881` 失败。
- 同一组 SIDX、playlist 和 fMP4 改由 `127.0.0.1` HTTP 服务提供后，`AVPlayerItem` 可进入 `readyToPlay`，播放时间前进，并完成前后 seek。

Apple 的 Resource Loader 文档说明，delegate 负责异步请求时必须持有 loading request 并最终明确完成或失败。更关键的是，Apple 工程师在对应 HLS 问题中说明 AVFoundation 需要直接加载媒体分段以执行自适应逻辑；社区报告的相同失败码也为 `-12881`。

参考：

- [AVAssetResourceLoaderDelegate 请求处理文档](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate/resourceloader(_:shouldwaitforloadingofrequestedresource:))
- [Apple Developer Forums：自定义 scheme 的 HLS 分段失败](https://developer.apple.com/forums/thread/113063)

## 决策

M1 的 DASH→HLS bridge 使用进程内 loopback HTTP server，而不是用 Resource Loader 返回 HLS 媒体字节：

1. server 只绑定 `127.0.0.1`，由系统分配临时端口。
2. 每个 server 实例使用随机、不可预测的 session path。
3. master playlist、media playlist 和媒体代理都使用标准 `http://127.0.0.1` URL。
4. playlist 保存在内存中；媒体请求按 AVPlayer 的 Range 转发到已排序的 CDN candidates。
5. SIDX 下载成功的 CDN 被提升为后续媒体 Range 的首选线路。
6. 上游响应必须通过状态码、`Content-Range` 和 body 长度校验；取消不会触发备用线路。
7. 播放项目替换或释放时停止 server，并取消连接与上游 Task。
8. server 不输出 cookie、token、上游响应 body 或完整鉴权 URL 到诊断信息。
9. 只有全部 SIDX reference 都从 type-1 SAP 开始且 `SAP_delta_time` 为 0 时，master
   才发布 I-frame rendition。I-frame playlist 继续引用同一媒体 route 的完整 fMP4
   fragment byte range；不预读、缓存或重写远端 fragment。
10. 同一 HLS AUDIO rendition group 以默认原声的 SIDX 起始时间为 canonical；按各自 timescale
    归一化后起点不一致的可选 AI 音轨在注册 route 与生成 master 前丢弃，不能把仅有菜单项
    当作同内容、可无缝切换的证明。
11. 用户线路偏好只在新播放进入 SIDX 准备前读取一次，并只调整视频候选。实验 bilivideo 候选
    只能由 playurl 原始 bilivideo URL 替换已核实 host 生成；一旦 SIDX 成功，记录的
    `sourceURL` 继续作为该 representation 的 init、media 与 loopback 唯一远端来源。

不使用非公开的 AVFoundation header 注入选项。若未来 Apple 提供正式、可验证的替代 API，再通过新 ADR 调整。

## 影响

### 正面影响

- AVPlayer 看到的是标准 HLS/HTTP Range 资源，符合已验证的运行路径。
- App 可以安全地添加 B 站 CDN 所需 header，而不把凭据写入 playlist URL。
- CDN fallback、Range 校验与取消仍由自有 Swift 代码控制并可使用 fixture 测试。
- loopback 层也能提供清晰的请求生命周期和最小诊断边界。
- I-frame rendition 复用既有媒体 route，因此 master 加载不会产生额外媒体请求；只有
  AVPlayer 进入 trick play 后才按需请求对应 fragment Range。

### 负面影响

- 需要维护一个最小 HTTP/1.1 server，并严格限制监听地址、路由、方法和 header 大小。
- AVPlayer 请求经过一次本地转发，增加少量复制和调度开销。
- I-frame playlist 传输完整 fragment，而不是只抽取单个 I-frame sample；实现保持无预读和
  可审计 Range 边界，但 trick play 网络流量高于重写单 sample 的方案。
- App 睡眠、播放项目替换和异常退出时的 server 生命周期需要专项测试。
- 不能把 `readyToPlay` 的本地 fixture 结果外推为真实 B 站 CDN 已经通过 M1 Gate。

## 验证

当前自动验证覆盖：

- loopback 仅使用 `127.0.0.1` URL，并返回严格的 `206` 与 `Content-Range`。
- 合成 H.264/AVC 视频与 AAC 音频通过生成的 HLS master/media playlist 进入 `readyToPlay`。
- 播放时间实际前进，暂停、向前 seek、向后 seek 和恢复播放通过。
- 首选 CDN 返回 403 后，SIDX 使用备用线路；后续 AVPlayer media Range 继续优先使用成功线路。
- 合法 `206/Content-Range` 但不可解析的错误页 body 会被拒绝并切换备用线路。
- 快速替换播放项目会取消旧媒体 Range，新项目仍可进入 `readyToPlay`。
- 自制 type-1 SAP fixture 的 master 会发布 I-frame rendition；加载完成前没有 I-frame
  playlist 请求，4 倍速播放后才出现 playlist 与上游 fragment Range，且请求不含认证头。

真实 B 站 AVC/AAC 样本已在 Apple Silicon/macOS 26 开发机与 GitHub Actions macOS 15.7.7 arm64 runner 上通过连续播放、双向 seek、时间轴采样和连续替换审计。受控测试还确认播放项目替换后旧 server 的 route、连接和上游 Task 全部归零。记录见 [`../validation/M1-real-playback-2026-07-21.md`](../validation/M1-real-playback-2026-07-21.md)。

M1 Gate 已通过。更多真实样本和 Intel Mac 覆盖保留为兼容性扩展，不改变本 ADR 的已接受状态。

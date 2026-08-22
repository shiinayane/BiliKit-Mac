# ADR 0012：仅 macOS 26 提供实验性静态响度均一化

- 状态：Conditional GO
- 日期：2026-08-22
- 关联：ADR 0002、ADR 0011、`security/playback-loudness-normalization.md`

## 背景

UGC playurl 在请求 `voice_balance=1` 后可能为当前 CID 与语义音轨响应返回完整的 integrated loudness、
LRA、true peak、threshold 与服务端 target。macOS 26 arm64 的真实运行验证表明，现有
`DASHToHLSBridge → loopback HLS → AVPlayerItem` 可通过无显式 track 的 post-effects
`MTAudioProcessingTap` 修改 Float32 PCM；macOS 15.7.7 x86_64 上同一入口不会进入 prepare/process。
Apple 也没有文档承诺 HLS 支持 Processing Tap。

## 决策

- 功能仅在 macOS 26 显示和运行，标记为实验性且默认关闭。设置只在下一次新播放开始时读取一次；
  macOS 15 即使存储中存在开启值，也不创建或安装 tap。
- BiliAPI 仅为 UGC original 与每个 AI/语言 playurl 请求加入 `voice_balance=1`。每个响应的完整有效
  metadata 只绑定自己的语义音轨；同轨码率 representation 可共享，不跨语义音轨复用。
- 策略使用服务端 target，按 `min(targetI-measuredI, targetTP-measuredTP, +6 dB)` 计算，再以
  `-12 dB` 保护衰减下限并转换为 `10^(dB/20)`。不使用 `target_offset`，不加入 limiter、compressor、
  实时测量或 target slider。
- 唯一 `AVPlayerEngine` 在替换新 item 前安装一个 tap，首帧直接使用默认语义音轨 gain；语义音轨切换
  只更新该 tap 的原子 target，并在实时线程内做约 150 ms 线性 ramp。用户 volume/mute 仍由现有
  `AVPlayer` 与 `PlaybackPreferencesController` 管理，不写回 normalization gain。
- 缺少/异常 metadata、true-peak 无法验证、音轨无法唯一映射、tap 创建失败或系统从未调用
  prepare/process 时均保持 unity，播放本身不得失败、静音或重建 item。

## 约束与证据边界

Processing Tap 的 HLS 接入是 macOS 26 当前实现行为，不是 Apple 的公开保证。未进入 callback 只能表现为
静默 unity，产品无法可靠宣称检测到了所有系统失效。未来系统更新必须重新验证；macOS 15 永远走无 tap
路径。PGC、Dolby、FLAC、第二音频管线、私有 API、下载/预扫和输出设备级 DSP 不在本决策范围。

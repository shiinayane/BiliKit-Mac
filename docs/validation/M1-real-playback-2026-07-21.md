# M1 播放可行性收尾验证——2026-07-21

## 结论

M1 Gate 通过，可以进入 M2。

指定游客 AVC/AAC DASH 样本经 loopback DASH→HLS bridge 进入 `AVPlayer`，已在本地 macOS 26 环境和 GitHub Actions macOS 15 环境完成连续播放、双向 seek、视频时间轴采样与连续播放项目替换。受控测试覆盖 403、无效 `Content-Range`、HTML 错误页、CDN fallback、取消传播和旧 server 资源释放。

这份结论证明当前 AVPlayer-first 技术路线满足进入产品纵向接入阶段的可行性门槛，不代表所有视频编码、CDN、账号状态和网络环境都已兼容。

## 真实网络运行环境

### 最低系统云端验证

- GitHub Actions：[运行 29810357925](https://github.com/shiinayane/BiliKit-Mac/actions/runs/29810357925)
- 验证提交：`a811028692de08789f03d60aa6323130ac02dc40`
- 系统：macOS 15.7.7（24G720），`arm64`
- Runner image：`macos-15-arm64`
- 工具链：Xcode 16.4（16F6）、Swift 6.1.2
- Package deployment target：macOS 15

### 本地交叉验证

- 系统：macOS 26.5.2（25F84），Apple Silicon（`arm64`）
- 工具链：Xcode 26.6（17F113）、Swift 6.3.3
- 同一收尾矩阵结果：通过

deployment target 只证明编译目标，不替代对应系统上的运行验证。本次 macOS 15 runner 已实际执行真实网络播放探针；Intel Mac 尚未覆盖，作为兼容性扩展保留，不阻塞 M2。

## 样本与选中轨道

- BVID：`BV1h4KU66ENd`
- CID：`40123826438`
- 游客请求画质：32（验证时对应 480p）
- 视频：representation 32，`avc1.640033`，486634 bit/s
- 音频：representation 30216，`mp4a.40.2`，65676 bit/s
- 观测到的候选 CDN 域名族：`bilivideo.com`、`akamaized.net`
- AVFoundation 报告的资源时长：1753.03 秒

记录中刻意不保存带签名的媒体 URL 或 API 响应 body。样本和游客接口会动态变化，未来单次失败必须结合受控回归测试判断，不能直接归因于 bridge 回归。

## macOS 15 收尾矩阵

手动触发工作流使用以下参数：

```sh
xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliPlaybackProbe \
  --bvid BV1h4KU66ENd \
  --cid 40123826438 \
  --play-seconds 30 \
  --forward-seek 30 \
  --backward-seek 5 \
  --seek-cycles 6 \
  --replacement-cycles 12 \
  --max-memory-growth-mib 64
```

云端记录结果：

```text
ready: duration=1753.03s selected-tracks=avc+aac
play: reached=30.02s
seek-forward/backward: 6 cycles ok
timeline: samples=552 max-video-delta=0.48s
replacement: 12 cycles ok
memory: baseline=87.75MiB peak=87.75MiB final-growth=0.00MiB
RESULT: PASS
```

本地同参数运行得到 673 个时间轴样本，最大视频偏差 0.03 秒，12 次替换后最终 RSS 增量同样为 0 MiB。

## 受控回归与资源证据

- Swift Package 测试 26 项全部通过。
- 合成 H.264/AVC 与 AAC fixture 覆盖起播、暂停、恢复和双向 seek。
- 首选 CDN 返回 403 时切换备用线路。
- 错误或不匹配的 `Content-Range` 被拒绝。
- 合法 Range 包装的 HTML/错误 body 被拒绝并切换备用线路。
- 快速替换会取消旧媒体 Range，取消不会错误触发 fallback。
- 连续 12 次替换后，每个旧 loopback server 均为停止状态，注册 route、活动连接和上游 Task 数均为 0；播放器释放后最后实例也归零。
- App 单元测试 1 项通过，无签名 `build-for-testing` 通过。
- 常规 GitHub Actions 的 macOS 15 与 macOS 26 构建和测试任务通过。

## 测量边界

- 时间轴采样比较 `AVPlayerItemVideoOutput` 的视频 presentation timestamp 与 `AVPlayer` timebase，用于发现视频帧明显脱离播放器时间基的情况。
- 该指标配合 AVC/AAC 同时选轨、播放时间持续前进和 seek 后恢复，足以支撑 M1 技术可行性判断；它不是通过独立音频采集完成的声学口型同步测试。
- RSS Gate 检查连续替换后的最终增长，连接和 Task 是否释放则由确定性的 server 诊断测试单独保证。
- 单个游客样本不能代表全部编码、清晰度、地区、登录态和 CDN；这些兼容性覆盖随 M2 纵向接入继续扩充。

## Gate 对照

| M1 Gate | 证据 | 结果 |
| --- | --- | --- |
| AVC 与 AAC 稳定起播并保持同一播放时间基 | 30 秒真实播放、552 个视频时间轴采样、合成双轨回归 | 通过 |
| 中段前后 seek 后继续播放 | 6 轮双向 seek，12 个目标位置全部通过 | 通过 |
| 403、错误 Range 或错误页时尝试备用线路 | 受控 HTTP/CDN fallback 测试 | 通过 |
| 取消或替换后无悬挂请求和持续资源增长 | 12 次替换、旧 server 资源归零、最终 RSS 增量 0 MiB | 通过 |

因此 M1 于 2026-07-21 关闭，下一阶段为 M2 游客浏览到播放的纵向闭环。

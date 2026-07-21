# M1 真实播放验证——2026-07-21

## 结果

指定样本在当前环境中通过。游客 AVC 视频轨与 AAC 音频轨经 loopback DASH→HLS bridge 进入 `AVPlayer`，播放时间超过 1 秒，并在向前、向后 seek 后恢复播放。

这份结果只证明当前样本和环境。macOS 15/26 CI 已通过，但长时间资源审计和更广的 CDN/失败矩阵仍未完成，因此尚不能关闭 M1 gate。

## 环境

- 日期：2026-07-21（Asia/Tokyo）
- 硬件架构：Apple Silicon（`arm64`）
- 运行系统：macOS 26.5.2（25F84）
- 工具链：Xcode 26.6（17F113）、Swift 6.3.3
- Package deployment target：macOS 15

deployment target 只能证明编译兼容性，不能替代对应系统上的运行验证。GitHub Actions 的 `macos-15` 与 `macos-26` 离线测试和 App 单元测试均已通过；真实 B 站探针仍只在上述本机环境运行。

## 样本与选中轨道

- BVID：`BV1h4KU66ENd`
- CID：`40123826438`
- 游客请求画质：32（验证时对应 480p）
- 视频：representation 32，`avc1.640033`，486634 bit/s
- 音频：representation 30216，`mp4a.40.2`，65676 bit/s
- 观测到的候选 CDN 域名族：`bilivideo.com`、`akamaized.net`
- AVFoundation 报告的资源时长：1753.03 秒

记录中刻意不保存带签名的媒体 URL 或 API 响应 body。样本和游客接口都可能动态变化，也可能在 bridge 实现不变时失效。

## 复现方法

从仓库根目录显式运行。该探针会发起真实网络请求，不属于 CI：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run \
  --package-path Packages/BiliKitCore \
  BiliPlaybackProbe \
  --bvid BV1h4KU66ENd \
  --cid 40123826438 \
  --play-seconds 1 \
  --forward-seek 30 \
  --backward-seek 5
```

记录结果：

```text
ready: duration=1753.03s
play: reached=1.03s
seek-forward: target=30.00s ok
seek-backward: target=5.00s ok
RESULT: PASS
```

探针只输出 BVID/CID、codec 元数据、bandwidth、CDN hostname 和播放结果。它不接受凭据，也不会输出带签名的媒体 URL 或响应 body。

## 配套回归检查

- Swift Package 测试 25 项全部通过，包括合成 AVPlayer 起播/seek、严格 Range 校验、CDN fallback、无效 body 拒绝以及取消/替换。
- App 单元测试 1 项通过，并完成无签名 macOS 构建。
- 全新 SwiftPM 编译命令以 `arm64-apple-macosx15.0` 为 target；探针 Mach-O 报告 `minos 15.0`。
- 构建后的 App 报告 `LSMinimumSystemVersion` 为 `15.0`。
- GitHub Actions 的 macOS 15 与 macOS 26 任务均已通过。

## M1 剩余证据

- 在 macOS 15 runner 上显式运行真实播放探针；条件允许时覆盖 Intel。
- 测量更长播放时段及多次 seek 后的音画同步。
- 在保留有效备用 CDN 的同时，注入真实或受控的 403、无效 `Content-Range` 和 HTML 错误响应。
- 审计连续替换和长时间播放中的连接、存活 Task 与内存变化。

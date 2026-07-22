# M4 统一播放时间线验证——2026-07-22

## 当前结论

M4.1 Gate 已通过，可以进入 M4.2 字幕纵向切片。

仓库现在只有一个平台无关的播放时间轴来源。`BiliApplication` 定义播放项目 identity、位置、时长、速率、状态和 discontinuity generation；`BiliPlayback` 负责把 AVPlayer 的周期时间、速率、控制状态、播放结束和时间跳变映射为该快照。Feature、字幕和后续弹幕不需要持有 `AVPlayer`、`CMTime`、KVO 或 observer token。

## 环境

- 日期：2026-07-22
- 系统：macOS 26.5.2（25F84），Apple Silicon `arm64`
- 工具链：Xcode 26.6（17F113），Apple Swift 6.3.3
- 媒体输入：仓库自制 AVC/AAC fragmented MP4 fixture，经现有 loopback HLS bridge 送入真实 AVPlayer

## 实现边界

- `PlaybackItemIdentity` 只在内存表达 BVID/CID，字符串和调试描述固定脱敏；时间线不写入日志、UserDefaults 或持久化。
- 每个播放项目取得独立内部 token。新项目建立后，旧 token 的位置更新和 clear 都会被拒绝，不能覆盖当前 identity。
- `AsyncStream` 使用 `bufferingNewest(1)`，每个订阅者立即取得当前快照；订阅取消时移除 continuation，不形成无界队列。
- AVPlayer periodic time observer 使用 30 Hz 间隔。KVO、通知和周期观察由独立 observer bag 持有，在替换、失败、取消、stop 和销毁时统一移除。
- 新加载、显式 seek、外部时间跳变和 clear 都推进 discontinuity generation；显式 seek 的 AVPlayer 跳变通知会去重，避免同一次操作重复推进。
- 关闭详情与切换视频都会 stop 当前播放器，移除 `AVPlayerItem`、停止 loopback asset 并清空时间线 identity，而不只是暂停。
- 播放倍速只接受有限的 `0.25...4`；非法、NaN、无限或负数时间线数值不会进入公开快照。

## 确定性测试

Application 虚拟状态测试覆盖：

- ready → 2× playing → paused；
- 向前与向后 seek 均推进 discontinuity generation；
- 新播放项目拒绝旧 token 的位置更新与清理；
- 独立订阅建立、当前快照投递与取消后 continuation 归零；
- 非法数值归一化，以及 identity 的字符串/调试描述脱敏。

Playback 集成测试使用自制媒体驱动真实 AVPlayer，覆盖：

- ready 后位置随播放推进，2× 速率进入时间线；
- pause 后速率归零且状态为 paused；
- 精确 seek 更新位置并推进 generation；
- 非法倍速失败关闭；
- stop 后 `currentItem`、identity 和播放状态归零；
- 既有替换加载测试继续证明旧媒体请求取消与 loopback 资源释放。

Feature 测试同时固定 identity 从详情 BVID/分 P CID 传入播放器，以及切换选择、reset 和旧任务返回时的 stop/代次隔离。

## 本地回归

以下验证均在上述环境通过：

```sh
sh Scripts/check-architecture.sh
sh Scripts/check-secrets.sh
sh Scripts/check-project-contract.sh
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/BiliKitCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BiliKitMac.xcodeproj -scheme BiliKitMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/BiliKitMac-derived CODE_SIGNING_ALLOWED=NO \
  build-for-testing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project BiliKitMac.xcodeproj -scheme BiliKitMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/BiliKitMac-derived CODE_SIGNING_ALLOWED=NO \
  test-without-building -only-testing:BiliKitMacTests
```

- Swift Package：124 项测试、22 个套件通过。
- App：无签名 `build-for-testing` 与 composition 测试通过。
- 无参数 App 测试中的签名 Keychain smoke 与 M4 已登录现场探针按设计跳过；它们不属于 M4.1 时间线 Gate。
- 架构、秘密、工程静态契约和 `git diff --check` 通过。

## 尚未覆盖的边界

- 本记录证明统一时间线与 AVPlayer 适配语义，不代表字幕 cue 选择、弹幕调度、overlay 渲染或持久化已经实现。
- 本地只运行当前 arm64 macOS；macOS 15/26 CI 需在后续提交推送后确认，Intel 与更多真实视频属于兼容性扩展。
- 30 分钟稳定性、连续 seek、resize、全屏、最大同屏和 RSS 指标属于 M4.4/M4 收口 Gate，不由本次短时合成媒体测试代替。

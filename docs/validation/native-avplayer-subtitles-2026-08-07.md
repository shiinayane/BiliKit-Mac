# AVPlayer 原生字幕验证——2026-08-07

## 结论

当前生产 Composition 只保留一个字幕呈现 owner：`AVPlayerEngine` 在同一次媒体 load 中
冻结字幕目录和 HLS route，AVPlayer 通过系统媒体选择菜单呈现轨道；默认不选择字幕。
旧 `SubtitleViewModel`、独立字幕 controls 和 SwiftUI 字幕 overlay 已从当前代码删除，
弹幕仍由同一个 `AVPlayerView` 的 `contentOverlayView` 呈现。

本记录不保存视频标识、标题、字幕正文、完整 URL、账号信息、凭据或真实 UI 截图。

## 环境与范围

- macOS 26.6.1，Apple Silicon arm64；
- Xcode 26.6（17F113）；
- 原生字幕实现提交：`7f48242`；
- 旧呈现层清理：提交后的当前工作树；
- 真实观察使用已登录的单分 P 公开视频，输入和内容均未写入仓库。

## 确定性证据

最高适用命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  BILIKIT_COMPACT_LOGS=1 \
  sh Scripts/run-quality-gates.sh app
```

结果：

- static architecture、secret、project contract、Swift format 与 diff 检查通过；
- Swift Package 244 项测试、38 个 suites 通过；
- App build-for-testing 通过；
- App 测试 15 项通过，4 项显式环境 probe 按契约跳过，无失败。

受控测试覆盖：

- master 中每条字幕使用用户标签，且 `DEFAULT`、`AUTOSELECT`、`FORCED` 均为 `NO`；
- WebVTT `X-TIMESTAMP-MAP`、非零 EPT、转义、Content-Length、HEAD、Range 与并发请求；
- 字幕目录与媒体并行准备、两秒有界 grace、迟到目录丢弃和 media-only 降级；
- generated body 共享加载、每 route 最多两次尝试、stop/unregister 取消与 terminal 状态；
- A→B→A 中非协作旧 reset 串行，旧 generation 不能启动 B 或覆盖新 A；stop 后排队
  load 不会恢复；
- unsafe label、catalog 失败和 variant timeline origin 不一致只移除字幕，不阻断媒体；
- App 生命周期测试证明登录状态变化会关闭 playback destination 并调用 playback stop，
  重新登录不会私自恢复已关闭的视频；Engine 测试另行证明 stop 会释放 player item、
  loopback server 与原生字幕资源；
- 单一 `AVPlayerView` 在内容更新与媒体替换期间保持 identity，Back/关窗后断开 player。

## 签名真实观察

签名 Debug App 使用生产 Composition、现有 Keychain 登录态和正式字幕 repository：

1. 脱敏目录 probe 返回 4 条 raw/usable 轨道；
2. 真实系统字幕菜单显示“中文”“中文（AI）”“English（AI）”“日本語（AI）”；
3. 详情页没有旧字幕 Picker 或 SwiftUI 字幕 overlay，弹幕设置仍可见；
4. 打开菜单前字幕正文请求计数为 0；选择轨道后观察到正文请求启动；
5. 整个详情页仍只有一个实际 `AVPlayerView`。

上述第 4 项只证明生产链路按需发起正文请求，不证明该次真实正文成功转为 WebVTT、
字幕 cue 已实际显示或时间同步准确。受控 WebVTT/HLS/AVFoundation 测试只覆盖构造、
时间映射、AVPlayer 识别与选择，不覆盖最终视觉呈现。

## 保留边界

- 目录 grace 固定为两秒；正文每 route 最多两次尝试，耗尽后需重新加载视频；
- catalog 或原生字幕失败时保持 media-only，不自动恢复已经删除的旧 overlay；
- 登录状态变化会关闭当前视频；重新登录不恢复已关闭的视频、播放位置或速率；
- 非协作 repository 无法被 Swift task 强制终止；生产 URLSession transport 仍依赖其取消
  契约，caller hard bound 与迟到结果丢弃已有确定性覆盖；
- 未重新执行 VoiceOver、Full Keyboard Access、不同系统版本、更多字幕 CDN/字段组合、
  长时间播放或分发构建验证。

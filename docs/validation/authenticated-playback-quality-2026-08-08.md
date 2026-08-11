# 登录态自动画质验证

> 日期：2026-08-08（Asia/Tokyo）
> 基线：`7fdb42ef623f5037ebca0634ab8e978b7e77a212`
> 范围：精确 legacy playurl 授权、失败分类、媒体隔离、既有单 item 原生 ABR 与生命周期。

## 1. 产品结果与非目标

本 Stage 让已有有效登录会话的用户，在服务端实际返回更多且生产 decoder 可消费时，有机会
取得更多 AVC/AAC representations。所有可用视频 representations 继续进入既有
DASH→loopback HLS multivariant master，由同一个 `AVPlayerItem` 和 `AVPlayer` 原生 ABR
选择。游客仍使用原匿名自动画质。

本 Stage 不提供手动画质菜单、不强制首档、不承诺 4K、不增加 HEVC/AV1 产品范围、不创建
第二 player/item host，也不恢复 `/x/player/wbi/playurl` 或设备画像实验。

## 2. 安全与失败契约

- authorizer 只允许未编码的 `GET https://api.bilibili.com:443/x/player/playurl` 与六项精确 query：
  `bvid`、`cid`、`qn`、`fnval`、`fnver`、`fourk`。
- 只有 Keychain 明确无 item 才匿名请求；过期/损坏、Keychain/authorizer 故障均不降级。
- HTTP 403/412、业务拒绝、非 JSON 与 redirect 不匿名重试；业务 `-101` 只在已授权 playurl
  上映射为认证失效，并由 App 层触发既有 revalidation。
- playurl 的 Cookie 不进入 `VideoPlayback.mediaHeaders`；相关推荐仍完全匿名。媒体 CDN、图片、
  字幕正文与 loopback Range server 的 transport 和 owner 均未修改。

## 3. owner 与生命周期

- `BiliCredentialRequestAuthorizer`：凭据读取、精确请求 allowlist、Cookie 临时注入。
- `BiliAPIClient.playback`：按凭据分类选择一次授权或匿名请求，解码全部可消费 representations。
- `BiliAPIClient` 认证 session epoch：把授权请求绑定到当时的 transport，并在授权后、发送失败和
  响应写回前拒绝已经失效的旧 epoch。
- `GuestVideoViewModel`：视频/分 P/retry/cancel generation，并只对确认认证失效发布重校验意图。
- `AppRootView`：跨 Auth/Browse 协调 revalidation；真实 signed-in/signed-out 边界沿既有行为
  关闭播放。
- `AVPlayerEngine`：保持唯一 player、item、bridge、loopback server 与第二层 UUID generation；
  本 Stage 没有修改该文件。

## 4. 自动验证

- 定向 Package：63 tests／4 suites 通过，覆盖 allowlist、无凭据匿名、非 missing 凭据失败、
  403/412/业务拒绝不重试、`-101` 认证失效、媒体 header 无 Cookie、相关推荐匿名与
  ViewModel 重校验信号，以及 stale ABA 授权失败隔离。
- 完整 Package：293 tests／42 suites 通过；其中 single-item ABR、replacement、ABA、取消、
  stop、loopback Range 与资源释放测试继续通过。
- 最高 `app` gate：静态契约与完整 Package 通过；默认并行的 Xcode `build-for-testing`
  多次触发依赖扫描竞态，虽 target graph 明确包含 `BiliApplication -> BiliModels`，仍临时报
  `BiliApplication is missing a dependency on BiliModels`。同一最终 diff 使用 fresh
  DerivedData 和 `-jobs 1` 的完整 `build-for-testing` 通过，随后全部 `BiliKitMacTests`
  `test-without-building` 通过。该工具链竞态因此保留为未关闭的 gate 环境问题，而不是把
  串行替代记作默认 gate 通过。
- App wiring 定向测试通过：playurl 返回认证失效后触发第二次 session restore，并仅在
  `signedIn -> signedOut` 边界关闭导航与播放；固定时间只作为 timeout。
- 独立并行审查发现并修复九项认证边界：percent-encoded path 绕过、authorization await
  跨 epoch 发送旧 Cookie、revalidation 确认 signed-out 时未失效其他认证 API、初次恢复的
  失效凭据未推进 epoch、迟到 QR validation 可能在登出后重写 Keychain，以及登出清理期间
  restore 重入、ViewModel revalidation 替换正在进行的 logout owner、任务取消后仍进入匿名
  fallback，以及 missing fallback sentinel 跨 epoch。fallback 现在在同一个 response owner 内
  绑定原 transport/epoch。相关新增用例所在的四组定向测试共 63 个；异步新增用例完全由事件／
  continuation 驱动，并覆盖忽略取消的迟到响应。

## 5. 签名真实 A/B

签名探针使用同一公开样本首分 P，各执行一次匿名与登录 playurl，不做 WBI、不重试。探针
只允许记录 HTTP/业务类别、AVC/AAC 数量、quality ID/高度集合、最高可消费高度与媒体
header 是否无 Cookie；账号身份、内容标识、标题、URL、媒体 host、Cookie、响应正文和原始
产物均不保留。

本轮结果：

| 请求 | HTTP／业务 | AVC／AAC | quality ID | 高度集合 | 最高可消费高度 | 媒体 Cookie |
| --- | --- | ---: | --- | --- | ---: | --- |
| 匿名 | 2xx／0 | 2／3 | 16, 32 | 360, 480 | 480 | 无 |
| 登录 | 2xx／0 | 5／3 | 16, 32, 64, 80, 112 | 360, 480, 720, 1080 | 1080 | 无 |

该结果只代表 2026-08-08 的单账号、单内容、单时点：它证明本次精确 legacy 授权请求比匿名
取得更多生产可消费 AVC representations，不证明所有内容/账号都提高，也不构成 4K 保证。
随后用户在真实 App 中人工确认登录后能够取得高清画质；该观察不记录账号或内容标识，也不
扩张上述单账号、单内容、单时点边界。

## 6. 未覆盖边界

- 真实登录远端 App UI 已观察登录播放取得高清，但没有在同一人工序列中记录当前 item 的
  网络 ABR、相关推荐重取与登出清理；API A/B 与 wiring test 不能替代这些
  尚未观察的端到端步骤。
- 真实网络中的 ABR 升降档时机由 AVFoundation 决定，不从一次探针推导普遍策略。
- 本 Stage 不验证 HEVC/AV1、会员/DRM/区域能力，也不绕过服务端限制。
- VoiceOver、Full Keyboard Access 与手动画质 UI 不在本 Stage 范围。

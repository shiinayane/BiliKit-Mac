# 登录态 AI 音轨协议验证

> 日期：2026-08-09（Asia/Tokyo）
> 基线：`44c0d3d230ecb7a3c7a7ecd9850bce5a4bd6b51f`
> 范围：语言目录、精确 `cur_language` 授权、独立 AI 媒体事实与 Cookie 终止边界。

## 1. 目标与非目标

本阶段验证登录态 legacy playurl 是否能在语言目录基础上，用唯一的可选
`cur_language` 取得与原声不同、且现有 AAC/SIDX 链路可以消费的媒体。验证通过后，只扩展
`BiliCredentialRequestAuthorizer` 的精确 query allowlist，并保留可重复的显式签名探针。

本阶段不把语言目录映射为生产 `PlaybackAudioTrack`，不改变 `BiliAPIClient.playback` 的生产
请求，不让 bridge 接受多条音轨，也不加入系统或自定义选择 UI。目录存在本身不视为取得 AI
媒体；这些产品能力继续由后续阶段承担。

> 后续状态：上述非目标中的生产语义轨、multi-rendition bridge 与系统 media selection 已由
> 同日阶段 5 实现并验证，见
> [`authenticated-ai-audio-stage5-2026-08-09.md`](./authenticated-ai-audio-stage5-2026-08-09.md)。

## 2. 安全契约

- endpoint 仍只能是未编码的
  `GET https://api.bilibili.com:443/x/player/playurl`。
- 原六项 query 保持不变；可选的第七项只能是唯一 `cur_language`，值必须满足受限 ASCII
  BCP 47 形态。空值、重复键、额外参数、编码路径字符和非法语言值全部拒绝。
- Cookie 只由 `BiliAuth` 临时加入上述 API 请求，在响应边界终止。媒体 SIDX Range 使用独立
  ephemeral、无 Cookie、无缓存、拒绝重定向的 transport。
- 探针不输出或保存账号身份、BVID/CID、标题、语言标题、完整媒体 URL/host、Cookie、响应
  正文或原始构建/测试产物。

## 3. 签名真实验证

签名测试宿主读取既有 Keychain 会话，对一个已确认公开样本执行一次基础登录态 playurl，
从内存语言目录选择一项，再执行一次带 `cur_language` 的请求。随后对返回的第一条 AAC
representation 执行一次严格 SIDX Range 读取。探针不自动重试。

脱敏结果：

| 观察 | 结果 |
| --- | --- |
| 语言目录 | 2 项，`production_type` 集合为 `[2]` |
| 服务端当前语言 | 与所选目录项一致 |
| 原声／AI AAC representations | 3／3 |
| AAC 资源路径集合 | 忽略 scheme、host、query、fragment 后仍不同 |
| AI 媒体 SIDX | 可解析，存在媒体 references 与完整长度 |
| 媒体 Range Cookie | 无 |

这组证据证明在本账号、单一公开内容和该时点，目录中的语言请求确实返回了资源路径不同且
可读取的 AAC 媒体，而不只是 CDN host 或签名 query 变化。它不证明所有账号、内容或地区
都提供 AI 音轨，也不把
`production_type=2` 的产品语义外推到未经验证的其他值。

一次附加复验尝试要求基础响应同时提供可验证的原声语言与 production type，以自动判断 AI
目标语言是否属于翻译；该条件在发起 AI 媒体请求前即失败。因此当前证据不支持自动添加
`public.translation`。后续只有取得独立、可靠的原声语言来源并确认目标语言不同，才能在
`public.machine-generated` 之外增加 translation 特征。

## 4. 自动验证与回退

- authorizer 单测覆盖基础六项 query、合法 `cur_language`，以及空值、大写 primary、编码
  路径字符和重复参数拒绝。
- 探针只有在目录受限、服务端回显匹配、AAC 规范化资源路径集合变化、SIDX 可解析且媒体
  无 Cookie 时
  才输出成功摘要；任一条件失败即失败关闭。
- 若远端协议漂移，生产播放仍不会发送 `cur_language`，因此保持既有单条原声音轨行为；可
  独立撤回第七项 allowlist 与探针，不影响阶段 1–3 的语义模型和 HLS master metadata。

## 5. 仍待后续阶段关闭

- 平台 production type 与 `public.machine-generated`／`public.translation` 的精确映射；只有
  音频源语言和目标语言证据充分时才能标记 translation。
- 系统菜单显示名称的可控程度，以及需要精确“原声／语言（AI）”时的自定义选择 UI。
- 多内容、不同账号/地区、签名 App 播放、取消/A→B/过期 generation、VoiceOver 与 Full
  Keyboard Access 的真实验收。

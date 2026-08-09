# 登录态 AI 多音轨生产验证

> 日期：2026-08-09（Asia/Tokyo）
> 基线：阶段 1–3 提交 `44c0d3d230ecb7a3c7a7ecd9850bce5a4bd6b51f`，加当前阶段 4–5 diff
> 范围：生产目录解码、语义轨映射、multi-rendition HLS bridge 与系统 AVPlayer media selection。

## 1. 生产契约

- 基础 playurl 始终先构造唯一默认 `.original` 语义轨，轨内保留全部 AAC bitrate
  representations。
- 只有已配置授权器、目录 `support=true`、条目数 1–8、语言/标题受限、无重复语言且
  `production_type=2` 时，才尝试 AI 请求。明确无凭据时保持原声；认证失效或授权器不可用
  仍失败关闭，不能伪装成游客成功。
- 每项 AI 响应必须回显所选语言、含可消费 AAC，并且忽略 scheme/host/query/fragment 后的
  资源路径集合与原声及已接受 AI 轨完全不相交。失败或漂移条目被省略，不影响原声。
- AI 轨为 `.machineGenerated`、非默认、可自动选择；HLS 只写
  `public.machine-generated`。由于基础响应不能稳定证明原声语言，当前不自动写
  `public.translation`。
- bridge 为每条语义轨创建带轨序号的独立 playlist/media route，避免不同轨复用相同
  representation ID 时碰撞；所有 rendition 共享同一个 HLS audio group，并且恰好一条原声
  为 default。任一 AI SIDX 或完整媒体长度读取失败只删除该可选轨；音频格式 metadata
  解析失败仅省略 `CHANNELS`／`BIT-DEPTH`／`SAMPLE-RATE`。原声索引或长度失败仍终止加载。
- 所有音轨、routes、AVPlayer item 和 media selection 都属于既有 `AVPlayerEngine` generation；
  stop、替换、取消与过期结果继续通过同一 owner 清理。

## 2. 自动验证

- API 测试用全假值响应证明基础请求后只按目录发出精确 `cur_language` 请求，并产生
  `original + machineGenerated` 两条语义轨；Cookie 不进入媒体 headers。
- builder 测试证明多条 audio renditions 共享 group、保留 default/autoselect、输出
  original/machine-generated characteristics、不输出 translation，并使用所有音轨中的最大
  bitrate 计算 variant 带宽。
- bridge 测试证明两个具有相同 representation ID 的语义轨仍得到不同 loopback routes；AI
  来源失败时 master 退化为单原声。
- fresh `app` gate 覆盖静态契约、完整 Package、Xcode build-for-testing 与 App unit tests；
  最终状态以本阶段最后一次 gate 结果为准。

## 3. 签名真实验收

同一显式公开样本和既有 Keychain 会话的脱敏结果：

| 观察 | 结果 |
| --- | --- |
| 目录／候选 production type | 2 项／`[2]` |
| 原声／单次 AI AAC representations | 3／3 |
| 生产 AI 语义轨 | 2 |
| AVPlayer audible options | 3 |
| 系统 media option 切换 | 从默认项切到另一项成功 |
| AI SIDX／媒体 Cookie | 可读／无 |

账号身份、BVID/CID、标题、语言标题、完整 URL/host、Cookie、响应正文、菜单文案与原始测试
产物均未保留。该结果仍只代表单账号、单内容、单时点，不证明所有内容、账号或地区都有 AI
音轨，也不证明系统 AVPlayerView 会逐字显示 HLS `NAME`。

## 4. 当前边界

- 当前优先使用系统 AVPlayer media selection；系统可能本地化或替换显示名。只有产品要求
  精确逐字显示“原声／语言（AI）”时，才另行设计自定义选择 UI。
- 没有可靠原声语言证据前不添加 translation；普通人工字幕也继续不添加
  `public.original-content`。
- 尚未做多内容/账号/地区矩阵、真实 App 菜单人工截图、VoiceOver、Full Keyboard Access、
  A→B→A 多音轨远端替换和登出中断验收。
- I-frame trick play 与本阶段独立，未加入任何 I-frame playlist、预取或额外媒体预算。

# 语义音轨与 HLS metadata 阶段 7 真实验收

> 日期：2026-08-09（Asia/Tokyo）
> 范围：`16e6e443b9eebe40374c3f451480c8eaa759c665` 加 Stage 7、系统菜单观察与审查修正 diff
> 环境：Apple Silicon、macOS 26、Xcode 26.6；开发签名 App test host 与真实公开媒体。

> 当前状态：审查前真实证据保留为有界历史观察；审查修正后的最终 App gate 与登录态探针
> 需要分别重新记录。未重新执行登录态探针前，不把旧运行外推为最终 diff 的远端验收。

## 1. 范围与安全边界

用户显式提供一条已知包含 AI 音轨目录的单分 P 公公开视频。本次准备流程用无认证 pages
请求确认唯一 CID，再把 BVID 与该 CID 交给开发签名 test host；探针 runner 本身仍要求两项
显式输入，不独立重查二者关系。输入只写入权限为 `0600` 的临时 plist；BVID、CID、账号、
远端原始语言标题、媒体 host、完整 URL、Cookie、响应正文、原始日志和 xcresult 均未写入
仓库或本记录，并在验证后删除。

Cookie 只进入既有精确 playurl 授权边界。SIDX、媒体 CDN 与 loopback 使用无 Cookie、无
Authorization、无缓存且拒绝重定向的独立 transport。探针只记录计数、布尔结果和
`production_type` 集合；运行结束前对临时日志执行秘密、URL 与内容标识扫描。

## 2. 登录态 AI 音轨与系统 media selection

脱敏观察如下：

| 观察 | 结果 |
| --- | --- |
| AI 语言目录 | 2 项，`production_type` 集合为 `[2]` |
| 原声／所选 AI AAC representations | 3／3 |
| 生产 AI 语义轨 | 2 |
| AVPlayer audible options | 3 |
| 系统 media option 切换 | 从默认项切换到另一项成功 |
| option 友好名称 | 全部非空，且没有裸 BCP-47 language tag |
| AI SIDX／媒体凭据 | 可读／无 Cookie、无 Authorization |

该结果证明当前生产 `BiliAPIClient → PlaybackManifest → AVPlayerEngine → DASHToHLSBridge`
链路在这条真实样本上形成一条原声和两条 machine-generated 语义轨，并由同一个
`AVPlayerItem` 暴露为三个可选择 audible options。

开发签名 App 另行完成可见系统菜单观察：audible 菜单能区分原始与 machine-generated
选项，legible 菜单能区分人工与 machine-generated 字幕；全部为系统生成的友好语义，未
出现裸 BCP-47 标签。具体语言组合和逐字菜单文案只存在于当次会话，不写入验证记录。该观察
同时证明系统会本地化或替换 HLS `NAME`，不应外推其他系统版本或语言环境逐字相同。

同语言 AI 字幕的 raw `NAME` 仍与人工字幕不同，以满足同一 HLS rendition group 内的唯一性；
`_hls.localized-rendition-names` 只在基础标签相同且 `CHARACTERISTICS` 可区分时提供共同的
字幕本地化基础名，再由 `public.machine-generated` 产生“（生成）”。音轨不提供本地化名称
覆盖，让系统直接根据 `LANGUAGE` 与 `CHARACTERISTICS` 生成语义名称；因此原声不再重复显示
raw `NAME` 与系统语言语义。字幕 master fallback 时字典退化为空，避免没有对应
`EXT-X-MEDIA` 的孤儿 key。原声音轨因为上游没有可靠语言，当前仍写为 `und`；系统可据此
表达未知语言与原始内容语义，待上游取得可靠原声语言后可自然替换为真实语言。

播放器窗口内采用系统 `.default` controls style；当前 SDK 中它等同 `.inline`。可见观察中
窗口态把字幕和音频作为独立入口，播放键两侧为前后跳 15 秒；进入全屏后系统自动切换为
`.floating`，退出后回到 inline 布局。一次全屏往返后音频入口被系统重新排入“更多”菜单，
但 media selection 仍可访问。这属于 AVKit 的动态控件排列边界，当前没有公开 API 固定某个
系统按钮的位置或强制其始终外露。

## 3. 真实 I-frame trick play

探针在加载前独立解析全部真实视频 representations 的 SIDX，并计算完整 fragment 的 HLS
BYTERANGE 集合。生产 bridge 为 6 个满足严格 type-1 SAP、`SAP_delta_time == 0` 条件的
视频 variants 发布 I-frame rendition。

`AVPlayerItem` ready 后记录每条 I-frame route 的基线，再调用 4 倍速播放。随后观察到：

1. 至少一条真实 I-frame playlist route 的 GET 计数增长；
2. 被请求 playlist 声明的全部 `EXT-X-BYTERANGE` 与相应真实 SIDX 的完整 fragment 集合
   一一相等；
3. 观察期全部媒体请求没有 Cookie 或 Authorization；
4. item 保持 `readyToPlay`；
5. stop 后全部 loopback server 的 listener、route、connection 与上游 task 归零。

因此，这次真实验证证明 AVPlayer 在正向 4 倍速下按需请求了内容与真实 SIDX 一致的
I-frame playlist，并维持无认证媒体边界。普通 playlist 与 I-frame playlist 共用同一媒体
route，单凭上游 Range 无法归因具体 fragment 由哪条 playlist 消费；本记录不声称已经证明
真实 I-frame fragment 的实际消费或画面级快进效果。

## 4. A → B → A 与真实 App 清理

审查前签名探针从该视频的公开相关推荐中选择一条不同视频，依次加载 A、B、A。三次安装得到
不同 `AVPlayerItem`；B 安装后 A 的 server 已停止，第二次 A 安装后 B 的 server 已停止，
最终 stop 后全部 server 诊断均为零。审查发现旧探针会让 B 再次经过登录态全目录 playback，
超过原安全文档的请求范围；当前探针已改为 B 使用匿名公开 playback，并对 A 的一次基础请求
及每个目录项至多一次精确请求做计数断言。该修正尚待再次获准执行真实登录态探针。

另一次当前分支开发 App 可见路径连续两次进入公开热门视频：播放中精确 App 进程均只有一个
`127.0.0.1` listener，系统 Back 后均为零，界面没有进入 playback failure。该可见路径只
补充真实 App 的基础播放与 Back 清理。探针中的 A → B → A 是逐次 await 的顺序替换，只证明
旧 server 停止与最终清理，不证明重叠 load、取消或迟到结果的真实 generation 隔离；后者由
确定性生命周期测试覆盖。

## 5. 自动 gate 与未关闭边界

- 审查修正后的最终 App gate 已在 Xcode 26.6 通过：Package 共 344 个测试、45 个 suite，
  随后 App build-for-testing 与 App unit tests 通过；需要真实登录输入的探针按设计跳过。
  apple-dev-loop 通用 build preflight 的 `xcodebuild -list` 在受限 sandbox 中因用户 cache／
  CoreSimulator 访问失败而归类为 sandbox；使用仓库隔离缓存的最高适用 App gate 已证明工程与
  shared scheme 可解析和构建。
- 审查前开发签名 App 构建与上述系统菜单路径已经通过；审查后的 production type、授权
  provenance、operation authentication epoch、AI 失败分类、音轨时间轴与 probe 请求上限
  修正尚未重新执行真实登录态探针。
  该远端验证必须再次得到用户明确批准，不能由自动 gate 或旧结果替代。
- 实际反向 trick play 未执行；synthetic 测试只证明系统报告 fast-reverse capability，不能
  外推真实反向图像进度。
- 未执行真实登出中断，因为它会删除用户当前 Keychain 会话；必须另行明确批准。
- 尚未由用户完成 VoiceOver 与 Full Keyboard Access 真人阅读／焦点顺序检查；AX tree、
  截图、build 和自动测试都不能替代这两项。
- 临时 App 可作开发签名运行，签名 test host 也成功读取 Keychain；但严格 codesign 校验为
  `CSSMERR_TP_NOT_TRUSTED`，因此不声称 Developer ID、notarization 或可分发签名通过。
- 全部远端结果只代表单账号、单内容、单时点，不证明所有地区、账号或视频都提供 AI 音轨。

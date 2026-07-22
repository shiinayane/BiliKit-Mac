# M4 字幕纵向切片验证——2026-07-22

## 当前结论

M4.2 Gate 已通过，可以进入 M4.3 弹幕数据与调度内核。生产实现、确定性测试和签名真实样本均已验证。

当前代码已经形成 `BiliAPI → BiliApplication → BiliBrowseFeature → App/Platform overlay` 纵向链路。字幕只消费 M4.1 的统一播放时间轴，不建立独立计时器；字幕 URL、授权器和正文 transport 均不会进入 Feature。

## 环境

- 日期：2026-07-22
- 系统：macOS 26.5.2（25F84），Apple Silicon `arm64`
- 工具链：Xcode 26.6（17F113），Apple Swift 6.3.3
- 确定性输入：仓库内全假值字幕目录、正文和错误 fixture
- 真实输入：签名 App 测试宿主中的已登录公开视频；真实标识、标题、正文和 URL 未写入仓库、日志或本记录

## 实现边界

- `BiliModels` 只公开字幕轨类型、轨道元数据和 cue；不包含 endpoint DTO、URL、Cookie 或网络错误正文。
- `BiliApplication` 定义目录、正文、reset port 和用途明确的应用错误；Use Case 校验播放 identity 与轨道归属。
- `BiliAPI` 通过已授权的 `/x/player/v2` 获取目录，并在 actor 内保存当前 identity 对应的轨道 ID→URL 映射；URL 不跨出 adapter。
- 字幕正文使用独立 ephemeral session，禁用 Cookie jar 和缓存，并拒绝重定向。来源策略只接受 HTTPS、443、无 userinfo/fragment、精确主机 `aisubtitle.hdslb.com` 和 `/bfs/` 路径前缀。
- 真实目录可能把空字符串 `subtitle_url` 作为不可用占位轨；decoder 忽略该条目并继续寻找可用轨。非空但畸形或来源不可信的 URL 仍使目录失败关闭。
- 目录上限 1 MiB、正文上限 2 MiB；两者均要求 JSON Content-Type。HTML、JSON 错误 envelope、空或未知结构不会降级解析。
- 最多接受 128 条字幕轨、20,000 条 cue 和 1 MiB cue 文本；cue 必须有限、非负、结束晚于开始、整体单调且不超过 24 小时。
- `SubtitleViewModel` 由 `@MainActor` 隔离，持有目录、切轨和时间轴 Task；切换视频/分 P/字幕轨、关闭详情和登出会取消旧工作并用 generation/identity 拒绝迟到结果。
- overlay 使用轻量 SwiftUI `Text`，同一时刻只呈现当前 cue；关闭字幕不删除已选轨道列表，但立即清除正文和当前 cue。

## 确定性测试

`BiliAPITests` 使用生产 repository/decoder 覆盖：

- 目录经授权 transport、正文经无 Cookie 专用 transport 的完整映射；
- 缺少授权器时在 transport 前失败；
- HTTP、userinfo、非 443 端口、loopback、相似主机、错误路径和 fragment 均被来源策略拒绝；
- 既有 M4 HTML/JSON 错误 fixture 接入生产 decoder 并失败关闭；
- 非单调、越过 24 小时和超大正文失败关闭；
- reset 清除 URL 映射，并使仍在飞行的目录结果失效。
- 空 URL 占位轨被忽略，随后可用轨仍能进入目录；该规则不放宽非空 URL 的来源检查。

`BiliBrowseFeatureTests` 覆盖：

- 暂停、2×、向前/向后 seek 后 cue 选择只跟随统一时间轴；
- 关闭字幕、单/多轨选择与切轨；
- 旧轨道、旧 identity 和旧时间线结果不能覆盖当前状态；
- 无字幕、认证失败、重试与 reset 的可见状态。

## 本地回归

以下验证在上述环境通过：

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

- Swift Package：138 项测试、24 个套件通过，其中新增 10 项 API/decoder 测试和 4 项 Feature 状态测试。
- App：无签名 `build-for-testing` 与 composition 测试通过；无参数测试中的签名 Keychain smoke 和 M4 已登录探针按设计跳过。
- 架构、秘密、工程静态契约和 `git diff --check` 通过。

## 签名真实样本 Gate

在已经登录且 Keychain 凭据可用的本机执行：

```sh
zsh Scripts/run-m4-authenticated-contract-probe.sh
```

脚本现在除 M4.0 的脱敏结构观察外，还会通过 App 的生产 composition 创建 `SubtitleViewModel`，使用生产 repository、来源策略和 decoder 加载同一真实样本。通过标志包含 `m4-subtitle-production`、非零轨道计数和 `decoder=ready`；脚本会显式检查该标志，跳过或只完成手写结构观察不算通过。输出不得包含 BVID、CID、标题、正文、完整 URL 或凭据。

本机签名探针已通过：目录响应为 JSON，共观察到 3 条轨道且 3 条可用；字幕正文来自 `aisubtitle.hdslb.com`，为 JSON，共 76 条 cue；App 生产 composition 最终报告 3 条轨道和 `decoder=ready`。测试结果为 `TEST SUCCEEDED`。

已对 `test.log` 扫描 BVID 模式、Cookie/token 名称及完整 HTTP(S) URL，未发现匹配；日志文件由全局 Git ignore 排除，不进入提交。

## 尚未覆盖的边界

- 当前未证明更多字幕 CDN 主机或未来 wire 结构；未知来源和结构继续失败关闭。
- 无签名 CI 不能替代 Keychain 授权与真实远端兼容性；推送后仍需确认 macOS 15/26 CI。
- 本记录不证明弹幕 decoder、调度、renderer、持久化、30 分钟稳定性、resize/全屏或 RSS Gate；这些属于 M4.3、M4.4 与 M4 收口。

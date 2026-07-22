# M4 协议与隐私 Gate——2026-07-22

## 当前结论

M4.0 Gate 已通过，允许进入 M4.1 统一播放时间轴。

匿名现场观察确认字幕目录使用 JSON，当前匿名样本明确报告需要登录且返回零条轨道；点播弹幕元数据和首段响应均为 `application/octet-stream` 二进制。签名 App 测试宿主随后通过现有 Keychain 授权器取得 1 条字幕轨，并在用途专属来源校验后下载、解析字幕正文。仓库记录只包含主机、字段名/类型、字节数和计数，不包含内容标识、URL、正文或凭据。

全假值 fixture、数据保留边界、ADR 0007 架构边界和 ADR 0008 SwiftProtobuf 依赖决策均已落地。M4.0 是实现前 Gate；字幕和弹幕生产 decoder 尚不存在，M4.2/M4.3 必须将负向 fixture 接入对应 decoder 测试后才能分别关闭。

## 环境

- 日期：2026-07-22
- 系统：macOS 26.5.2（25F84），Apple Silicon `arm64`
- 工具链：Apple Swift 6.3.3
- 访问方式：匿名 ephemeral HTTPS 探针，以及签名 App 测试宿主中的显式已登录探针；均拒绝重定向，不使用 Cookie jar/cache

## 脱敏观察

| 契约 | 状态 | Content-Type | 大小 | 结构结论 |
| --- | --- | --- | --- | --- |
| `/x/player/v2` | 200 | `application/json; charset=utf-8` | 约 2.3 KiB | 顶层含 `code/data/message/ttl`；`data.subtitle` 存在；当前匿名样本报告需要登录且轨道数为 0 |
| `/x/v2/dm/web/view` | 200 | `application/octet-stream` | 小于 1 KiB | 非 JSON/HTML 的二进制元数据 |
| `/x/v2/dm/web/seg.so` 首段 | 200 | `application/octet-stream` | 约 116 KiB | 非 JSON/HTML 的二进制分段 |
| 无效假值请求 | 200 或非成功缓存状态 | JSON 或空边界 | 很小 | HTTP 200 不能代表业务成功；必须先区分 JSON 错误与 protobuf |
| 已登录 `/x/player/v2` | 200 | JSON | 3,495 bytes | 1 条轨道；最小字段含 `id`/`id_str`、`lan`、`subtitle_url`，另观察到 AI 类型/状态与锁定字段 |
| 字幕正文 | 200 | JSON | 127,443 bytes | 来源主机为 `aisubtitle.hdslb.com`；761 条 cue；最小字段为 `from`、`to`、`content` |

记录刻意不保存样本 BVID/CID、标题、字幕/弹幕正文、完整响应 body、完整远端 URL或任何 Cookie。

## 已固定的本地材料

- `BiliAPIProbe --m4-contract --bvid <BVID> --cid <CID>`：只输出 path 对应的结构分类、状态、Content-Type、字节数、轨道计数和字段名。
- `M4AuthenticatedContractProbeTests`：仅在显式提供环境变量时运行于签名 App 测试宿主；通过 `BiliAuth` 的精确 `/x/player/v2` allowlist 使用现有登录凭据，只输出字幕主机、字段名、计数和大小。普通 CI 与无参数 App 测试会跳过，不自动访问网络或 Keychain。
- `BiliAPITests/Fixtures/subtitle-catalog.json` 与 `subtitle-body.json`：手写目录和 cue。
- `danmaku-segment-minimal.hex` 与 `danmaku-segment-truncated.hex`：自制最小 wire 输入和截断输入。
- `m4-error.json` 与 `m4-error.html`：错误响应失败关闭输入。
- [`../security/M4-data-privacy.md`](../security/M4-data-privacy.md)：内存、未来缓存、登出、手动清理、日志和 fixture 边界。

这些 fixture 尚未连接到字幕/弹幕 decoder；对应 deterministic contract test 必须与 M4.2/M4.3 的真实调用方在同一纵向切片落地，不能因文件存在或现场成功就视为 decoder 已验证。

## Gate 结论与后续约束

1. 已登录目录和字幕正文现场链路通过；无字幕样本会安全跳过，不能误报为协议失败。
2. 字幕正文当前只允许现场确认的 `aisubtitle.hdslb.com`；新主机默认失败关闭，取得同等级证据后才能扩展。
3. 空、截断、超大、HTML、JSON 错误和错误 Content-Type 已有全假值输入，但失败关闭结论必须由 M4.2/M4.3 的生产 decoder 测试证明。
4. ADR 0008 选择精确固定的 SwiftProtobuf 1.38.1 runtime，并将实际依赖接入延迟到 M4.3。隔离 Release 样本的最小 stripped 增量约 1.78 MiB，当前可接受。
5. M4.1 只建立唯一播放时间轴；不得借机提前创建字幕、弹幕、持久化 target 或把 AVPlayer 类型暴露到 Application/Feature。

## 本地回归

以下验证均在上述 macOS 26.5.2 Apple Silicon 环境通过：

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

普通无参数 App 测试中，签名 Keychain smoke 与 M4 现场探针按设计跳过；composition 测试通过。已登录字幕证据来自单独显式运行的签名测试宿主。macOS 15/26 CI 需要在后续提交推送后验证，当前本地结论不能代替云端结果。

## 已登录字幕探针运行方式

先在签名 BiliKit App 中确认当前为已登录状态，并选择一条确实带字幕的公开视频。运行仓库提供的脚本：

```sh
zsh Scripts/run-m4-authenticated-contract-probe.sh
```

脚本通过交互读取 BVID，避免将观看标识写进 shell 历史；CID 留空时通过游客分 P 目录取得首分 P。它先生成签名测试宿主，再只向临时 `.xctestrun` 注入参数，测试结束立即删除这些字段。探针不会打印 BVID/CID、Cookie、字幕 URL 或正文；若样本没有字幕会安全跳过，若正文主机不在当前精确 allowlist 中会失败关闭。完整脱敏日志写入仓库根目录的 `test.log`，该文件由 Git 忽略。

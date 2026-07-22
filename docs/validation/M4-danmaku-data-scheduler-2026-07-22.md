# M4 弹幕数据与调度验证——2026-07-22

## 当前结论

M4.3 Gate 已通过。生产 decoder、Application port、`BiliDanmaku` 调度内核、确定性测试和显式真实匿名探针均已完成；当前远端首段可以经过生产 protobuf decoder 映射为 typed event，并进入调度器。

M4.4 renderer 尚未开始。本阶段不会把每条弹幕创建为 SwiftUI `Text`，也不会提前声明窗口 resize、全屏、同屏上限或 30 分钟 RSS Gate 已通过。

## 环境与依赖

- 日期：2026-07-22
- 系统：macOS 26.5.2（25F84），Apple Silicon `arm64`
- 工具链：Xcode 26.6（17F113），Apple Swift 6.3.3
- SwiftProtobuf：exact 1.38.1，revision `55d7a1cc5666b85c13464aea1c4b4a90feccb4c8`
- 确定性输入：仓库自制最小、截断、空、超大、JSON 和 HTML 输入

ADR 0008 已生效：只有 `BiliAPI` target 链接 `SwiftProtobuf`。clean-room `danmaku.proto` 由项目自己的 M4 结构观察编写，并使用同一 1.38.1 checkout 自带的 `protoc` 与 `protoc-gen-swift` 显式生成；日常 App target 不挂 build-tool plugin。SwiftPM 与 Xcode 两条解析入口均由 `Package.resolved` 固定到同一 revision。

## Wire 与网络边界

- endpoint 固定为匿名 `GET /x/v2/dm/web/seg.so`，query 只能由正 CID、正 segment index 和固定 `type=1` 构成。
- 请求明确接受 `application/octet-stream`，不携带 Cookie；响应必须为 2xx、非空、最多 2 MiB 且 Content-Type 为二进制。
- 即使 Content-Type 被伪装为二进制，JSON/HTML 前缀也会在 protobuf decoder 前拒绝。
- 截断 varint/length-delimited、元素超过 20,000、时间越界、缺失 ID/正文、单条/总文本过大和颜色越界均失败关闭；未知字段由 runtime 跳过。
- 只映射滚动、顶部和底部基础类型；高级、互动、代码和反向类型在 adapter 边界明确丢弃。
- Domain event 不保留发送者 hash、action、创建时间或 wire 类型，字符串/调试描述固定脱敏。

## 调度与资源边界

- `BiliDanmaku` 只依赖 `BiliApplication` 与 `BiliModels`，不 import `BiliAPI`、SwiftProtobuf、网络、播放实现或 Feature。
- scheduler 只消费 M4.1 的 `PlaybackTimelineSnapshot`，不创建独立 wall-clock timer。
- 当前段与下一段组成预取窗口；会话最多同时加载 2 段，缓存最多保留 3 段。
- 同一 discontinuity generation 内按事件 ID 去重；暂停不发射，2× 仍按媒体时间窗发射。
- 向前或向后 seek/discontinuity 先清空 renderer 语义和已发射集合，不回填 seek 跨越的历史弹幕；回退后允许在新 generation 再次发射。
- 基础类型开关、最小权重和最多 128 个关键词过滤在调度前完成；旧 identity 的 segment、timeline 和迟到 Task 不能覆盖新会话。
- `AsyncStream` 使用 `bufferingNewest(4)`，未来 renderer 过载时保持有界；实际 lane、对象池和丢弃优先级由 M4.4 固定。

## 确定性验证

生产 API/decoder 测试覆盖：

- 自制最小 wire 经真实生成类型映射为 typed event，并验证请求不含 Cookie；
- 截断输入、空/超大响应、JSON/HTML 和错误 Content-Type 失败关闭；
- 不支持的高级 mode 被丢弃，缺失业务必需字段失败关闭；
- 取消保持为 `CancellationError`，不折叠为普通网络错误。

调度/会话测试覆盖：

- 暂停、2×、跨 6 分钟段边界和跨段重复事件去重；
- 大幅向前/向后 seek、generation 清理与重新发射；
- 基础类型、权重、关键词和关闭状态过滤；
- 旧 identity 拒绝、三段缓存上限、双请求并发上限；
- 会话替换取消旧加载，即使旧 adapter 忽略取消，迟到结果也不能覆盖新状态。

## 本地回归

以下验证已通过：

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

- Swift Package：152 项测试、28 个套件通过。
- App：新增 SwiftProtobuf 依赖后，无签名 `build-for-testing` 与 1 项 composition 测试通过；签名 Keychain smoke 和显式认证探针按设计跳过。
- 架构脚本已固定 `BiliDanmaku` 依赖方向，并禁止 `BiliAPI` 之外的 target import SwiftProtobuf。

## 真实匿名样本 Gate

执行：

```sh
zsh Scripts/run-m4-danmaku-probe.sh
```

脚本交互读取 BVID，CID 留空时由生产 API 选择首分 P，并固定请求首段。2026-07-22 的受控运行结果为：生产 decoder 解码 224 条基础弹幕，调度器发射 224 条，缓存 1 段，最终输出 `RESULT: PASS`。

根目录 `test.log` 已核对：只包含构建过程、`danmaku-production segment=ready`、解码/调度/缓存计数和最终状态，未记录 BVID、CID、正文、事件/用户标识、完整 URL、Cookie 或响应 body。该证据关闭 M4.3，并允许进入 M4.4 renderer。

## 尚未覆盖的边界

- 更多真实视频、后续分段、长视频和远端 wire 漂移尚未验证；未知结构继续失败关闭。
- macOS 15/26 CI 需在后续提交推送后确认；本地 Xcode 构建不能替代云端矩阵。
- Core Animation/AppKit lane allocator、碰撞预测、同屏/排队/对象池上限、resize、全屏、暂停冻结、30 分钟稳定性和 RSS 属于 M4.4/M4 收口。

# ADR 0008：点播弹幕使用 SwiftProtobuf runtime

- 状态：已接受
- 日期：2026-07-22
- 生效阶段：M4.3 首个点播弹幕生产 decoder 出现时

## 背景

M4.0 现场观察确认点播弹幕元数据和分段是 `application/octet-stream` 二进制响应。弹幕分段需要处理未知字段、重复 message、截断 varint、声明长度越界和未来 wire 漂移；手写一个只覆盖当前样本的 protobuf reader 会把协议安全边界变成长期自维护负担。

ADR 0007 已规定 endpoint、Content-Type/大小限制和 protobuf wire 解码入口属于 `BiliAPI`；`BiliDanmaku` 只应消费稳定的 Application/Models 类型并负责调度与呈现。本决策只选择 wire runtime，不改变依赖方向，也不立即增加 Package 依赖或空 target。

## 审计结果

审计对象是 Apple 官方仓库的 [SwiftProtobuf 1.38.1](https://github.com/apple/swift-protobuf/releases/tag/1.38.1)：

- 许可证为 [Apache License 2.0，并带 runtime library exception](https://github.com/apple/swift-protobuf/blob/1.38.1/LICENSE.txt)，允许本项目分发生成代码和链接后的产品；M6 仍应在第三方 notice 中列出依赖与许可证。
- 该版本要求 Swift 6.1+/Xcode 16.3+；包以 Swift 6 language mode 构建。本项目当前 Swift 6.3.3 满足要求，正式引入时仍须由 macOS 15/26 CI 同时证明。
- 官方建议生成器与 runtime 使用相同版本；因此版本必须精确固定，生成物必须可由同版本工具重复生成。
- 2026-07-22 的隔离 macOS 15 Release 样本只链接 `SwiftProtobuf` library product，并实际解析一个最小 well-known message。相对仅使用 Foundation 的基线，未 strip 可执行文件增加 3,553,576 bytes（约 3.39 MiB），`strip -x` 后增加 1,868,632 bytes（约 1.78 MiB）。编译器报告 production build 用时 32.03 秒；依赖 checkout 约 59 MiB。该测量是最小命令行样本，不等同于最终 App 增量，但足以排除数量级不可接受的方案。

## 决策

1. M4.3 首个真实点播弹幕 decoder 接入时，在现有 `Packages/BiliKitCore/Package.swift` 中以 exact requirement 固定 SwiftProtobuf 1.38.1；在此之前不引入依赖。
2. 只有 `BiliAPI` 依赖 `SwiftProtobuf` library product。`BiliDanmaku`、`BiliApplication`、`BiliModels` 和 Feature 不 import SwiftProtobuf，也不接触生成类型。
3. `.proto` schema 由本项目根据自有现场结构证据和公开协议机制 clean-room 编写，不复制参考项目的 schema、生成文件或 decoder。使用与 runtime 完全一致的 `protoc-gen-swift` 显式生成并提交 `.pb.swift`；不把 build-tool plugin 挂到日常 App target。
4. 网络边界必须先验证状态、`application/octet-stream`、非空与 2 MiB 分段上限，再交给 decoder。生成类型映射为 `BiliModels.DanmakuEvent` 后立即丢弃；未知字段可由 runtime 跳过，但缺少业务必需字段、截断、越界、HTML/JSON 错误和超大响应必须失败关闭。
5. 依赖升级必须重新核对许可证、Swift/Xcode 要求、生成器/runtime 一致性、macOS 15/26 CI 和 Release 体积；不能使用宽泛的自动大版本漂移。

## 未采用方案

### 手写通用 protobuf wire reader

运行时体积更小，但需要自行维护 varint、fixed32/64、length-delimited、未知字段、嵌套深度和恶意长度边界。对于不稳定远端协议，这一安全与维护成本高于约 1.78 MiB 的最小 stripped 体积增量。

### 在 `BiliDanmaku` 中直接解码 wire

会让呈现 adapter 持有 endpoint/wire 语义，并迫使它依赖网络数据层或把生成类型泄漏进 Application。该方向违反 ADR 0007 和现有 Clean Architecture 规则。

### 日常构建时运行 SwiftProtobuf plugin

可以避免提交生成文件，但会把 protoc/generator 可用性和额外构建工作带入每次 App/CI 构建。当前 schema 很小且变更低频，显式生成、审查并提交更可控。

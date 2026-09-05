# ADR 0013：V1 Developer ID 成品采用 Universal 架构

- 状态：Accepted
- 日期：2026-08-24
- 关联：ADR 0001、ADR 0003、[`../release/README.md`](../release/README.md)

## 背景

BiliKit 最低支持 macOS 15，而该系统版本仍覆盖 Apple Silicon 与部分 Intel Mac。只对外声明
“macOS 15+”却发布纯 `arm64` 成品，会让仍受系统支持的 Intel 用户无法启动。当前 App 与
SwiftProtobuf 均从源码构建，没有已知的 Apple-Silicon-only 二进制依赖。

2026-08-24 使用 Xcode 26.6（17F113）对 App target 执行无签名 Release 构建，显式设置
`ARCHS=arm64 x86_64` 与 `ONLY_ACTIVE_ARCH=NO`。构建成功，App bundle 内唯一 Mach-O
`Contents/MacOS/BiliKit` 同时包含 `arm64` 和 `x86_64`；生成的版本、最低系统、类别、版权及
Privacy Manifest 也核对通过。

## 决策

- V1 Developer ID 站外分发物冻结为 `arm64 + x86_64` Universal App。
- App target 的 Release 配置显式固定两个架构并关闭 `ONLY_ACTIVE_ARCH`；Debug 仍可只构建当前
  开发机架构以保持迭代速度。
- README、下载页、DMG 说明与未来 Sparkle appcast 必须一致声明 macOS 15+ 与 Universal。
- 最终 Developer ID archive 必须重新枚举 App 与全部嵌套 Mach-O，逐项确认两个 slice；无签名
  build 不能替代签名成品证据。
- 2026-09-05 维护者修订发布政策：真实 Intel macOS 15 的最小关键路径属于验证记录，
  不再作为发布门槛或公开支持限制。测试观察与维护者发布裁决分别记录，Intel CI 不冒充真人验证。

## 后果与变更条件

Universal 会增加编译时间和下载体积，也要求两种架构的依赖、签名、公证与运行证据保持一致。
如果未来要停止 Intel 支持，必须以新 ADR 取代本文，同时更新最低硬件说明、下载资产、更新 feed、
测试矩阵与支持政策；不能仅通过一次 Xcode build setting 改动静默移除 `x86_64`。

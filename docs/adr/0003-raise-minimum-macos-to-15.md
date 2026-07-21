# ADR 0003：最低系统版本提高到 macOS 15

- 状态：Accepted
- 日期：2026-07-21

## Context

ADR 0001 最初选择 macOS 14，以兼顾现代 SwiftUI API 和更广的设备覆盖。项目没有 macOS 14 开发或测试设备。设置 deployment target 可以发现 API availability 问题，但不能证明 AVFoundation、loopback 网络、取消传播和窗口集成能在该运行时工作。

GitHub 当前仍提供 `macos-14` hosted runner，但已于 2026-07-06 开始弃用，并计划在 2026-11-02 完全停止支持。依赖这个 runner 会形成一项短期内就无法持续验证的支持承诺。

## Decision

将 App、测试 target 和 `BiliKitCore` Package 的最低支持及 deployment version 统一提高到 macOS 15.0。

CI 必须同时运行：

- `macos-15`：代表最低支持运行时。
- `macos-26`：代表当前开发运行时。

真实 B 站播放继续作为显式探针，而不是 PR 必过检查，因为游客 API、媒体 URL、样本和 CDN 行为均属于动态外部依赖。

## Consequences

### Positive

- 最低版本声明具备可持续更新的 hosted runtime 验证路径。
- M1 可以在实际最低运行时验证 AVPlayer 与 loopback 行为，而不是从 deployment-target 编译结果推断兼容性。
- 可以直接使用 macOS 15 API，不再为 macOS 14 增加 availability 分支。

### Negative

- 无法升级到 macOS 15 的 Mac 不再受支持。
- 标准 `macos-15` runner 是 Apple Silicon，不能证明 Intel 兼容；Intel 仍是单独的条件性验证项。
- 若未来重新下探最低版本，必须先通过新 ADR 建立可维护的运行环境，再修改 deployment setting。

## References

- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub macOS 14 runner image and deprecation notice](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-Readme.md)

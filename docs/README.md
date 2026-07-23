# 项目文档

- [`ROADMAP.md`](./ROADMAP.md)：当前实施顺序与验收门槛。
- [`adr/`](./adr/)：已接受的架构决策。
- [`security/`](./security/)：认证、凭据和后续隐私边界的威胁模型。
- [`validation/`](./validation/)：注明日期、环境和适用边界的运行验证记录。
- [`development/QUALITY-GATES.md`](./development/QUALITY-GATES.md)：风险分级、任务契约、隔离审查和统一可执行 Gate。
- [`development/M4.4-renderer-spike-decision.md`](./development/M4.4-renderer-spike-decision.md)：已执行完毕的不可合入 renderer spike 决策边界。
- [`development/M4.4-renderer-spike-technical-plan.md`](./development/M4.4-renderer-spike-technical-plan.md)：已执行 spike 的技术边界与历史输入。
- [`development/M4.4-renderer-production-decision.md`](./development/M4.4-renderer-production-decision.md)：已授权并按真实播放反馈修订至 P4 的 renderer 生产决策契约。
- [`development/M4.4-renderer-production-technical-plan.md`](./development/M4.4-renderer-production-technical-plan.md)：不要求用户逐项确认的生产实施草案。
- [`RESEARCH-native-macos-client.md`](./RESEARCH-native-macos-client.md)：产品、竞品、播放、许可和分发研究基线。

现行文档必须区分仓库事实和目标方向。计划中的能力只有通过对应 gate 后，才能视为已实现。

## 本地参考项目

`references/` 专门存放用于研究第三方行为和项目历史的完整本地 checkout。该目录整体被 Git 忽略，也不进入 Xcode 工程；其中任何内容都不是 App 依赖或获准重新分发的输入。

将第三方源码、注释、fixture、图标或其他资产复制进 BiliKit 前，必须先核实来源和许可证兼容性。

已接受的决策：

- [`adr/0001-platform-naming-and-modules.md`](./adr/0001-platform-naming-and-modules.md)
- [`adr/0002-loopback-http-playback-bridge.md`](./adr/0002-loopback-http-playback-bridge.md)
- [`adr/0003-raise-minimum-macos-to-15.md`](./adr/0003-raise-minimum-macos-to-15.md)
- [`adr/0004-mvvm-clean-architecture.md`](./adr/0004-mvvm-clean-architecture.md)
- [`adr/0005-web-qr-authentication-boundary.md`](./adr/0005-web-qr-authentication-boundary.md)
- [`adr/0006-product-domain-feature-targets.md`](./adr/0006-product-domain-feature-targets.md)
- [`adr/0007-m4-timeline-danmaku-and-persistence-boundaries.md`](./adr/0007-m4-timeline-danmaku-and-persistence-boundaries.md)
- [`adr/0008-swift-protobuf-runtime.md`](./adr/0008-swift-protobuf-runtime.md)

当前安全基线：

- [`security/M3-threat-model.md`](./security/M3-threat-model.md)
- [`security/M4-data-privacy.md`](./security/M4-data-privacy.md)：字幕、弹幕、播放位置与未来本地缓存的数据边界。

当前验证记录：

- [`validation/M3-auth-state-machine-2026-07-21.md`](./validation/M3-auth-state-machine-2026-07-21.md)：Web QR 状态、成功/过期契约与脱敏探针。
- [`validation/M3-keychain-authorization-2026-07-21.md`](./validation/M3-keychain-authorization-2026-07-21.md)：Keychain envelope、请求授权与未签名环境边界。
- [`validation/M3-auth-feature-2026-07-21.md`](./validation/M3-auth-feature-2026-07-21.md)：认证 Application/Feature、完整本地登出与最小 UI smoke。
- [`validation/M3-watch-history-2026-07-21.md`](./validation/M3-watch-history-2026-07-21.md)：观看历史纵向闭环、真实扫码、重启恢复、登出与游客回退。
- [`validation/M3-pre-M4-architecture-review-2026-07-21.md`](./validation/M3-pre-M4-architecture-review-2026-07-21.md)：进入 M4 前的独立代码审查、领域 Feature 整理、阻断项与本地验证。
- [`validation/M3-audit-remediation-2026-07-22.md`](./validation/M3-audit-remediation-2026-07-22.md)：独立审查整改、真实播放回归、工程静态契约和 M3 关闭边界。
- [`validation/M4-protocol-contract-2026-07-22.md`](./validation/M4-protocol-contract-2026-07-22.md)：M4.0 匿名/已登录协议观察、假值 fixture、依赖审计与隐私 Gate 结论。
- [`validation/M4-playback-timeline-2026-07-22.md`](./validation/M4-playback-timeline-2026-07-22.md)：M4.1 唯一播放时间线、AVPlayer 适配、取消/替换隔离与本地回归。
- [`validation/M4-subtitle-vertical-slice-2026-07-22.md`](./validation/M4-subtitle-vertical-slice-2026-07-22.md)：M4.2 字幕生产链路、隐私/来源边界、确定性测试与签名真实样本 Gate。
- [`validation/M4-danmaku-data-scheduler-2026-07-22.md`](./validation/M4-danmaku-data-scheduler-2026-07-22.md)：M4.3 protobuf decoder、分段调度、依赖边界与真实匿名样本 Gate。
- [`validation/M4.3.5-engineering-governance-2026-07-22.md`](./validation/M4.3.5-engineering-governance-2026-07-22.md)：风险分级、隔离上下文审查、统一质量 Gate 与首次试运行。
- [`validation/M4.4-governance-correction-2026-07-23.md`](./validation/M4.4-governance-correction-2026-07-23.md)：决策价值 Gate、复杂度预算、三视角复审与旧 spike 授权撤销。
- [`validation/M4.4-renderer-production-2026-07-23.md`](./validation/M4.4-renderer-production-2026-07-23.md)：P4 镜像覆盖、真实视觉反馈、完整 App Gate、独立红区审查与 30 分钟生产 probe。

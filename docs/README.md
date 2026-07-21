# 项目文档

- [`ROADMAP.md`](./ROADMAP.md)：当前实施顺序与验收门槛。
- [`adr/`](./adr/)：已接受的架构决策。
- [`security/`](./security/)：认证、凭据和后续隐私边界的威胁模型。
- [`validation/`](./validation/)：注明日期、环境和适用边界的运行验证记录。
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

当前安全基线：

- [`security/M3-threat-model.md`](./security/M3-threat-model.md)

当前 M3 验证记录：

- [`validation/M3-auth-state-machine-2026-07-21.md`](./validation/M3-auth-state-machine-2026-07-21.md)：Web QR 状态、成功/过期契约与脱敏探针。
- [`validation/M3-keychain-authorization-2026-07-21.md`](./validation/M3-keychain-authorization-2026-07-21.md)：Keychain envelope、请求授权与未签名环境边界。
- [`validation/M3-auth-feature-2026-07-21.md`](./validation/M3-auth-feature-2026-07-21.md)：认证 Application/Feature、完整本地登出与最小 UI smoke。
- [`validation/M3-watch-history-2026-07-21.md`](./validation/M3-watch-history-2026-07-21.md)：观看历史纵向闭环、真实扫码、重启恢复、登出与游客回退。
- [`validation/M3-pre-M4-architecture-review-2026-07-21.md`](./validation/M3-pre-M4-architecture-review-2026-07-21.md)：进入 M4 前的独立代码审查、领域 Feature 整理、阻断项与本地验证。
- [`validation/M3-audit-remediation-2026-07-22.md`](./validation/M3-audit-remediation-2026-07-22.md)：独立审查整改、真实播放回归、工程静态契约和 M3 关闭边界。

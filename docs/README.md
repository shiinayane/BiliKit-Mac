# 项目文档

这里保存仍会影响当前开发判断的文档。Git 历史已经承担旧实施计划、阶段契约和治理试运行
的归档职责，不在 `docs/` 中保留第二份可被 AI 误读为现行规则的副本。

## 当前入口

- [`ROADMAP.md`](./ROADMAP.md)：当前能力、未完成结果和实施顺序。
- [`product/PRODUCT-VISION.md`](./product/PRODUCT-VISION.md)：v1 产品结果与范围。
- [`product/UIUX-VISION.md`](./product/UIUX-VISION.md)：长期界面与交互方向。
- [`development/QUALITY-GATES.md`](./development/QUALITY-GATES.md)：自动检查和真实行为验证入口。
- [`development/M5.0-daily-client-state-retention-decision.md`](./development/M5.0-daily-client-state-retention-decision.md)：
  M5.0 已确认问题、用户结果、资源边界与当前原生导航 revision。
- [`development/M5.0.1-external-facts-audit-contract.md`](./development/M5.0.1-external-facts-audit-contract.md)：
  M5.0.1 外部事实全面审计的证据等级、并行边界、产物和 Gate。

## 持久约束

- [`adr/`](./adr/)：已接受的架构决策。旧 ADR 保留当时背景，由明确写明“取代”的新 ADR
  更新当前决策。
- [`security/`](./security/)：认证、凭据、媒体来源和本地数据边界。
- [`validation/`](./validation/)：仍值得复查的真实设备、网络、性能、安全和兼容性证据。

验证记录是带日期的证据，不是当前测试数量、工具链或实现状态的权威来源。当前事实应先
核对代码、`Package.swift`、Xcode 工程和质量 Gate。

## 研究材料

[`RESEARCH-native-macos-client.md`](./RESEARCH-native-macos-client.md) 是立项期的竞品、技术、
许可和分发研究。它可以解释历史选择，但不定义当前模块名、路线图、工程结构或 AI 工作
流程。第三方 checkout 只允许放在被 Git 忽略的 `references/`，不得成为产品依赖、测试
fixture 或可复制源码。

# 项目文档

这里保存仍会影响当前开发判断的现行文档，以及具有长期复查价值的带日期证据。历史
阶段契约和审计记录用于解释当时事实，不再决定当前顺序；Git 历史承担已经失去复查价值
的临时计划归档。

## 当前入口

- [`ROADMAP.md`](./ROADMAP.md)：当前能力、大体方向和唯一已选择的后续阶段。
- [`product/PRODUCT-VISION.md`](./product/PRODUCT-VISION.md)：v1 产品结果与范围。
- [`product/UIUX-VISION.md`](./product/UIUX-VISION.md)：长期界面与交互方向。
- [`product/PRODUCT-CANDIDATES.md`](./product/PRODUCT-CANDIDATES.md)：已接受但未排期的
  无顺序候选；不表示实施授权。
- [`development/QUALITY-GATES.md`](./development/QUALITY-GATES.md)：自动检查和真实行为验证入口。
- [`development/M5.0-daily-client-state-retention-decision.md`](./development/M5.0-daily-client-state-retention-decision.md)：
  M5.0 的问题、用户结果、资源边界与完成摘要。
- [`development/M5.0.1-external-facts-audit-contract.md`](./development/M5.0.1-external-facts-audit-contract.md)：
  已完成的 M5.0.1 审计执行契约；只解释历史取证边界。
- [`audits/M5.0.1/`](./audits/M5.0.1/)：M5.0.1 带日期的发现、证据与用户裁决，不决定
  当前实施顺序。

## 持久约束

- [`adr/`](./adr/)：已接受的架构决策。旧 ADR 保留当时背景，由明确写明“取代”的新 ADR
  更新当前决策。
- [`security/`](./security/)：认证、凭据、媒体来源和本地数据边界。
- [`validation/`](./validation/)：仍值得复查的真实设备、网络、性能、安全和兼容性证据。

验证与审计记录是带日期的证据，不是当前测试数量、工具链、实现状态或排期的权威来源。
当前事实应先核对代码、`Package.swift`、Xcode 工程和质量 Gate；未实施候选以产品候选
登记为索引，再回到原始审计证据复核。

## 研究材料

[`RESEARCH-native-macos-client.md`](./RESEARCH-native-macos-client.md) 是立项期的竞品、技术、
许可和分发研究。它可以解释历史选择，但不定义当前模块名、路线图、工程结构或 AI 工作
流程。第三方 checkout 只允许放在被 Git 忽略的 `references/`，不得成为产品依赖、测试
fixture 或可复制源码。

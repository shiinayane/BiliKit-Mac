# 项目文档

这里仅保留会影响当前开发判断的现行文档，以及无法被代码和自动测试替代的带日期证据。
临时计划、逐轮审计稿和已完成阶段的重复状态表由 Git 历史归档，不继续占用当前入口。

## 从这里开始

- [`ROADMAP.md`](./ROADMAP.md)：当前能力、唯一进行中的阶段和后续候选。
- [`product/PRODUCT-VISION.md`](./product/PRODUCT-VISION.md)：V1 产品结果与范围。
- [`product/UIUX-VISION.md`](./product/UIUX-VISION.md)：界面与交互原则。
- [`product/PRODUCT-CANDIDATES.md`](./product/PRODUCT-CANDIDATES.md)：已记录但未排期的候选；不表示实施授权。
- [`development/QUALITY-GATES.md`](./development/QUALITY-GATES.md)：静态、Package 和 App 验证入口。

## V1 分发

- [`release/README.md`](./release/README.md)：Developer ID、签名、公证、DMG、Gatekeeper、Intel、
  Sparkle 与 Cloudflare 的当前决策和严格实施顺序。
- [`release/CHECKLIST.md`](./release/CHECKLIST.md)：发布候选逐项 Gate。
- [`release/MANIFEST.md`](./release/MANIFEST.md)：每个不可变发布候选的版本、工具链、签名、公证
  和最终分发物证据模板。
- [`adr/0013-v1-universal-developer-id-distribution.md`](./adr/0013-v1-universal-developer-id-distribution.md)：
  V1 Developer ID 成品采用 `arm64 + x86_64` Universal，并保留真实 Intel 发布 Gate。

无更新器 build 1 与 Sparkle build 2/3 已完成各自签名公证，本机正常升级由用户确认。
正式候选仍从新干净提交构建并检查最终签名身份、profile 与 Keychain 范围；历史 Apple 工单
状态不代替成品核验，旧候选验收也不代替当前版本的真实安装与跨系统 Gate。

## 长期约束

- [`adr/`](./adr/)：已接受的架构决策。旧 ADR 只由明确写明“取代”的新 ADR 更新。
- [`security/`](./security/)：认证、凭据、媒体来源、本地服务和数据隐私边界。
- [`evidence/`](./evidence/)：仍值得复查的审计摘要与核心能力证据索引。
- [`validation/`](./validation/)：索引所引用的少量详细真实验证记录。

## 阅读规则

1. 当前事实先核对代码、`Package.swift`、Xcode 工程和质量 Gate。
2. 排期只看 `ROADMAP.md`；候选清单不等于授权。
3. 发布只看 `release/`；旧阶段验证不等于当前 Release、签名或公证通过。
4. 带日期证据只证明所列环境和样本。工具链、服务端、签名身份或代码改变后应重新验证。
5. 需要追溯已删除的过程稿时使用 Git 历史，不把历史任务表恢复成现行规范。

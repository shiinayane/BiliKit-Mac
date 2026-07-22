## Goal

<!-- 用一句话说明本 PR 改变的可观察行为。 -->

## Context / Constraints

<!-- 列出相关 Roadmap、ADR、威胁模型、关键依赖与明确非目标。 -->

## Done when

<!-- 写出可执行验收条件；红区必须包含真实探针或测量。 -->

## 风险与关键路径

- 风险等级：绿区 / 黄区 / 红区
- 风险理由：
- 人工追踪的关键路径：
- 回滚方式：

## 验证

- [ ] `sh Scripts/run-quality-gates.sh static`
- [ ] `sh Scripts/run-quality-gates.sh package`（涉及 Package 代码时）
- [ ] `sh Scripts/run-quality-gates.sh app`（涉及 App/Xcode/composition 时）
- [ ] 任务专用真实探针/测量（红区；在下方写命令、环境和结果）

未验证或跳过项：

## 独立审查

<!-- 黄/红区填写独立上下文审查者、blocker/improvement/reject 结论及整改。 -->

- 使用角色/模型：
- 是否触发升级，原因：
- 契约/失败场景审查：
- 线程、所有权、安全与清理审查：
- 已知剩余边界：

红区附加确认：

- [ ] 用户已确认当前阶段的 spike 或生产契约
- [ ] 两个独立上下文分别完成失败场景与线程/所有权/安全审查
- [ ] 任务专用真实探针或长时测量已通过，或明确记录未验证边界
- [ ] 用户已确认一条最关键的真实链路与风险边界

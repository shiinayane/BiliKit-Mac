# P0 结果充分性治理升级验证

- 日期：2026-07-25
- 环境：macOS，arm64
- 范围：`AGENTS.md`、工程质量 Gate、项目 Agent mandate、PR 模板
- 性质：只读契约回放与静态文档验证；不证明 App 运行行为

## 任务契约

- **Goal**：让工程约束选择“满足产品结果的最低成本方案”，而不是让最容易实现的代理
  指标替代用户体验。
- **Context**：现有 Gate 强力限制复杂度与审查扩张，但 reviewer 被约束在已最小化契约
  内，缺少从权威产品结果打回欠解契约的明确权限。
- **Constraints**：不新增常驻产品 reviewer；不为绿区增加独立审查；Outcome floor
  限定在当前已接受切片；不在本变更修改 M5.0 生产契约或实现。
- **Outcome floor**：黄区、红区和重要 Gate 必须追踪权威结果、任务契约、候选、验收与
  证据；复杂度预算不得预选不充分方案；用户可见降级必须单独确认；验收失败必须重开
  契约而不是继续叠补丁。
- **Done when**：根规则、详细 Gate、Agent mandate 与 PR 模板语义一致；M5.0 回放能
  阻止代理绕过；Skill 与项目静态 Gate 通过；独立审查未发现 blocker。

## 回放案例

事实来源：

- `docs/product/PRODUCT-VISION.md` 要求正常返回恢复来源、已加载工作集、选择与可合理恢复
  的滚动上下文。
- `docs/product/UIUX-VISION.md` 要求视频返回恢复来源页面、滚动位置与选中卡片。
- `docs/development/M5.0-daily-client-state-retention-decision.md` D2 将 Phase 1B 限定为
  稳定 item identity，不承诺精确像素，并以“返回后看到离开前卡片与选中状态”关闭 Gate。

旧规则能够把保存 item identity、无重复请求和卡片可见当作完整验收，后续 reviewer
又被限制在已最小化契约内，因此不能阻止权威产品结果被代理指标替换。

按升级后规则回放时，该契约必须在实现前返回结果充分性与决策价值 Gate：

1. 明确返回连续性的 Outcome floor 和允许的视觉容差；
2. 区分 item identity／请求次数等支持代理与用户实际看到的视口连续性；
3. 比较保留来源导航状态与销毁后重构恢复的充分候选；
4. 单独展示并确认任何“只回到附近卡片”的用户可见降级；
5. 只有事实源明确把当前切片定义为后续路径基础时，才检查其兼容性；若是经过确认的
   一次性实现，则记录删除时机与返工成本。M5.0 已明确不拥有未来个性推荐，因此本次
   回放不要求它预建 M5.1 的分页或动态列表架构。

这项回放证明新规则能够阻止案例中的契约降级；它不预先决定 M5.0 应采用哪一种导航
或滚动实现，也不把精确像素恢复写成未经产品确认的固定阈值。

## Governance v1 压力测试

### 历史正反例

- M4.4 renderer 回放仍会先淘汰不充分候选，再以候选、指标和负载预算拒绝 broker、
  schema、watchdog 与完整 benchmark framework 等无决策价值扩张。
- M4.5 播放布局回放会拒绝最低成本但无法满足宽窗口信息层级的“始终 compact”路线，
  同时不要求该窄 slice 一次交付完整 App。
- 因此端到端黄金路径只绑定 Roadmap 阶段总 Gate；普通 slice、维护切片与不可合入
  spike 不自动承担完整产品关闭责任。

### ROADMAP 只读回放

- M5.1 需要在后续路线图重排中补充“独立可发现首页、唯一推荐来源、连续追加、进入
  视频再返回、准确失败且不回退热门”的直接 Outcome floor。
- M5.2 需要以首页 A → 推荐 B → 推荐 C → 返回最初来源的 walkthrough 直接关闭，
  资源计数与 generation 测试只是支持证据。
- M6 需要对签名／notarized 发布物重复同一 v1 黄金路径，而不是只列分散 smoke 项。
- 这些是后续 ROADMAP rebaseline 输入，不在本治理变更中改写历史完成事实或生产计划。

### 当前 M5.0 D2.1 回放

- 当前未提交实现的双 snapshot、`activate/deactivate/reset`、单 Task/latest pending、
  Feature-owned selection/viewport 与 App-owned typed route 可以保留；新规则不要求因
  治理缺口推倒实现，也不预建 M5.1 owner。
- D2.1 将 stable item anchor 改为 Feature-owned `CGFloat` viewport offset，并删除 App
  侧 selected identity，实际改变 Outcome floor、owner 和迁移责任；不能声明为无需重开
  前置 Gate 的“语义不变窄修订”。
- 热门 XCUI 已直接验证稳定布局下的视口坐标；搜索／tab 组合仍需按最终授权范围判断
  是否缺少直接验收。Feature offset 单测不能单独代替 SwiftUI surface 的用户结果。
- 这证明升级规则能保留有效实现，同时阻止 revision、owner 与验收范围漂移。

### 事实域回放

原根规则把当前代码放在所有事实来源首位，会让实现现状降低产品验收，也可能让长期愿景
扩张未确认切片。Governance v1 改为按 claim 分域：当前实现、产品结果、当次授权、架构
与迁移、安全隐私、完成证据和研究材料分别裁决；同域冲突必须先协调或明确取代。独立
复核进一步要求 Context 标明产品来源是已接受基线还是长期方向，避免愿景被误作当前
Outcome floor 或生产授权；该入口已同步到质量 Gate 与 PR 模板。

## 验证边界

- 已通过：`BILIKIT_COMPACT_LOGS=1 sh Scripts/run-quality-gates.sh static`
- 独立只读审查首轮发现的维护例外字段遗漏、跨切片要求过宽和绿区负担已整改；复核
  未发现剩余 blocker
- M4.4、M4.5、完整 ROADMAP、事实域和 clean/dirty M5.0 均完成独立只读回放
- 未运行 Xcode、签名、真实 UI 或性能验证；本变更不触及这些能力

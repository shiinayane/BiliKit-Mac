# ROADMAP 结果充分性重排记录

- 日期：2026-07-25（Asia/Tokyo）
- 基线：`origin/main` `73413fe`
- 范围：当前阶段事实、v1/v1.1 产品截线、M5.0–M6 Outcome floor 与直接验收边界

## 任务契约

- **Goal**：让 ROADMAP 能指导一个完整 App 的连续实施，不再把局部实现代理或分散
  smoke 当作用户结果，也不让旧阶段状态遮蔽当前优先级。
- **Context**：
  - 当前实现与配置以 `origin/main`、Package/Xcode 配置和 CI 为准；
  - v1 产品结果以已确认的 `PRODUCT-VISION.md` 与 M4.6 r1 精简截线为准；
  - 当前任务只授权文档重排，不授权 M5 endpoint、缓存、分页、媒体或认证写操作；
  - PR #11–#14 与带日期验证记录只证明各自覆盖的完成证据。
- **Constraints**：保留已接受的 v1/v1.1 截线；不改写历史验证；不丢弃 M5.0 遗留
  实现；不预建 M5.1 owner、Repository、cache、图片 pipeline 或播放抽象。
- **Outcome floor**：路线必须明确指导“个性推荐首页 → 视频 A → 推荐 B → 推荐 C →
  返回最初来源”，并在各 slice 与 M5/M6 总 Gate 中区分直接用户验收和内部支持证据。
- **Done when**：阶段状态、产品基线、M5.0 恢复边界、M5.1/M5.2 直接 UI 路径、
  M5.3 无代码关闭条件、M5 资源证据和 M6 发布物黄金路径一致；static Gate 与独立
  只读复核通过。

## 当前事实

- PR #11（merge `112598b`）、#12（merge `03b3d37`）、#13（merge `97d0630`）和
  #14（merge `73413fe`）均已合并；各 PR 的 macOS 15/26 checks 通过。M4.6、M4.7、
  M4.8 与 Governance v1 可以在当前 ROADMAP 标记完成。
- `origin/main` 尚未包含 M5.0 生产实现。另一个保留中的工作树存在实现候选，但未形成
  可审计提交，不能成为 ROADMAP 的当前事实；其具体 owner、返回表示和迁移差异必须在
  恢复时固定到新 revision 的证据包。
- M4.6 r1 已绑定用户对精简 v1 的确认：只读评论、服务端观看进度写入、独立播放器
  窗口、mini player 与 PiP 属于 v1.1；本次不重新解释早期愿景来扩张 v1。

## 重排结果

### M5.0

保留经新 revision 证明仍有效的实现，但先明确“返回进去时的样子”的直接可观察结果、
热门／搜索 × tab／播放返回矩阵、列表返回表示的 owner，以及内容变化／resize 边界。
内部 snapshot、item identity、offset 和 repository call 计数只作为支持证据。

### M5.1

首页必须是独立可发现且语义准确的个性推荐入口，只选择一个生产来源。Gate 直接覆盖
首载、同一续载位置／分页令牌的单次自动追加、稳定去重、返回连续性、刷新／追加失败、
骨架状态以及有界工作集；`LazyVStack` 本身不构成分页或资源正确性证据。结构 probe
默认无秘密，只能淘汰候选；生产选择必须在选定登录边界完成脱敏真实路径，新增凭据族
或授权 endpoint 会返回独立决策 Gate。

### M5.2

以“来源 → A → B → C → 返回最初来源”的无个人数据 walkthrough 直接验收，同时固定
单 player host、唯一时间轴、旧结果隔离和退出资源归零。生产 revision 必须先选择
identity commit point，并定义提交前／后准备失败、重试／返回和快速 B → C 的归属；
commit 前不退休当前 active 会话，失败或被替换时只释放候选，成功后才清理旧会话。

### M5.3

先观察真实日用阻断。没有阻断时仍以预登记、脱敏的生产 App 关键路径关闭而不写生产
代码；只有可重复阻断才能建立窄媒体 revision。

### M5 与 M6

M5 总 Gate 绑定选定生产来源、生产 adapter 和实际播放器链路，增加持续首页追加、
连续换视频和返回来源时的 CPU、physical footprint、卡顿与资源计数，并要求测量前
预登记预算。M6 必须在签名／notarized 发布物上重复完整 v1 黄金路径，不能由 fixture、
内部计数或分散 smoke 替代。

## 独立复核与静态验证

- 普通 reviewer 首轮阻止把可变的未提交实现写成公共当前事实，并移除对 cursor
  协议和全局 request 上限的预选；整改后无 blocker 或 improvement。
- red reviewer 首轮补齐无秘密来源 probe、选定登录边界真实证据、推荐 identity
  commit／rollback、M5 真实生产链路和测量前资源预算；最终复核无 blocker。
- `BILIKIT_COMPACT_LOGS=1 sh Scripts/run-quality-gates.sh static` 与
  `git diff --check` 通过。

## 验证边界

- 本记录不证明 M5.0 实现正确，也不授权 M5.1/M5.2 endpoint。
- 未运行 Xcode、签名 UI、真实账号、网络 probe 或 Instruments；本变更只重排当前
  产品和验证契约。
- 历史验证记录保留当时“远程 CI 未验证”的时点事实；当前 ROADMAP 依据已合并 PR
  的最终 check 结果描述现状，不回写历史记录。

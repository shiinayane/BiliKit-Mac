# M5.0.1 外部事实全面审计

状态：已完成并冻结的带日期审计。十条审计线、五个横向清单、独立交叉复核、五组最小
真实验证及用户逐项授权的窄修复均已完成。本目录保留当时事实和裁决，不决定当前实施
顺序。

本目录保存审计发现、证据边界和已授权修复的验证结果。执行规则见
[`../../development/M5.0.1-external-facts-audit-contract.md`](../../development/M5.0.1-external-facts-audit-contract.md)。

## 当前基线

- 生产基线：`a00744639f853ffbd7543a56c29a1588d41d93ea`
- 审计分支：`codex/m501-external-facts-audit`
- 基线日期：2026-07-27（Asia/Tokyo）
- 其他 worktree：`BiliKitMac-documentation-comments` 含未提交修改，明确排除且不触碰

完整工具链、工程与 reference 快照见 [`baseline.md`](./baseline.md)。

## 历史执行阶段

1. Gate 0：冻结基线和文件 owner；
2. Gate 1：完成十条审计线与五个横向清单的全量枚举；
3. Gate 2：按外部事实优先级取证；
4. Gate 3：只为会改变判断的争议运行最小真实验证；
5. Gate 4：交叉复核；
6. Gate 5：用户裁决并冻结审计。

## 文件 owner

- 主 Agent：本文件、`baseline.md`、`evidence-register.md`、`decision-register.md` 和
  `inventories/`。
- 第一轮 Agent A：`findings/01-api-auth-security.md`。
- 第一轮 Agent B：`findings/02-media-playback.md`。
- 第一轮 Agent C：`findings/03-concurrency-lifecycle.md` 与
  `findings/04-privacy-redirect-logging.md`。
- 第二轮 Agent D：`findings/05-native-ui-product-ia.md` 与
  `findings/07-accessibility-input.md`。
- 第二轮 Agent E：`findings/06-state-cache.md` 与
  `findings/09-architecture-necessity.md`。
- 主 Agent：`findings/08-performance-resources.md`、共享 evidence/decision register 与
  全部跨线复核。
- 第二轮 Agent F：`findings/10-engineering-distribution.md`。

## 当前阶段结论

- reference checkout 只完成本地 SHA 快照；任何“当前 OSS”结论仍须在使用前核对远端
  当前 commit 和日期。
- 五组验证已覆盖播放错误与弱网、生命周期与资源、Accessibility／键盘／布局、图片／缓存／
  滚动，以及签名安全边界。每项未获得的证据仍在 finding 和登记表中明确保留，不能由
  “五组完成”推导成全产品行为正确。
- 已使用签名 App、独立本机进程、受控 AVPlayer、Allocations 和脱敏匿名现场请求取得
  定点证据；熟练 VoiceOver 路径、Memory Graph、真实 macOS 15、Developer ID 与发布安装
  仍未覆盖。
- `bilibili-API-collect` 当前远端已永久关闭并删除文档，失效的 `main` 链接只能作为历史
  线索，不能计作 2026-07-27 的当前社区证据。
- `STATE-001`、`UI-008`、`MP-013`、`MP-014`、`M501-PRIV-003`、
  `M501-ENG-004` 与 `M501-PRIV-007` 已在用户逐项授权后完成窄修复；其余候选判断仍以
  `decision-register.md` 为准，不能因验证结束自动进入实施。
- Gate 5 已由用户 review 冻结；尚未实施的候选已迁入
  [`../../product/PRODUCT-CANDIDATES.md`](../../product/PRODUCT-CANDIDATES.md) 或继续
  保留为带触发条件的审计判断。审计完成不授权其进入生产。

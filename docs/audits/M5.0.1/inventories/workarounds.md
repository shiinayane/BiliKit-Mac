# Workaround 清单

状态：Gate 1 枚举中；由主 Agent 单写。

初始类别：

- API／WBI 403 后单次 key refresh 与重试：搜索最初见 `d63ba47`，字幕 WBI 迁移见
  `b60af1c`；
- Web QR 轮询间隔、180 秒／90 次总上限；
- transport request/resource timeout：认证、字幕、弹幕与生命周期阶段分别引入，
  不能视为同一个 workaround；
- Browse、Auth、Subtitle、Danmaku 与 Playback 的 generation／identity 隔离；
- Subtitle A → B → A reset／load 串行 worker：`25e4b87`；
- cue 时长合理性判断与自动重试曾作为未提交候选出现，WBI 根因确认后已 discard；当前 Git
  没有可审计实现，裁决记录见
  `docs/validation/M4.6-subtitle-lifecycle-roadmap-2026-07-25.md:34-43`；
- Browse 双工作集与 `deactivateRoute`／`reset`：M5 实现后由 `183d6f9`／`a9b4f1d`
  重命名；
- CDN candidate fallback、Range 错误 fallback；
- 特殊 `Referer`、`User-Agent`、`Range` 和 Content-Type 校验；
- 语义 `ScrollPosition`：`1db7f22`，真实验证记录更新于 `77c9a34`；
- resize 下的 Grid 列数与播放页布局决策；
- fixture／probe 专用启动和窗口配置。

Gate 1 必须回链引入 commit、原始症状、当前回归测试和根因是否已经变化。名称含
generation、retry 或 fallback 不自动构成删除理由。

# M4 性能与真实环境收口决策契约

> Revision：C1。状态：执行已停止。2026-07-23 独立红区终审发现 scheduler 去重状态存在跨分段无界增长路径；按本契约另立窄修复契约，M4 不得标记关闭。

## 决定什么

本轮只决定一件事：现有字幕、弹幕、时间轴、renderer 与播放 surface 是否已具备进入 M4.5 UI/UX 重构的稳定基线。

## 最低证据

1. 真实 App 在窗口放大、缩小、全屏和退出全屏后继续正常播放，字幕与弹幕恢复，播放器不重启或出现第二个 surface owner。
2. 长期运行跨越多个弹幕分段时，RSS 不随分段数持续单调增长；renderer 活动对象保持既有限界。
3. 连续 seek、播放项目替换和关闭页面后，旧 generation 不再显示，网络任务、时间轴观察、renderer、layer、surface 与 loopback 资源能够清理。
4. Package/App/static Gate、macOS 15/26 CI 与当前 macOS 真实 smoke 的结论一致。

## 失败与停止

- resize/fullscreen 导致播放重启、字幕/弹幕消失后不恢复、旧内容回流或 surface owner 大于 1；
- 经过预热后 RSS 仍随分段持续上升，或关闭后资源无法回落；
- 为取得结论必须开发通用 benchmark framework、修改 renderer 路线或明显扩大 harness；
- 测量结果含糊到无法支持关闭 M4。

出现以上任一情况即停止关闭 Gate，记录证据并单独修复；不得用放宽阈值或增加无关矩阵掩盖。

## 复杂度预算

- 复用现有 `BiliDanmakuProbe`、App 生产入口和系统进程采样；
- 最多增加 RSS、resize 与清理所需的窄计数，不新增 target、schema、endpoint 或通用 benchmark 层；
- 只使用一个代表性真实交互样本、一个仅用于替换验证的项目和一个 30 分钟受控负载，不做完整笛卡尔积；
- 验证记录不得保存 BVID、CID、标题、字幕／弹幕正文、账号标识或凭据。

## 完成后

全部证据通过则记录 M4 总 Gate，允许进入 M4.5 生产契约；任何一项失败则 M4 保持打开。

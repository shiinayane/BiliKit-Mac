# 完成声明真实性清单

状态：Gate 1 枚举中；由主 Agent 单写。

优先复核：

- `ROADMAP.md` 的 M0–M4.5 已完成声明；
- M1 真实播放、Range、seek、替换和 RSS 声明；
- M3 真实扫码、Keychain、登出、历史与安全边界声明；
- M4 字幕、弹幕、renderer、30 分钟和资源清理声明；
- M4.5 导航、键盘、焦点、大字体和真实 UI 声明；
- M5.0 原生导航、返回位置和工作集声明。

每项必须标注实际证据层：编译、fixture、确定性测试、签名 App、真实远端、真实 UI、
Instruments 或 CI。旧测试数量和 run ID 只描述当时执行，不自动证明当前基线。

## 已确认的状态漂移

- `ROADMAP.md` 与 `M5.0-native-navigation-state-retention-2026-07-26.md` 仍写
  macOS 15／26 CI 待完成；
- PR #18 的最终检查显示 macOS 15 `Build and test` 通过（3m24s）、macOS 26 通过
  （2m03s），真实播放 job 按条件 skipped；
- 因此“CI 待完成”已过时，但 CI 仍不替代文档列出的搜索 Tab 往返、Escape、resize、
  VoiceOver 或真实播放证据。审计阶段只登记，不直接关闭 M5.0 Gate。

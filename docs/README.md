# 项目文档

- [`ROADMAP.md`](./ROADMAP.md)：当前实施顺序与验收门槛。
- [`adr/`](./adr/)：已接受的架构决策。
- [`validation/`](./validation/)：注明日期、环境和适用边界的运行验证记录。
- [`RESEARCH-native-macos-client.md`](./RESEARCH-native-macos-client.md)：产品、竞品、播放、许可和分发研究基线。

现行文档必须区分仓库事实和目标方向。计划中的能力只有通过对应 gate 后，才能视为已实现。

## 本地参考项目

`references/` 专门存放用于研究第三方行为和项目历史的完整本地 checkout。该目录整体被 Git 忽略，也不进入 Xcode 工程；其中任何内容都不是 App 依赖或获准重新分发的输入。

将第三方源码、注释、fixture、图标或其他资产复制进 BiliKit 前，必须先核实来源和许可证兼容性。

已接受的决策：

- [`adr/0001-platform-naming-and-modules.md`](./adr/0001-platform-naming-and-modules.md)
- [`adr/0002-loopback-http-playback-bridge.md`](./adr/0002-loopback-http-playback-bridge.md)
- [`adr/0003-raise-minimum-macos-to-15.md`](./adr/0003-raise-minimum-macos-to-15.md)
- [`adr/0004-mvvm-clean-architecture.md`](./adr/0004-mvvm-clean-architecture.md)

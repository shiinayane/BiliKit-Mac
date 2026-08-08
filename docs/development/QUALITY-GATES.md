# 开发验证入口

> 2026-07-26 起，本文件不再定义红黄绿分级、任务契约、固定 reviewer 链、复杂度预算或
> 用户确认流程。旧路线图和验证记录中的相关文字只描述当时采用的过程，不是当前规则。

## 自动检查

按改动范围只运行最高适用命令：

```sh
sh Scripts/run-quality-gates.sh static
sh Scripts/run-quality-gates.sh package
sh Scripts/run-quality-gates.sh app
```

- `static`：文档、脚本、架构、秘密、工程配置和 Swift 格式检查。
- `package`：包含 `static`，并构建、测试本地 Swift Package。
- `app`：包含 `package`，并执行 App build-for-testing 和 App 测试。
- CI 使用同一个 App 入口，不维护第二套 lint 或测试规则。

## 构建产物生命周期

Gate 默认使用适合日常迭代的稳定缓存。缓存位于当前 checkout 的
`.build/bilikit-quality-gates/<checkout-key>/`；`checkout-key` 来自 canonical checkout
路径。同一 checkout 会复用 SwiftPM scratch、Xcode DerivedData、Xcode package checkout
以及 Clang／Swift module cache，不同 worktree 不共享这些可变状态。删除 checkout 时，这些
默认产物也随之进入同一清理边界。

验收或排查缓存污染时使用 fresh 模式：

```sh
BILIKIT_GATE_FRESH=1 sh Scripts/run-quality-gates.sh app
```

fresh 模式把 SwiftPM、Xcode、module cache 和精简日志都放入一次唯一、权限为 `0700` 的
临时根。脚本在成功、失败、`HUP`、`INT` 和 `TERM` 退出路径上验证 marker 与精确路径后清理
该根。需要保留失败现场时，唯一保留开关为：

```sh
BILIKIT_GATE_FRESH=1 \
BILIKIT_GATE_RETAIN_ARTIFACTS=1 \
BILIKIT_COMPACT_LOGS=1 \
sh Scripts/run-quality-gates.sh app
```

脚本会明确打印保留位置。保留目录包含构建产物和完整 gate 日志，需要由调用者在诊断后清理。
普通 compact 日志随 gate 退出清理；失败摘要仍打印最后 40 行。

`BILIKIT_DERIVED_DATA_PATH` 继续作为日常模式的调用方管理兼容入口；fresh 模式拒绝该覆盖，
以保证所有产物都位于唯一临时根。路径诊断可设置 `BILIKIT_GATE_PRINT_PATHS_ONLY=1`，它只输出
解析后的缓存路径，不运行 gate。所有模式都显式设置 SwiftPM scratch/package cache、Xcode
DerivedData/package cache 和 Clang／Swift module cache，避免回退到用户级 module cache。

异步测试必须用可观察事件、状态、continuation 或显式闸门判断工作开始和完成；固定时长
只能作为超时，不能用来推断状态已经稳定。

## 真实行为

自动检查只证明它实际覆盖的范围。根据改动内容补充最直接的真实观察，例如：

- 签名和 Keychain：签名 App 与真实 Keychain smoke；
- SwiftUI/AppKit：目标窗口和用户路径；
- 播放、字幕和弹幕：受控播放、切换、seek、取消与资源清理；
- CPU、内存、泄漏和卡顿：与问题匹配的 Instruments 或 `xctrace` 测量；
- 真实远端兼容性：脱敏、最小次数的现场 probe。

reviewer、subagent、Plan mode、专项 Skill 和长期计划文档都按任务需要使用。实现因新证据改变
时，更新当前说明或代码，不以偏离旧计划本身判错。

## Git 与记录

- 未经用户要求不提交、推送、创建 PR 或改写历史。
- PR 说明实际变化、验证结果和未验证边界即可，不要求风险等级或审查表单。
- `docs/validation/` 只记录以后仍需复查的真实设备、网络、性能、安全或兼容性证据。
- `docs/ROADMAP.md` 只在代码、测试和必要真实行为一致时更新状态。

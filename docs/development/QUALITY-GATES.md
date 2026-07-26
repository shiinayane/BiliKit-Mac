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

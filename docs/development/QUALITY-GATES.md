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

Gate 把检查范围与产物策略分开。默认策略是适合日常开发的 `iteration`：

```sh
sh Scripts/run-quality-gates.sh app iteration
```

省略第二个参数仍表示 `iteration`。缓存位于当前 checkout 的
`.build/bilikit-quality-gates/<checkout-key>/generations/<generation-key>/`；`checkout-key`
来自 canonical checkout 路径。`generation-key` 包含缓存 schema、完整 Xcode Developer
目录、Xcode／Swift 版本、architecture、`Package.swift`、两份 `Package.resolved`、
`project.pbxproj`、shared scheme、`.xcconfig` 和 `.xctestplan`。这些输入变化会建立新
generation；普通 Swift 源码、测试、资源和文档变化继续复用当前 generation，由 SwiftPM／
Xcode 自己做增量失效，不会因每次编辑变成 cold build。

日常定向测试必须同样使用当前 generation 的 SwiftPM scratch/cache/config/security 或
Xcode DerivedData/package/module 路径，且只能作为定向证据。日常 `iteration` Gate 证明当前
增量环境；production PR 最终自动验收必须在最高适用 mode 后使用独立的 `closure`。例如
代码、App 或 Composition 改动使用：

```sh
sh Scripts/run-quality-gates.sh app closure
```

`closure` 强制使用 fresh 私有根，并在输出与 GitHub Summary 中留下独立 artifact policy，
因此不能用普通 `app` 成功冒充最终 closure。仅为排查缓存污染可使用 diagnostic `fresh`；
`BILIKIT_GATE_FRESH=1` 作为旧调用方兼容入口等价于它：

```sh
sh Scripts/run-quality-gates.sh app fresh
```

`fresh` 与 `closure` 都把 SwiftPM scratch/cache/config/security/private home、Xcode
DerivedData/package checkout/package cache/private home、Clang／Swift／manifest ModuleCache
和精简日志放入一次唯一、权限为 `0700` 的临时根。xcodebuild 的 `HOME`、
`CFFIXED_USER_HOME` 与 `XDG_CACHE_HOME` 只对该子进程定向到 private home，避免内部 SwiftPM
manifest 与 Xcode log store 回落到用户目录。脚本在成功、失败、`HUP`、`INT` 和 `TERM` 等可捕获退出路径上验证
canonical prefix、owner、mode、schema marker、checkout identity 与 run identity 后，只清理
该精确根。finalizer 开始后会忽略二次可捕获信号，直到容量统计与精确清理完成。外部 bounded
runner 应终止 Gate 的整个进程组，避免只结束父 shell 而留下正在运行的编译子进程；以 `TERM`
实现 timeout 时应设置
`BILIKIT_GATE_TERM_IS_TIMEOUT=1`；最终 `timeout.inconclusive` 归因仍由实际发出 timeout 的
调用方确认。`SIGKILL`、断电或 marker 写入前的强制终止无法安全捕获，宁可遗留也不扩大删除
范围。

需要保留脱敏后的诊断产物时，唯一保留开关为：

```sh
BILIKIT_GATE_RETAIN_ARTIFACTS=1 \
sh Scripts/run-quality-gates.sh app fresh
```

脚本会打印保留位置及 `cleanup-retained` 精确命令。后续清理仍验证 owner、0700、marker、
checkout identity 和临时根 prefix；`/`、`HOME`、仓库根、外部目录、symlink 逃逸或缺失 marker
都会被拒绝。所有阶段无论 compact 开关如何都先捕获并脱敏 checkout/HOME/artifact path、完整
URL 和常见凭据字段；`BILIKIT_COMPACT_LOGS=0` 只表示向控制台回显脱敏后的完整日志。若脱敏或
原子替换失败，Gate 会覆盖 retain 并清理精确 fresh root，绝不保留或打印原始日志。普通日志
随 Gate 退出清理，compact 失败摘要只打印最后 40 行。

`BILIKIT_DERIVED_DATA_PATH` 只保留为 `iteration` 的受控兼容入口，并且只能解析为当前
generation 的直接子目录；fresh/closure 或任意外部路径都会失败关闭。路径诊断可设置
`BILIKIT_GATE_PRINT_PATHS_ONLY=1`，它只输出解析后的缓存路径，不运行检查。所有模式默认局部
使用 `/Applications/Xcode.app/Contents/Developer`，也允许调用方显式传入另一套完整
`DEVELOPER_DIR`；Gate 从不执行 `xcode-select --switch`。

每次退出会分别报告 `repository-artifacts` 的 total、SwiftPM scratch/cache/config/security、
private home、DerivedData、package、ModuleCache、logs 与无法归类的 other 大小，以及 iteration
generation 数。它只描述仓库产物，不等于 apple-dev-loop 的 session quota，也不等于磁盘真正
不足。出现旧 generation 或明确缓存污染证据时，确认没有同 checkout
并行 Gate 后运行：

```sh
sh Scripts/run-quality-gates.sh cleanup-iteration
```

该命令不接受路径参数，只能删除当前 checkout 下 marker 与 identity 验证通过的精确根；它不
扫描其他 worktree，也不触碰用户级 SwiftPM、DerivedData 或 ModuleCache。Gate 不会在任意编译
错误后自动重跑 fresh；失败会按明确证据区分 `configuration`、`toolchain`、`sandbox`、
`build`、`test.assertion`、`test.infrastructure`、`signing`、`timeout.inconclusive` 与
`unknown`。断言没有实际执行时，不能称为代码或测试 assertion 失败。

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

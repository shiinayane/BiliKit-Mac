# 开发验证入口

迭代期间只做最小定向验证；交付前只运行一次覆盖改动的最高适用 Gate：

```sh
sh Scripts/run-quality-gates.sh static
sh Scripts/run-quality-gates.sh package
sh Scripts/run-quality-gates.sh app
```

- `static`：架构、秘密模式、工程配置、Swift 格式、diff whitespace，以及本机发布安全契约与 feed 验签测试（需要 Python 3 和 Node）。
- `package`：包含 `static`，并构建、测试本地 Swift Package。
- `app`：包含 `package`，并执行 App build-for-testing 与 App unit tests。

Gate 每次使用私有临时目录保存 SwiftPM 与 Xcode 产物，退出时清理；不修改全局
`xcode-select`。手写 `xcodebuild`、XCUI 和 App 启动也必须统一使用本任务唯一的临时产物
根目录，并在任务结束时清理。其他 worktree 或旧共享 DerivedData 不算 fresh closure；仅用于
临时运行时诊断时需注明证据边界。CI 使用同一入口，并在 macOS 15/26
宿主上显式选择同一套新 Xcode/SDK；这个矩阵不承诺旧 SDK 编译兼容。

Gate 是交付闭包，不是迭代命令。定向测试可在同一任务内复用一份私有缓存；临时根必须由
当前任务唯一创建，不能跨 worktree 或任务复用，并在任务结束时整体删除：

```sh
task_artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/BiliKit-targeted.XXXXXX")
cleanup() { rm -rf -- "$task_artifact_root"; }
trap cleanup EXIT

sh Scripts/run-targeted-tests.sh \
    "$task_artifact_root" package 'GuestVideoViewModelTests'
sh Scripts/run-targeted-tests.sh \
    "$task_artifact_root" app 'BiliKitMacTests/PlaybackSourceSettingsTests'
```

重复调用同一模式会复用该任务根内的 SwiftPM scratch 或 Xcode DerivedData；`--filter` 和
`-only-testing` 只缩小测试执行集合，首次调用仍可能编译对应 test product 的完整依赖图。
脚本会在空任务根写入当前 canonical worktree 的 owner marker；非空但无 marker 或 owner 不匹配
时拒绝复用。最终验证仍使用上面的 Gate，由 Gate 创建并清理新的 fresh closure。

仅在明确的性能裁决中运行 Instruments/`xctrace`；事前限定问题、时长、次数和产物目录。
摘要完成后默认删除 raw trace，并退出 Instruments、确认没有开放 trace、清理临时产物。

测试服务于产品：优先用简单 unit/model/ViewModel 测试固定状态、identity、generation、
取消与资源清理。不得为了自动化改变用户 accessibility 语义。XCUI 只在更低层无法证明的
关键系统边界存在；依赖内部层级、固定 index、坐标、时序或截图偶然性的测试应删除。

自动检查只证明实际执行的范围。VoiceOver、Full Keyboard Access、签名、Keychain、真实
网络、播放和性能必须按任务需要分别观察，不能由 build、AX tree、mock 或截图互相替代。

未经用户要求不提交、推送、创建 PR 或改写历史。

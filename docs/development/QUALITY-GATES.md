# 开发验证入口

迭代期间只做最小定向验证；交付前只运行一次覆盖改动的最高适用 Gate：

```sh
sh Scripts/run-quality-gates.sh static
sh Scripts/run-quality-gates.sh package
sh Scripts/run-quality-gates.sh app
```

- `static`：架构、秘密模式、工程配置、Swift 格式和 diff whitespace。
- `package`：包含 `static`，并构建、测试本地 Swift Package。
- `app`：包含 `package`，并执行 App build-for-testing 与 App unit tests。

Gate 每次使用私有临时目录保存 SwiftPM 与 Xcode 产物，退出时清理；不修改全局
`xcode-select`。手写 `xcodebuild`、XCUI 和 App 启动也必须统一使用本任务唯一的临时产物
根目录，并在任务结束时清理。其他 worktree 或旧共享 DerivedData 不算 fresh closure；仅用于
临时运行时诊断时需注明证据边界。CI 使用同一入口。

仅在明确的性能裁决中运行 Instruments/`xctrace`；事前限定问题、时长、次数和产物目录。
摘要完成后默认删除 raw trace，并退出 Instruments、确认没有开放 trace、清理临时产物。

测试服务于产品：优先用简单 unit/model/ViewModel 测试固定状态、identity、generation、
取消与资源清理。不得为了自动化改变用户 accessibility 语义。XCUI 只在更低层无法证明的
关键系统边界存在；依赖内部层级、固定 index、坐标、时序或截图偶然性的测试应删除。

自动检查只证明实际执行的范围。VoiceOver、Full Keyboard Access、签名、Keychain、真实
网络、播放和性能必须按任务需要分别观察，不能由 build、AX tree、mock 或截图互相替代。

未经用户要求不提交、推送、创建 PR 或改写历史。

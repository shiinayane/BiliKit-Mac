# M4 scheduler 去重保留边界修复实施草案

> 状态：实施草案，不代表用户逐项确认；D1 已确认并完成本机实现与验证，可在不改变决策、风险和复杂度预算时调整。

1. 先增加跨越至少八段的失败测试，覆盖唯一 ID、相邻分段重复 ID、cache 淘汰、向后 seek、generation 变化和 reset。
2. 将去重状态按分段保留并随有效窗口裁剪；内部只暴露测试所需的计数，不增加产品公共配置。
3. 让既有受控入口使用自制 repository、timeline、`DanmakuSession`、scheduler、controller 与 renderer；确定性测试用虚拟时间跨越八段并直接断言去重上界，probe 用既有 wall-clock 参数跨越六段并记录离散 RSS。
4. 复用既有 renderer 视觉容量结论，不重做路线选择；完整链路的 80 events/s、30 分钟运行只回答跨分段 RSS 与 stop 清理，不开发新的 soak 框架。
5. 运行定向测试、统一 App Gate和独立红区复审；通过后再请求提交 PR，以 macOS 15/26 CI 作为正式关闭 M4 的最后条件。

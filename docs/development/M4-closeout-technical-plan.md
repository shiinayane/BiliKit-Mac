# M4 性能与真实环境收口实施草案

> 状态：已停止。renderer-only 负载已完成，但没有经过 `DanmakuSession` 与跨分段 scheduler，不能用于关闭 M4；后续只按独立 scheduler 修复契约继续。

1. 先运行现有 Package/App 基线，确认不是在已知失败上测量。
2. 为现有 renderer probe 增加进程 RSS 的起点、预热后周期样本、停止前与清理后结果；输出只保留 MiB、计数和状态。
3. 运行 80 events/s、30 分钟生产 probe。以预热后的样本判断是否存在随时间持续增长的趋势，不设没有历史依据的伪精确 MiB 阈值。
4. 构建并启动签名 App，通过 Computer Use 执行宽窄 resize、全屏往返、连续 seek、切换视频／返回和关闭窗口；使用现有诊断计数与进程采样核对资源。
5. 运行统一 App Gate，记录当前 macOS 真实环境与远程 CI 的适用边界。
6. 由未参与实施的独立红区上下文审查线程、owner、资源和隐私证据；通过后才关闭 M4。

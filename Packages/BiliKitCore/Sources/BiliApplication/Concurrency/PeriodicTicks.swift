/// 系统时钟的周期时刻，周期轮询的唯一实现。
///
/// 观看进度的周期 heartbeat（`WatchProgressSession.Environment.live`）与播放页「正在看」人数的刷新
/// （`VideoOnlineViewerModel`，由 App 注入）共用；测试换成手动的时刻。
public enum PeriodicTicks {
    /// 每隔 `interval` 产生一次。
    ///
    /// 在消费方的 Task 里睡眠，不另起 Task：消费方取消或停止迭代时流随之结束，没有要清理的睡眠者。间隔从消费方
    /// 要下一个时刻时算起，消费方处理一次的耗时会顺延下一次。
    public static func system(every interval: Duration) -> AsyncStream<Void> {
        AsyncStream(unfolding: {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return nil
            }
            return ()
        })
    }
}

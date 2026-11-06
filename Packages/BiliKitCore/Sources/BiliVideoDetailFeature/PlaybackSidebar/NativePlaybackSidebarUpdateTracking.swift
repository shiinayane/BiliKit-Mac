/// 侧栏快照的代次与在途数；由 `NativePlaybackSidebarController` 独占持有，只经下面的方法改变。
///
/// `generation` 在每次应用快照（`beginApplication`）、原地重载或拆除（`invalidate`）时递增。快照完成回调与分页
/// 判断捕获当时的代次，不相等说明已有更新的快照：旧完成回调不再恢复视口与精测，只在在途数归零时补一次
/// 分页判断；旧分页判断直接放弃。`applicationsInFlight` 是已交给数据源、完成回调还没回来的快照数，大于 0 时
/// 更新策略只整体替换、分页也等它归零。
@MainActor
final class NativePlaybackSidebarSnapshotTracker {
    private(set) var generation: UInt64 = 0
    private(set) var applicationsInFlight = 0

    /// 不经数据源完成回调的变化（原地重载、拆除）：只让旧回调与旧分页判断失效。
    func invalidate() {
        generation &+= 1
    }

    /// 把一个快照交给数据源之前调用，返回这次的代次；完成回调里调用 `finishApplication`。
    func beginApplication() -> UInt64 {
        generation &+= 1
        applicationsInFlight += 1
        return generation
    }

    func finishApplication() {
        applicationsInFlight = max(0, applicationsInFlight - 1)
    }
}

/// 侧栏行高的分批精测：私有持有精测 Task 与它的代次，只暴露开始与取消。
///
/// 每次 `start` 或 `cancel` 都递增代次并让旧循环在下一批之前停下（含仍在 `delay` 里等待的循环）；循环每批调用
/// 一次 `step`（返回 false 即停止），批间让出 main actor。只有代次仍相等时结束的循环才清空 Task。由侧栏控制器
/// 持有，控制器在更新、改宽度与拆除时取消。
@MainActor
final class NativePlaybackSidebarRefinementScheduler {
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func start(after delay: Duration = .zero, step: @escaping @MainActor () -> Bool) {
        generation &+= 1
        let currentGeneration = generation
        task = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            while !Task.isCancelled, self?.generation == currentGeneration, step() {
                await Task.yield()
            }
            guard let self, self.generation == currentGeneration else { return }
            self.task = nil
        }
    }
}

/// 侧栏列表近尾分页判断的调度（评论侧栏与 UP 主空间列表）：私有持有那个等一轮 main actor 再判断的 Task，同时只有一个。
///
/// 持有者决定何时取消（评论侧栏在快照更新、条目原地变化与拆除时，空间列表在拆除时）；判断本身（代次、在途数、
/// 近尾状态）由调用方的闭包完成。
@MainActor
final class NativePlaybackSidebarPaginationScheduler {
    private var task: Task<Void, Never>?

    var isScheduled: Bool { task != nil }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 等一轮 main actor 再调用 `check`：让本轮布局与可见项更新完；期间被取消就不调用。
    func schedule(_ check: @escaping @MainActor () -> Void) {
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.task = nil
            guard !Task.isCancelled else { return }
            check()
        }
    }
}

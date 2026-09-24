/// 只保留最新一次意图的单个 Task：替换或取消后，旧 Task 既不能写回，也不能清掉新 Task 的引用。
///
/// `isCurrent()` 在 token 仍匹配且当前 Task 未取消时为真；业务身份（请求、subject、BVID）
/// 仍由调用方自行比对。各 Feature 的 ViewModel 共用这一实现，不再各自维护 generation。
@MainActor
package final class LatestTask {
    package typealias IsCurrent = @MainActor () -> Bool

    package private(set) var task: Task<Void, Never>?
    private var token = 0

    package init() {}

    deinit {
        task?.cancel()
    }

    /// 最新意图仍未结束；被替换或取消的旧 Task 不计入。
    package var isRunning: Bool {
        task != nil
    }

    package func replace(
        _ operation: @escaping @MainActor (_ isCurrent: @escaping IsCurrent) async -> Void
    ) {
        token &+= 1
        let currentToken = token
        task?.cancel()
        let isCurrent: IsCurrent = { [weak self] in
            self?.token == currentToken && !Task.isCancelled
        }
        task = Task { [weak self] in
            await operation(isCurrent)
            guard let self, token == currentToken else { return }
            task = nil
        }
    }

    package func cancel() {
        token &+= 1
        task?.cancel()
        task = nil
    }

    package func wait() async {
        await task?.value
    }
}

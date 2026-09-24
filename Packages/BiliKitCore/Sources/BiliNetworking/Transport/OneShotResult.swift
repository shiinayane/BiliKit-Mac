import Synchronization

/// 只交付一次的异步结果：结果可以早于等待方到达，首个结果之后的交付全部忽略。
///
/// 用于把 delegate、状态回调或超时竞争桥接为单个 `await`，替代各处手写的
/// “锁 + continuation + 已完成标记”。同一实例只允许一个等待方。
package final class OneShotResult<Value: Sendable>: Sendable {
    private enum State {
        case pending(CheckedContinuation<Value, any Error>?)
        case resolved(Result<Value, any Error>)
    }

    private let state = Mutex(State.pending(nil))

    package init() {}

    package func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Value, any Error>? in
                switch state {
                case .resolved(let result):
                    return result
                case .pending:
                    state = .pending(continuation)
                    return nil
                }
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }

    /// 返回 false 表示已有结果，本次交付被忽略。
    @discardableResult
    package func resolve(_ result: Result<Value, any Error>) -> Bool {
        let outcome = state.withLock {
            state -> (accepted: Bool, waiter: CheckedContinuation<Value, any Error>?) in
            guard case .pending(let waiter) = state else { return (false, nil) }
            state = .resolved(result)
            return (true, waiter)
        }
        outcome.waiter?.resume(with: result)
        return outcome.accepted
    }
}

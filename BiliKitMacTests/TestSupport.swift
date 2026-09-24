import BiliApplication
import Observation

/// App 测试 target 共用的等待与记录替身；各测试文件不再各自复制。

/// 等待 AppKit 在后续 main actor 回合完成的布局或 diff 应用；只让出执行权，不按固定时长轮询。
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

/// 等待 `@Observable` 状态满足条件：每次被追踪属性变化后才重新判断，超时由测试的 time limit 兜底。
@MainActor
func waitForObservedState(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// 可等待的事件计数：记录端 `record()`，等待端挂起到计数达到目标为止。
actor TestEventCounter {
    private(set) var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(untilCount target: Int = 1) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

/// `AuthenticatedSessionInvalidating` 的唯一测试替身，只记录失效次数。
actor RecordingSessionInvalidator: AuthenticatedSessionInvalidating {
    private(set) var invalidationCount = 0

    func invalidateAuthenticatedSession() {
        invalidationCount += 1
    }
}

import Foundation
import Observation

@testable import BiliBrowseFeature

/// 本 target 共用的等待与闸门替身；各测试文件不再各自复制。

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

/// 等到当前视频意图写回终态；内容准备与播放器安装期间的状态都不算完成。
@MainActor
func waitUntilSettled(_ model: VideoViewModel) async {
    await waitForObservedState {
        switch model.state {
        case .idle, .ready, .failed, .failedPage:
            true
        case .loading, .loadingPage, .preparingPlayback:
            false
        }
    }
}

/// 让替身中的请求挂起到测试放行；放行后后续请求直接通过。
///
/// 挂起期间忽略取消以模拟迟到结果，但记录取消事件，测试据此确认旧意图已被新意图取消。
actor TestGate {
    private let entries = TestEventCounter()
    private let cancellations = TestEventCounter()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await entries.signal()
        guard !isOpen else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancellations.signal() }
        }
    }

    /// 等到第 `count` 个请求进入；等待失败时先放行，避免挂起的请求拖住测试。
    func waitForEntries(_ count: Int = 1) async throws {
        do {
            try await entries.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    /// 等到第 `count` 个挂起中的请求被取消；等待失败时先放行。
    func waitForCancellations(_ count: Int = 1) async throws {
        do {
            try await cancellations.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    func open() {
        isOpen = true
        waiters.resumeAll()
    }
}

actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

// MARK: - 挂起与计数等待

/// 由持有者在自己的隔离域内同步使用的计数等待表；计数本身由持有者保存与推进。
struct CountWaiters {
    private var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// `current` 已达到 `target` 时立即恢复，否则登记到 `resume(reaching:)`。
    mutating func add(
        _ continuation: CheckedContinuation<Void, Never>,
        until target: Int,
        current: Int
    ) {
        if current >= target {
            continuation.resume()
        } else {
            pending.append((target, continuation))
        }
    }

    mutating func resume(reaching count: Int) {
        let ready = pending.filter { $0.target <= count }
        pending.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

import Testing

@testable import BiliApplication

@MainActor
struct LatestTaskTests {
    enum Supersession: CaseIterable, Sendable {
        case replace
        case cancel
    }

    @Test(.timeLimit(.minutes(1)), arguments: Supersession.allCases)
    func supersededOperationIsCancelledAndCanNoLongerWriteBack(
        _ supersession: Supersession
    ) async {
        let latest = LatestTask()
        let oldGate = Gate()
        let oldFinished = Gate()
        let newGate = Gate()
        let log = Log()

        latest.replace { isCurrent in
            await oldGate.wait()
            log.entries.append("old cancelled=\(Task.isCancelled) current=\(isCurrent())")
            oldFinished.open()
        }
        switch supersession {
        case .replace:
            latest.replace { isCurrent in
                await newGate.wait()
                log.entries.append("new cancelled=\(Task.isCancelled) current=\(isCurrent())")
            }
        case .cancel:
            latest.cancel()
        }

        oldGate.open()
        await oldFinished.wait()
        #expect(log.entries == ["old cancelled=true current=false"])
        // 旧 Task 结束不能清掉新意图的引用。
        #expect(latest.isRunning == (supersession == .replace))

        newGate.open()
        await latest.wait()
        #expect(!latest.isRunning)
        switch supersession {
        case .replace:
            #expect(log.entries.last == "new cancelled=false current=true")
        case .cancel:
            #expect(log.entries.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func completedOperationReleasesItsTask() async {
        let latest = LatestTask()
        let gate = Gate()

        latest.replace { _ in await gate.wait() }
        #expect(latest.isRunning)
        gate.open()
        await latest.wait()

        #expect(!latest.isRunning)
    }
}

/// 不响应取消的闸门：让旧 operation 在被取代后仍能被显式放行，以观察它的写回判断。
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.resumeAll()
    }
}

@MainActor
private final class Log {
    var entries: [String] = []
}

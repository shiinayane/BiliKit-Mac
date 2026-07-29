import Foundation
import Testing

struct SubtitlePlaybackFreezeSpikeTests {
    @Test
    func subtitleCompletedBeforeMediaCutoffIsIncludedImmediately() async {
        let subtitleSource = ControlledStream<String>()
        let deadline = ControlledStream<Void>()
        subtitleSource.yield("already-prepared")

        let outcome = await freezeSubtitleAtMediaCutoff(
            generation: 1,
            subtitleStream: subtitleSource.stream,
            deadlineStream: deadline.stream
        )

        #expect(
            outcome
                == .included(
                    generation: 1,
                    value: "already-prepared"
                )
        )
        #expect(deadline.terminationProbe.wasCancelled)
    }

    @Test
    func subtitleCompletedDuringGraceWindowIsIncluded() async {
        let subtitleSource = ControlledStream<String>()
        let deadline = ControlledStream<Void>()
        let freeze = Task {
            await freezeSubtitleAtMediaCutoff(
                generation: 2,
                subtitleStream: subtitleSource.stream,
                deadlineStream: deadline.stream
            )
        }

        subtitleSource.yield("prepared-webvtt")
        let outcome = await freeze.value

        #expect(
            outcome
                == .included(
                    generation: 2,
                    value: "prepared-webvtt"
                )
        )
        #expect(deadline.terminationProbe.wasCancelled)
    }

    @Test
    func deadlineOmitsSubtitleAndRejectsLateCompletion() async {
        let subtitleSource = ControlledStream<String>()
        let deadline = ControlledStream<Void>()
        let freeze = Task {
            await freezeSubtitleAtMediaCutoff(
                generation: 7,
                subtitleStream: subtitleSource.stream,
                deadlineStream: deadline.stream
            )
        }

        deadline.yield(())
        let outcome = await freeze.value
        let lateYield = subtitleSource.yield("too-late")

        #expect(outcome == .omitted(generation: 7, reason: .deadline))
        #expect(lateYield.wasTerminated)
        #expect(subtitleSource.terminationProbe.wasCancelled)
    }

    @Test
    func cancellationTerminatesSubtitleAndDeadlineWaiters() async {
        let subtitleSource = ControlledStream<String>()
        let deadline = ControlledStream<Void>()
        let freeze = Task {
            await freezeSubtitleAtMediaCutoff(
                generation: 11,
                subtitleStream: subtitleSource.stream,
                deadlineStream: deadline.stream
            )
        }

        freeze.cancel()
        let outcome = await freeze.value

        #expect(outcome == .omitted(generation: 11, reason: .cancelled))
        #expect(subtitleSource.terminationProbe.wasCancelled)
        #expect(deadline.terminationProbe.wasCancelled)
    }

    @Test
    func replacementRejectsLateOldGenerationAndIncludesNewGeneration() async {
        let oldSubtitle = ControlledStream<String>()
        let oldDeadline = ControlledStream<Void>()
        let oldFreeze = Task {
            await freezeSubtitleAtMediaCutoff(
                generation: 20,
                subtitleStream: oldSubtitle.stream,
                deadlineStream: oldDeadline.stream
            )
        }
        oldFreeze.cancel()
        let oldOutcome = await oldFreeze.value

        let newSubtitle = ControlledStream<String>()
        let newDeadline = ControlledStream<Void>()
        let newFreeze = Task {
            await freezeSubtitleAtMediaCutoff(
                generation: 21,
                subtitleStream: newSubtitle.stream,
                deadlineStream: newDeadline.stream
            )
        }
        let lateOldYield = oldSubtitle.yield("old-generation")
        newSubtitle.yield("new-generation")
        let newOutcome = await newFreeze.value

        #expect(
            oldOutcome == .omitted(generation: 20, reason: .cancelled)
        )
        #expect(lateOldYield.wasTerminated)
        #expect(
            newOutcome
                == .included(
                    generation: 21,
                    value: "new-generation"
                )
        )
    }
}

private enum SubtitleFreezeOmission: Sendable, Equatable {
    case deadline
    case cancelled
}

private enum SubtitleFreezeOutcome<Value: Sendable & Equatable>:
    Sendable,
    Equatable
{
    case included(generation: UInt64, value: Value)
    case omitted(generation: UInt64, reason: SubtitleFreezeOmission)
}

private enum SubtitleFreezeEvent<Value: Sendable & Equatable>: Sendable {
    case subtitle(Value)
    case deadline
    case cancelled
}

private func freezeSubtitleAtMediaCutoff<Value: Sendable & Equatable>(
    generation: UInt64,
    subtitleStream: AsyncStream<Value>,
    deadlineStream: AsyncStream<Void>
) async -> SubtitleFreezeOutcome<Value> {
    await withTaskGroup(
        of: SubtitleFreezeEvent<Value>.self
    ) { group in
        group.addTask {
            var iterator = subtitleStream.makeAsyncIterator()
            guard let value = await iterator.next() else {
                return .cancelled
            }
            return .subtitle(value)
        }
        group.addTask {
            var iterator = deadlineStream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                return .cancelled
            }
            return .deadline
        }

        let first = await group.next() ?? .cancelled
        group.cancelAll()

        return switch first {
        case .subtitle(let value):
            .included(generation: generation, value: value)
        case .deadline:
            .omitted(generation: generation, reason: .deadline)
        case .cancelled:
            .omitted(generation: generation, reason: .cancelled)
        }
    }
}

private final class ControlledStream<Element: Sendable>: @unchecked Sendable {
    let stream: AsyncStream<Element>
    let terminationProbe = StreamTerminationProbe()

    private let continuation: AsyncStream<Element>.Continuation

    init() {
        let pair = AsyncStream<Element>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [terminationProbe] reason in
            if case .cancelled = reason {
                terminationProbe.recordCancelled()
            }
        }
    }

    @discardableResult
    func yield(
        _ element: Element
    ) -> AsyncStream<Element>.Continuation.YieldResult {
        continuation.yield(element)
    }
}

private final class StreamTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func recordCancelled() {
        lock.withLock {
            cancelled = true
        }
    }
}

extension AsyncStream.Continuation.YieldResult {
    fileprivate var wasTerminated: Bool {
        if case .terminated = self {
            return true
        }
        return false
    }
}

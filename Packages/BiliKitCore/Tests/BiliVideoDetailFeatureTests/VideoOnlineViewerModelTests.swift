import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 「正在看」人数：选中分 P 时读一次，之后只在时间线正在播放这个分 P 的刷新时刻再读；读取失败保留上一次的人数，B 站不显示
/// 时清空；被取代的分 P 迟到的结果丢弃。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VideoOnlineViewerModelTests {
    private static let identity = PlaybackItemIdentity(bvid: "BV1OnlineFix", cid: 1)
    private static let other = PlaybackItemIdentity(bvid: "BV1OnlineFix", cid: 2)

    @Test
    func refreshesOnlyWhilePlayingTheSelectedPart() async throws {
        let repository = OnlineViewerRepositoryStub(
            results: [
                Self.identity: [
                    .success("12"), .success("20"), .failure(.unavailable), .success(nil)
                ]
            ]
        )
        let timeline = ManualTimeline()
        let ticks = ManualRefreshTicks()
        let model = VideoOnlineViewerModel(
            useCase: VideoOnlineViewerUseCase(repository: repository),
            timeline: timeline,
            refreshTicks: { _ in ticks.stream() }
        )
        timeline.send(Self.snapshot(Self.identity, .paused))

        // 选中时读一次，不管是否在播。
        model.select(Self.identity)
        try await ticks.waitUntilWaiting(1)
        #expect(model.text(for: Self.identity) == "12")
        #expect(model.text(for: Self.other) == nil)

        // 暂停中的刷新时刻不发请求。
        await ticks.fire()
        try await ticks.waitUntilWaiting(2)
        #expect(await repository.requestCount == 1)

        // 播放中刷新。
        timeline.send(Self.snapshot(Self.identity, .playing))
        await ticks.fire()
        try await ticks.waitUntilWaiting(3)
        #expect(model.text(for: Self.identity) == "20")

        // 读取失败保留上一次的人数。
        await ticks.fire()
        try await ticks.waitUntilWaiting(4)
        #expect(await repository.requestCount == 3)
        #expect(model.text(for: Self.identity) == "20")

        // B 站不显示时清空。
        await ticks.fire()
        try await ticks.waitUntilWaiting(5)
        #expect(model.viewers == nil)

        // 播放器上在播的是另一个分 P：不发请求。
        timeline.send(Self.snapshot(Self.other, .playing))
        await ticks.fire()
        try await ticks.waitUntilWaiting(6)
        #expect(await repository.requestCount == 4)

        model.reset()
    }

    @Test
    func supersededPartResultIsDropped() async throws {
        let gate = TestGate()
        let model = VideoOnlineViewerModel(
            useCase: VideoOnlineViewerUseCase(
                repository: OnlineViewerRepositoryStub(
                    results: [Self.identity: [.success("12")], Self.other: [.success("30")]],
                    gates: [Self.identity: gate]
                )
            ),
            timeline: ManualTimeline(),
            refreshTicks: { _ in AsyncStream { $0.finish() } }
        )

        let superseded = SpawnedTasks { model.select(Self.identity) }
        try await gate.waitForEntries()
        model.select(Self.other)
        await waitForObservedState { model.viewers != nil }
        await gate.open()
        await superseded.finished()

        #expect(model.viewers == VideoOnlineViewers(identity: Self.other, text: "30"))
        model.reset()
    }

    private static func snapshot(
        _ identity: PlaybackItemIdentity,
        _ state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 10,
            durationSeconds: 300,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: 1,
            loadIntent: PlaybackLoadIntent()
        )
    }
}

/// 「正在看」人数读取替身：按分 P 依次给出预设结果，用完后是 nil；给了闸门的分 P 先在闸门处挂起。
private actor OnlineViewerRepositoryStub: VideoOnlineViewerRepository {
    private var results: [PlaybackItemIdentity: [Result<String?, ContentApplicationError>]]
    private let gates: [PlaybackItemIdentity: TestGate]
    private(set) var requestCount = 0

    init(
        results: [PlaybackItemIdentity: [Result<String?, ContentApplicationError>]],
        gates: [PlaybackItemIdentity: TestGate] = [:]
    ) {
        self.results = results
        self.gates = gates
    }

    func onlineViewerText(for identity: PlaybackItemIdentity) async throws -> String? {
        requestCount += 1
        if let gate = gates[identity] {
            await gate.pass()
        }
        guard var queue = results[identity], !queue.isEmpty else { return nil }
        let result = queue.removeFirst()
        results[identity] = queue
        return try result.get()
    }
}

/// 手动的刷新时刻：模型每次开始等下一个时刻都记一次，测试据此知道上一个时刻已经处理完，再 `fire()` 放出下一个。
private actor ManualRefreshTicks {
    private let waits = TestEventCounter()
    private var pending: CheckedContinuation<Void?, Never>?

    nonisolated func stream() -> AsyncStream<Void> {
        AsyncStream(
            unfolding: { await self.next() },
            onCancel: { Task { await self.finish() } }
        )
    }

    func waitUntilWaiting(_ count: Int) async throws {
        try await waits.wait(until: count)
    }

    func fire() {
        pending?.resume(returning: ())
        pending = nil
    }

    private func next() async -> Void? {
        await withCheckedContinuation { continuation in
            pending = continuation
            Task { await waits.signal() }
        }
    }

    private func finish() {
        pending?.resume(returning: nil)
        pending = nil
    }
}

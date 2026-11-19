import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 章节模型：当前章节每个快照都跟着位置变；「进入第几章」只在播放落定到另一章时提示一次，开播、拖动途中与同一章内的
/// 跳转不提示；读取失败不记下结果、同一分 P 再选时重读，被取代的分 P 迟到的结果丢弃。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VideoChapterModelTests {
    private static let identity = PlaybackItemIdentity(bvid: "BV1ChapterFix", cid: 1)
    private static let chapters = [
        VideoChapter(startSeconds: 0, endSeconds: 100, title: "A", coverURL: nil),
        VideoChapter(startSeconds: 100, endSeconds: 200, title: "B", coverURL: nil),
        VideoChapter(startSeconds: 200, endSeconds: 300, title: "C", coverURL: nil)
    ]

    @Test
    func announcesOnlySettledChapterChanges() async {
        let timeline = ManualTimeline()
        let model = VideoChapterModel(
            useCase: VideoChapterUseCase(
                repository: ChapterRepositoryStub(
                    results: [Self.identity: [.success(Self.chapters)]]
                )
            ),
            timeline: timeline
        )
        var announced: [Int] = []
        let cancel = model.observeAnnouncements { announced.append($0.number) }
        model.select(Self.identity)
        await waitForObservedState { model.chapters != nil }
        let intent = PlaybackLoadIntent()
        func send(
            _ position: Double,
            _ generation: UInt64,
            _ state: PlaybackTimelineState = .playing
        ) {
            timeline.send(
                PlaybackTimelineSnapshot(
                    identity: Self.identity,
                    positionSeconds: position,
                    durationSeconds: 300,
                    rate: state == .playing ? 1 : 0,
                    state: state,
                    discontinuityGeneration: generation,
                    loadIntent: intent
                )
            )
        }

        // 从续播位置开播：落定后只记下所在章节，不提示。
        send(199, 1)
        send(199.3, 1)
        send(199.6, 1)
        #expect(model.currentIndex == 1)
        #expect(announced.isEmpty)

        // 顺着播放跨进下一章：立刻提示。
        send(199.9, 1)
        send(200.1, 1)
        #expect(announced == [3])

        // 拖动：每一步都推进代次，途中跨过的章节不提示，当前章节照样跟着变；停下后播满落定时长才提示。
        send(50, 2)
        send(120, 3)
        send(20, 4)
        #expect(model.currentIndex == 0)
        send(20.3, 4)
        #expect(announced == [3])
        send(20.6, 4)
        #expect(announced == [3, 1])

        // 新位置的快照先于推进代次的跳变到达：同一代里的大步移动也按跳变等落定。
        send(110, 4)
        #expect(announced == [3, 1])
        send(110.6, 4)
        #expect(announced == [3, 1, 2])

        // 暂停中跳到另一章：当前章节立刻变，提示等恢复播放落定后才出现。
        send(210, 5, .paused)
        #expect(model.currentIndex == 2)
        send(210, 6)
        send(210.6, 6)
        #expect(announced == [3, 1, 2, 3])

        // 在同一章里跳转：不提示。
        send(205, 7)
        send(205.6, 7)
        #expect(announced == [3, 1, 2, 3])
        cancel()
    }

    @Test
    func failedReadIsRetriedAndSupersededPartIsDropped() async throws {
        let other = PlaybackItemIdentity(bvid: Self.identity.bvid, cid: 2)
        let gate = TestGate()
        let model = VideoChapterModel(
            useCase: VideoChapterUseCase(
                repository: ChapterRepositoryStub(
                    results: [
                        Self.identity: [.failure(.unavailable), .success(Self.chapters)],
                        other: [.success(Array(Self.chapters.prefix(1)))]
                    ],
                    gates: [other: gate]
                )
            ),
            timeline: ManualTimeline()
        )

        await SpawnedTasks { model.select(Self.identity) }.finished()
        #expect(model.chapters == nil)
        model.select(Self.identity)
        await waitForObservedState { model.chapters != nil }
        #expect(model.chapters?.chapters == Self.chapters)

        let superseded = SpawnedTasks { model.select(other) }
        try await gate.waitForEntries()
        #expect(model.chapters == nil)
        model.select(Self.identity)
        await waitForObservedState { model.chapters?.identity == Self.identity }
        await gate.open()
        await superseded.finished()
        #expect(model.chapters?.identity == Self.identity)
        #expect(model.chapters?.chapters.isEmpty == true)
    }
}

/// 章节读取替身：按分 P 依次给出预设结果，用完后是空列表；给了闸门的分 P 先在闸门处挂起。
private actor ChapterRepositoryStub: VideoChapterRepository {
    private var results: [PlaybackItemIdentity: [Result<[VideoChapter], ContentApplicationError>]]
    private let gates: [PlaybackItemIdentity: TestGate]

    init(
        results: [PlaybackItemIdentity: [Result<[VideoChapter], ContentApplicationError>]],
        gates: [PlaybackItemIdentity: TestGate] = [:]
    ) {
        self.results = results
        self.gates = gates
    }

    func chapters(for identity: PlaybackItemIdentity) async throws -> [VideoChapter] {
        if let gate = gates[identity] {
            await gate.pass()
        }
        guard var queue = results[identity], !queue.isEmpty else { return [] }
        let result = queue.removeFirst()
        results[identity] = queue
        return try result.get()
    }
}

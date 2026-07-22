import BiliApplication
import BiliModels
import Testing

@Suite
struct DanmakuSegmentUseCaseTests {
    private let identity = PlaybackItemIdentity(
        bvid: "BV1DanmakuFixture",
        cid: 700_001
    )

    @Test
    func invalidSegmentIndexFailsBeforeRepository() async {
        let repository = ApplicationDanmakuRepository(returnedIndex: 1)
        let useCase = DanmakuSegmentUseCase(repository: repository)

        await #expect(throws: DanmakuApplicationError.invalidRequest) {
            try await useCase.segment(index: 0, for: identity)
        }
        #expect(await repository.callCount() == 0)
    }

    @Test
    func mismatchedSegmentIndexFailsClosed() async {
        let repository = ApplicationDanmakuRepository(returnedIndex: 2)
        let useCase = DanmakuSegmentUseCase(repository: repository)

        await #expect(throws: DanmakuApplicationError.invalidResponse) {
            try await useCase.segment(index: 1, for: identity)
        }
    }
}

private actor ApplicationDanmakuRepository: DanmakuSegmentRepository {
    let returnedIndex: Int
    private var calls = 0

    init(returnedIndex: Int) {
        self.returnedIndex = returnedIndex
    }

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) -> DanmakuSegment {
        calls += 1
        return DanmakuSegment(index: returnedIndex, events: [])
    }

    func callCount() -> Int { calls }
}

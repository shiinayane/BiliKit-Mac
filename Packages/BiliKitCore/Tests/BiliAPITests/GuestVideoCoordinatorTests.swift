import BiliAPI
import BiliModels
import Foundation
import Testing

struct GuestVideoCoordinatorTests {
    @Test
    func resolvesDetailPagesAndPlaybackForFirstOrderedPage() async throws {
        let api = GuestAPIStub()
        let coordinator = GuestVideoCoordinator(api: api)

        await coordinator.selectVideo("BV1FixtureA1")

        guard case let .ready(context) = await coordinator.state else {
            Issue.record("游客视频上下文未进入 ready")
            return
        }
        #expect(context.detail.bvid == "BV1FixtureA1")
        #expect(context.pages.map(\.index) == [1, 2])
        #expect(context.selectedPage.index == 1)
        #expect(context.playback.manifest.videoRepresentations.first?.id == 32)
        #expect(await api.playbackCIDs() == [900_001])
    }

    @Test
    func newerSelectionCancelsAndSupersedesOlderResult() async throws {
        let api = GuestAPIStub(slowBVID: "BV1Slow0001")
        let coordinator = GuestVideoCoordinator(api: api)

        let slowSelection = Task {
            await coordinator.selectVideo("BV1Slow0001")
        }
        try await Task.sleep(for: .milliseconds(20))
        let fastSelection = Task {
            await coordinator.selectVideo("BV1Fast0002")
        }

        await fastSelection.value
        await slowSelection.value

        guard case let .ready(context) = await coordinator.state else {
            Issue.record("最新选择未进入 ready")
            return
        }
        #expect(context.detail.bvid == "BV1Fast0002")
        #expect(await api.cancelledBVIDs().contains("BV1Slow0001"))
        #expect(await api.playbackBVIDs() == ["BV1Fast0002"])
    }
}

private actor GuestAPIStub: BiliAPIService {
    private let slowBVID: String?
    private var observedCancelledBVIDs: Set<String> = []
    private var observedPlaybackBVIDs: [String] = []
    private var observedPlaybackCIDs: [Int64] = []

    init(slowBVID: String? = nil) {
        self.slowBVID = slowBVID
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        await delay(for: bvid)
        return makeDetail(bvid: bvid)
    }

    func pages(for bvid: String) async throws -> [VideoPage] {
        await delay(for: bvid)
        return [
            VideoPage(
                cid: 900_002,
                index: 2,
                title: "第二部分",
                durationSeconds: 240
            ),
            VideoPage(
                cid: 900_001,
                index: 1,
                title: "第一部分",
                durationSeconds: 120
            ),
        ]
    }

    func playback(
        for bvid: String,
        cid: Int64,
        quality: Int
    ) async throws -> VideoPlayback {
        observedPlaybackBVIDs.append(bvid)
        observedPlaybackCIDs.append(cid)
        return try makePlayback()
    }

    func cancelledBVIDs() -> Set<String> {
        observedCancelledBVIDs
    }

    func playbackBVIDs() -> [String] {
        observedPlaybackBVIDs
    }

    func playbackCIDs() -> [Int64] {
        observedPlaybackCIDs
    }

    private func delay(for bvid: String) async {
        let duration: Duration = bvid == slowBVID ? .milliseconds(180) : .milliseconds(5)
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
        if Task.isCancelled {
            observedCancelledBVIDs.insert(bvid)
        }
    }

    private func makeDetail(bvid: String) -> VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: "合成详情 \(bvid)",
            summary: "测试说明",
            coverURL: URL(string: "https://images.example.invalid/cover.jpg"),
            owner: VideoOwner(id: 10_001, name: "测试作者"),
            statistics: VideoStatistics(
                viewCount: 100,
                danmakuCount: 10,
                likeCount: 20
            ),
            durationSeconds: 360,
            publishedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
    }

    private func makePlayback() throws -> VideoPlayback {
        let segmentBase = SegmentBase(
            initialization: try MediaByteRange(start: 0, endInclusive: 999),
            index: try MediaByteRange(start: 1_000, endInclusive: 1_999)
        )
        let videoURL = try #require(
            URL(string: "https://media.example.invalid/video.m4s")
        )
        let audioURL = try #require(
            URL(string: "https://media.example.invalid/audio.m4s")
        )
        return VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [
                    MediaRepresentation(
                        id: 32,
                        kind: .video,
                        codecs: "avc1.64001f",
                        mimeType: "video/mp4",
                        primaryURL: videoURL,
                        segmentBase: segmentBase
                    ),
                ],
                audioRepresentations: [
                    MediaRepresentation(
                        id: 30216,
                        kind: .audio,
                        codecs: "mp4a.40.2",
                        mimeType: "audio/mp4",
                        primaryURL: audioURL,
                        segmentBase: segmentBase
                    ),
                ]
            ),
            mediaHeaders: [:]
        )
    }
}

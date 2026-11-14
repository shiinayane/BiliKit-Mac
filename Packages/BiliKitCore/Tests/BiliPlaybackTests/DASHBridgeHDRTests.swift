import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

/// 固定 HDR 档的发布契约：至多加入一个 HDR 档，有 HDR 档时每个视频档都写 `VIDEO-RANGE`、杜比视界
/// profile 8 带 `SUPPLEMENTAL-CODECS`、profile 5 以 `dvh1` 写 `CODECS` 与 PQ；HDR 档的 init 不是 HDR、
/// 缺帧率、编码与 init 不符或时间轴起点与 SDR 档不同时只丢这一档，SDR 档与字幕照常发布；SIDX 能解析
/// 但有零时长分段时同样只丢这一档。
struct DASHBridgeHDRTests {
    @Test
    func bridgeAddsOneTaggedHDRRungBesideTheSDRLadder() async throws {
        let fixture = try HDRFixture(host: "hdr-rung.fixture.bilivideo.com")

        let master = try await fixture.prepareMaster(
            hdrVideos: [fixture.dolbyVision, fixture.pq]
        )

        #expect(master.contains("video/\(fixture.dolbyVision.id).m3u8"))
        #expect(!master.contains("video/\(fixture.pq.id).m3u8"))
        #expect(master.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db4h",VIDEO-RANGE=HLG"#))
        let streams = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        #expect(streams.count == 2)
        #expect(streams.filter { $0.contains("VIDEO-RANGE=SDR") }.count == 1)
        #expect(master.contains("TYPE=SUBTITLES"))
    }

    @Test
    func dolbyVisionProfile5IsPublishedAsPQUnderItsOwnCodec() async throws {
        let fixture = try HDRFixture(host: "hdr-profile5.fixture.bilivideo.com")

        let master = try await fixture.prepareMaster(hdrVideos: [fixture.profile5, fixture.pq])

        let lines = master.split(separator: "\n").map(String.init)
        let stream = try #require(
            lines.firstIndex { $0.hasSuffix("video/\(fixture.profile5.id).m3u8") }
        )
        #expect(lines[stream - 1].contains(#"CODECS="dvh1.05.06,"#))
        #expect(lines[stream - 1].contains("VIDEO-RANGE=PQ"))
        #expect(!master.contains("SUPPLEMENTAL-CODECS"))
        #expect(!master.contains("video/\(fixture.pq.id).m3u8"))
    }

    /// playurl 把 profile 5 标成普通 HEVC 时，照抄进 master 的 `CODECS` 与码流不符，这一档不发布。
    @Test
    func dolbyVisionProfile5LabeledAsHEVCIsSkippedForTheNextCandidate() async throws {
        let fixture = try HDRFixture(host: "hdr-profile5-mislabeled.fixture.bilivideo.com")

        let master = try await fixture.prepareMaster(
            hdrVideos: [fixture.profile5LabeledHEVC, fixture.pq]
        )

        #expect(!master.contains("video/\(fixture.profile5LabeledHEVC.id)"))
        #expect(master.contains("video/\(fixture.pq.id).m3u8"))
    }

    enum Failure: String, CaseIterable, Sendable {
        case sdrInitialization
        case missingFrameRate
        case shiftedTimeline
        case zeroDurationSegment
    }

    @Test(arguments: Failure.allCases)
    func failedHDRRungIsDroppedWithoutAffectingSDROrSubtitles(_ failure: Failure) async throws {
        let fixture = try HDRFixture(
            host: "hdr-\(failure.rawValue).fixture.bilivideo.com",
            failure: failure
        )

        let master = try await fixture.prepareMaster(hdrVideos: [fixture.dolbyVision])

        #expect(!master.contains("video/\(fixture.dolbyVision.id)"))
        #expect(!master.contains("VIDEO-RANGE"))
        #expect(master.contains("video/\(fixture.sdr.id).m3u8"))
        #expect(master.contains("TYPE=SUBTITLES"))
    }

    /// 一档 SDR（fixture AVC）加 HDR 候选（杜比视界 8.4、HDR 真彩、杜比视界 5 及其编码标错的副本），
    /// HDR 档的 init 是合成的。
    private struct HDRFixture {
        let sdr: MediaRepresentation
        let audio: MediaRepresentation
        let dolbyVision: MediaRepresentation
        let pq: MediaRepresentation
        let profile5: MediaRepresentation
        let profile5LabeledHEVC: MediaRepresentation
        let media: [URL: Data]

        init(host: String, failure: Failure? = nil) throws {
            let base = try makeFourSecondMedia(host: host)
            let baseVideo = try #require(base.media[base.video.primaryURL])
            let dolbyVisionInit =
                failure == .sdrInitialization
                ? makeHEVCInitialization(transfer: 1)
                : makeHEVCInitialization(
                    transfer: 18,
                    dolbyVision: DolbyVisionFixture(profile: 8, level: 6, compatibilityID: 4)
                )
            var dolbyVisionData = try replacingInitialization(in: baseVideo, with: dolbyVisionInit)
            if failure == .shiftedTimeline {
                dolbyVisionData = try shiftingTimelineOrigin(of: dolbyVisionData)
            }
            if failure == .zeroDurationSegment {
                dolbyVisionData = try zeroingFirstSegmentDuration(of: dolbyVisionData)
            }
            let pqData = try replacingInitialization(in: baseVideo, with: makeHEVCInitialization())
            let dolbyVisionURL = try #require(URL(string: "https://\(host)/dolby-vision"))
            let pqURL = try #require(URL(string: "https://\(host)/pq"))
            let frameRate: Double? = failure == .missingFrameRate ? nil : 24
            sdr = base.video
            audio = base.audio
            dolbyVision = try makeFixtureTrack(
                id: 126,
                kind: .video,
                codecs: "hvc1.2.4.L150.90",
                bandwidth: 200_000,
                data: dolbyVisionData,
                primaryURL: dolbyVisionURL,
                videoAttributes: VideoRepresentationAttributes(
                    width: 256,
                    height: 144,
                    frameRate: frameRate
                )
            ).representation
            pq = try makeFixtureTrack(
                id: 125,
                kind: .video,
                codecs: "hvc1.2.4.L150.90",
                bandwidth: 200_000,
                data: pqData,
                primaryURL: pqURL,
                videoAttributes: VideoRepresentationAttributes(
                    width: 256,
                    height: 144,
                    frameRate: 24
                )
            ).representation
            let profile5Data = try replacingInitialization(
                in: baseVideo,
                with: makeHEVCInitialization(
                    sampleEntry: "dvh1",
                    transfer: nil,
                    dolbyVision: DolbyVisionFixture(profile: 5, level: 6, compatibilityID: 0)
                )
            )
            let profile5URL = try #require(URL(string: "https://\(host)/profile5"))
            let profile5Track = { (id: Int, codecs: String) in
                try makeFixtureTrack(
                    id: id,
                    kind: .video,
                    codecs: codecs,
                    bandwidth: 200_000,
                    data: profile5Data,
                    primaryURL: profile5URL,
                    videoAttributes: VideoRepresentationAttributes(
                        width: 256,
                        height: 144,
                        frameRate: 24
                    )
                ).representation
            }
            profile5 = try profile5Track(127, "dvh1.05.06")
            profile5LabeledHEVC = try profile5Track(128, "hev1.1.6.L153.90")
            var media = base.media
            media[dolbyVisionURL] = dolbyVisionData
            media[pqURL] = pqData
            media[profile5URL] = profile5Data
            self.media = media
        }

        func prepareMaster(hdrVideos: [MediaRepresentation]) async throws -> String {
            let prepared = try await makeFixtureBridge(FixtureRangeTransport(media: media)).prepare(
                videos: [sdr],
                hdrVideos: hdrVideos,
                audioTracks: [makeSelectedAudioTrack(representation: audio)],
                headers: [:],
                subtitleSource: NativeSubtitleSource(
                    useCase: SubtitleUseCase(
                        repository: FixtureSubtitleRepository(
                            catalog: .tracks([
                                SubtitleTrack(
                                    id: "standard-zh",
                                    languageCode: "zh",
                                    displayName: "中文",
                                    kind: .standard
                                )
                            ])
                        ),
                        reportAuthenticationInvalidation: {}
                    ),
                    identity: PlaybackItemIdentity(bvid: "BV1HDRFixture", cid: 900_020)
                )
            )
            defer { prepared.stop() }
            return try await fetchText(prepared.url)
        }
    }
}

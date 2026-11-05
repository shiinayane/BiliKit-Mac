import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

/// 固定 HDR 档的发布契约：至多加入一个 HDR 档，有 HDR 档时每个视频档都写 `VIDEO-RANGE`、杜比视界带
/// `SUPPLEMENTAL-CODECS`；HDR 档的 init 不是 HDR、缺帧率或时间轴起点与 SDR 档不同时只丢这一档，SDR 档
/// 与字幕照常发布。
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

    enum Failure: String, CaseIterable, Sendable {
        case sdrInitialization
        case missingFrameRate
        case shiftedTimeline
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

    /// 一档 SDR（fixture AVC）加两档 HDR 候选（杜比视界 8.4、HDR 真彩），HDR 档的 init 是合成的。
    private struct HDRFixture {
        let sdr: MediaRepresentation
        let audio: MediaRepresentation
        let dolbyVision: MediaRepresentation
        let pq: MediaRepresentation
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
                dolbyVisionData = try Self.shiftingTimelineOrigin(of: dolbyVisionData)
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
            var media = base.media
            media[dolbyVisionURL] = dolbyVisionData
            media[pqURL] = pqData
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

        /// 把 SIDX 的起始呈现时间加一秒，让这一档的时间轴起点与 SDR 档不同。
        private static func shiftingTimelineOrigin(of data: Data) throws -> Data {
            var result = data
            let sidx = try #require(firstTopLevelBox(named: "sidx", in: result))
            let timescale = Int(readUInt32(in: result, at: sidx.offset + 16))
            let valueOffset = sidx.offset + 20
            switch result[sidx.offset + 8] {
            case 0:
                let shifted = readUInt32(in: result, at: valueOffset) + UInt32(timescale)
                result.replaceSubrange(
                    valueOffset..<(valueOffset + 4),
                    with: withUnsafeBytes(of: shifted.bigEndian) { Data($0) }
                )
            default:
                let high = UInt64(readUInt32(in: result, at: valueOffset)) << 32
                let shifted =
                    high + UInt64(readUInt32(in: result, at: valueOffset + 4)) + UInt64(timescale)
                result.replaceSubrange(
                    valueOffset..<(valueOffset + 8),
                    with: withUnsafeBytes(of: shifted.bigEndian) { Data($0) }
                )
            }
            return result
        }
    }
}

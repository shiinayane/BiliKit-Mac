import BiliModels
import Foundation
import Testing

@testable import BiliAPI

/// 固定 playurl 视频阶梯的编码规则：HEVC 覆盖 AVC 的全部 SDR 清晰度时播 HEVC 并以 AVC 为回退，否则只播
/// AVC；HDR 档与 AV1 不进入阶梯，形状不认识的单条档位只丢这一条。
struct DASHVideoLadderTests {
    /// `id`、`codecid`、`codecs` 描述一条 `dash.video`，其余字段照 fixture 的首条视频。
    struct Rung: Sendable, CustomTestStringConvertible {
        let id: Int
        let codecid: Int
        let codecs: String

        static func avc(_ id: Int) -> Rung {
            Rung(id: id, codecid: 7, codecs: "avc1.640032")
        }

        static func hevc(_ id: Int) -> Rung {
            Rung(id: id, codecid: 12, codecs: "hev1.1.6.L153.90")
        }

        static func av1(_ id: Int) -> Rung {
            Rung(id: id, codecid: 13, codecs: "av01.0.13M.08")
        }

        var testDescription: String { "\(id)/\(codecid)" }
    }

    struct LadderCase: Sendable, CustomTestStringConvertible {
        let name: String
        let rungs: [Rung]
        let primary: [Int]
        let fallback: [Int]

        var testDescription: String { name }
    }

    @Test(arguments: [
        LadderCase(
            name: "HEVC 覆盖 AVC：播 HEVC，8K 一并加入，AVC 作回退",
            rungs: [.avc(80), .avc(64), .hevc(127), .hevc(80), .hevc(64)],
            primary: [127, 80, 64],
            fallback: [80, 64]
        ),
        LadderCase(
            name: "HEVC 缺 AVC 的档位：只播 AVC",
            rungs: [.avc(80), .avc(64), .avc(32), .hevc(80), .hevc(64)],
            primary: [80, 64, 32],
            fallback: []
        ),
        LadderCase(
            name: "只有 AV1 与 AVC：只播 AVC",
            rungs: [.av1(80), .av1(64), .avc(80), .avc(64)],
            primary: [80, 64],
            fallback: []
        ),
        LadderCase(
            name: "HDR 真彩与杜比视界不进入 SDR 阶梯",
            rungs: [.hevc(126), .hevc(125), .hevc(120), .hevc(80), .avc(80)],
            primary: [120, 80],
            fallback: [80]
        ),
        LadderCase(
            name: "只有 HEVC：播 HEVC，没有回退",
            rungs: [.hevc(80), .hevc(64)],
            primary: [80, 64],
            fallback: []
        )
    ])
    func playURLChoosesOneCodecForTheVideoLadder(_ ladder: LadderCase) async throws {
        let playback = try await playback(rungs: ladder.rungs)

        let manifest = try #require(playback.dashManifest)
        #expect(manifest.videoRepresentations.map(\.id) == ladder.primary)
        #expect(manifest.fallbackVideoRepresentations.map(\.id) == ladder.fallback)
        let primaryCodecs = Set(manifest.videoRepresentations.map { $0.codecs.prefix(4) })
        #expect(primaryCodecs.count == 1)
    }

    @Test
    func playURLWithOnlyAV1VideoIsUnsupported() async throws {
        await #expect(throws: BiliAPIError.noSupportedVideo) {
            try await playback(rungs: [.av1(80), .av1(64)])
        }
    }

    /// 请求的档位多于能播放的：一条缺少必需字段的视频只丢这一条，其余照常组成阶梯。
    @Test
    func malformedVideoRungIsDroppedWithoutFailingThePlayback() async throws {
        let playback = try await playback(rungs: [.avc(80), .avc(64)]) { videos in
            var malformed = videos[0]
            malformed["id"] = 127
            malformed.removeValue(forKey: "codecs")
            videos.insert(malformed, at: 0)
        }

        #expect(playback.dashManifest?.videoRepresentations.map(\.id) == [80, 64])
    }

    private func playback(
        rungs: [Rung],
        adjust: (inout [[String: Any]]) -> Void = { _ in }
    ) async throws -> VideoPlayback {
        let response = try mutatedFixture("playurl") { data in
            var dash = try #require(data["dash"] as? [String: Any])
            let template = try #require((dash["video"] as? [[String: Any]])?.first)
            var videos = rungs.map { rung in
                var video = template
                video["id"] = rung.id
                video["codecid"] = rung.codecid
                video["codecs"] = rung.codecs
                video["base_url"] =
                    "https://media.fixture.bilivideo.com/video-\(rung.id)-\(rung.codecid).m4s"
                video["backup_url"] = [String]()
                return video
            }
            adjust(&videos)
            dash["video"] = videos
            data["dash"] = dash
        }
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )
        return try await client.playback(for: "BV1FixtureA1", cid: 900_001)
    }
}

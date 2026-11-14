import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

/// 固定原声附加音频组的发布契约。
///
/// 原声的每个附加版本（其余 AAC 档、杜比音频）各成一个 AUDIO group，成员与默认组相同，配音在每组引用
/// 同一个 URI；附加版本读不出音频格式，或时间轴起点与视频、默认原声
/// 都不同时只丢这一组，默认组、配音与其他组照常发布。杜比全景声（`dash.dolby.type == 2`）的组由
/// loopback 提供补上 JOC 标记的 init，并写 `CHANNELS="16/JOC"`；补不了时按普通杜比音频发布。
///
/// SIDX 能解析但有零时长分段时同样只丢这一组：它会让生成 playlist 报错。
struct DASHBridgeAudioGroupTests {
    @Test
    func bridgePublishesOneGroupPerOriginalVersionWithSharedDubs() async throws {
        let fixture = try AudioGroupFixture(host: "audio-groups.fixture.bilivideo.com")

        let master = try await fixture.prepareMaster()

        for groupID in ["audio-30280", "audio-30232", "audio-30250"] {
            #expect(master.contains(#"AUDIO="\#(groupID)""#))
        }
        #expect(
            master.contains(
                #"GROUP-ID="audio-30250",NAME="原声",CHARACTERISTICS="public.original-content",CHANNELS="6""#
            )
        )
        let dubLines = master.split(separator: "\n").filter { $0.contains(#"NAME="English（AI）""#) }
        #expect(dubLines.count == 3)
        #expect(Set(dubLines.map { $0.split(separator: ",").last ?? "" }).count == 1)
    }

    enum Failure: String, CaseIterable, Sendable {
        case unreadableFormat
        case shiftedTimeline
        case zeroDurationSegment
    }

    @Test(arguments: Failure.allCases)
    func failedVersionDropsOnlyItsGroup(_ failure: Failure) async throws {
        let fixture = try AudioGroupFixture(
            host: "audio-\(failure.rawValue).fixture.bilivideo.com",
            failure: failure
        )

        let master = try await fixture.prepareMaster()

        #expect(!master.contains("audio-30250"))
        #expect(master.contains(#"AUDIO="audio-30280""#))
        #expect(master.contains(#"AUDIO="audio-30232""#))
        #expect(master.contains(#"NAME="English（AI）""#))
    }

    /// 较早稿件里 AAC 各档（连同配音）与视频的 SIDX 起点相差约 83 ms，杜比与视频对齐（实测）。
    ///
    /// 杜比组按视频起点收进 master，其余 AAC 组按默认原声起点收进 master。fixture 的视频从 1024/12288 秒
    /// 开始、AAC 从 0 开始，差值相同。
    @Test
    func versionsMatchingEitherVideoOrDefaultAACOriginArePublished() async throws {
        let fixture = try AudioGroupFixture(
            host: "audio-aac-offset.fixture.bilivideo.com",
            dolbyAlignedToVideo: true
        )

        let master = try await fixture.prepareMaster()

        for groupID in ["audio-30280", "audio-30232", "audio-30250"] {
            #expect(master.contains(#"AUDIO="\#(groupID)""#))
        }
        #expect(master.contains(#"NAME="English（AI）""#))
    }

    /// 全景声组的 init 由 loopback 提供：B 站 init 的 `dec3` 末尾补上 JOC 标记（box 长度随之加 2），
    /// 分段仍走 CDN；master 按 Apple HLS Authoring Spec 写 `CHANNELS="16/JOC"`。
    @Test
    func atmosGroupServesJOCMarkedInitializationFromLoopback() async throws {
        let fixture = try AudioGroupFixture(
            host: "audio-atmos.fixture.bilivideo.com",
            dolbyIsAtmos: true
        )

        let master = try await fixture.prepareMaster { _, text in
            let playlistURI = try #require(
                text.split(separator: "\n").first { $0.contains(#"GROUP-ID="audio-30250""#) }?
                    .split(separator: ",").last?
                    .dropFirst(#"URI=""#.count).dropLast()
            )
            let playlist = try await fetchText(try #require(URL(string: String(playlistURI))))
            let mapLine = try #require(
                playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MAP:") }
            )
            #expect(!mapLine.contains("BYTERANGE"))
            #expect(playlist.contains("#EXT-X-BYTERANGE:"))
            let initURL = try #require(
                URL(string: String(mapLine.dropFirst(#"#EXT-X-MAP:URI=""#.count).dropLast()))
            )
            let served = try await URLSession.shared.data(from: initURL).0
            let original = makeAudioInitialization(sampleEntry: "ec-3", children: biliAtmosDEC3())
            #expect(served.count == original.count + 2)
            let dec3 = try #require(served.range(of: Data("dec3".utf8)))
            #expect(readUInt32(in: served, at: dec3.lowerBound - 4) == 8 + 7)
            #expect(
                served[dec3.upperBound..<(dec3.upperBound + 7)]
                    == Data([0x14, 0x00, 0x20, 0x0f, 0x00, 0x01, 0x10])
            )
            #expect(try AudioFormatMetadataParser().parse(served).channelCount == 6)
        }

        #expect(
            master.contains(
                #"GROUP-ID="audio-30250",NAME="原声",CHARACTERISTICS="public.original-content",CHANNELS="16/JOC""#
            )
        )
    }

    /// `dash.dolby.type` 不是全景声时不补标记：init 照常按区间从 CDN 读，写声道数。
    @Test
    func nonAtmosDolbyKeepsRemoteInitializationAndChannelCount() async throws {
        let fixture = try AudioGroupFixture(host: "audio-dolby-plain.fixture.bilivideo.com")

        let master = try await fixture.prepareMaster()

        #expect(
            master.contains(
                #"GROUP-ID="audio-30250",NAME="原声",CHARACTERISTICS="public.original-content",CHANNELS="6""#
            )
        )
        #expect(!master.contains("JOC"))
    }

    /// 一档视频，原声 30280 带两个附加版本（AAC 30232 与合成 init 的杜比 30250），加一条 AI 配音。
    ///
    /// 杜比默认与 AAC 同起点；`dolbyAlignedToVideo` 时改为视频的起点（与 AAC 不同）。`dolbyIsAtmos` 时杜比
    /// 用 B 站全景声 init 的 `dec3`。
    private struct AudioGroupFixture {
        let video: MediaRepresentation
        let original: SelectedPlaybackAudioTrack
        let dub: SelectedPlaybackAudioTrack
        let media: [URL: Data]

        init(
            host: String,
            failure: Failure? = nil,
            dolbyAlignedToVideo: Bool = false,
            dolbyIsAtmos: Bool = false
        ) throws {
            let base = try makeFourSecondMedia(host: host)
            let audioData = try #require(base.media[base.audio.primaryURL])
            var dolbyData = try replacingInitialization(
                in: audioData,
                with: makeAudioInitialization(
                    sampleEntry: "ec-3",
                    children: dolbyIsAtmos
                        ? biliAtmosDEC3()
                        : eac3Configuration(
                            acmod: 7,
                            lfe: true,
                            dependentSubstreams: failure == .unreadableFormat ? 1 : 0
                        )
                )
            )
            if dolbyAlignedToVideo {
                // 视频 SIDX 起点 1024/12288 秒，换成杜比的 48 kHz 时间基是 4000。
                dolbyData = try settingSIDXEarliestPresentationTime(4_000, in: dolbyData)
            }
            if failure == .shiftedTimeline {
                dolbyData = try shiftingTimelineOrigin(of: dolbyData)
            }
            if failure == .zeroDurationSegment {
                dolbyData = try zeroingFirstSegmentDuration(of: dolbyData)
            }
            let lowURL = try #require(URL(string: "https://\(host)/aac-low"))
            let dolbyURL = try #require(URL(string: "https://\(host)/dolby"))
            let dubURL = try #require(URL(string: "https://\(host)/dub-en"))
            let low = try makeFixtureTrack(
                id: 30_232,
                kind: .audio,
                codecs: "mp4a.40.2",
                bandwidth: 16_000,
                data: audioData,
                primaryURL: lowURL
            ).representation
            let dolby = try makeFixtureTrack(
                id: 30_250,
                kind: .audio,
                codecs: "ec-3",
                bandwidth: 64_000,
                data: dolbyData,
                primaryURL: dolbyURL
            ).representation
            let dubAudio = try makeFixtureTrack(
                id: 30_280,
                kind: .audio,
                codecs: "mp4a.40.2",
                bandwidth: 32_000,
                data: audioData,
                primaryURL: dubURL
            ).representation
            video = base.video
            original = SelectedPlaybackAudioTrack(
                track: .original(
                    representations: [base.audio, low],
                    dolby: dolby,
                    dolbyIsAtmos: dolbyIsAtmos
                ),
                representation: base.audio,
                additionalRepresentations: [low, dolby]
            )
            dub = makeSelectedAudioTrack(
                trackID: "machine-generated:en",
                displayName: "English（AI）",
                languageTag: "en",
                role: .machineGenerated,
                isDefault: false,
                isAutoselect: false,
                representation: dubAudio
            )
            var media = base.media
            media[lowURL] = audioData
            media[dolbyURL] = dolbyData
            media[dubURL] = audioData
            self.media = media
        }

        /// 准备播放并取回 master；`inspect` 在会话停止前检查同一会话的其他 route。
        func prepareMaster(
            inspect: (URL, String) async throws -> Void = { _, _ in }
        ) async throws -> String {
            let prepared = try await makeFixtureBridge(FixtureRangeTransport(media: media)).prepare(
                videos: [video],
                audioTracks: [original, dub],
                headers: [:],
                subtitleSource: nil
            )
            defer { prepared.stop() }
            let master = try await fetchText(prepared.url)
            try await inspect(prepared.url, master)
            return master
        }
    }
}

import BiliModels
import Foundation
import Testing

@testable import BiliPlayback

/// 固定原声附加音频组的发布契约：原声的每个附加版本（其余 AAC 档、杜比音频）各成一个 AUDIO group，
/// 成员与默认组相同，配音在每组引用同一个 URI；附加版本读不出音频格式或时间轴起点与原声不同时只丢
/// 这一组，默认组、配音与其他组照常发布。
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

    /// 一档视频，原声 30280 带两个附加版本（AAC 30232 与合成 init 的杜比 30250），加一条 AI 配音。
    private struct AudioGroupFixture {
        let video: MediaRepresentation
        let original: SelectedPlaybackAudioTrack
        let dub: SelectedPlaybackAudioTrack
        let media: [URL: Data]

        init(host: String, failure: Failure? = nil) throws {
            let base = try makeFourSecondMedia(host: host)
            let audioData = try #require(base.media[base.audio.primaryURL])
            var dolbyData = try replacingInitialization(
                in: audioData,
                with: makeAudioInitialization(
                    sampleEntry: "ec-3",
                    children: eac3Configuration(
                        acmod: 7,
                        lfe: true,
                        dependentSubstreams: failure == .unreadableFormat ? 1 : 0
                    )
                )
            )
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
                track: .original(representations: [base.audio, low], dolby: dolby),
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

        func prepareMaster() async throws -> String {
            let prepared = try await makeFixtureBridge(FixtureRangeTransport(media: media)).prepare(
                videos: [video],
                audioTracks: [original, dub],
                headers: [:],
                subtitleSource: nil
            )
            defer { prepared.stop() }
            return try await fetchText(prepared.url)
        }
    }
}

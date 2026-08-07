@preconcurrency import AVFoundation
@preconcurrency import AVKit
import AppKit
import BiliModels
import BiliPlayback
import Foundation
import XCTest

/// 显式 opt-in 的签名 App test-host 原生字幕菜单探针。
///
/// 媒体与字幕全部来自仓库内的合成 fixture；探针不访问网络，也不改变产品播放路径。
final class NativeSubtitleStage0AVPlayerViewProbeTests: XCTestCase {
    @MainActor
    func testThreeUserLabelsInRealAVPlayerViewWhenExplicitlyConfigured()
        async throws
    {
        guard
            ProcessInfo.processInfo.environment[
                "BILIKIT_STAGE0_OBSERVE_AVPLAYERVIEW_MENU"
            ] == "1"
        else {
            throw XCTSkip("仅在显式观察原生字幕菜单时运行")
        }

        let videoData = try fixtureData(named: "video-avc")
        let audioData = try fixtureData(named: "audio-aac")
        let video = try makeFixtureTrack(
            id: 80,
            kind: .video,
            codecs: "avc1.4d400b",
            bandwidth: 50_000,
            data: videoData
        )
        let audio = try makeFixtureTrack(
            id: 30_280,
            kind: .audio,
            codecs: "mp4a.40.2",
            bandwidth: 96_000,
            data: audioData
        )
        let subtitleMPEGTimestamp = try mpegTSTimestamp(for: video.index)
        XCTAssertEqual(subtitleMPEGTimestamp, 7_500)

        let server = LoopbackPlaybackServer()
        try await server.start()
        defer { server.stop() }

        let masterURL = try server.url(for: "stage0/master.m3u8")
        let videoPlaylistURL = try server.url(for: "stage0/video.m3u8")
        let audioPlaylistURL = try server.url(for: "stage0/audio.m3u8")
        let subtitlePlaylistURLs = try [
            server.url(for: "stage0/subtitle-zh.m3u8"),
            server.url(for: "stage0/subtitle-zh-ai.m3u8"),
            server.url(for: "stage0/subtitle-en.m3u8"),
        ]
        let videoMediaURL = try server.register(
            .inMemory(data: videoData, contentType: AVFileType.mp4.rawValue),
            at: "stage0/video.mp4"
        )
        let audioMediaURL = try server.register(
            .inMemory(data: audioData, contentType: AVFileType.mp4.rawValue),
            at: "stage0/audio.mp4"
        )
        let videoPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: video.representation,
            index: video.index,
            mediaURI: videoMediaURL
        )
        let audioPlaylist = try HLSMediaPlaylistBuilder().build(
            representation: audio.representation,
            index: audio.index,
            mediaURI: audioMediaURL
        )
        let subtitlePlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:3
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:2.083,
            subtitle.vtt
            #EXT-X-ENDLIST

            """
        let labels = ["中文", "中文（AI）", "English"]
        let subtitlePaths = ["subtitle-zh", "subtitle-zh-ai", "subtitle-en"]

        for (index, path) in subtitlePaths.enumerated() {
            let playlist = subtitlePlaylist.replacingOccurrences(
                of: "subtitle.vtt",
                with: "\(path).vtt"
            )
            _ = try server.register(
                playlistResource(playlist),
                at: "stage0/\(path).m3u8"
            )
            _ = try server.register(
                .inMemory(
                    data: Data(
                        "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(subtitleMPEGTimestamp)\n\n00:00:00.000 --> 00:00:01.500\n\(labels[index])\n"
                            .utf8
                    ),
                    contentType: "text/vtt"
                ),
                at: "stage0/\(path).vtt"
            )
        }

        let masterPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistURL.absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(subtitlePlaylistURLs[0].absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="中文（AI）",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(subtitlePlaylistURLs[1].absoluteString)"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="English",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="\(subtitlePlaylistURLs[2].absoluteString)"
            #EXT-X-STREAM-INF:BANDWIDTH=146000,AVERAGE-BANDWIDTH=146000,RESOLUTION=128x72,FRAME-RATE=24.000,CODECS="avc1.4d400b,mp4a.40.2",AUDIO="audio",SUBTITLES="subtitles"
            \(videoPlaylistURL.absoluteString)

            """
        _ = try server.register(
            playlistResource(videoPlaylist),
            at: "stage0/video.m3u8"
        )
        _ = try server.register(
            playlistResource(audioPlaylist),
            at: "stage0/audio.m3u8"
        )
        _ = try server.register(
            playlistResource(masterPlaylist),
            at: "stage0/master.m3u8"
        )

        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let playerView = AVPlayerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        playerView.player = player
        playerView.controlsStyle = .floating
        let window = NSWindow(
            contentRect: playerView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Native Subtitle Stage 0"
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            playerView.player = nil
        }

        try await waitUntilReadyToPlay(item)
        let loadedGroup = try await asset.loadMediaSelectionGroup(
            for: .legible
        )
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertEqual(Set(group.options.map(\.displayName)), Set(labels))
        XCTAssertNil(
            item.currentMediaSelection.selectedMediaOption(in: group)
        )
        print("STAGE0_AVPLAYERVIEW_READY labels=中文|中文（AI）|English")
        try? await Task.sleep(for: .seconds(30))
    }

    private func fixtureData(named name: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url =
            repositoryRoot
            .appendingPathComponent(
                "Packages/BiliKitCore/Tests/BiliPlaybackTests/Fixtures"
            )
            .appendingPathComponent("\(name).mp4")
        return try Data(contentsOf: url)
    }

    private func makeFixtureTrack(
        id: Int,
        kind: MediaKind,
        codecs: String,
        bandwidth: Int,
        data: Data
    ) throws -> (representation: MediaRepresentation, index: SegmentIndex) {
        let sidx = try XCTUnwrap(firstTopLevelBox(named: "sidx", in: data))
        let representation = MediaRepresentation(
            id: id,
            kind: kind,
            codecs: codecs,
            mimeType: kind == .video ? "video/mp4" : "audio/mp4",
            bandwidth: bandwidth,
            videoAttributes: kind == .video
                ? try VideoRepresentationAttributes(
                    width: 128,
                    height: 72,
                    frameRate: 24
                )
                : nil,
            primaryURL: try XCTUnwrap(
                URL(string: "https://fixture.invalid/\(id)")
            ),
            backupURLs: [],
            segmentBase: SegmentBase(
                initialization: try MediaByteRange(
                    start: 0,
                    endInclusive: Int64(sidx.offset - 1)
                ),
                index: try MediaByteRange(
                    start: Int64(sidx.offset),
                    endInclusive: Int64(sidx.offset + sidx.size - 1)
                )
            )
        )
        let index = try SIDXParser().parse(
            data.subdata(in: sidx.offset..<(sidx.offset + sidx.size)),
            boxStartOffset: UInt64(sidx.offset)
        )
        return (representation, index)
    }

    private func firstTopLevelBox(
        named expectedType: String,
        in data: Data
    ) -> (offset: Int, size: Int)? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(readUInt32(in: data, at: offset))
            let type = String(
                data: data.subdata(in: (offset + 4)..<(offset + 8)),
                encoding: .ascii
            )
            guard size >= 8, offset + size <= data.count else { return nil }
            if type == expectedType { return (offset, size) }
            offset += size
        }
        return nil
    }

    private func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
    }

    private func playlistResource(_ playlist: String) -> LoopbackPlaybackResource {
        .inMemory(
            data: Data(playlist.utf8),
            contentType: "application/vnd.apple.mpegurl"
        )
    }

    private func mpegTSTimestamp(for index: SegmentIndex) throws -> UInt64 {
        guard index.timescale > 0 else {
            throw ProbeFailure.invalidTimestampMap
        }
        let product = index.earliestPresentationTime
            .multipliedReportingOverflow(by: 90_000)
        guard !product.overflow else {
            throw ProbeFailure.invalidTimestampMap
        }
        return product.partialValue / UInt64(index.timescale)
    }

    @MainActor
    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while item.status == .unknown, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if item.status == .failed {
            throw item.error ?? ProbeFailure.itemFailedWithoutError
        }
        guard item.status == .readyToPlay else { throw ProbeFailure.timedOut }
    }
}

private enum ProbeFailure: Error {
    case invalidTimestampMap
    case itemFailedWithoutError
    case timedOut
}

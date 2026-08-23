import AVFoundation
import Testing

@testable import BiliPlayback

struct ProgressivePlaybackEndTimeTests {
    @Test(arguments: ["video-avc", "audio-aac"])
    func usesObservedTrackEndWithoutSubtractingATolerance(
        fixtureName: String
    ) async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: fixtureName,
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks).filter {
            $0.mediaType == .video || $0.mediaType == .audio
        }
        let expectedEnds = try await tracks.asyncMap {
            CMTimeRangeGetEnd(try await $0.load(.timeRange))
        }
        let expected = try #require(
            expectedEnds.max(by: {
                CMTimeCompare($0, $1) < 0
            })
        )

        let actual = try #require(
            try await AVPlayerEngine.lastPresentableMediaEndTime(in: asset)
        )

        #expect(CMTimeCompare(actual, expected) == 0)
        #expect(actual.seconds > 0)
    }
}

extension Array {
    fileprivate func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}

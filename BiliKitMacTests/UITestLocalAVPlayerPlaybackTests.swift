import AVFoundation
import BiliApplication
import BiliModels
import Testing

@testable import BiliKit

@Suite(.serialized)
struct UITestLocalAVPlayerPlaybackTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func realPlayerReplacesItemAdvancesTimelineAndCleansResources() async throws {
        let playback = UITestLocalAVPlayerPlayback()
        defer { playback.stop() }
        let first = PlaybackItemIdentity(bvid: "fixture-video-A", cid: 101)
        let replacement = PlaybackItemIdentity(
            bvid: "fixture-video-B",
            cid: 102
        )

        try await playback.load(Self.emptyPlayback, identity: first)
        #expect(
            await waitUntil {
                playback.status == "playing"
                    && playback.positionMilliseconds >= 100
            }
        )
        let playerIdentity = ObjectIdentifier(playback.player)
        let firstItem = try #require(playback.player.currentItem)
        let firstItemIdentity = ObjectIdentifier(firstItem)
        let firstGeneration = playback.itemGeneration

        try await playback.load(Self.emptyPlayback, identity: replacement)
        #expect(
            await waitUntil {
                playback.status == "playing"
                    && playback.positionMilliseconds >= 100
            }
        )
        #expect(ObjectIdentifier(playback.player) == playerIdentity)
        #expect(playback.player.currentItem !== firstItem)
        #expect(
            playback.player.currentItem.map(ObjectIdentifier.init)
                != firstItemIdentity
        )
        #expect(playback.itemGeneration == firstGeneration + 1)
        #expect(playback.lastStoppedItemAlias == first.bvid)
        #expect(playback.activeObserverCount == 1)

        playback.stop()
        #expect(playback.player.currentItem == nil)
        #expect(playback.activeObserverCount == 0)
        #expect(!playback.isLoaded)
        #expect(playback.itemAlias == "none")
        #expect(playback.status == "stopped")
        #expect(!playback.mediaDirectoryExists)
        #expect(UITestLocalAVPlayerResourceRegistry.shared.activeItems == 0)
        #expect(UITestLocalAVPlayerResourceRegistry.shared.activeObservers == 0)
        #expect(
            UITestLocalAVPlayerResourceRegistry.shared.activeMediaDirectories == 0
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func stopDuringPreparingPreventsLateItemInstallation() async {
        let playback = UITestLocalAVPlayerPlayback()
        defer { playback.stop() }
        let identity = PlaybackItemIdentity(
            bvid: "fixture-video-preparing",
            cid: 103
        )
        let loadTask = Task {
            try await playback.load(Self.emptyPlayback, identity: identity)
        }

        #expect(
            await waitUntil {
                playback.startedLoadGeneration == 1
            }
        )
        playback.stop()

        do {
            try await loadTask.value
            Issue.record("cancelled preparing load unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected preparing error: \(error)")
        }

        #expect(playback.settledLoadGeneration == 1)
        #expect(playback.player.currentItem == nil)
        #expect(playback.activeObserverCount == 0)
        #expect(!playback.isLoaded)
        #expect(!playback.mediaDirectoryExists)
        #expect(UITestLocalAVPlayerResourceRegistry.shared.activeItems == 0)
        #expect(UITestLocalAVPlayerResourceRegistry.shared.activeObservers == 0)
        #expect(
            UITestLocalAVPlayerResourceRegistry.shared.activeMediaDirectories == 0
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static let emptyPlayback = VideoPlayback(
        manifest: PlaybackManifest(
            videoRepresentations: [],
            audioRepresentations: []
        ),
        mediaHeaders: [:]
    )
}

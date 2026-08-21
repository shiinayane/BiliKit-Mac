@preconcurrency import AppKit
import BiliApplication
import MediaPlayer
import Testing

@testable import BiliKit

@Suite(.serialized)
@MainActor
struct SystemNowPlayingControllerTests {
    @Test
    func singleAndMultiplePartMappingRemainMinimal() {
        let single = SystemNowPlayingPresentation(
            totalTitle: "总标题",
            artist: "UP 主",
            partTitle: "P1",
            partCount: 1,
            coverURL: URL(string: "https://example.invalid/cover")
        )
        #expect(single.title == "总标题")
        #expect(single.artist == "UP 主")
        #expect(single.albumTitle == nil)

        let multiple = SystemNowPlayingPresentation(
            totalTitle: "总标题",
            artist: "UP 主",
            partTitle: "第二章",
            partCount: 2,
            coverURL: nil
        )
        #expect(multiple.title == "第二章")
        #expect(multiple.albumTitle == "总标题")

        let duplicate = SystemNowPlayingPresentation(
            totalTitle: "总标题",
            artist: "  ",
            partTitle: " 总标题 ",
            partCount: 3,
            coverURL: nil
        )
        #expect(duplicate.title == "总标题")
        #expect(duplicate.albumTitle == nil)
        #expect(duplicate.artist == nil)
    }

    @Test
    func publishedDictionaryContainsNoContentIdentifiersOrURLs() {
        let presentation = SystemNowPlayingPresentation(
            totalTitle: "公开标题",
            artist: "公开作者",
            partTitle: nil,
            partCount: 1,
            coverURL: URL(string: "https://example.invalid/private-cover")
        )
        let info = SystemNowPlayingController.info(
            presentation: presentation,
            timeline: Self.timeline(position: 12, state: .playing),
            defaultPlaybackRate: 1
        )

        #expect(info[MPMediaItemPropertyTitle] as? String == "公开标题")
        #expect(info[MPMediaItemPropertyArtist] as? String == "公开作者")
        #expect(
            info[MPNowPlayingInfoPropertyMediaType] as? UInt
                == MPNowPlayingInfoMediaType.video.rawValue
        )
        #expect(info[MPNowPlayingInfoPropertyExcludeFromSuggestions] as? Bool == true)
        #expect(info[MPNowPlayingInfoPropertyAssetURL] == nil)
        #expect(info[MPNowPlayingInfoPropertyExternalContentIdentifier] == nil)
        #expect(info[MPNowPlayingInfoPropertyServiceIdentifier] == nil)
        #expect(
            !info.values.contains { value in
                let text = String(describing: value)
                return text.contains("BVSecret")
                    || text.contains("900001")
                    || text.contains("example.invalid")
            }
        )
    }

    @Test
    func preferredRateIsDistinctFromMomentaryAndPausedRates() {
        let presentation = SystemNowPlayingPresentation(
            totalTitle: "倍速视频",
            artist: "UP 主",
            partTitle: nil,
            partCount: 1,
            coverURL: nil
        )
        let playing = SystemNowPlayingController.info(
            presentation: presentation,
            timeline: PlaybackTimelineSnapshot(
                identity: PlaybackItemIdentity(bvid: "BVRate", cid: 1),
                positionSeconds: 10,
                durationSeconds: 120,
                rate: 2,
                state: .playing,
                discontinuityGeneration: 1
            ),
            defaultPlaybackRate: 1.5
        )
        #expect(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 2)
        #expect(
            playing[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double
                == 1.5
        )

        let paused = SystemNowPlayingController.info(
            presentation: presentation,
            timeline: Self.timeline(state: .paused),
            defaultPlaybackRate: 1.5
        )
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(
            paused[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double
                == 1.5
        )
    }

    @Test
    func elapsedOnlyUpdatesDoNotRepublishEverySecond() {
        let center = RecordingNowPlayingCenter()
        let commands = RecordingRemoteCommands()
        let controller = SystemNowPlayingController(
            center: center,
            remoteCommands: commands
        )
        let fixture = SessionFixture()
        let windowID = controller.registerWindow()

        fixture.update(controller, windowID: windowID, timeline: Self.timeline(position: 1))
        fixture.update(controller, windowID: windowID, timeline: Self.timeline(position: 2))
        fixture.update(controller, windowID: windowID, timeline: Self.timeline(position: 30))

        #expect(center.publications.count == 1)
        fixture.update(
            controller,
            windowID: windowID,
            timeline: Self.timeline(position: 31, discontinuity: 2)
        )
        #expect(center.publications.count == 2)
    }

    @Test
    func pausingCurrentSessionKeepsMetadataAndPublishesPausedState() {
        let center = RecordingNowPlayingCenter()
        let controller = SystemNowPlayingController(
            center: center,
            remoteCommands: RecordingRemoteCommands()
        )
        let fixture = SessionFixture(title: "Pause Fixture")
        let windowID = controller.registerWindow()

        fixture.update(controller, windowID: windowID, timeline: Self.timeline())
        fixture.update(
            controller,
            windowID: windowID,
            timeline: Self.timeline(position: 25, state: .paused)
        )

        #expect(center.clearCount == 0)
        #expect(center.latestTitle == "Pause Fixture")
        #expect(center.states.last == .paused)
        #expect(
            center.publications.last?[MPNowPlayingInfoPropertyPlaybackRate]
                as? Double == 0
        )

        fixture.update(
            controller,
            windowID: windowID,
            timeline: Self.timeline(position: 25, state: .paused),
            defaultPlaybackRate: 1.5
        )
        #expect(
            center.publications.last?[
                MPNowPlayingInfoPropertyDefaultPlaybackRate
            ] as? Double == 1.5
        )
        #expect(center.clearCount == 0)

        fixture.update(
            controller,
            windowID: windowID,
            timeline: Self.timeline(position: 25, state: .playing)
        )
        #expect(center.clearCount == 0)
        #expect(center.latestTitle == "Pause Fixture")
        #expect(center.states.last == .playing)
    }

    @Test
    func staleArtworkCannotOverwriteReplacement() async {
        let center = RecordingNowPlayingCenter()
        let commands = RecordingRemoteCommands()
        let loader = ControlledArtworkLoader()
        let controller = SystemNowPlayingController(
            center: center,
            remoteCommands: commands,
            artworkLoader: { url in await loader.load(url) }
        )
        let first = SessionFixture(
            generation: 1,
            title: "A",
            coverURL: URL(string: "https://example.invalid/a")!
        )
        let second = SessionFixture(
            generation: 2,
            identity: PlaybackItemIdentity(bvid: "BVReplacement", cid: 2),
            title: "B",
            coverURL: URL(string: "https://example.invalid/b")!
        )
        let windowID = controller.registerWindow()
        first.update(controller, windowID: windowID, timeline: Self.timeline())
        second.update(
            controller,
            windowID: windowID,
            timeline: Self.timeline(
                identity: second.identity
            )
        )

        await confirmation("only the current artwork is published") { confirmation in
            center.onPublish = { info in
                guard info[MPMediaItemPropertyArtwork] != nil else { return }
                #expect(info[MPMediaItemPropertyTitle] as? String == "B")
                confirmation()
            }
            await loader.complete(
                URL(string: "https://example.invalid/a")!,
                image: Self.image()
            )
            await loader.complete(
                URL(string: "https://example.invalid/b")!,
                image: Self.image()
            )
            await Task.yield()
        }
    }

    @Test
    func remoteCommandsValidateContentAndRouteStatus() {
        let center = RecordingNowPlayingCenter()
        let commands = RecordingRemoteCommands()
        let controller = SystemNowPlayingController(
            center: center,
            remoteCommands: commands
        )
        let fixture = SessionFixture()

        #expect(commands.invoke(.play) == .noSuchContent)
        let windowID = controller.registerWindow()
        fixture.update(controller, windowID: windowID, timeline: Self.timeline())
        #expect(commands.invoke(.play) == .success)
        #expect(fixture.performed == [.play])
        #expect(commands.invoke(.skip(offsetSeconds: 17)) == .success)
        #expect(commands.invoke(.skip(offsetSeconds: -23)) == .success)
        #expect(fixture.performed == [.play, .skip(offsetSeconds: 17), .skip(offsetSeconds: -23)])
        #expect(commands.invoke(.skip(offsetSeconds: 0)) == .noSuchContent)
        #expect(commands.invoke(.seek(positionSeconds: 121)) == .noSuchContent)

        fixture.update(
            controller,
            windowID: windowID,
            timeline: Self.timeline(position: 120, state: .ended)
        )
        #expect(commands.invoke(.play) == .noSuchContent)
        #expect(commands.invoke(.seek(positionSeconds: 60)) == .noSuchContent)
        #expect(commands.invoke(.skip(offsetSeconds: -15)) == .noSuchContent)

        fixture.acceptsCommands = false
        fixture.update(controller, windowID: windowID, timeline: Self.timeline())
        #expect(commands.invoke(.pause) == .commandFailed)
        #expect(commands.installationCount == 1)
        controller.close()
        #expect(commands.removalCount == 1)
        controller.close()
        #expect(commands.removalCount == 1)
    }

    @Test
    func skipEventsPreserveTheirIntervalAndDirection() {
        #expect(
            SystemNowPlayingCommand.skip(interval: 17, direction: .forward)
                == .skip(offsetSeconds: 17)
        )
        #expect(
            SystemNowPlayingCommand.skip(interval: 23, direction: .backward)
                == .skip(offsetSeconds: -23)
        )
        #expect(
            SystemNowPlayingCommand.skip(interval: 0, direction: .forward)
                == nil
        )
        #expect(
            SystemNowPlayingCommand.skip(
                interval: .infinity,
                direction: .backward
            ) == nil
        )
    }

    @Test
    func relativeSkipTargetsClampToTheCurrentItem() {
        #expect(
            SystemNowPlayingSeekTarget.relative(
                positionSeconds: 20,
                durationSeconds: 120,
                offsetSeconds: 17
            ) == 37
        )
        #expect(
            SystemNowPlayingSeekTarget.relative(
                positionSeconds: 5,
                durationSeconds: 120,
                offsetSeconds: -23
            ) == 0
        )
        #expect(
            SystemNowPlayingSeekTarget.relative(
                positionSeconds: 115,
                durationSeconds: 120,
                offsetSeconds: 17
            ) == 120
        )
        #expect(
            SystemNowPlayingSeekTarget.relative(
                positionSeconds: 20,
                durationSeconds: 120,
                offsetSeconds: 0
            ) == nil
        )
    }

    @Test
    func handlerInstallationIsRemovedWhenProcessOwnerIsReleased() {
        let commands = RecordingRemoteCommands()
        var controller: SystemNowPlayingController? = SystemNowPlayingController(
            center: RecordingNowPlayingCenter(),
            remoteCommands: commands
        )
        let weakController = WeakSystemNowPlayingControllerBox(controller)

        #expect(commands.installationCount == 1)
        controller = nil

        #expect(weakController.value == nil)
        #expect(commands.removalCount == 1)
    }

    @Test
    func playingWindowWinsAndConditionalRemovalFallsBack() {
        let center = RecordingNowPlayingCenter()
        let controller = SystemNowPlayingController(
            center: center,
            remoteCommands: RecordingRemoteCommands()
        )
        let first = SessionFixture(title: "First")
        let second = SessionFixture(
            identity: PlaybackItemIdentity(bvid: "BVSecond", cid: 2),
            title: "Second"
        )
        let firstWindow = controller.registerWindow()
        let secondWindow = controller.registerWindow()

        first.update(controller, windowID: firstWindow, timeline: Self.timeline())
        second.update(
            controller,
            windowID: secondWindow,
            timeline: Self.timeline(identity: second.identity, state: .paused)
        )
        #expect(center.latestTitle == "First")

        second.update(
            controller,
            windowID: secondWindow,
            timeline: Self.timeline(identity: second.identity)
        )
        #expect(center.latestTitle == "Second")
        controller.markWindowActive(firstWindow)
        #expect(center.latestTitle == "First")

        let clearsBeforeNonWinnerRemoval = center.clearCount
        controller.removeWindow(secondWindow)
        #expect(center.latestTitle == "First")
        #expect(center.clearCount == clearsBeforeNonWinnerRemoval)

        second.update(
            controller,
            windowID: secondWindow,
            timeline: Self.timeline(identity: second.identity)
        )
        #expect(center.latestTitle == "Second")
        controller.removeWindow(secondWindow)
        #expect(center.latestTitle == "First")
        #expect(center.clearCount == clearsBeforeNonWinnerRemoval)

        controller.removeWindow(firstWindow)
        #expect(center.clearCount == clearsBeforeNonWinnerRemoval + 1)
    }

    private static func timeline(
        identity: PlaybackItemIdentity = PlaybackItemIdentity(
            bvid: "BVSecret",
            cid: 900_001
        ),
        position: Double = 10,
        state: PlaybackTimelineState = .playing,
        discontinuity: UInt64 = 1
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 120,
            rate: state == .playing ? 1 : 0,
            state: state,
            discontinuityGeneration: discontinuity
        )
    }

    private static func image() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage()
        else {
            preconditionFailure("Unable to create the artwork test image")
        }
        return image
    }
}

@MainActor
private final class SessionFixture {
    let generation: UInt64
    let identity: PlaybackItemIdentity
    let item = NSObject()
    let title: String
    let coverURL: URL?
    var acceptsCommands = true
    private(set) var performed: [SystemNowPlayingCommand] = []

    init(
        generation: UInt64 = 1,
        identity: PlaybackItemIdentity = PlaybackItemIdentity(
            bvid: "BVSecret",
            cid: 900_001
        ),
        title: String = "Fixture",
        coverURL: URL? = nil
    ) {
        self.generation = generation
        self.identity = identity
        self.title = title
        self.coverURL = coverURL
    }

    func update(
        _ controller: SystemNowPlayingController,
        windowID: UUID,
        timeline: PlaybackTimelineSnapshot,
        defaultPlaybackRate: Double = 1
    ) {
        controller.update(
            windowID: windowID,
            generation: generation,
            playbackIdentity: identity,
            playerItemIdentifier: ObjectIdentifier(item),
            presentation: SystemNowPlayingPresentation(
                totalTitle: title,
                artist: "UP",
                partTitle: nil,
                partCount: 1,
                coverURL: coverURL
            ),
            timeline: timeline,
            defaultPlaybackRate: defaultPlaybackRate
        ) { [weak self] command, identity, itemIdentifier in
            guard let self, self.acceptsCommands,
                identity == self.identity,
                itemIdentifier == ObjectIdentifier(self.item)
            else { return false }
            self.performed.append(command)
            return true
        }
    }
}

@MainActor
private final class WeakSystemNowPlayingControllerBox {
    weak var value: SystemNowPlayingController?

    init(_ value: SystemNowPlayingController?) {
        self.value = value
    }
}

@MainActor
private final class RecordingNowPlayingCenter: SystemNowPlayingCenterWriting {
    private(set) var publications: [[String: Any]] = []
    private(set) var states: [MPNowPlayingPlaybackState] = []
    private(set) var clearCount = 0
    var onPublish: (([String: Any]) -> Void)?

    var latestTitle: String? {
        publications.last?[MPMediaItemPropertyTitle] as? String
    }

    func publish(info: [String: Any], state: MPNowPlayingPlaybackState) {
        publications.append(info)
        states.append(state)
        onPublish?(info)
    }

    func clear() {
        clearCount += 1
    }
}

@MainActor
private final class RecordingRemoteCommands: SystemRemoteCommandManaging {
    private(set) var installationCount = 0
    private(set) var removalCount = 0
    private var handler:
        (
            @Sendable (SystemNowPlayingCommand) ->
                SystemNowPlayingCommandResult
        )?

    func install(
        handler:
            @escaping @Sendable (SystemNowPlayingCommand) ->
            SystemNowPlayingCommandResult
    ) {
        guard self.handler == nil else { return }
        installationCount += 1
        self.handler = handler
    }

    func removeHandlers() {
        guard handler != nil else { return }
        removalCount += 1
        handler = nil
    }

    func invoke(
        _ command: SystemNowPlayingCommand
    ) -> SystemNowPlayingCommandResult {
        handler?(command) ?? .noSuchContent
    }
}

private actor ControlledArtworkLoader {
    private var continuations: [URL: CheckedContinuation<CGImage?, Never>] = [:]
    private var completed: [URL: CGImage] = [:]

    func load(_ url: URL) async -> CGImage? {
        if let image = completed.removeValue(forKey: url) {
            return image
        }
        return await withCheckedContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func complete(_ url: URL, image: CGImage) {
        if let continuation = continuations.removeValue(forKey: url) {
            continuation.resume(returning: image)
        } else {
            completed[url] = image
        }
    }
}

@preconcurrency import AVFoundation
@preconcurrency import AVKit
import AppKit
import BiliAPI
import BiliApplication
import BiliAuth
import BiliModels
import BiliNetworking
import BiliPlayback
import Foundation
import XCTest

/// 显式 opt-in 的签名 production-chain 探针；只输出标签与计数，不输出 identity、URL 或正文。
final class NativeSubtitleStage2ProductionProbeTests: XCTestCase {
    private static let inputEnvironmentKey =
        "BILIKIT_NATIVE_SUBTITLE_STAGE2_INPUT_FILE"

    @MainActor
    func testRealCatalogReachesNativePlayerAndBodyStaysLazy() async throws {
        guard
            let input = try Stage2ProbeInput.load(
                environmentKey: Self.inputEnvironmentKey
            )
        else {
            throw XCTSkip("仅在显式提供安全本机输入时运行 Stage 2 production probe")
        }
        let bvid = try XCTUnwrap(input["bvid"])
        let cid = try XCTUnwrap(Int64(try XCTUnwrap(input["cid"])))
        guard Self.isValidBVID(bvid), cid > 0 else {
            throw Stage2ProbeFailure.invalidInput
        }

        let transportFactory: @Sendable () -> any HTTPTransport = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            return URLSessionTransport(
                configuration: configuration,
                redirectPolicy: .reject
            )
        }
        let api = BiliAPIClient(
            requestAuthorizer: BiliCredentialRequestAuthorizer(),
            transportFactory: transportFactory
        )
        let repository = Stage2RecordingSubtitleRepository(
            base: BiliSubtitleRepository(client: api)
        )
        let engine = AVPlayerEngine(
            subtitleUseCase: SubtitleUseCase(repository: repository)
        )
        engine.player.isMuted = true
        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        defer { engine.stop() }

        let playback = try await api.playback(for: bvid, cid: cid)
        try await engine.load(playback, identity: identity)
        let item = try XCTUnwrap(engine.player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        let labels = group.options.map(\.displayName)
        let catalogDiagnostics = await repository.catalogDiagnostics()
        XCTAssertEqual(
            labels,
            ["中文", "中文（AI）", "English（AI）", "日本語（AI）"],
            "catalog-requests=\(catalogDiagnostics.requests) "
                + "successes=\(catalogDiagnostics.successes) "
                + "failure=\(catalogDiagnostics.failureType ?? "none") "
                + "elapsed=\(catalogDiagnostics.elapsed)"
        )
        XCTAssertNil(
            item.currentMediaSelection.selectedMediaOption(in: group)
        )
        let initialCueRequestCount = await repository.cueRequestCount
        XCTAssertEqual(initialCueRequestCount, 0)

        let playerView = AVPlayerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        playerView.player = engine.player
        playerView.controlsStyle = .floating
        let window = NSWindow(
            contentRect: playerView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Native Subtitle Stage 2"
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            playerView.player = nil
        }

        item.select(group.options[0], in: group)
        engine.play()
        try await Self.waitUntil {
            await repository.cueRequestCount == 1
        }
        engine.pause()

        engine.stop()
        try await Self.waitUntil {
            await repository.resetCount == 1
        }
        XCTAssertNil(engine.player.currentItem)
        print(
            "STAGE2_NATIVE_SUBTITLE_READY "
                + "labels=中文|中文（AI）|English（AI）|日本語（AI） "
                + "cue-requests=1 reset-count=1 stopped=true"
        )
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard await condition() else {
            throw Stage2ProbeFailure.timedOut
        }
    }

    private static func isValidBVID(_ value: String) -> Bool {
        value.count == 12
            && value.hasPrefix("BV")
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }
    }
}

private actor Stage2RecordingSubtitleRepository: SubtitleRepository {
    private let base: any SubtitleRepository
    private var catalogRequestCount = 0
    private var catalogSuccessCount = 0
    private var catalogFailureType: String?
    private var catalogElapsed = Duration.zero
    private(set) var cueRequestCount = 0
    private(set) var resetCount = 0

    init(base: any SubtitleRepository) {
        self.base = base
    }

    func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        catalogRequestCount += 1
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let tracks = try await base.tracks(for: identity)
            catalogElapsed = start.duration(to: clock.now)
            catalogSuccessCount += 1
            return tracks
        } catch {
            catalogElapsed = start.duration(to: clock.now)
            catalogFailureType = String(reflecting: type(of: error))
            throw error
        }
    }

    func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        cueRequestCount += 1
        return try await base.cues(for: trackID, identity: identity)
    }

    func reset(for identity: PlaybackItemIdentity) async {
        resetCount += 1
        await base.reset(for: identity)
    }

    func catalogDiagnostics() -> (
        requests: Int,
        successes: Int,
        failureType: String?,
        elapsed: Duration
    ) {
        (
            catalogRequestCount,
            catalogSuccessCount,
            catalogFailureType,
            catalogElapsed
        )
    }
}

private enum Stage2ProbeInput {
    private static let maximumBytes = 4 * 1_024

    static func load(environmentKey: String) throws -> [String: String]? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey]
        else {
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: path
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o077 == 0
        else {
            throw Stage2ProbeFailure.insecureInput
        }
        let data = try Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        )
        guard data.count <= maximumBytes else {
            throw Stage2ProbeFailure.insecureInput
        }
        return try PropertyListDecoder().decode(
            [String: String].self,
            from: data
        )
    }
}

private enum Stage2ProbeFailure: Error {
    case invalidInput
    case insecureInput
    case timedOut
}

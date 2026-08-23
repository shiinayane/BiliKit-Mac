import AVFoundation
import BiliAPI
import BiliApplication
import BiliAuth
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import BiliNetworking
import BiliPlayback
import CoreGraphics
import Foundation
import SwiftUI

typealias CommentAssetURLResolver = @Sendable (CommentAssetReference) -> URL?
typealias CommentVideoLinkResolver = @Sendable (CommentLinkTarget) -> String?
typealias CommentLinkURLResolver = @Sendable (CommentLinkTarget) -> URL?

enum SystemNowPlayingSeekTarget {
    static func relative(
        positionSeconds: Double,
        durationSeconds: Double,
        offsetSeconds: Double
    ) -> Double? {
        guard positionSeconds.isFinite,
            durationSeconds.isFinite,
            durationSeconds > 0,
            offsetSeconds.isFinite,
            offsetSeconds != 0
        else { return nil }
        return min(max(positionSeconds + offsetSeconds, 0), durationSeconds)
    }
}

@MainActor
@Observable
final class AccountSessionCoordinator: AuthenticatedSessionInvalidating {
    private(set) var generation: UInt64 = 0
    private(set) var scope = AccountSessionScope.unresolved
    @ObservationIgnored
    private var sessionInvalidators: [UUID: any AuthenticatedSessionInvalidating] = [:]

    func publish(_ scope: AccountSessionScope) {
        guard scope != .unresolved, scope != self.scope else { return }
        self.scope = scope
        generation &+= 1
    }

    func registerSessionInvalidator(
        _ invalidator: any AuthenticatedSessionInvalidating
    ) -> UUID {
        let registrationID = UUID()
        sessionInvalidators[registrationID] = invalidator
        return registrationID
    }

    func unregisterSessionInvalidator(_ registrationID: UUID) {
        sessionInvalidators[registrationID] = nil
    }

    func invalidateAuthenticatedSession() async {
        let invalidators = Array(sessionInvalidators.values)
        await withTaskGroup(of: Void.self) { group in
            for invalidator in invalidators {
                group.addTask {
                    await invalidator.invalidateAuthenticatedSession()
                }
            }
        }
    }
}

@MainActor
/// App 的 Composition Root：创建具体 adapter，并把它们收窄为 Feature 所需的 port。
///
/// 这里刻意同时看见 API、认证、播放和弹幕实现。一个环境只创建一个 `AVPlayerEngine`，
/// 原生字幕、弹幕、视频模型与 AppKit player host 必须共享它的播放 identity 和时间线。
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    let playbackPreferencesController: PlaybackPreferencesController
    private let guestContentRepository: any GuestContentRepository
    private let relatedVideoRepository: any RelatedVideoRepository
    private let uploaderSignatureRepository: any UploaderSignatureRepository
    private let commentRepository: any CommentRepository
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentVideoLinkResolver: CommentVideoLinkResolver
    let commentLinkURLResolver: CommentLinkURLResolver
    private let historyRepository: any WatchHistoryRepository
    private let danmakuSession: DanmakuSession
    private let danmakuController: DanmakuPresentationController
    private let danmakuRenderer: CoreAnimationDanmakuRenderer
    private let danmakuPreferencesStore: any DanmakuPreferencesStoring
    private let authenticationService: any AuthenticationServicing
    private let authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    let open: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void

    init(
        guestContentRepository: any GuestContentRepository,
        relatedVideoRepository: any RelatedVideoRepository,
        uploaderSignatureRepository: any UploaderSignatureRepository,
        commentRepository: any CommentRepository,
        commentAssetURLResolver: @escaping CommentAssetURLResolver = { _ in nil },
        commentVideoLinkResolver: @escaping CommentVideoLinkResolver = { target in
            guard case .video(let bvid) = target else { return nil }
            return bvid
        },
        commentLinkURLResolver: @escaping CommentLinkURLResolver = { _ in nil },
        historyRepository: any WatchHistoryRepository,
        danmakuRepository: any DanmakuSegmentRepository,
        playerEngine: AVPlayerEngine,
        playbackPreferencesController: PlaybackPreferencesController,
        danmakuPreferencesStore: any DanmakuPreferencesStoring =
            UserDefaultsDanmakuPreferencesStore(),
        authenticationService: any AuthenticationServicing,
        authenticationQRCodeProvider: any AuthenticationQRCodeProviding,
        open: @escaping @MainActor @Sendable () -> Void = {},
        close: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        precondition(
            playerEngine.nativeSubtitlesEnabled,
            "AVPlayerEngine must own native subtitle presentation"
        )
        self.guestContentRepository = guestContentRepository
        self.relatedVideoRepository = relatedVideoRepository
        self.uploaderSignatureRepository = uploaderSignatureRepository
        self.commentRepository = commentRepository
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentVideoLinkResolver = commentVideoLinkResolver
        self.commentLinkURLResolver = commentLinkURLResolver
        self.historyRepository = historyRepository
        self.playerEngine = playerEngine
        self.playbackPreferencesController = playbackPreferencesController
        self.danmakuPreferencesStore = danmakuPreferencesStore
        let renderer = CoreAnimationDanmakuRenderer(style: .production)
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        self.danmakuRenderer = renderer
        self.danmakuController = controller
        self.danmakuSession = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: danmakuRepository),
            timeline: playerEngine,
            presentationSink: controller
        )
        self.authenticationService = authenticationService
        self.authenticationQRCodeProvider = authenticationQRCodeProvider
        self.open = open
        self.close = close
    }

    var nativeSubtitlesEnabled: Bool {
        playerEngine.nativeSubtitlesEnabled
    }

    func makeSystemNowPlayingPlaybackConnection()
        -> SystemNowPlayingPlaybackConnection
    {
        SystemNowPlayingPlaybackConnection(
            currentSnapshot: { [playerEngine] in
                playerEngine.currentTimelineSnapshot
            },
            timelineUpdates: { [playerEngine] in
                playerEngine.timelineUpdates()
            },
            currentItemIdentifier: { [playerEngine] in
                playerEngine.player.currentItem.map(ObjectIdentifier.init)
            },
            currentDefaultPlaybackRate: { [playerEngine] in
                Double(playerEngine.player.defaultRate)
            },
            observeDefaultPlaybackRate: { [playerEngine] notify in
                let observation = playerEngine.player.observe(
                    \.defaultRate,
                    options: [.new]
                ) { player, change in
                    let rate = Double(change.newValue ?? player.defaultRate)
                    Task { @MainActor in notify(rate) }
                }
                return SystemNowPlayingDefaultRateObservation {
                    observation.invalidate()
                }
            },
            perform: { [playerEngine] command, identity, itemIdentifier in
                guard playerEngine.currentTimelineSnapshot.identity == identity,
                    let item = playerEngine.player.currentItem,
                    ObjectIdentifier(item) == itemIdentifier
                else { return false }
                switch command {
                case .play:
                    playerEngine.play()
                    return true
                case .pause:
                    playerEngine.pause()
                    return true
                case .togglePlayPause:
                    if playerEngine.currentTimelineSnapshot.state == .playing
                        || playerEngine.currentTimelineSnapshot.state == .buffering
                    {
                        playerEngine.pause()
                    } else {
                        playerEngine.play()
                    }
                    return true
                case .seek(let positionSeconds):
                    return Self.requestSystemSeek(
                        positionSeconds,
                        engine: playerEngine,
                        identity: identity,
                        itemIdentifier: itemIdentifier
                    )
                case .skip(let offsetSeconds):
                    let snapshot = playerEngine.currentTimelineSnapshot
                    guard let duration = snapshot.durationSeconds,
                        let target = SystemNowPlayingSeekTarget.relative(
                            positionSeconds: snapshot.positionSeconds,
                            durationSeconds: duration,
                            offsetSeconds: offsetSeconds
                        )
                    else {
                        return false
                    }
                    return Self.requestSystemSeek(
                        target,
                        engine: playerEngine,
                        identity: identity,
                        itemIdentifier: itemIdentifier
                    )
                }
            }
        )
    }

    private static func requestSystemSeek(
        _ positionSeconds: Double,
        engine: AVPlayerEngine,
        identity: PlaybackItemIdentity,
        itemIdentifier: ObjectIdentifier
    ) -> Bool {
        guard positionSeconds.isFinite, positionSeconds >= 0,
            let duration = engine.currentTimelineSnapshot.durationSeconds,
            positionSeconds <= duration
        else { return false }
        guard engine.currentTimelineSnapshot.identity == identity,
            let item = engine.player.currentItem,
            ObjectIdentifier(item) == itemIdentifier
        else { return false }
        return engine.requestSeek(to: .seconds(positionSeconds))
    }

    func makeBrowseViewModel() -> GuestBrowseViewModel {
        GuestBrowseViewModel(
            useCase: GuestFeedUseCase(repository: guestContentRepository)
        )
    }

    func makeVideoViewModel() -> GuestVideoViewModel {
        GuestVideoViewModel(
            useCase: GuestVideoUseCase(repository: guestContentRepository),
            playback: playerEngine,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedVideoRepository
            ),
            uploaderSignatureUseCase: UploaderSignatureUseCase(
                repository: uploaderSignatureRepository
            )
        )
    }

    func makeCommentsViewModel() -> PlaybackCommentsViewModel {
        PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: commentRepository)
        )
    }

    func makeDanmakuViewModel() -> DanmakuControlsViewModel {
        let preferences = danmakuPreferencesStore.load()
        return DanmakuControlsViewModel(
            presentation: danmakuSession,
            initialSpeedLevel: preferences.speedLevel,
            initialOpacity: preferences.opacity,
            initialDisplayArea: preferences.displayArea,
            initialDensity: preferences.density,
            saveSpeedLevel: { [danmakuPreferencesStore] speedLevel in
                danmakuPreferencesStore.saveSpeedLevel(speedLevel)
            },
            saveOpacity: { [danmakuPreferencesStore] opacity in
                danmakuPreferencesStore.saveOpacity(opacity)
            },
            saveDisplayArea: { [danmakuPreferencesStore] displayArea in
                danmakuPreferencesStore.saveDisplayArea(displayArea)
            },
            saveDensity: { [danmakuPreferencesStore] density in
                danmakuPreferencesStore.saveDensity(density)
            }
        )
    }

    func makePlayerView(
        videoModel: GuestVideoViewModel,
        danmakuModel: DanmakuControlsViewModel
    ) -> AnyView {
        AnyView(
            PlayerHostView(
                player: playerEngine.player,
                danmakuRenderer: danmakuRenderer,
                danmakuController: danmakuController,
                videoModel: videoModel,
                beginMomentaryPlaybackRate: { [playerEngine] rate in
                    try? playerEngine.beginMomentaryPlaybackRate(Double(rate))
                },
                endMomentaryPlaybackRate: { [playerEngine] sessionID in
                    playerEngine.endMomentaryPlaybackRate(sessionID: sessionID)
                },
                seekByTransportOffset: { [playerEngine] offset in
                    playerEngine.seekByTransportOffset(offset)
                },
                adjustVolume: { [playbackPreferencesController] offset in
                    playbackPreferencesController.adjustVolume(by: offset)
                },
                togglePlayback: { [playerEngine] in
                    playerEngine.togglePlayback()
                },
                toggleDanmaku: { [danmakuModel] in
                    danmakuModel.toggleEnabled()
                },
                toggleSubtitles: { [playerEngine] in
                    await playerEngine.toggleNativeSubtitles()
                },
                timelineUpdates: { [playerEngine] in
                    playerEngine.timelineUpdates()
                }
            )
        )
    }

    func makeAuthenticationViewModel() -> AuthenticationViewModel {
        AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: authenticationQRCodeProvider
        )
    }

    func makeWatchHistoryViewModel() -> WatchHistoryViewModel {
        WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: historyRepository)
        )
    }

    /// 创建生产对象图，并保持游客、媒体与字幕正文请求不自动继承登录 Cookie。
    ///
    /// 只有 BiliAPI 私有标记的账户读取才经过 authorizer；公开 Browse、Search、评论、
    /// playurl 与 WBI 弹幕分段在明确无本地凭据时仍请求同一个 endpoint。登出还会替换 API 的
    /// ephemeral transport，使旧认证会话中的在途请求失效。
    static func live(
        accountSessionCoordinator: AccountSessionCoordinator? = nil,
        appSettingsModel: AppSettingsModel? = nil
    ) -> AppEnvironment {
        let requestAuthorizer = BiliCredentialRequestAuthorizer()
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
            requestAuthorizer: requestAuthorizer,
            transportFactory: transportFactory
        )
        appSettingsModel?.configureBenchmark(client: api)
        let sessionRegistration = accountSessionCoordinator.map {
            AppEnvironmentSessionRegistration(
                coordinator: $0,
                invalidator: api
            )
        }
        let sessionInvalidator: any AuthenticatedSessionInvalidating
        if let accountSessionCoordinator {
            sessionInvalidator = accountSessionCoordinator
        } else {
            sessionInvalidator = api
        }
        let authenticationService = BiliAuthenticationService(
            additionalSessionInvalidators: [sessionInvalidator]
        )
        let player = AVPlayer()
        let playbackPreferencesController = PlaybackPreferencesController(
            player: player
        )
        let subtitleRepository = BiliSubtitleRepository(client: api)
        let playerEngine = AVPlayerEngine(
            player: player,
            subtitleUseCase: SubtitleUseCase(repository: subtitleRepository),
            sourcePreferenceProvider: {
                appSettingsModel?.playbackSourcePreference ?? .serverDefault
            },
            loudnessNormalizationEnabledProvider: {
                if #available(macOS 26.0, *) {
                    appSettingsModel?.loudnessNormalizationEnabled ?? false
                } else {
                    false
                }
            }
        )
        let guestRepository = BiliGuestRepository(client: api)
        let commentAssetResolver = BiliCommentAssetResolver()
        let commentLinkResolver = BiliCommentLinkResolver()
        return AppEnvironment(
            guestContentRepository: guestRepository,
            relatedVideoRepository: guestRepository,
            uploaderSignatureRepository: guestRepository,
            commentRepository: BiliCommentRepository(client: api),
            commentAssetURLResolver: { reference in
                commentAssetResolver.imageURL(for: reference)
            },
            commentLinkURLResolver: { target in
                commentLinkResolver.externalURL(for: target)
            },
            historyRepository: BiliWatchHistoryRepository(client: api),
            danmakuRepository: BiliDanmakuRepository(client: api),
            playerEngine: playerEngine,
            playbackPreferencesController: playbackPreferencesController,
            authenticationService: authenticationService,
            authenticationQRCodeProvider: AuthenticationQRCodeProvider(
                service: authenticationService
            ),
            open: { sessionRegistration?.open() },
            close: { sessionRegistration?.close() }
        )
    }

    private static let emptyDanmakuConfiguration = DanmakuLaneConfiguration.production(
        surfaceWidth: 0,
        surfaceHeight: 0
    )
}

@MainActor
private final class AppEnvironmentSessionRegistration {
    private weak var coordinator: AccountSessionCoordinator?
    private let invalidator: any AuthenticatedSessionInvalidating
    private var registrationID: UUID?

    init(
        coordinator: AccountSessionCoordinator,
        invalidator: any AuthenticatedSessionInvalidating
    ) {
        self.coordinator = coordinator
        self.invalidator = invalidator
    }

    func open() {
        guard registrationID == nil, let coordinator else { return }
        registrationID = coordinator.registerSessionInvalidator(invalidator)
    }

    func close() {
        guard let registrationID else { return }
        coordinator?.unregisterSessionInvalidator(registrationID)
        self.registrationID = nil
    }
}

private struct AuthenticationQRCodeProvider: AuthenticationQRCodeProviding {
    let service: BiliAuthenticationService

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try await service.makeQRCodeImage(scale: scale)
    }
}

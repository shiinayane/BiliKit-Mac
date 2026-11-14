import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliModels
import BiliVideoDetailFeature
import SwiftUI

/// 窗口级组装：一个窗口必须同代、跨 SwiftUI `body` 重算保持稳定的整个对象图，由 `AppRootView` 在视图身份首次
/// 出现时构造一次（`ProcessComposition.makeWindow()`）。
///
/// 拥有本窗口的全部模型（浏览、视频、评论、弹幕、认证、稍后再看与稍后再看会话、观看历史、收藏夹列表与夹内页面、UP 主空间、热搜与
/// 联想、搜索会话）、账户写入的协调者与效果路由、导航协调、
/// 来源描述与复核参与者、播放器视图、窗口图片管线、来源网格的保活、评论短链解析、评论图片预览面板与图片保存、Now Playing 与观看进度的连接，以及
/// 经 `WindowAdapters` 拿到的具体实现。只引用进程级对象（账户会话、设置、Now Playing 控制器、搜索历史），不创建
/// 也不关闭它们。视频、弹幕模型与播放器视图必须共享 adapter 里同一个播放器；分别重建会让画面、时间线与弹幕指向
/// 不同的播放项目。
///
/// 生命周期：`open()` 在窗口出现时调用一次（登记会话、开始观看进度与 Now Playing）；`close()` 在窗口消失时调用，
/// 不可逆，之后不再打开，也不再向进程级对象登记本窗口。关闭顺序见 `close()`。
@MainActor
final class WindowComposition {
    let process: ProcessComposition
    /// 本窗口在进程级测速权限汇总（`AppSettingsModel`）里的键；关窗时第一步注销。
    let benchmarkAuthenticationOwnerID = UUID()
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let watchLaterModel: WatchLaterViewModel
    /// 稍后再看的排序、筛选与关键词；关窗与账户变化时由稍后再看来源的描述恢复默认。
    let watchLaterSession: WatchLaterSession
    let historyModel: WatchHistoryViewModel
    /// 侧栏「收藏夹」组的列表；窗口级复核参与者，mid 取自本窗口认证模型的账户范围。
    let favoriteFolderList: FavoriteFolderListModel
    /// 收藏夹来源的选择、条件与夹内内容；经收藏夹来源的描述绑定来源。
    let favoriteFolders: FavoriteFolderViewModel
    /// 本窗口用户发起的账户写入（卡片菜单、读屏操作、⌘⌫ 与播放页的点赞投币）；窗口级复核参与者，关窗时取消在途写入。
    let accountWrites: AccountWriteCoordinator
    /// 播放页点赞、投币、收藏按钮的状态；窗口级复核参与者，账户只取写入门槛的账户。
    let engagementModel: VideoEngagementModel
    /// 播放器上发送弹幕的输入胶囊；发送经 `accountWrites`，关窗时 reset。
    let danmakuComposer: DanmakuComposerModel
    /// 评论区底部输入框与评论行上的赞、踩；写入经 `accountWrites`，关窗时 reset。
    let commentWrite: PlaybackCommentWriteModel
    let trendingSearchModel: TrendingSearchViewModel
    let searchSuggestionSource: SearchSuggestionSource
    /// 搜索来源的草稿、筛选与已提交的条件；关窗时由搜索来源的描述 reset。
    let searchSession: VideoSearchSession
    /// 侧栏来源的描述，按侧栏顺序。
    let sources: AppSources
    /// 本窗口全部账户复核参与者；`AppRootView` 只读取与转交结果。
    let revalidationParticipants: AccountRevalidationParticipants
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    /// 在当前视频的播放器里跳到某秒并播放；播放器 item 不属于该视频时不动作。
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    /// 评论短链的在途解析；换视频与关窗时取消。
    let commentShortLinks = CommentShortLinkResolution()
    /// 评论图片的保存；预览关闭后已确认的保存照常完成，关窗时取消。
    private let commentImageSaver = NativeCommentImageSaver()
    /// 评论图片预览面板；换视频与退出播放时由 `AppShellView` 关闭，关窗时在取消图片保存之前关闭。
    let commentImagePreview: NativeCommentImagePreviewPresenter
    /// 窗口内所有封面、头像与评论图片共用的匿名有界图片管线。
    let imagePipeline: NativeVideoImagePipeline
    private let imagePipelineOwner = NativeVideoImagePipelineOwner(cacheLimits: .window)
    /// 各来源网格的保活，保活容器交给 `AppShellView` 构造各来源的网格依赖；关窗时在关闭图片管线之前丢弃。
    let gridRetainerOwner = NativeVideoGridRetainerOwner()
    private let systemNowPlayingCoordinator: SystemNowPlayingWindowCoordinator
    private let watchProgressConnection: WatchProgressWindowConnection
    private let adapters: WindowAdapters
    /// 把写入效果落到本窗口视图上；打开时登记进进程级集线器，关窗时注销。
    private let accountWriteEffectRouter: AccountWriteEffectRouter
    private var accountWriteEffectRegistration: UUID?
    private var isOpen = false
    /// 关闭不可逆：之后不再打开，也不再向进程级对象登记本窗口。
    private(set) var isClosed = false

    init(process: ProcessComposition, adapters: WindowAdapters) {
        self.process = process
        self.adapters = adapters
        let browseModel = BrowseViewModel(
            useCase: FeedUseCase(repository: adapters.feedRepository)
        )
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: adapters.videoRepository),
            playback: adapters.playback,
            relatedVideoUseCase: RelatedVideoUseCase(repository: adapters.relatedVideoRepository),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: adapters.uploaderProfileRepository
            ),
            playbackAuthenticationInvalidations: adapters.makePlaybackAuthenticationInvalidations()
        )
        let danmakuModel = Self.makeDanmakuModel(adapters: adapters)
        let uploaderSpace = UploaderSpaceViewModel(
            useCase: UploaderVideoUseCase(repository: adapters.uploaderVideoRepository),
            profileUseCase: UploaderProfileUseCase(repository: adapters.uploaderProfileRepository)
        )
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { videoModel.select($0) },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            },
            uploaderSpace: uploaderSpace
        )
        let commentsModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: adapters.commentRepository)
        )
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: adapters.watchLaterRepository)
        )
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: adapters.historyRepository)
        )
        let trendingSearchModel = TrendingSearchViewModel(
            useCase: TrendingSearchUseCase(repository: adapters.trendingSearchRepository)
        )
        self.navigationCoordinator = navigationCoordinator
        self.browseModel = browseModel
        self.videoModel = videoModel
        self.commentsModel = commentsModel
        self.danmakuModel = danmakuModel
        let authenticationModel = AuthenticationViewModel(
            service: adapters.authenticationService,
            qrCodeProvider: adapters.authenticationQRCodeProvider
        )
        self.authenticationModel = authenticationModel
        self.watchLaterModel = watchLaterModel
        let watchLaterSession = WatchLaterSession(model: watchLaterModel)
        self.watchLaterSession = watchLaterSession
        self.historyModel = historyModel
        let favoritesUseCase = FavoritesUseCase(repository: adapters.favoritesRepository)
        let accountSession = process.accountSession
        let favoriteFolderList = FavoriteFolderListModel(
            useCase: favoritesUseCase,
            accountScope: {
                Self.settledAccountScope(
                    windowScope: authenticationModel.sessionScope,
                    isRestoring: authenticationModel.resolutionPhase == .restoring,
                    accountSession: accountSession
                )
            }
        )
        let favoriteFolders = FavoriteFolderViewModel(
            useCase: favoritesUseCase,
            folderList: favoriteFolderList
        )
        self.favoriteFolderList = favoriteFolderList
        self.favoriteFolders = favoriteFolders
        let writableAccount: @MainActor () -> WritableAccount? = {
            Self.writableAccount(
                windowScope: authenticationModel.sessionScope,
                isRestoring: authenticationModel.resolutionPhase == .restoring,
                accountSession: accountSession
            )
        }
        let engagementUseCase = VideoEngagementUseCase(
            repository: adapters.videoEngagementRepository
        )
        let engagementModel = VideoEngagementModel(
            useCase: engagementUseCase,
            accountID: { writableAccount()?.accountID }
        )
        self.engagementModel = engagementModel
        let accountWriteEffectRouter = AccountWriteEffectRouter(
            watchLaterModel: watchLaterModel,
            favoriteFolderList: favoriteFolderList,
            favoriteFolders: favoriteFolders,
            engagementModel: engagementModel,
            writableAccount: writableAccount
        )
        let accountWriteEffects = process.accountWriteEffects
        self.accountWriteEffectRouter = accountWriteEffectRouter
        let accountWrites = AccountWriteCoordinator(
            watchLater: WatchLaterWriteUseCase(repository: adapters.watchLaterWriteRepository),
            watchLaterModel: watchLaterModel,
            favoritesWrite: FavoritesWriteUseCase(repository: adapters.favoritesWriteRepository),
            favorites: favoritesUseCase,
            favoriteFolders: favoriteFolders,
            engagement: engagementUseCase,
            engagementModel: engagementModel,
            recommendationFeedback: RecommendationFeedbackUseCase(
                repository: adapters.recommendationFeedbackRepository
            ),
            danmakuPost: DanmakuPostUseCase(repository: adapters.danmakuPostRepository),
            commentWrite: CommentWriteUseCase(repository: adapters.commentWriteRepository),
            browseModel: browseModel,
            writableAccount: writableAccount,
            publish: { delivery, appliedLocally in
                accountWriteEffectRouter.apply(delivery, appliedLocally: appliedLocally)
                accountWriteEffects.publish(delivery, excluding: accountWriteEffectRouter)
            }
        )
        self.accountWrites = accountWrites
        // 发出成功的弹幕交给同一个弹幕会话上屏；发送时刻取同一个播放器的时间线。
        let danmakuComposer = DanmakuComposerModel(
            presentation: adapters.danmakuPresentation,
            timeline: adapters.currentTimeline,
            canPost: { accountWrites.isWritable },
            post: { request, completion in
                accountWrites.postDanmaku(request, completion: completion)
            }
        )
        self.danmakuComposer = danmakuComposer
        commentWrite = PlaybackCommentWriteModel(
            comments: commentsModel,
            canWrite: { accountWrites.isWritable },
            uploaderID: { subject in
                videoModel.presentedContext.flatMap { context in
                    context.detail.aid == subject.oid ? context.detail.owner.id : nil
                }
            },
            post: { request, completion in
                accountWrites.postComment(request, completion: completion)
            },
            react: { operation, rollback in
                accountWrites.setCommentReaction(operation, rollback: rollback)
            }
        )
        self.trendingSearchModel = trendingSearchModel
        searchSuggestionSource = SearchSuggestionSource(
            useCase: SearchSuggestionUseCase(repository: adapters.searchSuggestionRepository)
        )
        let searchSession = VideoSearchSession(
            browseModel: browseModel,
            recordHistory: process.searchHistory.record
        )
        self.searchSession = searchSession
        let sources = AppSources(
            browseModel: browseModel,
            watchLaterModel: watchLaterModel,
            watchLaterSession: watchLaterSession,
            historyModel: historyModel,
            favoriteFolderList: favoriteFolderList,
            favoriteFolders: favoriteFolders,
            searchSession: searchSession,
            trendingSearchModel: trendingSearchModel
        )
        self.sources = sources
        // 收藏夹列表是侧栏常驻的元数据，窗口已登录就读取，不绑定来源；夹内页面经收藏夹来源的描述绑定。
        let windowWide: [any AccountRevalidationParticipant] = [
            videoModel, browseModel, danmakuModel, commentsModel, uploaderSpace, favoriteFolderList,
            accountWrites, engagementModel
        ]
        revalidationParticipants = AccountRevalidationParticipants(
            entries: windowWide.map { .init(participant: $0, route: nil) }
                + sources.ordered.compactMap { source in
                    source.revalidationParticipant.map { .init(participant: $0, route: source.id) }
                }
        )
        playerContent = adapters.makePlayerContent(
            videoModel,
            danmakuModel,
            PlayerEngagementShortcuts.make(
                accountWrites: accountWrites,
                engagementModel: engagementModel,
                videoModel: videoModel
            ),
            PlayerWindowContext(
                imagePipeline: imagePipelineOwner.pipeline,
                // 与评论里不带时间的视频链接同一导航：换到该视频的播放页，离开侧栏上下文层。
                openVideo: { [navigationCoordinator] bvid in
                    navigationCoordinator.openPlayback(bvid)
                },
                canWriteAccount: { accountWrites.isWritable },
                danmakuComposer: danmakuComposer,
                addToWatchLater: { bvid in accountWrites.addToWatchLater(bvid: bvid) },
                continuePlayback: { [navigationCoordinator] bvid, preferredCID in
                    navigationCoordinator.continuePlayback(bvid, preferredCID: preferredCID)
                }
            )
        )
        commentAssetURLResolver = adapters.commentAssetURLResolver
        commentLinkRouter = adapters.commentLinkRouter
        seekPlayback = adapters.seekPlayback
        imagePipeline = imagePipelineOwner.pipeline
        commentImagePreview = NativeCommentImagePreviewPresenter(
            imagePipeline: imagePipelineOwner.pipeline,
            resolveURL: adapters.commentAssetURLResolver,
            imageSaver: commentImageSaver
        )
        systemNowPlayingCoordinator = SystemNowPlayingWindowCoordinator(
            controller: process.nowPlaying,
            connection: adapters.nowPlayingConnection,
            videoModel: videoModel
        )
        watchProgressConnection = adapters.makeWatchProgressConnection(videoModel)
    }

    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        adapters.open()
        accountWriteEffectRegistration = process.accountWriteEffects.register(
            accountWriteEffectRouter
        )
        watchProgressConnection.start()
        systemNowPlayingCoordinator.start()
    }

    /// 关窗；不可逆，重复调用不再动作。
    ///
    /// 按顺序：先从进程级测速注销本窗口；再关闭播放（停止播放器、字幕与弹幕）并恢复新窗口的来源；各来源
    /// 丢弃内容；取消认证临时任务与评论；取消在途账户写入（含弹幕）、清空弹幕输入胶囊并从写入效果集线器注销；取消短链解析；关闭评论图片预览（挂在它上面
    /// 的保存面板按取消结束）再取消图片保存；停止观看进度与 Now Playing；丢弃保活的网格；关闭图片管线；最后
    /// 由 adapter 取消弹幕的内存压力监听、停止播放偏好的持久化、注销窗口 API 的会话并失效短链 session（只在打开过
    /// 之后）。模型与连接先停下自己的任务，再拆掉它们依赖的 adapter。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        process.settings.removeAuthenticationOwner(benchmarkAuthenticationOwnerID)
        navigationCoordinator.resetForWindowClosure()
        sources.resetForWindowClosure()
        authenticationModel.cancelTransientWork()
        commentsModel.reset()
        accountWrites.close()
        engagementModel.reset()
        danmakuComposer.reset()
        commentWrite.reset()
        if let accountWriteEffectRegistration {
            process.accountWriteEffects.unregister(accountWriteEffectRegistration)
        }
        commentShortLinks.cancel()
        commentImagePreview.close()
        commentImageSaver.cancel()
        watchProgressConnection.stop()
        systemNowPlayingCoordinator.close()
        gridRetainerOwner.close()
        imagePipelineOwner.shutdown()
        if isOpen {
            adapters.close()
        }
    }

    /// 其他窗口换号引起的本窗口复核结束后由 `AppRootView` 调用：复核前收藏夹列表已被丢弃，复核得出的范围没变时不会有
    /// 账户变化通知，这里让它按此刻的范围重新对齐（范围变了时与账户变化通知重复调用也无妨，已在读取就不再请求）。
    func externalSessionRevalidationDidFinish() {
        favoriteFolderList.synchronize()
    }

    /// 本窗口的账户范围此刻是否可信：认证仍在确认、或其他窗口换号而本窗口还没复核到时为 `unresolved`，否则是本窗口的
    /// 范围。
    ///
    /// 收藏夹列表按它读取（`unresolved` 时不读取、也不丢弃），账户写入按它决定门槛（`writableAccount`）。
    ///
    /// 复核期间窗口范围仍是旧账户，Keychain 里却可能已是新账户的 Cookie 或没有凭据：此时读取会用新 Cookie 读旧 mid，
    /// 把旧账户的公开收藏夹显示出来，凭据失败还会触发一次普通复核、替换掉进行中的外部复核；写入则会以旧账户的名义改动
    /// 新账户（写授权器另按 `DedeUserID` 拦下）。见 SECURITY-MODEL §2、§3。
    static func settledAccountScope(
        windowScope: AccountSessionScope,
        isRestoring: Bool,
        accountSession: AccountSessionCoordinator
    ) -> AccountSessionScope {
        guard !isRestoring, !accountSession.awaitsRevalidation(ofWindowScope: windowScope) else {
            return .unresolved
        }
        return windowScope
    }

    /// 账户写入的门槛：`settledAccountScope` 是已登录且 mid 已知时给出账户与进程账户会话代次，否则为 nil（菜单项禁用、
    /// 不发写请求）。
    static func writableAccount(
        windowScope: AccountSessionScope,
        isRestoring: Bool,
        accountSession: AccountSessionCoordinator
    ) -> WritableAccount? {
        guard
            case .signedIn(let accountID?) = settledAccountScope(
                windowScope: windowScope,
                isRestoring: isRestoring,
                accountSession: accountSession
            ),
            accountID > 0
        else { return nil }
        return WritableAccount(accountID: accountID, sessionGeneration: accountSession.generation)
    }

    func markWindowActive() {
        systemNowPlayingCoordinator.markWindowActive()
    }

    /// 主 API 的「已确认未登录」；由 `AccountSignedOutConfirmation.isConfirmed` 判定后传入。
    func synchronizeSignedOutConfirmation(_ isConfirmed: Bool) {
        adapters.synchronizeSignedOutConfirmation(isConfirmed)
    }

    func synchronizeWatchProgressAccess(_ scope: AccountSessionScope) {
        let isSignedIn: Bool
        if case .signedIn = scope {
            isSignedIn = true
        } else {
            isSignedIn = false
        }
        watchProgressConnection.setReportingAccess(isSignedIn)
    }

    /// 弹幕控制模型：初值来自设备级偏好，改动立即写回。
    private static func makeDanmakuModel(adapters: WindowAdapters) -> DanmakuControlsViewModel {
        let store = adapters.danmakuPreferences
        let preferences = store.load()
        return DanmakuControlsViewModel(
            presentation: adapters.danmakuPresentation,
            initialSpeedLevel: preferences.speedLevel,
            initialOpacity: preferences.opacity,
            initialDisplayArea: preferences.displayArea,
            initialDensity: preferences.density,
            initialMergesDuplicates: preferences.mergesDuplicates,
            saveSpeedLevel: { store.saveSpeedLevel($0) },
            saveOpacity: { store.saveOpacity($0) },
            saveDisplayArea: { store.saveDisplayArea($0) },
            saveDensity: { store.saveDensity($0) },
            saveMergesDuplicates: { store.saveMergesDuplicates($0) }
        )
    }
}

extension ProcessComposition {
    /// 构造一个生产窗口：窗口自己的 adapter（API、播放器、弹幕）加上对本进程共享对象的引用。
    func makeWindow() -> WindowComposition {
        WindowComposition(process: self, adapters: .live(process: self))
    }
}

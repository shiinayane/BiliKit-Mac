import BiliAPI
import BiliApplication
import BiliAuth
import BiliPlayback
import Foundation

/// 进程级组装：整个 App 生命周期只有一份，由 `BiliKitMacApp` 持有，所有窗口共享。
///
/// 拥有账户会话协调器（窗口间广播账户变化、推进认证 epoch）、唯一的观看进度 writer（构造时就登记进账户会话，
/// 不存在“先准备再读取”的顺序）、窗口间的账户写入效果集线器、凭据续期、设置与线路测速、系统 Now Playing、本机搜索历史与更新器。不拥有任何窗口的
/// 对象图：窗口组装（`makeWindow()` 构造的 `WindowComposition`）拿到这些共享对象的引用，各自注册、注销与清理。进程退出前不关闭；
/// Now Playing 的封面管线与各 client 随进程释放。
@MainActor
final class ProcessComposition {
    let accountSession: AccountSessionCoordinator
    /// 进程内唯一的观看进度写入通道（串行、单并发），窗口的进度会话都经它上报。
    let watchProgressRepository: any WatchProgressRepository
    let settings: AppSettingsModel
    let nowPlaying: SystemNowPlayingController
    let searchHistory: SearchHistoryStore
    let updater: AppUpdater
    /// 把一个窗口确认成功的账户写入效果转给其他窗口；窗口打开时登记、关闭时注销。
    let accountWriteEffects = AccountWriteEffectHub()
    /// 进程唯一的凭据续期 owner：各窗口的认证服务共用它，续期因此串行，不会拿已轮换的 refresh_token 再发。
    let credentialRenewal = AccountCredentialRenewal()

    init(
        accountSession: AccountSessionCoordinator,
        watchProgressRepository: any WatchProgressRepository,
        settings: AppSettingsModel,
        nowPlaying: SystemNowPlayingController,
        searchHistory: SearchHistoryStore,
        updater: AppUpdater
    ) {
        self.accountSession = accountSession
        self.watchProgressRepository = watchProgressRepository
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.searchHistory = searchHistory
        self.updater = updater
    }

    /// 生产进程：测速与观看进度各用一个专用 API client，都登记进账户会话，登出与凭据失效时一并失效。
    static func live() -> ProcessComposition {
        let accountSession = AccountSessionCoordinator()
        let writeAPI = LiveAPIClients.watchProgressWriter()
        let watchProgressRepository = installWatchProgressWriter(
            base: BiliWatchProgressRepository(client: writeAPI),
            transport: writeAPI,
            accountSession: accountSession
        )
        return ProcessComposition(
            accountSession: accountSession,
            watchProgressRepository: watchProgressRepository,
            settings: liveSettings(accountSession: accountSession),
            nowPlaying: SystemNowPlayingController(),
            searchHistory: SearchHistoryStore(),
            updater: AppUpdater()
        )
    }

    /// 把进度写入包成进程唯一的串行 writer，并让它与底层 transport 都随账户会话失效。
    ///
    /// 两者都要登记：writer 丢弃旧会话排队中的上报，transport 取消旧会话的在途请求。见 SECURITY-MODEL §3。
    static func installWatchProgressWriter(
        base: any WatchProgressRepository,
        transport: any AuthenticatedSessionInvalidating,
        accountSession: AccountSessionCoordinator
    ) -> any WatchProgressRepository {
        let writer = SerializedWatchProgressRepository(base: base)
        _ = accountSession.registerSessionInvalidator(writer)
        _ = accountSession.registerSessionInvalidator(transport)
        return writer
    }

    /// 设置窗口的模型；线路测速只用自己的 client，样本发现只读详情与 playurl。
    private static func liveSettings(accountSession: AccountSessionCoordinator) -> AppSettingsModel
    {
        let api = LiveAPIClients.cdnBenchmark()
        _ = accountSession.registerSessionInvalidator(api)
        let discoverer = CDNBenchmarkSampleDiscoverer(client: api)
        let benchmark = BilivideoRouteBenchmark()
        return AppSettingsModel(
            store: UserDefaultsPlaybackSourcePreferenceStore(),
            discover: { targetCount in
                do {
                    return try await discoverer.discover(targetCount: targetCount).map {
                        PlaybackRouteBenchmarkSample(
                            template: $0.videoRepresentation,
                            headers: $0.mediaHeaders
                        )
                    }
                } catch {
                    throw PlaybackRouteBenchmarkOperationError.mappingDiscoveryError(error)
                }
            },
            resetDiscovery: { await discoverer.resetSeenSamples() },
            run: { samples, progress in
                try await benchmark.benchmarkUnifiedPool(
                    samples: samples,
                    progress: progress
                )
            }
        )
    }
}

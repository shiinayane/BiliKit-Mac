import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Synchronization

@testable import BiliKit

/// 测试用的进程级组装：与生产同一个类型，换成不碰网络、系统 Now Playing 与真实偏好的替身。
///
/// 搜索历史用一份 `ScratchDefaults`，搜索历史在构造时读完初值后即丢弃。经它构造的窗口不写入搜索历史
/// （测试的搜索会话各自注入写入闭包）。
@MainActor
func makeTestProcess() -> ProcessComposition {
    guard let scratch = ScratchDefaults() else {
        preconditionFailure("无法创建隔离的 UserDefaults")
    }
    defer { scratch.discard() }
    return ProcessComposition(
        accountSession: AccountSessionCoordinator(),
        deviceIdentity: makeOfflineDeviceIdentity(),
        watchProgressRepository: WatchProgressRepositoryStub(holdsReports: false),
        settings: AppSettingsModel(
            store: MemoryPlaybackSourcePreferenceStore(),
            discover: { _ in [] },
            resetDiscovery: {},
            run: { _, _ in [] }
        ),
        nowPlaying: SystemNowPlayingController(
            center: RecordingNowPlayingCenter(),
            remoteCommands: RecordingRemoteCommands(),
            artworkLoader: { _ in nil }
        ),
        searchHistory: SearchHistoryStore(defaults: scratch.defaults),
        updater: AppUpdater()
    )
}

/// 不碰网络、不写真实偏好的设备标识：spi 与激活都以网络失败结束，Cookie 退回本地值。
func makeOfflineDeviceIdentity() -> BiliDeviceIdentity {
    BiliDeviceIdentity(store: MemoryDeviceIdentityStore(), transport: OfflineHTTPTransport())
}

/// 设备标识存储的测试替身：只在内存，不写真实偏好。
final class MemoryDeviceIdentityStore: DeviceIdentityStoring, Sendable {
    private let identity = Mutex<DeviceIdentity?>(nil)

    func load() -> DeviceIdentity? { identity.withLock { $0 } }
    func save(_ identity: DeviceIdentity) { self.identity.withLock { $0 = identity } }
    func clear() { identity.withLock { $0 = nil } }
}

/// 不碰网络的 transport：每个请求都以网络失败结束，设备标识因此退回本地值。
struct OfflineHTTPTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

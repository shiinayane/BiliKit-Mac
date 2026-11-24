import BiliApplication
import BiliNetworking
import Foundation

/// 进程唯一的设备标识 owner：取得、持久化、激活并轮换网页端读取携带的设备 Cookie。
///
/// 拥有当前标识、在途的准备 Task 与自己的 credential-free transport；不拥有账户凭据，也不决定哪些请求携带
/// （`BiliAPIClient` 按 access 决定，见 SECURITY-MODEL §3）。由 Composition 构造一份，注入所有 API client，并登记进
/// 账户会话：登出与凭据失效时经 `invalidateAuthenticatedSession()` 清除持久化的值、取消在途准备。
///
/// 准备一次标识：存储中仍在保留期内的值 → 匿名 `GET /x/frontend/finger/spi` → 本地生成值（只在内存，不持久化），
/// 然后不分登录状态激活一次（ExClimbWuzhi），激活返回后才交给第一个请求。未激活的 `buvid3` 会让搜索收到
/// `v_voucher` 挑战，所以激活必须先于任何携带它的请求；服务端是否长期记住激活未知，而浏览器每次打开页面都运行指纹脚本，
/// 因此每个进程对同一标识也激活一次。并发调用共享同一个准备 Task。actor 隔离；跨 `await` 可重入，所以准备返回后用
/// `generation` 复核：会话失效时递增，不一致的迟到结果直接丢弃，既不写回存储也不成为当前值，调用方随后按新代次重新准备。
public actor BiliDeviceIdentity: DeviceCookieProviding, AuthenticatedSessionInvalidating {
    private let store: any DeviceIdentityStoring
    private let httpClient: HTTPClient
    private let clock: @Sendable () -> Int64
    private var current: DeviceIdentity?
    private var pendingPreparation: Task<PreparedIdentity, Never>?
    /// 会话失效时以 `&+=` 递增；准备返回后与发起时的值比对，不一致就丢弃这次结果。
    private var generation: UInt64 = 0

    /// 生产实例：无凭据、拒绝跳转、`preparationTimeout` 时限的 session。
    public init(store: any DeviceIdentityStoring) {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = Self.preparationTimeout
        configuration.timeoutIntervalForResource = Self.preparationTimeout
        self.init(store: store, transport: URLSessionTransport(configuration: configuration))
    }

    /// spi 与激活各自的时限。
    ///
    /// 第一个网页端读取要等准备完成，交互请求默认的 30 秒会把首页、播放与搜索一起拖住；spi 失败时退回本地值，
    /// 激活失败时照常交出标识，所以短时限只让准备更快放弃。调长会在 spi 不通的网络里拖慢每次启动的第一批请求，
    /// 调短会在慢网络里更常退回本地值或跳过激活。
    static let preparationTimeout: TimeInterval = 5

    /// `transport` 必须是不保存 Cookie 的 ephemeral transport（`credentialFreeEphemeral`），spi 与激活都只带这里写入的头。
    public init(store: any DeviceIdentityStoring, transport: any HTTPTransport) {
        self.init(
            store: store,
            transport: transport,
            clock: { Int64(Date().timeIntervalSince1970) }
        )
    }

    init(
        store: any DeviceIdentityStoring,
        transport: any HTTPTransport,
        clock: @escaping @Sendable () -> Int64
    ) {
        self.store = store
        httpClient = HTTPClient(transport: transport)
        self.clock = clock
    }

    /// 等待者取消时立即以 `CancellationError` 结束，共享的准备照常完成。
    ///
    /// `Task.value` 不响应等待者的取消，所以经一个 `AsyncStream` 转交：等待者取消时迭代立即结束；中继 Task 仍等准备
    /// 完成并记下当前值，准备只由会话失效取消，不因任何一个等待者离开而中断。
    public func deviceCookie() async throws -> String {
        try Task.checkCancellation()
        if let current { return current.cookieHeader }
        let (cookies, continuation) = AsyncStream.makeStream(of: String.self)
        Task {
            continuation.yield(await identity().cookieHeader)
            continuation.finish()
        }
        for await cookie in cookies { return cookie }
        throw CancellationError()
    }

    /// 登出与凭据失效：丢弃当前与持久化的标识，取消在途准备；下一个网页端读取重新准备一组。
    ///
    /// 不让匿名阶段的请求与上一个账户共用同一个设备标识。登录成功不经过这里，与 `BiliAPIClient` 的认证 epoch 相同。
    public func invalidateAuthenticatedSession() async {
        generation &+= 1
        pendingPreparation?.cancel()
        pendingPreparation = nil
        current = nil
        store.clear()
    }

    private func identity() async -> DeviceIdentity {
        while true {
            if let current { return current }
            let preparationGeneration = generation
            let preparation =
                pendingPreparation
                ?? Task { [store, httpClient, clock] in
                    await Self.prepare(store: store, client: httpClient, clock: clock)
                }
            pendingPreparation = preparation
            let prepared = await preparation.value
            // 等待期间会话已失效：这组属于旧会话，丢弃后按新代次重来。
            guard preparationGeneration == generation else { continue }
            pendingPreparation = nil
            // 同一个准备的其他等待者可能已经先写好了当前值。
            if let current { return current }
            if prepared.persists {
                store.save(prepared.identity)
            }
            current = prepared.identity
            return prepared.identity
        }
    }

    /// 一次准备的结果；`persists` 只对 spi 新下发的值为真，存储里读出的与本地生成的都不写回。
    private struct PreparedIdentity: Sendable {
        let identity: DeviceIdentity
        let persists: Bool
    }

    private static func prepare(
        store: any DeviceIdentityStoring,
        client: HTTPClient,
        clock: @Sendable () -> Int64
    ) async -> PreparedIdentity {
        let now = clock()
        let prepared: PreparedIdentity
        if let stored = store.load(), stored.isFresh(at: now) {
            prepared = PreparedIdentity(identity: stored, persists: false)
        } else if let issued = await fetchIssuedIdentity(using: client, issuedAt: now) {
            prepared = PreparedIdentity(identity: issued, persists: true)
        } else {
            prepared = PreparedIdentity(identity: .localFallback(issuedAt: now), persists: false)
        }
        // 会话已失效的准备不再激活：结果会被丢弃，激活只会多发一个请求。激活失败静默、不重试。
        if !Task.isCancelled,
            let request = activationRequest(cookie: prepared.identity.cookieHeader)
        {
            _ = try? await client.send(request)
        }
        return prepared
    }

    private static func fetchIssuedIdentity(
        using client: HTTPClient,
        issuedAt: Int64
    ) async -> DeviceIdentity? {
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else {
            return nil
        }
        let request = HTTPRequest(url: url, headers: browserHeaders(accept: "application/json"))
        guard let response = try? await client.send(request),
            response.body.count <= maximumResponseSize,
            let envelope = try? JSONDecoder().decode(SpiEnvelope.self, from: response.body),
            envelope.code == 0,
            let data = envelope.data
        else { return nil }
        return DeviceIdentity(buvid3: data.buvid3, buvid4: data.buvid4, issuedAt: issuedAt)
    }

    /// 激活请求只带设备 Cookie，不带账户凭据；payload 是固定键与随机值，不含本机真实环境，见 SECURITY-MODEL §3。
    private static func activationRequest(cookie: String) -> HTTPRequest? {
        guard
            let url = URL(string: "https://api.bilibili.com/x/internal/gaia-gateway/ExClimbWuzhi"),
            let body = activationBody()
        else { return nil }
        var headers = browserHeaders(accept: "application/json")
        headers["Content-Type"] = "application/json"
        headers["Cookie"] = cookie
        return HTTPRequest(url: url, method: .post, headers: headers, body: body)
    }

    /// 网页指纹脚本上报的最小形状（与 PiliPlus 相同的三个键）：`adca` 是 `navigator.platform`，与 User-Agent 的
    /// Macintosh 一致；`bfe9` 本应是 canvas 指纹的 base64 尾部，这里每次随机，不读取本机任何环境。
    private static func activationBody() -> Data? {
        var bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        bytes += [0, 0, 0, 0, 73, 69, 78, 68]
        bytes += (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        let canvasTail = String(Data(bytes).base64EncodedString().suffix(50))
        let fingerprint: [String: Any] = [
            "3064": 1,
            "39c8": "333.1387.fp.risk",
            "3c43": ["adca": "MacIntel", "bfe9": canvasTail]
        ]
        guard let fingerprintData = try? JSONSerialization.data(withJSONObject: fingerprint),
            let payload = String(data: fingerprintData, encoding: .utf8)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["payload": payload])
    }

    private static func browserHeaders(accept: String) -> [String: String] {
        [
            "Accept": accept,
            "User-Agent": HTTPUserAgent.browserCompatible,
            "Referer": "https://www.bilibili.com/"
        ]
    }

    /// spi 正文的上限；正常响应约 200 字节，超出按异常响应丢弃、改用本地值。
    private static let maximumResponseSize = 16 * 1_024

    private struct SpiEnvelope: Decodable {
        let code: Int
        let data: SpiData?
    }

    private struct SpiData: Decodable {
        let buvid3: String
        let buvid4: String?

        private enum CodingKeys: String, CodingKey {
            case buvid3 = "b_3"
            case buvid4 = "b_4"
        }
    }
}

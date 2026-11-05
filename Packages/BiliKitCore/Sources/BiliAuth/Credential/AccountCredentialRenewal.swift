import BiliNetworking
import Foundation

/// 凭据续期的进程级 owner：用 Keychain 里凭据的 refresh_token 换一份新凭据（新的 access_token、refresh_token 与
/// Cookie）并写回 Keychain。
///
/// 拥有续期专用的 transport 与上一次强制续期的时刻；不拥有登录状态：何时续期由各窗口的 `BiliAuthenticationService`
/// 决定，状态也由它发布。App Composition 只创建一个实例，所有窗口共用；续期按调用顺序串行执行，后到的一次会读到前一次
/// 写回的新凭据，按它重新判断，不会拿已轮换掉的 refresh_token 再发。
///
/// 续期从不删除凭据、不改变登录状态：网络、业务码、正文不合规与 Keychain 失败都保留原凭据，最坏结果只是没有续期。
/// 一旦开始就做完（调用方的取消不传进来）：服务端可能已经轮换 token，半途放弃会让本地只剩失效的旧 token。写回前再读一次
/// Keychain，凭据已不是续期前那一份（登出、换号或另一次续期）就丢弃结果。见 SECURITY-MODEL §2。
public actor AccountCredentialRenewal {
    /// 一次续期的起因。
    enum Trigger: Sendable {
        /// 启动时的例行检查：离到期不足 `renewalWindow` 才续期。
        case nearExpiry
        /// 窗口复核：某个页面遇到凭据失败，不论离到期多久都续期一次（受 `minimumForcedInterval` 限制），让只有
        /// token 失效、Cookie 仍有效的凭据恢复。
        case forced
    }

    /// 离到期不足这么久时启动就续期。
    ///
    /// 扫码得到的凭据约 180 天到期，续期后 Cookie 约 90 天到期（token 仍是 180 天），整份凭据按最早的算；30 天意味着
    /// 每月至少打开一次的用户不会因到期被登出，又不会每次启动都轮换 token。调大会更早、更频繁地续期，调小则长时间不打开
    /// App 的用户更容易错过续期窗口。
    static let renewalWindow: TimeInterval = 30 * 86_400
    /// 两次强制续期之间的最短间隔：同一次凭据失败会让多个页面各自触发复核，间隔内只续一次，免得连续轮换 token。
    static let minimumForcedInterval: TimeInterval = 10 * 60

    /// 续期唯一连接的地址，与扫码登录同一主机，见 SECURITY-MODEL §2。
    private static let renewalURL: URL = {
        guard
            let url = URL(
                string: "https://passport.bilibili.com/x/passport-login/oauth2/refresh_token"
            )
        else {
            preconditionFailure("Static credential renewal URL must be valid")
        }
        return url
    }()

    private let httpClient: HTTPClient
    private let store: any AccountCredentialStoring
    private let decoder = JSONDecoder()
    /// 上一次强制续期发起的时刻（不论成败），只在 `.forced` 通过间隔检查时更新。
    private var lastForcedAttempt: Date?
    /// 最后一次排进来的续期；新的续期先等它结束，续期因此串行。
    private var tail: Task<Void, Never>?

    public init() {
        httpClient = HTTPClient(transport: AuthenticationHTTP.makeProductionTransport())
        store = KeychainAccountCredentialStore()
    }

    /// 网络与 Keychain 两个系统边界；`init()` 由此接入认证专用 session 与 Keychain store。
    init(transport: any HTTPTransport, store: any AccountCredentialStoring) {
        httpClient = HTTPClient(transport: transport)
        self.store = store
    }

    /// 按 `trigger` 判断并在需要时续期，结束（含不需要、失败）后返回；不抛错。
    func renewIfNeeded(_ trigger: Trigger) async {
        let previous = tail
        // 非结构化 Task：调用方被取消也不打断已经开始的续期，理由见类型说明。
        let task = Task {
            await previous?.value
            await self.renew(trigger)
        }
        tail = task
        await task.value
    }

    private func renew(_ trigger: Trigger) async {
        guard let original = try? store.load(), !original.isExpired(),
            let accountID = original.value(for: .userID).flatMap(Int64.init)
        else {
            return
        }
        let now = Date.now
        switch trigger {
        case .nearExpiry:
            guard original.expiresAt.timeIntervalSince(now) < Self.renewalWindow else { return }
        case .forced:
            if let lastForcedAttempt,
                now.timeIntervalSince(lastForcedAttempt) < Self.minimumForcedInterval
            {
                return
            }
            lastForcedAttempt = now
        }
        guard
            let request = AuthenticationHTTP.signedFormRequest(
                url: Self.renewalURL,
                parameters: [
                    "access_key": original.appAccessToken.value,
                    "refresh_token": original.appAccessToken.refreshToken
                ]
            ),
            let response = try? await httpClient.send(request),
            response.body.count <= AuthenticationHTTP.maximumResponseSize,
            response.looksLikeJSON(),
            let envelope = try? decoder.decode(RenewalEnvelope.self, from: response.body),
            envelope.code == 0,
            let issued = envelope.data?.credential(receivedAt: .now),
            issued.mid == accountID
        else {
            return
        }
        // 比较并写回：续期期间凭据被登出删掉、换成另一账户或另一次续期写过，就丢弃这份结果。
        guard (try? store.load()) == original else { return }
        try? store.save(issued.credential)
    }
}

/// 续期响应：顶层 `code` 为 0 时 `data` 是与扫码登录成功相同形状的凭据。
private struct RenewalEnvelope: Decodable, Sendable {
    let code: Int
    let data: IssuedCredentialPayload?

    private enum CodingKeys: String, CodingKey {
        case code
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        // 非 0 时 `data` 常为 null 或别的形状，只在成功时要求它是凭据。
        data = code == 0 ? try? container.decode(IssuedCredentialPayload.self, forKey: .data) : nil
    }
}

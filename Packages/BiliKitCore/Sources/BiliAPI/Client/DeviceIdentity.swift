import Foundation

/// 网页端读取携带的一组设备 Cookie：`buvid3`、可选的 `buvid4` 与下发时刻 `b_nut`。
///
/// 是设备标识而不是凭据：不证明任何账户身份，也不进 Keychain；持久化与清理规则见 SECURITY-MODEL §6，
/// 哪些请求携带见 §3。值只从 spi 下发或 `localFallback` 生成，经 `init?(buvid3:buvid4:issuedAt:)` 校验字符集与长度，
/// 不合格的值不会写进 Cookie 头。
public struct DeviceIdentity: Sendable, Equatable {
    public let buvid3: String
    public let buvid4: String?
    /// 下发时刻（Unix 秒），即 `b_nut`；保留期按它计算。
    public let issuedAt: Int64

    /// 值必须是 Cookie 安全的短 token：spi 的 `b_3` 形如 `8-4-4-4-17` 位十六进制加 `infoc`，`b_4` 另含 base64 段；
    /// 不按精确格式匹配，接口细节漂移时仍可用，但拒绝分号、空白与过长的值，防止注入额外的 Cookie。
    public init?(buvid3: String, buvid4: String?, issuedAt: Int64) {
        guard Self.isCookieSafe(buvid3, maximumLength: Self.maximumBuvid3Length),
            buvid4.map({ Self.isCookieSafe($0, maximumLength: Self.maximumBuvid4Length) }) ?? true,
            issuedAt > 0
        else { return nil }
        self.buvid3 = buvid3
        self.buvid4 = buvid4
        self.issuedAt = issuedAt
    }

    /// spi 不可用时的本地值：与 spi 相同的 `8-4-4-4-17` 位大写十六进制加 `infoc`，没有 `buvid4`。
    ///
    /// 只在本进程内存中使用、不持久化，下次启动再向 spi 取。
    static func localFallback(issuedAt: Int64) -> DeviceIdentity {
        let groups = [8, 4, 4, 4, 17].map { length in
            String((0..<length).map { _ in hexDigits.randomElement() ?? "0" })
        }
        let value = groups.joined(separator: "-") + "infoc"
        guard let identity = DeviceIdentity(buvid3: value, buvid4: nil, issuedAt: issuedAt) else {
            preconditionFailure("本地生成的 buvid3 必须满足自身的校验")
        }
        return identity
    }

    /// 授权器给出的 Cookie 之后并入的那一段。
    var cookieHeader: String {
        var parts = ["buvid3=\(buvid3)", "b_nut=\(issuedAt)"]
        if let buvid4 {
            parts.append("buvid4=\(buvid4)")
        }
        return parts.joined(separator: "; ")
    }

    /// 是否仍在保留期内；时钟回拨到下发时刻之前同样视为失效，重新取一组。
    func isFresh(at now: Int64) -> Bool {
        now >= issuedAt && now - issuedAt < Self.retentionSeconds
    }

    /// 保留期：一年，与浏览器里 `buvid3` Cookie 的寿命一致。
    ///
    /// 调短会更频繁地换设备标识（更像新设备），调长则让同一标识在本机留得更久。
    static let retentionSeconds: Int64 = 365 * 24 * 60 * 60

    /// spi 的 `b_3` 为 46 个字符，`b_4` 约 76 个；上限留出余量，只用于拒绝明显异常的值。
    private static let maximumBuvid3Length = 64
    private static let maximumBuvid4Length = 160
    private static let hexDigits = Array("0123456789ABCDEF")
    private static let cookieSafeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-+/="
    )

    private static func isCookieSafe(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy(cookieSafeCharacters.contains)
    }
}

/// 设备标识的持久化 port：由 App 以偏好实现，`BiliDeviceIdentity` 是唯一调用方。
///
/// `load` 读到缺失、版本不符或校验失败的值时返回 nil（实现应同时删掉坏值）；`clear` 在登出与凭据失效时调用。
/// 实现只保存这三项，不保存账户信息。
public protocol DeviceIdentityStoring: Sendable {
    func load() -> DeviceIdentity?
    func save(_ identity: DeviceIdentity)
    func clear()
}

/// 请求管线取设备 Cookie 的 port；`BiliAPIClient` 只在网页端读取（`anonymous`、`accountRead`）时调用。
///
/// 返回授权器之后并入的 Cookie 片段；取不到下发值时由实现给出本地值。只在调用方任务取消时抛出
/// `CancellationError`，并且必须立即响应取消，不能让被取消的请求等到准备结束。
public protocol DeviceCookieProviding: Sendable {
    func deviceCookie() async throws -> String
}

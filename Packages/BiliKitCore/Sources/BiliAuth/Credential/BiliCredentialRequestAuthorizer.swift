import BiliNetworking
import Foundation

public enum BiliRequestAuthorizationError:
    HTTPRequestAuthorizationFailure, Sendable, Equatable
{
    case requestNotAllowed
    case credentialHeaderAlreadyPresent
    case missingCredential
    case expiredCredential
    case invalidCredential
    case credentialStoreUnavailable
    case validationUnavailable

    public var authorizationFailureKind: HTTPRequestAuthorizationFailureKind {
        switch self {
        case .missingCredential:
            .missingCredential
        case .expiredCredential, .invalidCredential:
            .invalidCredential
        case .credentialStoreUnavailable, .validationUnavailable:
            .unavailable
        case .requestNotAllowed, .credentialHeaderAlreadyPresent:
            .denied
        }
    }
}

/// 从 Keychain 按需读取 Cookie，并只授权代码内精确列出的 Bilibili API 请求。
///
/// 调用方声明“需要认证”并不足够：scheme、host、port、method、path、query 与现有 Cookie
/// header 都会再次验证。损坏或过期凭据会清除，媒体/CDN/loopback 请求无法通过此边界。
public struct BiliCredentialRequestAuthorizer: HTTPRequestAuthorizing, Sendable {
    private static let maximumResponseSize = 256 * 1_024
    private static let navigationValidationURL: URL = {
        guard
            let url = URL(
                string: "https://api.bilibili.com/x/web-interface/nav"
            )
        else {
            preconditionFailure("Static navigation validation URL must be valid")
        }
        return url
    }()

    private let store: any WebCredentialStoring
    private let httpClient: HTTPClient
    private let transportInvalidator: (@Sendable () -> Void)?

    public init() {
        let transport = Self.makeProductionTransport()
        store = KeychainWebCredentialStore()
        httpClient = HTTPClient(transport: transport)
        transportInvalidator = { transport.invalidateAndCancel() }
    }

    init(
        store: any WebCredentialStoring,
        transport: any HTTPTransport = Self.makeProductionTransport()
    ) {
        self.store = store
        httpClient = HTTPClient(transport: transport)
        if let invalidating = transport as? any HTTPTransportInvalidating {
            transportInvalidator = { invalidating.invalidateAndCancel() }
        } else {
            transportInvalidator = nil
        }
    }

    /// 返回附带短生命周期 Cookie header 的新请求；原请求不会被原地共享或缓存。
    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        guard Self.isAllowed(request) else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard
            !request.headers.keys.contains(where: {
                $0.caseInsensitiveCompare("Cookie") == .orderedSame
            })
        else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential: WebCredential
        do {
            guard let stored = try store.load() else {
                throw BiliRequestAuthorizationError.missingCredential
            }
            credential = stored
        } catch let error as BiliRequestAuthorizationError {
            throw error
        } catch WebCredentialStoreError.corruptCredential {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.invalidCredential
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }

        guard !credential.isExpired() else {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.expiredCredential
        }

        var headers = request.headers
        headers["Cookie"] = credential.cookieHeader
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    public func deleteStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }

    public func invalidateSession() {
        transportInvalidator?()
    }

    /// 验证已存凭据当前是否仍登录；明确失效会清除，验证不可用则保留并抛错。
    func restoreAccountSession() async throws -> StoredAccountSessionRestoreResult {
        let request = HTTPRequest(
            url: Self.navigationValidationURL,
            headers: [
                "Accept": "application/json",
                "Referer": "https://www.bilibili.com/",
                "User-Agent": "BiliKitMac/0.1",
            ]
        )
        let authorized: HTTPRequest
        do {
            authorized = try await authorize(request)
        } catch BiliRequestAuthorizationError.missingCredential {
            return .signedOut(hadCredential: false)
        } catch BiliRequestAuthorizationError.expiredCredential,
            BiliRequestAuthorizationError.invalidCredential
        {
            return .signedOut(hadCredential: true)
        }

        let response: HTTPResponse
        do {
            response = try await httpClient.send(authorized)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BiliRequestAuthorizationError.validationUnavailable
        }
        guard response.body.count <= Self.maximumResponseSize,
            Self.looksLikeJSON(response),
            let envelope = try? JSONDecoder().decode(
                NavigationAuthenticationEnvelope.self,
                from: response.body
            ),
            envelope.code == 0,
            let data = envelope.data
        else {
            throw BiliRequestAuthorizationError.validationUnavailable
        }
        guard case .signedIn(let identity) = data.authenticationResult else {
            try purgeStoredCredential()
            return .signedOut(hadCredential: true)
        }
        return .signedIn(identity)
    }

    private static func isAllowed(_ request: HTTPRequest) -> Bool {
        guard
            let components = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }
        guard
            components.scheme?.lowercased() == "https"
                && components.host?.lowercased() == "api.bilibili.com"
                && (components.port == nil || components.port == 443)
                && components.user == nil
                && components.password == nil
                && components.fragment == nil
                && request.method == .get
        else {
            return false
        }
        switch components.percentEncodedPath {
        case "/x/web-interface/nav":
            return components.queryItems?.isEmpty != false
        case "/x/web-interface/history/cursor":
            return isAllowedHistoryQuery(components.queryItems)
        case "/x/player/playurl":
            return isAllowedPlaybackQuery(components.queryItems)
        case "/x/player/wbi/v2":
            return isAllowedPlayerWBIQuery(components.queryItems)
        case "/x/v2/dm/wbi/web/seg.so":
            return isAllowedDanmakuWBIQuery(components.queryItems)
        default:
            return false
        }
    }

    private static func isAllowedDanmakuWBIQuery(
        _ queryItems: [URLQueryItem]?
    ) -> Bool {
        guard let queryItems, queryItems.count == 5 else { return false }
        var values: [String: String] = [:]
        for item in queryItems {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                return false
            }
        }
        guard values.count == 5,
            Set(values.keys) == ["type", "oid", "segment_index", "w_rid", "wts"],
            values["type"] == "1",
            let oid = values["oid"].flatMap(Int64.init),
            oid > 0,
            let segmentIndex = values["segment_index"].flatMap(Int.init),
            (1...10_000).contains(segmentIndex),
            let timestamp = values["wts"].flatMap(Int64.init),
            timestamp > 0,
            let signature = values["w_rid"],
            signature.count == 32,
            signature.allSatisfy({
                $0.isASCII
                    && ($0.isNumber || ("a"..."f").contains($0))
            })
        else {
            return false
        }
        return true
    }

    private static func isAllowedPlaybackQuery(
        _ queryItems: [URLQueryItem]?
    ) -> Bool {
        guard let queryItems, (6...7).contains(queryItems.count) else {
            return false
        }
        var values: [String: String] = [:]
        for item in queryItems {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                return false
            }
        }
        let requiredKeys: Set<String> = [
            "bvid", "cid", "qn", "fnval", "fnver", "fourk",
        ]
        let keys = Set(values.keys)
        guard keys == requiredKeys || keys == requiredKeys.union(["cur_language"]),
            let bvid = values["bvid"],
            bvid.count == 12,
            bvid.hasPrefix("BV"),
            bvid.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }),
            let cid = values["cid"].flatMap(Int64.init),
            cid > 0,
            let quality = values["qn"].flatMap(Int.init),
            quality > 0,
            values["fnval"] == "976",
            values["fnver"] == "0",
            values["fourk"] == "1"
        else {
            return false
        }
        if let language = values["cur_language"],
            !isAllowedAudioLanguage(language)
        {
            return false
        }
        return true
    }

    private static func isAllowedAudioLanguage(_ value: String) -> Bool {
        guard (2...35).contains(value.count) else { return false }
        let subtags = value.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard let primary = subtags.first,
            (2...3).contains(primary.count),
            primary.allSatisfy({
                $0.isASCII && $0.isLetter && $0.isLowercase
            })
        else {
            return false
        }
        return subtags.dropFirst().allSatisfy { subtag in
            (1...8).contains(subtag.count)
                && subtag.allSatisfy {
                    $0.isASCII && ($0.isLetter || $0.isNumber)
                }
        }
    }

    private static func isAllowedPlayerWBIQuery(
        _ queryItems: [URLQueryItem]?
    ) -> Bool {
        guard let queryItems, queryItems.count == 4 else { return false }
        var values: [String: String] = [:]
        for item in queryItems {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                return false
            }
        }
        guard values.count == 4,
            Set(values.keys) == ["bvid", "cid", "w_rid", "wts"],
            let bvid = values["bvid"],
            bvid.count == 12,
            bvid.hasPrefix("BV"),
            bvid.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }),
            let cid = values["cid"].flatMap(Int64.init),
            cid > 0,
            let timestamp = values["wts"].flatMap(Int64.init),
            timestamp > 0,
            let signature = values["w_rid"],
            signature.count == 32,
            signature.allSatisfy({
                $0.isASCII
                    && ($0.isNumber || ("a"..."f").contains($0))
            })
        else {
            return false
        }
        return true
    }

    private static func isAllowedHistoryQuery(
        _ queryItems: [URLQueryItem]?
    ) -> Bool {
        guard let queryItems, queryItems.count == 4 else { return false }
        var values: [String: String] = [:]
        for item in queryItems {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                return false
            }
        }
        guard values.count == 4,
            Set(values.keys) == ["max", "view_at", "business", "ps"],
            let maximum = values["max"].flatMap(Int64.init),
            let viewedAt = values["view_at"].flatMap(Int64.init),
            let pageSize = values["ps"].flatMap(Int.init),
            maximum >= 0,
            viewedAt >= 0,
            (1...50).contains(pageSize),
            let business = values["business"],
            business.count <= 64,
            business.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            return false
        }
        return true
    }

    private func purgeStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }

    private static func looksLikeJSON(_ response: HTTPResponse) -> Bool {
        if let contentType = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased(),
            !contentType.contains("json")
        {
            return false
        }
        guard
            let firstByte = response.body.first(where: {
                ![9, 10, 13, 32].contains($0)
            })
        else {
            return false
        }
        return firstByte == 0x7B
    }

    private static func makeProductionTransport() -> URLSessionTransport {
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
}

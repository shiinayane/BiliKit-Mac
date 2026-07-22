import BiliNetworking
import Foundation

public enum BiliRequestAuthorizationError: Error, Sendable, Equatable {
    case requestNotAllowed
    case credentialHeaderAlreadyPresent
    case missingCredential
    case expiredCredential
    case invalidCredential
    case credentialStoreUnavailable
    case validationUnavailable
}

public struct BiliCredentialRequestAuthorizer: HTTPRequestAuthorizing, Sendable {
    private static let maximumResponseSize = 256 * 1_024

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

    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        guard Self.isAllowed(request) else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !request.headers.keys.contains(where: {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
        }) else {
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

    public func restoreLoginState() async throws -> Bool {
        let request = HTTPRequest(
            url: URL(
                string: "https://api.bilibili.com/x/web-interface/nav"
            )!,
            headers: [
                "Accept": "application/json",
                "Referer": "https://www.bilibili.com/",
                "User-Agent": "BiliKitMac/0.1",
            ]
        )
        let authorized: HTTPRequest
        do {
            authorized = try await authorize(request)
        } catch BiliRequestAuthorizationError.missingCredential,
                BiliRequestAuthorizationError.expiredCredential,
                BiliRequestAuthorizationError.invalidCredential {
            return false
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
                  NavigationEnvelope.self,
                  from: response.body
              ),
              envelope.code == 0,
              let data = envelope.data
        else {
            throw BiliRequestAuthorizationError.validationUnavailable
        }
        guard data.isLogin else {
            try purgeStoredCredential()
            return false
        }
        return true
    }

    private static func isAllowed(_ request: HTTPRequest) -> Bool {
        guard let components = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        guard components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.bilibili.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
            && request.method == .get
        else {
            return false
        }
        switch components.path {
        case "/x/web-interface/nav":
            return components.queryItems?.isEmpty != false
        case "/x/web-interface/history/cursor":
            return isAllowedHistoryQuery(components.queryItems)
        case "/x/player/v2":
            return isAllowedPlayerV2Query(components.queryItems)
        default:
            return false
        }
    }

    private static func isAllowedPlayerV2Query(
        _ queryItems: [URLQueryItem]?
    ) -> Bool {
        guard let queryItems, queryItems.count == 2 else { return false }
        var values: [String: String] = [:]
        for item in queryItems {
            guard values.updateValue(item.value ?? "", forKey: item.name) == nil else {
                return false
            }
        }
        guard values.count == 2,
              Set(values.keys) == ["bvid", "cid"],
              let bvid = values["bvid"],
              bvid.count == 12,
              bvid.hasPrefix("BV"),
              bvid.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber)
              }),
              let cid = values["cid"].flatMap(Int64.init),
              cid > 0
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
           !contentType.contains("json") {
            return false
        }
        guard let firstByte = response.body.first(where: {
            ![9, 10, 13, 32].contains($0)
        }) else {
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

    private struct NavigationEnvelope: Decodable {
        let code: Int
        let data: NavigationData?
    }

    private struct NavigationData: Decodable {
        let isLogin: Bool
    }
}

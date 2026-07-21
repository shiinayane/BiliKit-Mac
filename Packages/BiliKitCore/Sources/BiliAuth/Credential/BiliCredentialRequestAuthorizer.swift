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

    public init() {
        store = KeychainWebCredentialStore()
        httpClient = HTTPClient(transport: Self.makeProductionTransport())
    }

    init(
        store: any WebCredentialStoring,
        transport: any HTTPTransport = Self.makeProductionTransport()
    ) {
        self.store = store
        httpClient = HTTPClient(transport: transport)
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
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.bilibili.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
            && components.path == "/x/web-interface/nav"
            && request.method == .get
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

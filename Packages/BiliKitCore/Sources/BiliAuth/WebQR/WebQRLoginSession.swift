import BiliNetworking
import Foundation

public actor WebQRLoginSession {
    public static let productionBaseURL = URL(
        string: "https://passport.bilibili.com"
    )!

    private static let qrCodeHost = "account.bilibili.com"
    private static let maximumResponseSize = 256 * 1_024

    public private(set) var state: WebQRLoginState = .signedOut

    private let httpClient: HTTPClient
    private let baseURL: URL
    private let decoder = JSONDecoder()
    private var generation: UInt64 = 0
    private var activeChallenge: ActiveChallenge?
    private var pendingCredential: PendingCredential?
    private var latestPollID: UInt64 = 0

    public init() {
        httpClient = HTTPClient(transport: Self.makeProductionTransport())
        baseURL = Self.productionBaseURL
    }

    init(
        transport: any HTTPTransport,
        baseURL: URL = WebQRLoginSession.productionBaseURL
    ) {
        httpClient = HTTPClient(transport: transport)
        self.baseURL = baseURL
    }

    @discardableResult
    public func requestQRCode() async throws -> WebQRLoginState {
        generation &+= 1
        let operationGeneration = generation
        activeChallenge = nil
        pendingCredential = nil
        latestPollID = 0
        state = .requestingQRCode

        do {
            let response = try await send(path: "/x/passport-login/web/qrcode/generate")
            try Task.checkCancellation()
            try requireCurrentGeneration(operationGeneration)

            let envelope: GenerateEnvelope
            do {
                envelope = try decoder.decode(GenerateEnvelope.self, from: response.body)
            } catch {
                return fail(.invalidResponse, generation: operationGeneration)
            }
            guard envelope.code == 0 else {
                return fail(
                    .serviceRejected(envelope.code),
                    generation: operationGeneration
                )
            }
            guard let data = envelope.data,
                  Self.isValidQRCodeKey(data.qrcodeKey),
                  Self.isValidQRCodeURL(data.url)
            else {
                return fail(.invalidResponse, generation: operationGeneration)
            }

            let qrCode = WebQRCode(payload: data.url)
            activeChallenge = ActiveChallenge(
                generation: operationGeneration,
                key: data.qrcodeKey,
                qrCode: qrCode
            )
            state = .awaitingScan(qrCode)
            return state
        } catch is StaleOperationError {
            throw CancellationError()
        } catch is CancellationError {
            resetIfCurrent(operationGeneration)
            throw CancellationError()
        } catch let failure as WebQRLoginFailure {
            return fail(failure, generation: operationGeneration)
        } catch {
            return fail(.network, generation: operationGeneration)
        }
    }

    @discardableResult
    public func pollOnce() async throws -> WebQRLoginState {
        guard let challenge = activeChallenge,
              challenge.generation == generation
        else {
            state = .failed(.noActiveChallenge)
            return state
        }

        latestPollID &+= 1
        let pollID = latestPollID

        do {
            let response = try await send(
                path: "/x/passport-login/web/qrcode/poll",
                queryItems: [
                    URLQueryItem(name: "qrcode_key", value: challenge.key),
                ]
            )
            try Task.checkCancellation()
            try requireCurrentPoll(
                generation: challenge.generation,
                pollID: pollID
            )

            let envelope: PollEnvelope
            do {
                envelope = try decoder.decode(PollEnvelope.self, from: response.body)
            } catch {
                return fail(.invalidResponse, generation: challenge.generation)
            }
            guard envelope.code == 0 else {
                return fail(
                    .serviceRejected(envelope.code),
                    generation: challenge.generation
                )
            }
            guard let data = envelope.data else {
                return fail(.invalidResponse, generation: challenge.generation)
            }

            switch data.code {
            case 0:
                let observation = Self.safeObservation(
                    data: data,
                    response: response
                )
                pendingCredential = Self.pendingCredential(
                    from: response,
                    generation: challenge.generation
                )
                activeChallenge = nil
                state = .awaitingCredentialValidation(observation)
                return state
            case 86_101:
                state = .awaitingScan(challenge.qrCode)
                return state
            case 86_090:
                state = .awaitingConfirmation(challenge.qrCode)
                return state
            case 86_038:
                activeChallenge = nil
                state = .expired
                return state
            default:
                return fail(
                    .unsupportedStatus(
                        Self.safeObservation(data: data, response: response)
                    ),
                    generation: challenge.generation
                )
            }
        } catch is StaleOperationError {
            throw CancellationError()
        } catch is CancellationError {
            resetIfCurrent(challenge.generation)
            throw CancellationError()
        } catch let failure as WebQRLoginFailure {
            return fail(failure, generation: challenge.generation)
        } catch {
            return fail(.network, generation: challenge.generation)
        }
    }

    public func cancel() {
        generation &+= 1
        latestPollID &+= 1
        activeChallenge = nil
        pendingCredential = nil
        state = .signedOut
    }

    public func validatePendingCredential() async throws -> Bool {
        guard let pendingCredential else {
            throw WebQRLoginFailure.incompleteCredential
        }
        self.pendingCredential = nil
        guard generation == pendingCredential.generation else {
            throw CancellationError()
        }

        let response = try await sendNavigationValidation(
            cookieHeader: pendingCredential.cookieHeader
        )
        try Task.checkCancellation()
        guard generation == pendingCredential.generation else {
            throw CancellationError()
        }
        let envelope: NavigationEnvelope
        do {
            envelope = try decoder.decode(NavigationEnvelope.self, from: response.body)
        } catch {
            throw WebQRLoginFailure.invalidResponse
        }
        guard envelope.code == 0, let data = envelope.data else {
            throw WebQRLoginFailure.invalidResponse
        }
        return data.isLogin
    }

    private func send(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> HTTPResponse {
        let url = try endpoint(path: path, queryItems: queryItems)
        let response: HTTPResponse
        do {
            response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    headers: [
                        "Accept": "application/json",
                        "User-Agent": "BiliKitMac/0.1",
                    ]
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case let .unacceptableStatusCode(status):
                throw WebQRLoginFailure.httpStatus(status)
            case .nonHTTPResponse:
                throw WebQRLoginFailure.network
            }
        } catch {
            throw WebQRLoginFailure.network
        }

        guard response.body.count <= Self.maximumResponseSize else {
            throw WebQRLoginFailure.responseTooLarge
        }
        guard Self.looksLikeJSON(response) else {
            throw WebQRLoginFailure.nonJSONResponse
        }
        return response
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw WebQRLoginFailure.invalidResponse
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw WebQRLoginFailure.invalidResponse
        }
        return url
    }

    private func sendNavigationValidation(
        cookieHeader: String
    ) async throws -> HTTPResponse {
        let url = URL(
            string: "https://api.bilibili.com/x/web-interface/nav"
        )!
        let response: HTTPResponse
        do {
            response = try await httpClient.send(
                HTTPRequest(
                    url: url,
                    headers: [
                        "Accept": "application/json",
                        "Cookie": cookieHeader,
                        "Referer": "https://www.bilibili.com/",
                        "User-Agent": "BiliKitMac/0.1",
                    ]
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case let .unacceptableStatusCode(status):
                throw WebQRLoginFailure.httpStatus(status)
            case .nonHTTPResponse:
                throw WebQRLoginFailure.network
            }
        } catch {
            throw WebQRLoginFailure.network
        }
        guard response.body.count <= Self.maximumResponseSize else {
            throw WebQRLoginFailure.responseTooLarge
        }
        guard Self.looksLikeJSON(response) else {
            throw WebQRLoginFailure.nonJSONResponse
        }
        return response
    }

    private func requireCurrentGeneration(_ expected: UInt64) throws {
        guard generation == expected else {
            throw StaleOperationError()
        }
    }

    private func requireCurrentPoll(
        generation expectedGeneration: UInt64,
        pollID expectedPollID: UInt64
    ) throws {
        guard generation == expectedGeneration,
              latestPollID == expectedPollID
        else {
            throw StaleOperationError()
        }
    }

    private func fail(
        _ failure: WebQRLoginFailure,
        generation expected: UInt64
    ) -> WebQRLoginState {
        guard generation == expected else {
            return state
        }
        activeChallenge = nil
        state = .failed(failure)
        return state
    }

    private func resetIfCurrent(_ expected: UInt64) {
        guard generation == expected else { return }
        activeChallenge = nil
        state = .signedOut
    }

    private static func isValidQRCodeKey(_ key: String) -> Bool {
        key.utf8.count == 32 && !key.utf8.contains(where: { $0 < 0x21 || $0 > 0x7E })
    }

    private static func isValidQRCodeURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == qrCodeHost
            && url.user == nil
            && url.password == nil
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

    private static func safeObservation(
        data: PollData,
        response: HTTPResponse
    ) -> WebQRStatusObservation {
        let components = data.url.flatMap {
            URLComponents(string: $0)
        }
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: response.headers,
            for: productionBaseURL
        )
        let cookieAttributeNames = Set(
            cookies.flatMap { cookie in
                cookie.properties?.keys.map(\.rawValue) ?? []
            }
        )
        let cookieObservations = cookies.map {
            WebQRCookieObservation(
                name: $0.name,
                domain: $0.domain,
                path: $0.path,
                isSecure: $0.isSecure,
                isHTTPOnly: $0.isHTTPOnly,
                isSessionOnly: $0.isSessionOnly,
                hasExpiry: $0.expiresDate != nil
            )
        }.sorted { $0.name < $1.name }

        return WebQRStatusObservation(
            code: data.code,
            dataFieldNames: data.fieldNames.sorted(),
            urlScheme: components?.scheme,
            urlHost: components?.host,
            urlQueryNames: Array(
                Set(components?.queryItems?.map(\.name) ?? [])
            ).sorted(),
            refreshTokenPresent: !(data.refreshToken ?? "").isEmpty,
            responseHeaderNames: response.headers.keys
                .map { $0.lowercased() }
                .sorted(),
            cookieNames: Array(Set(cookies.map(\.name))).sorted(),
            cookieAttributeNames: cookieAttributeNames.sorted(),
            cookies: cookieObservations
        )
    }

    private static func pendingCredential(
        from response: HTTPResponse,
        generation: UInt64
    ) -> PendingCredential? {
        let allowedNames = Set([
            "DedeUserID",
            "DedeUserID__ckMd5",
            "SESSDATA",
            "bili_jct",
            "sid",
        ])
        let requiredNames = Set(["DedeUserID", "SESSDATA", "bili_jct"])
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: response.headers,
            for: productionBaseURL
        ).filter { allowedNames.contains($0.name) }
        guard requiredNames.isSubset(of: Set(cookies.map(\.name))) else {
            return nil
        }
        let cookieHeader = cookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return PendingCredential(
            generation: generation,
            cookieHeader: cookieHeader
        )
    }

    private static func makeProductionTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: configuration,
            delegate: RejectRedirectDelegate(),
            delegateQueue: nil
        )
        return URLSessionTransport(session: session)
    }
}

private struct ActiveChallenge: Sendable {
    let generation: UInt64
    let key: String
    let qrCode: WebQRCode
}

private struct PendingCredential: Sendable {
    let generation: UInt64
    let cookieHeader: String
}

private struct StaleOperationError: Error {}

private struct GenerateEnvelope: Decodable, Sendable {
    let code: Int
    let data: GenerateData?
}

private struct GenerateData: Decodable, Sendable {
    let url: String
    let qrcodeKey: String

    private enum CodingKeys: String, CodingKey {
        case url
        case qrcodeKey = "qrcode_key"
    }
}

private struct PollEnvelope: Decodable, Sendable {
    let code: Int
    let data: PollData?
}

private struct PollData: Decodable, Sendable {
    let code: Int
    let url: String?
    let refreshToken: String?
    let fieldNames: [String]

    private enum CodingKeys: String, CodingKey {
        case code
        case url
        case refreshToken = "refresh_token"
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        refreshToken = try container.decodeIfPresent(
            String.self,
            forKey: .refreshToken
        )
        let allFields = try decoder.container(keyedBy: FieldKey.self)
        fieldNames = allFields.allKeys.map(\.stringValue)
    }
}

private struct NavigationEnvelope: Decodable, Sendable {
    let code: Int
    let data: NavigationData?
}

private struct NavigationData: Decodable, Sendable {
    let isLogin: Bool
}

private final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

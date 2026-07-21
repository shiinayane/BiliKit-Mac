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
            case 86_101:
                state = .awaitingScan(challenge.qrCode)
                return state
            default:
                return fail(
                    .unsupportedStatus(data.code),
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
        state = .signedOut
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

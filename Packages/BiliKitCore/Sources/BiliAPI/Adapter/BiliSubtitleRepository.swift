import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

public actor BiliSubtitleRepository: SubtitleRepository {
    private static let maximumBodySize = 2 * 1_024 * 1_024

    private let client: BiliAPIClient
    private let bodyTransport: any HTTPTransport
    private let bodyClient: HTTPClient
    private let decoder = JSONDecoder()
    private var generation: UInt64 = 0
    private var currentIdentity: PlaybackItemIdentity?
    private var resourceURLs: [String: URL] = [:]

    public init(client: BiliAPIClient) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.init(
            client: client,
            bodyTransport: URLSessionTransport(
                configuration: configuration,
                redirectPolicy: .reject
            )
        )
    }

    public init(
        client: BiliAPIClient,
        bodyTransport: any HTTPTransport
    ) {
        self.client = client
        self.bodyTransport = bodyTransport
        bodyClient = HTTPClient(transport: bodyTransport)
    }

    public func tracks(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleTrack] {
        generation &+= 1
        let requestGeneration = generation
        currentIdentity = identity
        resourceURLs.removeAll(keepingCapacity: false)

        do {
            let resources = try await client.subtitleResources(for: identity)
            try Task.checkCancellation()
            guard generation == requestGeneration else {
                throw CancellationError()
            }
            currentIdentity = identity
            resourceURLs = Dictionary(
                uniqueKeysWithValues: resources.map { ($0.track.id, $0.url) }
            )
            return resources.map(\.track)
        } catch is CancellationError {
            clearIfCurrent(generation: requestGeneration)
            throw CancellationError()
        } catch let error as BiliAPIError {
            clearIfCurrent(generation: requestGeneration)
            throw Self.applicationError(error)
        } catch {
            clearIfCurrent(generation: requestGeneration)
            throw SubtitleApplicationError.unavailable
        }
    }

    public func cues(
        for trackID: String,
        identity: PlaybackItemIdentity
    ) async throws -> [SubtitleCue] {
        guard currentIdentity == identity,
              let url = resourceURLs[trackID],
              SubtitleURLPolicy().allows(url)
        else {
            throw SubtitleApplicationError.invalidRequest
        }
        let requestGeneration = generation
        let request = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": "https://www.bilibili.com/video/\(identity.bvid)/",
                "User-Agent": "BiliKitMac/0.1",
            ]
        )

        do {
            let response = try await bodyClient.send(request)
            try Task.checkCancellation()
            guard generation == requestGeneration,
                  currentIdentity == identity
            else {
                throw CancellationError()
            }
            guard response.body.count <= Self.maximumBodySize else {
                throw BiliAPIError.responseTooLarge(response.body.count)
            }
            guard Self.looksLikeJSON(response) else {
                throw BiliAPIError.nonJSONResponse
            }
            let payload: SubtitleBodyPayload
            do {
                payload = try decoder.decode(
                    SubtitleBodyPayload.self,
                    from: response.body
                )
            } catch {
                throw BiliAPIError.decodingFailed
            }
            return try payload.cues()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case let .unacceptableStatusCode(status):
                throw Self.applicationError(.httpStatus(status))
            case .nonHTTPResponse:
                throw SubtitleApplicationError.transportFailure
            }
        } catch let error as BiliAPIError {
            throw Self.applicationError(error)
        } catch let error as SubtitleApplicationError {
            throw error
        } catch {
            throw SubtitleApplicationError.transportFailure
        }
    }

    public func reset(for identity: PlaybackItemIdentity) {
        guard currentIdentity == identity else { return }
        generation &+= 1
        currentIdentity = nil
        resourceURLs.removeAll(keepingCapacity: false)
    }

    private func clearIfCurrent(generation requestGeneration: UInt64) {
        guard generation == requestGeneration else { return }
        currentIdentity = nil
        resourceURLs.removeAll(keepingCapacity: false)
    }

    private static func looksLikeJSON(_ response: HTTPResponse) -> Bool {
        guard let contentType = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased(),
              contentType.contains("json")
        else {
            return false
        }
        guard let firstByte = response.body.first(where: {
            ![9, 10, 13, 32].contains($0)
        }) else {
            return false
        }
        return firstByte == 0x7B
    }

    private static func applicationError(
        _ error: BiliAPIError
    ) -> SubtitleApplicationError {
        switch error {
        case .invalidRequest:
            .invalidRequest
        case .authorizationRequired:
            .authenticationRequired
        case .transportFailure:
            .transportFailure
        case .httpStatus(403), .nonJSONResponse,
             .apiRejected(code: -403, _), .apiRejected(code: -412, _):
            .requestRestricted
        case .responseTooLarge, .decodingFailed, .missingData,
             .invalidSubtitleData, .untrustedSubtitleOrigin,
             .nonProtobufResponse, .invalidDanmakuData:
            .invalidResponse
        case .httpStatus, .apiRejected:
            .unavailable
        case .invalidWBIKey, .signingFailed, .invalidMediaData,
             .noAVCVideo, .noAACAudio:
            .invalidResponse
        }
    }
}

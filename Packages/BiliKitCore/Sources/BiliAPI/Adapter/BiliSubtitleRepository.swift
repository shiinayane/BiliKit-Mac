import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 保存当前播放 identity 的字幕轨→正文 URL 映射，并按需读取正文。
///
/// URL 不越过 adapter；正文使用独立无 Cookie、无缓存、拒绝重定向的 transport。
/// generation 与 identity 共同防止旧目录或正文结果进入新视频。
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
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
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
        } catch {
            clearIfCurrent(generation: requestGeneration)
            throw Self.applicationError(error)
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
                "User-Agent": HTTPUserAgent.short
            ]
        )

        do {
            let response: HTTPResponse
            do {
                response = try await bodyClient.send(request)
            } catch let error as HTTPClientError {
                throw BiliAPIError(error)
            }
            try Task.checkCancellation()
            guard generation == requestGeneration,
                currentIdentity == identity
            else {
                throw CancellationError()
            }
            guard response.body.count <= Self.maximumBodySize else {
                throw BiliAPIError.responseTooLarge(response.body.count)
            }
            guard response.looksLikeJSON() else {
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
        } catch {
            throw Self.applicationError(error)
        }
    }

    /// 仅清理仍匹配的 identity，避免迟到的旧 reset 清除后来加载的映射。
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

    /// 目录与正文共用同一映射；两者的非 API 错误都来自 transport，因此 fallback 为传输失败。
    private static func applicationError(_ error: any Error) -> any Error {
        BiliAPIError.domainError(
            for: error,
            fallback: SubtitleApplicationError.transportFailure
        ) { failure in
            switch failure {
            case .invalidRequest:
                .invalidRequest
            case .authorizationRequired, .authenticationInvalid,
                .authorizationUnavailable:
                .authenticationRequired
            case .restricted:
                .requestRestricted
            case .transport:
                .transportFailure
            case .unexpectedHTTPStatus, .rejected:
                .unavailable
            case .unsupportedMedia, .noPlayableMedia, .invalidResponse:
                .invalidResponse
            }
        }
    }
}

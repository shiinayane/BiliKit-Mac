import BiliModels
import BiliNetworking
import Foundation

public protocol BiliAPIService: Sendable {
    func popular(page: Int, pageSize: Int) async throws -> PopularPage
    func pages(for bvid: String) async throws -> [VideoPage]
    func playback(for bvid: String, cid: Int64, quality: Int) async throws -> VideoPlayback
}

public actor BiliAPIClient: BiliAPIService {
    public static let productionBaseURL = URL(
        string: "https://api.bilibili.com"
    )!

    private static let maximumResponseSize = 5 * 1_024 * 1_024

    private let httpClient: HTTPClient
    private let baseURL: URL
    private let userAgent: String
    private let decoder: JSONDecoder

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = BiliAPIClient.productionBaseURL,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BiliKitMac/0.1"
    ) {
        httpClient = HTTPClient(transport: transport)
        self.baseURL = baseURL
        self.userAgent = userAgent
        decoder = JSONDecoder()
    }

    public func popular(
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> PopularPage {
        guard page > 0, (1...50).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: PopularPayload = try await get(
            path: "/x/web-interface/popular",
            queryItems: [
                URLQueryItem(name: "pn", value: String(page)),
                URLQueryItem(name: "ps", value: String(pageSize)),
            ],
            referer: "https://www.bilibili.com/"
        )
        let videos = try payload.list.map { try $0.model() }
        return PopularPage(videos: videos, pageNumber: page, pageSize: pageSize)
    }

    public func pages(for bvid: String) async throws -> [VideoPage] {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [PagePayload] = try await get(
            path: "/x/player/pagelist",
            queryItems: [URLQueryItem(name: "bvid", value: bvid)],
            referer: Self.videoReferer(bvid)
        )
        return try payload.map { try $0.model() }
    }

    public func playback(
        for bvid: String,
        cid: Int64,
        quality: Int = 32
    ) async throws -> VideoPlayback {
        guard Self.isValidBVID(bvid), cid > 0, quality > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let referer = Self.videoReferer(bvid)
        let payload: PlayURLPayload = try await get(
            path: "/x/player/playurl",
            queryItems: [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: String(cid)),
                URLQueryItem(name: "qn", value: String(quality)),
                URLQueryItem(name: "fnval", value: "16"),
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "0"),
            ],
            referer: referer
        )

        let video = try payload.dash.video
            .filter(\.isAVCVideo)
            .map { try $0.model(kind: .video) }
        let audio = try payload.dash.audio
            .filter(\.isAACAudio)
            .map { try $0.model(kind: .audio) }
        guard !video.isEmpty else { throw BiliAPIError.noAVCVideo }
        guard !audio.isEmpty else { throw BiliAPIError.noAACAudio }

        return VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: video,
                audioRepresentations: audio
            ),
            mediaHeaders: [
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )
    }

    private func get<Payload: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem],
        referer: String
    ) async throws -> Payload {
        let url = try endpoint(path: path, queryItems: queryItems)
        let request = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": userAgent,
            ]
        )

        let response: HTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            switch error {
            case let .unacceptableStatusCode(status):
                throw BiliAPIError.httpStatus(status)
            case .nonHTTPResponse:
                throw BiliAPIError.transportFailure
            }
        } catch {
            throw BiliAPIError.transportFailure
        }

        guard response.body.count <= Self.maximumResponseSize else {
            throw BiliAPIError.responseTooLarge(response.body.count)
        }
        guard Self.looksLikeJSON(response) else {
            throw BiliAPIError.nonJSONResponse
        }

        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(
                code: status.code,
                message: status.message ?? ""
            )
        }
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let payload = envelope.data else {
            throw BiliAPIError.missingData
        }
        return payload
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    private static func isValidBVID(_ bvid: String) -> Bool {
        bvid.hasPrefix("BV")
            && bvid.count <= 24
            && bvid.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func videoReferer(_ bvid: String) -> String {
        "https://www.bilibili.com/video/\(bvid)/"
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
        return firstByte == 0x7B || firstByte == 0x5B
    }
}

private struct APIStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String?
}

private struct APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
}

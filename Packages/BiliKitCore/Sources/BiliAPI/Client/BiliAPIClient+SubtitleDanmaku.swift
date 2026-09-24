import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 字幕目录与弹幕 protobuf 分段；字幕正文由 `BiliSubtitleRepository` 另行读取。
extension BiliAPIClient {
    private static let maximumSubtitleCatalogSize = 1 * 1_024 * 1_024
    private static let maximumDanmakuSegmentSize = 2 * 1_024 * 1_024

    func subtitleResources(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleRemoteTrack] {
        guard Self.isValidBVID(identity.bvid), identity.cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        guard hasAccountAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        return try await withWBIKeyRefresh { forceKeyRefresh in
            try await signedSubtitleResources(
                for: identity,
                forceKeyRefresh: forceKeyRefresh
            )
        }
    }

    func danmakuSegmentData(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> Data {
        guard Self.isValidBVID(identity.bvid),
            identity.cid > 0,
            (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(index)
        else {
            throw BiliAPIError.invalidRequest
        }
        return try await withWBIKeyRefresh { forceKeyRefresh in
            try await signedDanmakuSegmentData(
                index: index,
                for: identity,
                forceKeyRefresh: forceKeyRefresh
            )
        }
    }

    private func signedSubtitleResources(
        for identity: PlaybackItemIdentity,
        forceKeyRefresh: Bool
    ) async throws -> [SubtitleRemoteTrack] {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: [
                "bvid": identity.bvid,
                "cid": String(identity.cid)
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let payload: SubtitleCatalogPayload = try await get(
            path: "/x/player/wbi/v2",
            percentEncodedQuery: query,
            referer: Self.videoReferer(identity.bvid),
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            ),
            maximumResponseSize: Self.maximumSubtitleCatalogSize
        )
        return try payload.resources()
    }

    private func signedDanmakuSegmentData(
        index: Int,
        for identity: PlaybackItemIdentity,
        forceKeyRefresh: Bool
    ) async throws -> Data {
        let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
        let query = try wbiSigner.sign(
            parameters: [
                "type": "1",
                "oid": String(identity.cid),
                "segment_index": String(index)
            ],
            keys: keys,
            timestamp: timestampProvider()
        )
        let url = try endpoint(
            path: "/x/v2/dm/wbi/web/seg.so",
            percentEncodedQuery: query
        )
        let access: RequestAccess =
            hasAccountAuthorizer
            ? .accountRead(
                missingCredential: .useAnonymousRequest,
                mapsAuthenticationInvalidation: false
            )
            : .anonymous
        let response = try await response(
            baseRequest: HTTPRequest(
                url: url,
                headers: [
                    "Accept": "application/octet-stream",
                    "Referer": Self.videoReferer(identity.bvid),
                    "User-Agent": userAgent
                ]
            ),
            access: access,
            maximumResponseSize: Self.maximumDanmakuSegmentSize
        ).response
        guard !response.body.isEmpty else {
            throw BiliAPIError.invalidDanmakuData
        }
        guard Self.looksLikeProtobuf(response) else {
            if Self.isKnownNonProtobufBody(response.body),
                let status = try? decoder.decode(
                    APIStatusEnvelope.self,
                    from: response.body
                )
            {
                if status.code == -101 {
                    throw BiliAPIError.authenticationInvalid
                }
                if status.code != 0 {
                    throw BiliAPIError.apiRejected(
                        code: status.code,
                        message: status.message ?? ""
                    )
                }
            }
            throw BiliAPIError.nonProtobufResponse
        }
        return response.body
    }

    private static func looksLikeProtobuf(_ response: HTTPResponse) -> Bool {
        guard
            let contentType = response.headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value.lowercased(),
            contentType.contains("application/octet-stream")
        else {
            return false
        }
        return !isKnownNonProtobufBody(response.body)
    }

    private static func isKnownNonProtobufBody(_ body: Data) -> Bool {
        if (try? JSONSerialization.jsonObject(with: body)) != nil {
            return true
        }
        guard let text = String(data: body, encoding: .utf8) else {
            return false
        }
        let normalized =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("<html")
            || normalized.hasPrefix("<!doctype")
    }
}

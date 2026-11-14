import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定 playurl 媒体映射契约：只映射 AVC 与 AAC 且交给 CDN 的 header 不带凭据，DASH 优先，
/// 只有单段、安全来源的 MP4 才映射为 progressive，FLV 按 MP4 清晰度重取一次，
/// 不可信来源被拒，续播信息只取自带凭据的响应。
struct BiliAPIClientPlayURLTests {
    @Test
    func playURLMapsOnlyAVCAndAACRepresentationsWithAnonymousMediaHeaders() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("playurl")],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let manifest = try #require(playback.dashManifest)
        let video = try #require(manifest.videoRepresentations.first)
        let audioTrack = try #require(manifest.audioTracks.first)
        let audio = try #require(audioTrack.representations.first)
        #expect(manifest.videoRepresentations.count == 1)
        #expect(manifest.audioTracks.count == 1)
        #expect(audioTrack.id == "original")
        #expect(audioTrack.displayName == "原声")
        #expect(audioTrack.languageTag == nil)
        #expect(audioTrack.role == .original)
        #expect(audioTrack.isDefault)
        #expect(audioTrack.isAutoselect)
        #expect(audioTrack.representations.map(\.id) == [30216, 30280])
        #expect(video.id == 32)
        #expect(video.urlCandidates.count == 2)
        #expect(video.videoAttributes?.width == 1280)
        #expect(video.videoAttributes?.height == 720)
        #expect(video.videoAttributes?.frameRate == 60_000.0 / 1_001.0)
        #expect(video.segmentBase.initialization.start == 0)
        #expect(video.segmentBase.initialization.endInclusive == 999)
        #expect(audio.id == 30216)
        #expect(audio.segmentBase.index.start == 800)
        #expect(audio.segmentBase.index.endInclusive == 1599)
        #expect(playback.mediaHeaders["Referer"]?.contains("BV1FixtureA1") == true)
        // playurl 请求可带账户凭据，交给 CDN 的媒体 header 不得带。
        #expect(Set(playback.mediaHeaders.keys) == ["Referer", "User-Agent"])

        let request = try #require(playURLRequests(transport).first)
        #expect(request.headers["Cookie"] == StubAuthorizer.cookie)
        let queryItems = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(queryItems?.contains(URLQueryItem(name: "web_location", value: "1315873")) == true)
        #expect(queryItems?.first(where: { $0.name == "w_rid" })?.value?.count == 32)
        // gaia 与 dm_img 风控字段不分登录状态；try_look 只属于本地无凭据的匿名请求。
        #expect(queryItems?.contains(URLQueryItem(name: "gaia_source", value: "pre-load")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "isGaiaAvoided", value: "true")) == true)
        #expect(queryItems?.contains { $0.name == "try_look" } == false)
        #expect(queryItems?.contains(URLQueryItem(name: "dm_img_list", value: "[]")) == true)
        #expect(
            queryItems?.contains(
                URLQueryItem(name: "dm_img_inter", value: #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#)
            ) == true
        )
        for name in ["dm_img_str", "dm_cover_img_str"] {
            let value = try #require(queryItems?.first { $0.name == name }?.value)
            #expect(!value.isEmpty)
            #expect(
                value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/".contains($0)) }
            )
        }
        #expect(queryItems?.contains(URLQueryItem(name: "qn", value: "127")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "fnval", value: "2000")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "fourk", value: "1")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "cid", value: "900001")) == true)
    }

    @Test
    func voucherBesideRealDataIsNotTreatedAsChallenge() async throws {
        let response = try mutatedFixture("playurl") {
            $0["v_voucher"] = "voucher_fixture"
        }
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let playback = try await client.playback(for: "BV1FixtureA1", cid: 900_001)

        #expect(playback.dashManifest != nil)
    }

    /// 没有 DASH 的单段 durl：`mp4`（360P）、较早视频的 `hdmp4`（720P）与只有 720P 转码稿件的 `mp4720`
    /// 都按 progressive MP4 播放。
    @Test(arguments: [ProgressiveShape.singleSafeSegment, .hdMP4Container, .mp4720Container])
    func playURLMapsSingleSafeDURLAsProgressiveMedia(shape: ProgressiveShape) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    try shape.response()
                ],
                answersWBINavOnce: true
            )
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        guard case .progressive(let source) = playback.media else {
            Issue.record("Expected progressive media")
            return
        }
        #expect(source.contentLength == 50_000_000)
        #expect(source.durationMilliseconds == 884_983)
        #expect(source.container == .mp4)
        #expect(source.urlCandidates.count == 2)
        #expect(playback.mediaHeaders["Cookie"] == nil)
    }

    @Test
    func playURLPrefersDASHWhenDURLIsAlsoPresent() async throws {
        // DASH 优先级还必须防止未消费的漂移 durl 破坏旧路径。
        let response = try mutatedFixture("playurl") {
            $0["durl"] = [["unexpected": true]]
        }
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        #expect(playback.dashManifest != nil)
    }

    /// 较早视频的请求清晰度只有 FLV 时，按 `support_formats` 里不高于请求（120）的最高 MP4 清晰度重取
    /// 一次，高于请求的 127 不选；单个格式条目损坏不影响其余条目。
    @Test
    func flvOnlyQualityRetriesAtTheHighestMP4QualityNotAboveTheRequest() async throws {
        let transport = StubTransport(
            responses: [
                legacyDURLResponse(format: "flv480", segments: ["part-1.flv", "part-2.flv"]),
                legacyDURLResponse(format: "mp4", segments: ["whole.mp4"])
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(transport: transport)

        let playback = try await client.playback(for: "BV1FixtureA1", cid: 900_001)

        guard case .progressive(let source) = playback.media else {
            Issue.record("Expected progressive media")
            return
        }
        #expect(source.primaryURL.lastPathComponent == "whole.mp4")
        #expect(playURLQualities(transport) == ["127", "64"])
    }

    /// 重取后仍是 FLV 时不再继续重试，按不支持的容器失败。
    @Test
    func flvRetryThatStillReturnsFLVFailsAsUnsupportedContainer() async throws {
        let transport = StubTransport(
            responses: [
                legacyDURLResponse(format: "flv480", segments: ["part-1.flv"]),
                legacyDURLResponse(format: "flv360", segments: ["part-1.flv"])
            ],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.unsupportedProgressiveMedia(.unsupportedContainer)) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(playURLQualities(transport) == ["127", "64"])
    }

    @Test(arguments: [
        (ProgressiveShape.emptyDURL, ProgressiveMediaFailure.empty),
        (.twoSegments, .multipleSegments),
        (.malformedSecondSegment, .multipleSegments),
        (.zeroDuration, .invalidDuration),
        (.zeroSize, .invalidSize),
        (.loopbackOnly, .noSafeURL),
        (.missingURL, .noSafeURL),
        (.flvContainer, .unsupportedContainer)
    ])
    func playURLRejectsUnsupportedProgressiveShape(
        shape: ProgressiveShape,
        expected: ProgressiveMediaFailure
    ) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try shape.response()], answersWBINavOnce: true)
        )

        await #expect(throws: BiliAPIError.unsupportedProgressiveMedia(expected)) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
    }

    @Test(arguments: [true, false])
    func serverResumeMetadataIsKeptOnlyForAuthenticatedResponse(
        authenticated: Bool
    ) async throws {
        let response = try mutatedFixture("playurl") {
            $0["last_play_cid"] = 900_002
            $0["last_play_time"] = 42_500
        }
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true),
            requestAuthorizer: authenticated ? StubAuthorizer() : nil
        )

        let playback = try await client.playback(
            for: "BV1FixtureA1",
            cid: 900_001
        )

        let serverResume = PlaybackResumeMetadata(
            lastPlayedCID: 900_002,
            positionMilliseconds: 42_500
        )
        #expect(playback.resumeMetadata == (authenticated ? serverResume : nil))
    }

    @Test
    func playURLPreservesVideoWhenFrameRateCannotBeNormalized() async throws {
        let fixture = try fixtureResponse("playurl")
        let invalidBody = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(
                of: "\"frame_rate\": \"60000/1001\"",
                with: "\"frame_rate\": \"60/0\""
            )
        let response = HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: Data(invalidBody.utf8)
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let playback = try await client.playback(for: "BV1FixtureA1", cid: 900_001)

        let video = try #require(playback.dashManifest?.videoRepresentations.first)
        #expect(video.id == 32)
        #expect(video.videoAttributes?.frameRate == nil)
    }

    @Test
    func playURLRejectsRepresentationsWithoutTrustedMediaOrigin() async throws {
        let fixture = try fixtureResponse("playurl")
        let unsafeBody = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(of: "media.fixture.bilivideo.com", with: "127.0.0.1")
            .replacingOccurrences(of: "backup.fixture.bilivideo.com", with: "localhost")
        let response = HTTPResponse(
            statusCode: fixture.statusCode,
            headers: fixture.headers,
            body: Data(unsafeBody.utf8)
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        await #expect(throws: BiliAPIError.invalidMediaData) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
    }

    /// 按发出顺序列出各次 playurl 请求的 `qn`（请求的清晰度）。
    private func playURLQualities(_ transport: StubTransport) -> [String?] {
        playURLRequests(transport).map { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "qn" }?.value
        }
    }

    /// 没有 DASH 的较早视频 playurl：`support_formats` 含一条损坏条目。
    private func legacyDURLResponse(format: String, segments: [String]) -> HTTPResponse {
        let durl = segments.map {
            #"{"order":1,"length":144288,"size":21365404,"url":"https://media.fixture.bilivideo.com/"#
                + $0 + #""}"#
        }
        let supportFormats =
            #"[{"quality":127,"format":"mp4"},{"quality":80,"format":"flv"},{"quality":64,"format":"hdmp4"},"#
            + #"{"quality":32,"format":"flv480"},{"quality":"bad"},{"quality":16,"format":"mp4"}]"#
        return jsonResponse(
            #"{"code":0,"message":"OK","data":{"format":""# + format + #"","durl":["#
                + durl.joined(separator: ",") + #"],"support_formats":"# + supportFormats + "}}"
        )
    }
}

/// playurl 只返回 durl 时的各种形状；只有单段、安全来源、MP4（`mp4*`／`hdmp4`）可以映射为 progressive 媒体。
enum ProgressiveShape: Sendable {
    case singleSafeSegment
    case emptyDURL
    case twoSegments
    case malformedSecondSegment
    case zeroDuration
    case zeroSize
    case loopbackOnly
    case missingURL
    case flvContainer
    case hdMP4Container
    case mp4720Container

    func response() throws -> HTTPResponse {
        let backup = "https://backup.fixture.bilivideo.com/preview.mp4"
        func segment(
            path: String = "preview.mp4",
            length: Int64 = 884_983,
            size: Int64 = 50_000_000,
            url: String? = nil,
            backupURLs: [String] = [backup]
        ) -> [String: Any] {
            [
                "length": length,
                "size": size,
                "url": url ?? "https://media.fixture.bilivideo.com/\(path)",
                "backup_url": backupURLs
            ]
        }
        let durl: [[String: Any]] =
            switch self {
            case .singleSafeSegment, .flvContainer, .hdMP4Container, .mp4720Container: [segment()]
            case .emptyDURL: []
            case .twoSegments: [segment(), segment(path: "part-2.mp4")]
            case .malformedSecondSegment: [segment(), ["unexpected": true]]
            case .zeroDuration: [segment(length: 0)]
            case .zeroSize: [segment(size: 0)]
            case .loopbackOnly: [segment(url: "http://127.0.0.1/media.mp4", backupURLs: [])]
            case .missingURL: [["length": 884_983, "size": 50_000_000, "backup_url": []]]
            }
        let format =
            switch self {
            case .flvContainer: "flv480"
            case .hdMP4Container: "hdmp4"
            case .mp4720Container: "mp4720"
            default: "mp4"
            }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(
                withJSONObject: [
                    "code": 0,
                    "message": "OK",
                    "data": ["durl": durl, "format": format]
                ]
            )
        )
    }
}

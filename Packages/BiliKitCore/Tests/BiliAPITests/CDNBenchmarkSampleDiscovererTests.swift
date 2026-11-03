import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定测速样本发现：近期投稿列表与 nav 匿名，详情与 playurl 按账户读取、没有凭据时不匿名降级，
/// 每个候选的请求链有界、拿到所需数量即停，样本的分区与 UP 主互不重复，只接受高清 AVC 且媒体 header
/// 不带凭据；取消不会把样本记为已用过，重置后同一候选可以再次使用。
@Suite(.timeLimit(.minutes(1)))
struct CDNBenchmarkSampleDiscovererTests {
    private static let candidateA = Candidate(bvid: "BV1FixtureA1", mid: 10_001)
    private static let candidateB = Candidate(
        bvid: "BV1FixtureB2",
        mid: 10_002,
        duration: 360,
        cid: 900_002
    )

    @Test
    func authenticatesOnlyDetailAndPlayURLAndKeepsDiscoveryBounded() async throws {
        let popular = Candidate(bvid: "BV1FixtureB2", mid: 20_002, duration: 600, play: #""50000""#)
        var candidate = Self.candidateA
        candidate.play = #""120""#
        let transport = StubTransport(
            responses: [
                rank(popular, candidate), try fixtureResponse("nav"), detail(candidate),
                try playURL()
            ]
        )

        let samples = try await discoverer(transport).discover()

        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.videoRepresentation.kind == .video)
        #expect(sample.videoRepresentation.id == 64)
        #expect(sample.videoRepresentation.bandwidth == 800_000)
        #expect(sample.mediaHeaders["Cookie"] == nil)
        let requests = transport.capturedRequests()
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/view",
                "/x/player/wbi/playurl"
            ]
        )
        // 近期列表与 WBI nav 保持匿名；view 与 playurl 按账户读取。
        #expect(
            requests.map { $0.headers["Cookie"] } == [
                nil, nil, StubAuthorizer.cookie, StubAuthorizer.cookie
            ]
        )
        #expect(requests.allSatisfy { $0.headers["Authorization"] == nil })
        let query = try #require(
            URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(query.contains(URLQueryItem(name: "order", value: "pubdate")))
        #expect(query.contains(URLQueryItem(name: "cate_id", value: "201")))
        #expect(query.contains(URLQueryItem(name: "page", value: "1")))
        #expect(query.contains(URLQueryItem(name: "pagesize", value: "5")))
        #expect(query.contains(URLQueryItem(name: "time_from", value: "20231102")))
        #expect(query.contains(URLQueryItem(name: "time_to", value: "20231115")))
    }

    @Test
    func cancellationStopsBeforeAnotherDiscoveryRequest() async throws {
        let transport = StubTransport([.suspended(rank(Self.candidateA))])
        let discoverer = discoverer(transport)
        let task = Task { try await discoverer.discover() }
        await transport.waitForRequests(1)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(transport.capturedRequests().count == 1)
    }

    @Test
    func cancellationAfterFinalPlayURLDoesNotMarkSampleAsSeen() async throws {
        let rank = rank(Self.candidateA)
        let detail = detail(Self.candidateA)
        let transport = StubTransport(
            [
                .response(rank), .response(detail),
                .cancellingCaller(try playURL()),
                .response(rank), .response(detail), .response(try playURL())
            ],
            answersWBINavOnce: true
        )
        let discoverer = discoverer(transport)

        let cancelled = Task { try await discoverer.discover() }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await discoverer.discover().count == 1)
    }

    @Test
    func rejectedDetailUsesNextCandidateWithoutExceedingBoundedRequestChain() async throws {
        var mismatched = Self.candidateA
        mismatched.tid = 999
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA, Self.candidateB),
                detail(mismatched),
                detail(Self.candidateB),
                try playURL()
            ],
            answersWBINavOnce: true
        )

        let samples = try await discoverer(transport).discover()

        #expect(samples.count == 1)
        #expect(
            transport.businessRequests().map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/wbi/view",
                "/x/web-interface/wbi/view",
                "/x/player/wbi/playurl"
            ]
        )
    }

    @Test
    func stopsImmediatelyAfterOneQualifiedSample() async throws {
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA, Self.candidateB),
                detail(Self.candidateA),
                try playURL(),
                rank()
            ],
            answersWBINavOnce: true
        )

        let samples = try await discoverer(transport).discover()

        #expect(samples.count == 1)
        #expect(
            transport.businessRequests().map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/wbi/view",
                "/x/player/wbi/playurl"
            ]
        )
    }

    @Test
    func qualifiedAVCDoesNotRequireAnAudioRepresentation() async throws {
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA),
                detail(Self.candidateA),
                try playURL(removesAudio: true)
            ],
            answersWBINavOnce: true
        )

        let samples = try await discoverer(transport).discover()

        #expect(samples.count == 1)
        #expect(samples.first?.videoRepresentation.kind == .video)
    }

    @Test
    func requestedSampleCountUsesDifferentRegionsAndUploaders() async throws {
        var secondRegion = Self.candidateB
        secondRegion.tid = 124
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA),
                detail(Self.candidateA),
                try playURL(),
                rank(secondRegion),
                detail(secondRegion),
                try playURL()
            ],
            answersWBINavOnce: true
        )

        let samples = try await discoverer(transport).discover(targetCount: 2)

        #expect(samples.count == 2)
        #expect(
            transport.businessRequests().map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/wbi/view",
                "/x/player/wbi/playurl",
                "/x/web-interface/newlist_rank",
                "/x/web-interface/wbi/view",
                "/x/player/wbi/playurl"
            ]
        )
    }

    @Test
    func resettingDiscoveryLifecycleAllowsTheSameAnonymousCandidateAgain() async throws {
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA), detail(Self.candidateA), try playURL(),
                rank(Self.candidateA), detail(Self.candidateA), try playURL()
            ],
            answersWBINavOnce: true
        )
        let discoverer = discoverer(transport)

        #expect(try await discoverer.discover().count == 1)
        await discoverer.resetSeenSamples()
        #expect(try await discoverer.discover().count == 1)
        #expect(transport.businessRequests().count == 6)
    }

    @Test
    func rejectsAnonymousQualityManifestEvenWhenOriginsAreComparable() async throws {
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA),
                detail(Self.candidateA),
                try playURL(promotesAVCToHighQuality: false)
                // 其余分区的近期列表都是空的；多备的空列表足够覆盖全部分区，用不完也无妨。
            ] + Array(repeating: rank(), count: 32),
            answersWBINavOnce: true
        )

        let samples = try await discoverer(transport).discover()

        #expect(samples.isEmpty)
        // 唯一的候选只请求一次详情与 playurl；之后只剩各分区的近期列表。
        let paths = transport.businessRequests().map(\.url.path)
        #expect(
            Array(paths.prefix(3)) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/wbi/view",
                "/x/player/wbi/playurl"
            ]
        )
        #expect(paths.dropFirst(3).allSatisfy { $0 == "/x/web-interface/newlist_rank" })
    }

    @Test
    func missingCredentialDoesNotFallBackToAnonymousDetail() async throws {
        let transport = StubTransport(
            responses: [
                rank(Self.candidateA), try fixtureResponse("nav"), detail(Self.candidateA),
                try playURL()
            ]
        )

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await discoverer(transport, authorized: false).discover()
        }
        // 签名需要的 WBI nav 是匿名请求；详情本身不会匿名发出。
        #expect(
            transport.capturedRequests().map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                StubTransport.wbiNavPath
            ]
        )
    }

    private func discoverer(
        _ transport: StubTransport,
        authorized: Bool = true
    ) -> CDNBenchmarkSampleDiscoverer {
        CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: authorized ? StubAuthorizer() : nil
            ),
            now: { Date(timeIntervalSince1970: 1_700_100_000) }
        )
    }

    private func rank(_ candidates: Candidate...) -> HTTPResponse {
        let items = candidates.map {
            #"{"bvid":"\#($0.bvid)","duration":\#($0.duration),"senddate":1700074800,"mid":\#($0.mid),"play":\#($0.play)}"#
        }
        return jsonResponse(
            #"{"code":0,"data":{"result":[\#(items.joined(separator: ","))]}}"#
        )
    }

    private func detail(_ candidate: Candidate) -> HTTPResponse {
        jsonResponse(
            #"{"code":0,"data":{"bvid":"\#(candidate.bvid)","cid":\#(candidate.cid),"duration":\#(candidate.duration),"pubdate":1700074800,"tid":\#(candidate.tid),"owner":{"mid":\#(candidate.mid)}}}"#
        )
    }

    /// 测速只接受高清 AVC 且主备地址可比较的 manifest；默认把 fixture 调整为合格样本。
    private func playURL(
        promotesAVCToHighQuality: Bool = true,
        removesAudio: Bool = false
    ) throws -> HTTPResponse {
        var text = String(decoding: try fixtureResponse("playurl").body, as: UTF8.self)
        if promotesAVCToHighQuality {
            text = text.replacingOccurrences(of: "\"id\": 32", with: "\"id\": 64")
                .replacingOccurrences(
                    of: "\"bandwidth\": 500000",
                    with: "\"bandwidth\": 800000"
                )
        }
        text = text.replacingOccurrences(
            of: "https://media.fixture.bilivideo.com/video-avc-primary.m4s",
            with: "https://upos-sz-mirrorhw.bilivideo.com/video-avc-primary.m4s"
        ).replacingOccurrences(
            of: "https://backup.fixture.bilivideo.com/video-avc.m4s",
            with: "https://upos-hz-mirrorakam.akamaized.net/video-avc.m4s"
        )
        var body = Data(text.utf8)
        if removesAudio {
            var root = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            var data = try #require(root["data"] as? [String: Any])
            var dash = try #require(data["dash"] as? [String: Any])
            dash.removeValue(forKey: "audio")
            data["dash"] = dash
            root["data"] = data
            body = try JSONSerialization.data(withJSONObject: root)
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }
}

/// 近期投稿候选；`play` 是原样写入 JSON 的片段，以覆盖字符串与数字两种形状。
private struct Candidate {
    let bvid: String
    let mid: Int64
    var duration = 300
    var play = "120"
    var tid = 201
    var cid: Int64 = 900_001
}

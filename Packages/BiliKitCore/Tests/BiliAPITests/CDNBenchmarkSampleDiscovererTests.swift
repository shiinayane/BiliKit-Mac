import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

@Suite(.timeLimit(.minutes(1)))
struct CDNBenchmarkSampleDiscovererTests {
    @Test
    func usesAuthenticationOnlyForHighQualityPlayURLAndKeepsDiscoveryBounded() async throws {
        let now: Int64 = 1_700_100_000
        let rankResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureB2","duration":600,"senddate":1700074800,"mid":20002,"play":"50000"},{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":"120"}]}}"#
                    .utf8
            )
        )
        let detailResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
                    .utf8
            )
        )
        let transport = DiscoveryRecordingTransport(
            responses: [rankResponse, detailResponse, try fixtureResponse("playurl")]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: DiscoveryAuthorizer()
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: client,
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        let samples = try await discoverer.discover()

        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.videoRepresentation.kind == .video)
        #expect(sample.mediaHeaders["Cookie"] == nil)
        let requests = await transport.requests
        #expect(
            requests.map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/view",
                "/x/player/playurl",
            ]
        )
        #expect(requests[0].headers["Cookie"] == nil)
        #expect(requests[1].headers["Cookie"] == nil)
        #expect(requests[2].headers["Cookie"] == "SIGNED_IN_FIXTURE")
        #expect(requests.allSatisfy { $0.headers["Authorization"] == nil })
        #expect(sample.videoRepresentation.id == 64)
        #expect(sample.videoRepresentation.bandwidth == 800_000)
        let query = try #require(
            URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(query.contains(URLQueryItem(name: "order", value: "pubdate")))
        #expect(query.contains(URLQueryItem(name: "cate_id", value: "201")))
        #expect(query.contains(URLQueryItem(name: "page", value: "1")))
        #expect(query.contains(URLQueryItem(name: "pagesize", value: "5")))
        let dateFrom = try #require(query.first(where: { $0.name == "time_from" })?.value)
        let dateTo = try #require(query.first(where: { $0.name == "time_to" })?.value)
        #expect(dateFrom == "20231102")
        #expect(dateTo == "20231115")
    }

    @Test
    func cancellationStopsBeforeAnotherDiscoveryRequest() async throws {
        let transport = BlockingDiscoveryTransport()
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: Date.init,
            regionIDs: [1, 3, 4]
        )
        let task = Task { try await discoverer.discover() }
        try await waitUntil { await transport.requests.count == 1 }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func cancellationAfterFinalPlayURLDoesNotMarkSampleAsSeen() async throws {
        let now: Int64 = 1_700_100_000
        let rank = jsonResponse(
            #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120}]}}"#
        )
        let detail = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
        )
        let transport = CancellingFinalPlayURLTransport(
            responses: [
                rank, detail, try fixtureResponse("playurl"),
                rank, detail, try fixtureResponse("playurl"),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        let cancelled = Task { try await discoverer.discover() }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await discoverer.discover().count == 1)
    }

    @Test
    func rejectedDetailUsesNextCandidateWithoutExceedingBoundedRequestChain() async throws {
        let now: Int64 = 1_700_100_000
        let rank = jsonResponse(
            #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120},{"bvid":"BV1FixtureB2","duration":360,"senddate":1700074800,"mid":10002,"play":140}]}}"#
        )
        let mismatchedDetail = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":999,"owner":{"mid":10001}}}"#
        )
        let acceptedDetail = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureB2","cid":900002,"duration":360,"pubdate":1700074800,"tid":201,"owner":{"mid":10002}}}"#
        )
        let transport = DiscoveryRecordingTransport(
            responses: [
                rank,
                mismatchedDetail,
                acceptedDetail,
                try fixtureResponse("playurl"),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        let samples = try await discoverer.discover()

        #expect(samples.count == 1)
        #expect(
            await transport.requests.map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/view",
                "/x/web-interface/view",
                "/x/player/playurl",
            ]
        )
    }

    @Test
    func stopsImmediatelyAfterOneQualifiedSample() async throws {
        let now: Int64 = 1_700_100_000
        let rank = jsonResponse(
            #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120},{"bvid":"BV1FixtureB2","duration":360,"senddate":1700074800,"mid":10002,"play":140}]}}"#
        )
        let firstDetail = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
        )
        let transport = DiscoveryRecordingTransport(
            responses: [
                rank,
                firstDetail,
                try fixtureResponse("playurl"),
                jsonResponse(#"{"code":0,"data":{"result":[]}}"#),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201, 124]
        )

        let samples = try await discoverer.discover()

        #expect(samples.count == 1)
        #expect(
            await transport.requests.map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/view",
                "/x/player/playurl",
            ]
        )
    }

    @Test
    func qualifiedAVCDoesNotRequireAnAudioRepresentation() async throws {
        let now: Int64 = 1_700_100_000
        let transport = DiscoveryRecordingTransport(
            responses: [
                jsonResponse(
                    #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120}]}}"#
                ),
                jsonResponse(
                    #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
                ),
                try fixtureResponse("playurl", removesAudio: true),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        let samples = try await discoverer.discover()

        #expect(samples.count == 1)
        #expect(samples.first?.videoRepresentation.kind == .video)
    }

    @Test
    func requestedSampleCountUsesDifferentRegionsAndUploaders() async throws {
        let now: Int64 = 1_700_100_000
        let firstRank = jsonResponse(
            #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120}]}}"#
        )
        let secondRank = jsonResponse(
            #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureB2","duration":360,"senddate":1700074800,"mid":10002,"play":140}]}}"#
        )
        let transport = DiscoveryRecordingTransport(
            responses: [
                firstRank,
                jsonResponse(
                    #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
                ),
                try fixtureResponse("playurl"),
                secondRank,
                jsonResponse(
                    #"{"code":0,"data":{"bvid":"BV1FixtureB2","cid":900002,"duration":360,"pubdate":1700074800,"tid":124,"owner":{"mid":10002}}}"#
                ),
                try fixtureResponse("playurl"),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201, 124]
        )

        let samples = try await discoverer.discover(targetCount: 2)

        #expect(samples.count == 2)
        #expect(
            await transport.requests.map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/view",
                "/x/player/playurl",
                "/x/web-interface/newlist_rank",
                "/x/web-interface/view",
                "/x/player/playurl",
            ]
        )
    }

    @Test
    func resettingDiscoveryLifecycleAllowsTheSameAnonymousCandidateAgain() async throws {
        let now: Int64 = 1_700_100_000
        let rank = jsonResponse(
            #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120}]}}"#
        )
        let detail = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
        )
        let transport = DiscoveryRecordingTransport(
            responses: [
                rank, detail, try fixtureResponse("playurl"),
                rank, detail, try fixtureResponse("playurl"),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        #expect(try await discoverer.discover().count == 1)
        await discoverer.resetSeenSamples()
        #expect(try await discoverer.discover().count == 1)
        #expect(await transport.requests.count == 6)
    }

    @Test
    func rejectsAnonymousQualityManifestEvenWhenOriginsAreComparable() async throws {
        let now: Int64 = 1_700_100_000
        let transport = DiscoveryRecordingTransport(
            responses: [
                jsonResponse(
                    #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120}]}}"#
                ),
                jsonResponse(
                    #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
                ),
                try fixtureResponse("playurl", promotesAVCToHighQuality: false),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: DiscoveryAuthorizer()
            ),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        let samples = try await discoverer.discover()

        #expect(samples.isEmpty)
        #expect(await transport.requests.count == 3)
    }

    @Test
    func missingCredentialDoesNotFallBackToAnonymousPlayURL() async throws {
        let now: Int64 = 1_700_100_000
        let transport = DiscoveryRecordingTransport(
            responses: [
                jsonResponse(
                    #"{"code":0,"data":{"result":[{"bvid":"BV1FixtureA1","duration":300,"senddate":1700074800,"mid":10001,"play":120}]}}"#
                ),
                jsonResponse(
                    #"{"code":0,"data":{"bvid":"BV1FixtureA1","cid":900001,"duration":300,"pubdate":1700074800,"tid":201,"owner":{"mid":10001}}}"#
                ),
                try fixtureResponse("playurl"),
            ]
        )
        let discoverer = CDNBenchmarkSampleDiscoverer(
            client: BiliAPIClient(transport: transport),
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            regionIDs: [201]
        )

        await #expect(throws: BiliAPIError.authorizationRequired) {
            try await discoverer.discover()
        }
        #expect(
            await transport.requests.map(\.url.path) == [
                "/x/web-interface/newlist_rank",
                "/x/web-interface/view",
            ]
        )
    }

    private func fixtureResponse(
        _ name: String,
        promotesAVCToHighQuality: Bool = true,
        removesAudio: Bool = false
    ) throws -> HTTPResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        var body = try Data(contentsOf: url)
        if name == "playurl", var text = String(data: body, encoding: .utf8) {
            if promotesAVCToHighQuality {
                text = text.replacingOccurrences(
                    of: "\"id\": 32",
                    with: "\"id\": 64"
                ).replacingOccurrences(
                    of: "\"bandwidth\": 500000",
                    with: "\"bandwidth\": 800000"
                )
            }
            text = text.replacingOccurrences(
                of: "https://media.example.invalid/video-avc-primary.m4s",
                with: "https://upos-sz-mirrorhw.bilivideo.com/video-avc-primary.m4s"
            ).replacingOccurrences(
                of: "https://backup.example.invalid/video-avc.m4s",
                with: "https://upos-hz-mirrorakam.akamaized.net/video-avc.m4s"
            )
            body = Data(text.utf8)
        }
        if removesAudio,
            var root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            var data = root["data"] as? [String: Any],
            var dash = data["dash"] as? [String: Any]
        {
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

    private func jsonResponse(_ value: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(value.utf8)
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await condition())
    }
}

private actor DiscoveryRecordingTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw DiscoveryTransportError.noResponse }
        return responses.removeFirst()
    }
}

private actor BlockingDiscoveryTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        try await Task.sleep(for: .seconds(60))
        throw DiscoveryTransportError.noResponse
    }
}

private actor CancellingFinalPlayURLTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var didCancel = false

    init(responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw DiscoveryTransportError.noResponse }
        let response = responses.removeFirst()
        if request.url.path == "/x/player/playurl", !didCancel {
            didCancel = true
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return response
    }
}

private enum DiscoveryTransportError: Error {
    case noResponse
}

private struct DiscoveryAuthorizer: HTTPRequestAuthorizing {
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        var headers = request.headers
        headers["Cookie"] = "SIGNED_IN_FIXTURE"
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }
}

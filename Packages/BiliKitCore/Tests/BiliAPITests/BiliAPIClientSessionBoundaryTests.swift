import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定认证会话边界契约：带凭据的请求被拒或本地凭据失败时不匿名重试，
/// 任务取消或会话失效后，在途的授权、请求与响应都以取消结束，既不补发也不写回；不绑定会话的匿名读取
/// 改走换入的 transport，不因会话失效报告网络失败。
struct BiliAPIClientSessionBoundaryTests {
    @Test(arguments: [
        (HTTPResponse(statusCode: 412, body: Data()), BiliAPIError.httpStatus(412)),
        (
            jsonResponse(#"{"code":-352,"message":"blocked"}"#),
            .apiRejected(code: -352, message: "blocked")
        ),
        (jsonResponse(#"{"code":-101,"message":"fixture"}"#), .authenticationInvalid)
    ])
    func authenticatedRejectionDoesNotRetryAnonymously(
        response: HTTPResponse,
        expected: BiliAPIError
    ) async throws {
        let transport = StubTransport(responses: [response], answersWBINavOnce: true)
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: expected) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(
            playURLRequests(transport).map { $0.headers["Cookie"] }
                == [StubAuthorizer.cookie]
        )
    }

    /// 只有本地明确无凭据才匿名重试；凭据失效、不可用或被拒绝时失败关闭，不发出任何 playurl。
    @Test(arguments: [
        (HTTPRequestAuthorizationFailureKind.invalidCredential, BiliAPIError.authenticationInvalid),
        (.unavailable, .authorizationUnavailable),
        (.denied, .invalidRequest)
    ])
    func localCredentialFailureDoesNotFallBackToAnonymousPlayback(
        kind: HTTPRequestAuthorizationFailureKind,
        expected: BiliAPIError
    ) async throws {
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(.fail(kind))
        )

        await #expect(throws: expected) {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        #expect(playURLRequests(transport).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledMissingCredentialResolutionDoesNotSendAnonymousFallback() async throws {
        let authorizer = StubAuthorizer(.fail(.missingCredential), suspendingCall: 1)
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilSuspended()

        playbackTask.cancel()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(playURLRequests(transport).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingCredentialResolutionCannotCrossSessionInvalidationBoundary() async throws {
        let authorizer = StubAuthorizer(.fail(.missingCredential), suspendingCall: 1)
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: authorizer
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilSuspended()

        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(playURLRequests(transport).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedRequestCannotCrossSessionInvalidationBoundary() async throws {
        let authorizer = StubAuthorizer(suspendingCall: 1)
        let response = try fixtureResponse("playurl")
        let firstTransport = StubTransport(responses: [response], answersWBINavOnce: true)
        let replacementTransport = StubTransport(responses: [response])
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            requestAuthorizer: authorizer,
            transportFactory: { transportFactory.makeTransport() }
        )

        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilSuspended()

        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(playURLRequests(firstTransport).isEmpty)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedResponseCannotWriteBackAfterSessionInvalidation() async throws {
        let response = try fixtureResponse("playurl")
        let firstTransport = StubTransport([
            .response(try fixtureResponse("nav")), .suspended(response)
        ])
        let replacementTransport = StubTransport(responses: [response])
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            requestAuthorizer: StubAuthorizer(),
            transportFactory: { transportFactory.makeTransport() }
        )

        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await firstTransport.waitForRequests(2)

        await client.invalidateAuthenticatedSession()
        firstTransport.resumeSuspendedRequest()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(playURLRequests(firstTransport).count == 1)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test(.timeLimit(.minutes(1)))
    func authenticatedPlaybackEpochCannotChangeBetweenBaseAndAIAudio()
        async throws
    {
        let response = try semanticAudioResponse(
            audioPath: "original-audio.m4s",
            languageCatalog: machineGeneratedEnglishCatalog
        )
        let authorizer = StubAuthorizer(suspendingCall: 2)
        let firstTransport = StubTransport(responses: [response], answersWBINavOnce: true)
        let replacementTransport = StubTransport(responses: [response])
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            requestAuthorizer: authorizer,
            transportFactory: { transportFactory.makeTransport() }
        )
        let playbackTask = Task {
            try await client.playback(for: "BV1FixtureA1", cid: 900_001)
        }
        await authorizer.waitUntilSuspended()

        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await playbackTask.value
        }
        #expect(playURLRequests(firstTransport).count == 1)
        #expect(replacementTransport.capturedRequests().isEmpty)
        #expect(firstTransport.wasInvalidated)
    }

    @Test(.timeLimit(.minutes(1)))
    func anonymousReadWaitingForTheDeviceIdentityUsesTheReplacementTransport() async throws {
        let identityTransport = StubTransport([
            .suspended(
                jsonResponse(#"{"code":0,"data":{"b_3":"ISSUED-3infoc","b_4":"ISSUED-4"}}"#)
            ),
            .response(jsonResponse(#"{"code":0,"data":{}}"#))
        ])
        let deviceIdentity = BiliDeviceIdentity(
            store: MemoryDeviceIdentityStore(),
            transport: identityTransport
        )
        // 旧 transport 没有任何回放：请求落到它上面就以网络失败结束。
        let firstTransport = StubTransport(responses: [])
        let replacementTransport = StubTransport(responses: [jsonResponse(#"{"code":0,"data":{}}"#)]
        )
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            deviceCookies: deviceIdentity,
            transportFactory: { transportFactory.makeTransport() }
        )
        let url = try await client.endpoint(path: "/x/fixture", queryItems: [])

        let read = Task { () async throws -> EmptyFixturePayload in
            try await client.get(url: url, referer: nil)
        }
        await identityTransport.waitForRequests(1)
        await client.invalidateAuthenticatedSession()
        identityTransport.resumeSuspendedRequest()

        _ = try await read.value
        #expect(firstTransport.capturedRequests().isEmpty)
        #expect(replacementTransport.capturedRequests().count == 1)
    }
}

private struct EmptyFixturePayload: Decodable, Sendable {}

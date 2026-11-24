import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定设备标识的准备、持久化与轮换：存储里的有效值直接复用，spi 只为没有有效值时请求一次并持久化，不可用时退回
/// 不持久化的本地值；每个进程对每个标识先激活一次（只带设备 Cookie）再交给请求；会话失效清除存储并丢弃在途准备。
struct BiliDeviceIdentityTests {
    private static let now: Int64 = 1_700_000_000
    private static let spiPath = "/x/frontend/finger/spi"
    private static let activationPath = "/x/internal/gaia-gateway/ExClimbWuzhi"

    @Test
    func storedFreshIdentityIsReusedAndActivatedOnce() async throws {
        let stored = try identity("STORED", issuedAt: Self.now - 60)
        let transport = StubTransport(responses: [activationResponse()])
        let deviceIdentity = makeIdentity(store: MemoryDeviceIdentityStore(stored), transport)

        let first = try await deviceIdentity.deviceCookie()
        let second = try await deviceIdentity.deviceCookie()

        #expect(first == "buvid3=STORED-3infoc; b_nut=\(Self.now - 60); buvid4=STORED-4")
        #expect(second == first)
        let requests = transport.capturedRequests()
        #expect(requests.map(\.url.path) == [Self.activationPath])
        let activation = try #require(requests.first)
        #expect(activation.method == .post)
        // 激活只带设备 Cookie，不带账户凭据。
        #expect(activation.headers["Cookie"] == first)
        let body = try #require(activation.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["payload"] is String)
    }

    @Test
    func concurrentCallersShareOnePreparationAndTheIssuedValueIsPersisted() async throws {
        let transport = StubTransport([
            .suspended(spiResponse("ISSUED")),
            .response(activationResponse())
        ])
        let store = MemoryDeviceIdentityStore()
        let deviceIdentity = makeIdentity(store: store, transport)

        async let first = deviceIdentity.deviceCookie()
        async let second = deviceIdentity.deviceCookie()
        await transport.waitForRequests(1)
        transport.resumeSuspendedRequest()
        let cookies = try await [first, second]

        let expected = "buvid3=ISSUED-3infoc; b_nut=\(Self.now); buvid4=ISSUED-4"
        #expect(cookies == [expected, expected])
        let requests = transport.capturedRequests()
        #expect(requests.map(\.url.path) == [Self.spiPath, Self.activationPath])
        // spi 本身匿名：不带任何 Cookie；激活用的是刚下发的这一组。
        #expect(requests.first?.headers["Cookie"] == nil)
        #expect(requests.last?.headers["Cookie"] == expected)
        #expect(store.identity == (try identity("ISSUED", issuedAt: Self.now)))
        #expect(store.saveCount == 1)
    }

    /// 未激活的标识会让搜索收到 `v_voucher`，所以调用方要等激活返回；等待中的取消立即结束这个调用方，
    /// 但不取消共享的准备，后来者照常拿到同一组。
    @Test(.timeLimit(.minutes(1)))
    func callersWaitForActivationAndTheirCancellationLeavesThePreparationRunning() async throws {
        let transport = StubTransport([
            .response(spiResponse("ISSUED")),
            .suspended(activationResponse())
        ])
        let store = MemoryDeviceIdentityStore()
        let deviceIdentity = makeIdentity(store: store, transport)

        let cancelled = Task { try await deviceIdentity.deviceCookie() }
        await transport.waitForRequests(2)
        cancelled.cancel()
        // 激活仍挂起：这个调用方没有提前拿到标识，取消也不必等准备结束。
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        async let later = deviceIdentity.deviceCookie()
        transport.resumeSuspendedRequest()

        #expect(try await later == "buvid3=ISSUED-3infoc; b_nut=\(Self.now); buvid4=ISSUED-4")
        #expect(
            transport.capturedRequests().map(\.url.path) == [Self.spiPath, Self.activationPath]
        )
        #expect(store.saveCount == 1)
    }

    @Test(arguments: [
        HTTPResponse(statusCode: 412, body: Data()),
        jsonResponse(#"{"code":-352,"data":null}"#),
        // 含分号的值会注入额外的 Cookie，按异常响应丢弃。
        jsonResponse(#"{"code":0,"data":{"b_3":"A;evil=1","b_4":"B"}}"#)
    ])
    func unusableSpiFallsBackToAnActivatedLocalValueThatIsNotPersisted(
        response: HTTPResponse
    ) async throws {
        let store = MemoryDeviceIdentityStore()
        let transport = StubTransport(responses: [response, activationResponse()])
        let deviceIdentity = makeIdentity(store: store, transport)

        let cookie = try await deviceIdentity.deviceCookie()

        let local =
            /buvid3=[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{17}infoc; b_nut=1700000000/
        #expect(cookie.wholeMatch(of: local) != nil)
        #expect(store.saveCount == 0)
        #expect(transport.capturedRequests().last?.headers["Cookie"] == cookie)
        // 同一进程内沿用这一个本地值，不再反复请求 spi 或激活。
        #expect(try await deviceIdentity.deviceCookie() == cookie)
        #expect(transport.capturedRequests().count == 2)
    }

    @Test
    func identityPastItsRetentionIsReplaced() async throws {
        let expired = try identity(
            "EXPIRED",
            issuedAt: Self.now - DeviceIdentity.retentionSeconds
        )
        let store = MemoryDeviceIdentityStore(expired)
        let transport = StubTransport(responses: [spiResponse("RENEWED"), activationResponse()])
        let deviceIdentity = makeIdentity(store: store, transport)

        let cookie = try await deviceIdentity.deviceCookie()

        #expect(cookie.hasPrefix("buvid3=RENEWED-3infoc;"))
        #expect(store.identity == (try identity("RENEWED", issuedAt: Self.now)))
    }

    @Test
    func sessionInvalidationClearsTheStoreAndDiscardsTheInFlightPreparation() async throws {
        let transport = StubTransport([
            .suspended(spiResponse("OLD")),
            .response(spiResponse("NEW")),
            .response(activationResponse())
        ])
        let store = MemoryDeviceIdentityStore()
        let deviceIdentity = makeIdentity(store: store, transport)

        async let cookie = deviceIdentity.deviceCookie()
        await transport.waitForRequests(1)
        await deviceIdentity.invalidateAuthenticatedSession()

        // 旧会话发起的准备被取消、不激活；等待者按新代次重新准备，旧值既不返回也不写回。
        #expect(try await cookie.hasPrefix("buvid3=NEW-3infoc;"))
        #expect(
            transport.capturedRequests().map(\.url.path)
                == [Self.spiPath, Self.spiPath, Self.activationPath]
        )
        #expect(store.clearCount == 1)
        #expect(store.identity == (try identity("NEW", issuedAt: Self.now)))
        #expect(store.saveCount == 1)
    }

    private func makeIdentity(
        store: MemoryDeviceIdentityStore,
        _ transport: StubTransport
    ) -> BiliDeviceIdentity {
        BiliDeviceIdentity(store: store, transport: transport, clock: { Self.now })
    }

    private func identity(_ tag: String, issuedAt: Int64) throws -> DeviceIdentity {
        try #require(
            DeviceIdentity(buvid3: "\(tag)-3infoc", buvid4: "\(tag)-4", issuedAt: issuedAt)
        )
    }

    private func spiResponse(_ tag: String) -> HTTPResponse {
        jsonResponse(#"{"code":0,"data":{"b_3":"\#(tag)-3infoc","b_4":"\#(tag)-4"}}"#)
    }

    private func activationResponse() -> HTTPResponse {
        jsonResponse(#"{"code":0,"data":{}}"#)
    }
}

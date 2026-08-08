import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

struct BiliGuestRepositoryTests {
    @Test
    func mapsInvalidRequestAtAdapterBoundary() async {
        let repository = BiliGuestRepository(
            client: BiliAPIClient(transport: UnexpectedTransport())
        )

        await #expect(throws: GuestApplicationError.invalidRequest) {
            try await repository.popular(page: 0, pageSize: 20)
        }
    }

    @Test(arguments: [403, 412])
    func mapsRestrictedResponseAtAdapterBoundary(statusCode: Int) async {
        let repository = BiliGuestRepository(
            client: BiliAPIClient(
                transport: FixedResponseTransport(
                    response: HTTPResponse(statusCode: statusCode, body: Data())
                )
            )
        )

        await #expect(throws: GuestApplicationError.requestRestricted) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func mapsMalformedPayloadAtAdapterBoundary() async {
        let repository = BiliGuestRepository(
            client: BiliAPIClient(
                transport: FixedResponseTransport(
                    response: HTTPResponse(
                        statusCode: 200,
                        headers: ["Content-Type": "application/json"],
                        body: Data("{".utf8)
                    )
                )
            )
        )

        await #expect(throws: GuestApplicationError.invalidResponse) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }

    @Test
    func mapsUnsupportedPlaybackAtAdapterBoundary() async throws {
        let fixture = try fixtureResponse("playurl")
        let body = String(decoding: fixture.body, as: UTF8.self)
            .replacingOccurrences(of: #""codecid": 7"#, with: #""codecid": 12"#)
            .replacingOccurrences(of: "avc1.64001f", with: "hev1.1.6.L120.90")
        let repository = BiliGuestRepository(
            client: BiliAPIClient(
                transport: FixedResponseTransport(
                    response: HTTPResponse(
                        statusCode: fixture.statusCode,
                        headers: fixture.headers,
                        body: Data(body.utf8)
                    )
                )
            )
        )

        await #expect(throws: GuestApplicationError.unsupportedMedia) {
            try await repository.playback(
                for: "BV1FixtureA1",
                cid: 900_001
            )
        }
    }

    @Test
    func preservesCancellationAtAdapterBoundary() async {
        let repository = BiliGuestRepository(
            client: BiliAPIClient(transport: CancellationTransport())
        )

        await #expect(throws: CancellationError.self) {
            try await repository.popular(page: 1, pageSize: 20)
        }
    }

    private func fixtureResponse(_ name: String) throws -> HTTPResponse {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: try Data(contentsOf: url)
        )
    }
}

private struct FixedResponseTransport: HTTPTransport {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}

private struct CancellationTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw CancellationError()
    }
}

private struct UnexpectedTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        Issue.record("Invalid input should fail before transport")
        throw CancellationError()
    }
}

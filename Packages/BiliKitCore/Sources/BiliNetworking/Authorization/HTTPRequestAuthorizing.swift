import Foundation

public protocol HTTPRequestAuthorizing: Sendable {
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest
}

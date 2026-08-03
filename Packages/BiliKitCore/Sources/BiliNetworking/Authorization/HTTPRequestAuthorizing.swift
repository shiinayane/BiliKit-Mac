import Foundation

/// 为已经通过实现方精确 allowlist 的请求临时附加认证材料。
///
/// 协议不代表任意请求都有权获得凭据；实现必须同时验证目标、方法与 endpoint 语义。
public protocol HTTPRequestAuthorizing: Sendable {
    func authorize(_ request: HTTPRequest) async throws -> HTTPRequest
}

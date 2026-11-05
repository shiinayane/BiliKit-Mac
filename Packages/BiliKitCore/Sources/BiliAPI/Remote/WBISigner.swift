import BiliNetworking
import CryptoKit
import Foundation

/// 从 nav 的两张图片地址取出的 WBI key：各取文件名去掉扩展名，必须都是 32 个字符，否则抛
/// `invalidWBIKey`。
///
/// 只由 `BiliAPIClient.wbiKey` 构造，由客户端按 UTC 自然日缓存；会话失效时清掉缓存。
struct WBIKeyMaterial: Sendable, Equatable {
    let imageKey: String
    let subKey: String

    init(imageURL: String, subURL: String) throws {
        imageKey = try Self.key(from: imageURL)
        subKey = try Self.key(from: subURL)
        guard imageKey.count == 32, subKey.count == 32 else {
            throw BiliAPIError.invalidWBIKey
        }
    }

    private static func key(from value: String) throws -> String {
        guard let url = URL(string: value) else {
            throw BiliAPIError.invalidWBIKey
        }
        let key = url.deletingPathExtension().lastPathComponent
        guard !key.isEmpty else {
            throw BiliAPIError.invalidWBIKey
        }
        return key
    }
}

/// WBI 签名：按混排表从两段 key 取 32 位 mixin key，参数加 `wts` 后按键排序、去掉 `!'()*`、按
/// unreserved 规则编码，拼上 mixin key 求 MD5 作为 `w_rid`。
///
/// 由 `BiliAPIClient.signedRequest` 与观看进度 heartbeat 调用；返回已编码的完整 query，
/// 调用方必须原样作为 percent-encoded query 使用，不得再经 `URLComponents.queryItems` 重新编码。
/// 混排表与过滤字符是 B 站 Web 端的签名规则，改动会让签名请求被拒；MD5 只是协议规定的摘要，
/// 不承担安全性。
struct WBISigner: Sendable {
    private static let mixinTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]
    private static let filteredCharacters = CharacterSet(charactersIn: "!'()*")

    func sign(
        parameters: [String: String],
        keys: WBIKeyMaterial,
        timestamp: Int64
    ) throws -> String {
        let originalKey = Array(keys.imageKey + keys.subKey)
        guard originalKey.count >= 64 else {
            throw BiliAPIError.invalidWBIKey
        }
        let mixinKey = String(
            Self.mixinTable.prefix(32).map { originalKey[$0] }
        )
        var signedParameters = parameters
        signedParameters["wts"] = String(timestamp)
        let filteredPairs = signedParameters.keys.sorted().map { key in
            let filteredValue = signedParameters[key, default: ""]
                .components(separatedBy: Self.filteredCharacters)
                .joined()
            return (key, filteredValue)
        }
        guard let query = URLQueryUnreservedEncoding.query(filteredPairs) else {
            throw BiliAPIError.signingFailed
        }
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        return "\(query)&w_rid=\(signature)"
    }
}

import Foundation

/// 把 query 的键或值中 RFC 3986 unreserved 以外的字符全部百分号编码。
///
/// `URLComponents.queryItems` 会保留 `+` 等字符，服务端按表单解码时 `+` 变成空格；用户输入的自由
/// 文本（搜索词）、WBI 签名（BiliAPI）与 APP 签名（BiliAuth）都必须按这一规则编码，各条路径对同一个值的编码
/// 保持一致，签名的 MD5 输入才与实际发出的字符串相同。
public enum URLQueryUnreservedEncoding {
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }

    /// 按给定顺序编码每个键与值，拼成 `name=value&…` 的 percent-encoded query；任一项无法编码时为 nil。
    ///
    /// 结果直接作为 percent-encoded query 或 urlencoded 正文使用，不得再经 `queryItems` 重新编码；WBI 与 APP 签名的
    /// MD5 输入就是这个字符串。
    public static func query(_ pairs: [(String, String)]) -> String? {
        var encodedPairs: [String] = []
        for (name, value) in pairs {
            guard let encodedName = encode(name), let encodedValue = encode(value) else {
                return nil
            }
            encodedPairs.append("\(encodedName)=\(encodedValue)")
        }
        return encodedPairs.joined(separator: "&")
    }
}

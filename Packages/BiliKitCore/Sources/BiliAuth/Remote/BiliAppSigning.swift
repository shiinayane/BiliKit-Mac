import BiliNetworking
import CryptoKit
import Foundation

/// B 站 App 端接口的 APP 签名：补上 `appkey` 与 `ts`，按键名排序后按 unreserved 规则编码，拼上 appsec 求 MD5 作为
/// `sign`。
///
/// 只用 TV 端（云视听小电视）的一对 key：TV 扫码登录用它取码与轮询。B 站发出的 access_token 只认发它的 appkey，换
/// key 调用返回 -663，所以凡是要带这份登录凭据的 App 端请求都必须用同一对 key 签名。这对值是从官方客户端提取、在
/// 开源客户端里公开流传的，不是秘密；B 站轮换它时 TV 登录会整体失效，见 SECURITY-MODEL §9。MD5 只是协议规定的
/// 摘要，不提供安全性。
enum BiliAppSigning {
    static let appKey = "4409e2ce8ffd12b8"
    private static let appSecret = "59b43e04ad6965f34319062b478f83dd"

    /// 签名用的保留参数名：调用方不得自带，否则签名会覆盖或重复它们。
    private static let reservedNames: Set<String> = ["appkey", "ts", "sign"]

    /// 返回 urlencoded 正文，`sign` 在末尾；参数含保留名或无法编码时为 nil（调用方的编程错误）。
    ///
    /// `timestamp` 是 Unix 秒，由调用方取发送时刻；服务端按它判断请求是否过期。
    static func signedForm(_ parameters: [String: String], timestamp: Int64) -> String? {
        guard reservedNames.isDisjoint(with: parameters.keys) else { return nil }
        var all = parameters
        all["appkey"] = appKey
        all["ts"] = String(timestamp)
        let pairs = all.keys.sorted().map { ($0, all[$0] ?? "") }
        guard let query = URLQueryUnreservedEncoding.query(pairs) else { return nil }
        let digest = Insecure.MD5.hash(data: Data((query + appSecret).utf8))
        let sign = digest.map { String(format: "%02x", $0) }.joined()
        return query + "&sign=" + sign
    }
}

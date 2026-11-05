import BiliNetworking
import Foundation

/// 网页端两个写授权器（观看进度 heartbeat、用户发起的账户写入）共用的表单解析与 CSRF 编码，App 端的读取与写入授权器
/// 也用这里的 query 解析。
///
/// 凭据读取的唯一规则是 `AccountCredentialStoring.loadCredential(isConfirmedSignedOut:)`。
///
/// 只放两边逐字相同的规则；各自的 path、header、字段 schema 与 Cookie 白名单仍在各自的授权器里，不因共用这些
/// 帮手而合并成一个泛化的写授权器（见 SECURITY-MODEL §3）。无状态。
enum WriteRequestAuthorizationSupport {
    /// 把 `a=1&b=2` 形式的 query 或表单解码为字段；字段名为空、缺 `=`、无法百分号解码或同名字段重复时为 nil。
    ///
    /// 重复字段一律拒绝：服务端取第一个还是最后一个不可知，校验的值必须就是被使用的值。
    static func decodedUniqueFields(_ value: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                let name = String(parts[0]).removingPercentEncoding,
                let value = String(parts[1]).removingPercentEncoding,
                !name.isEmpty,
                result.updateValue(value, forKey: name) == nil
            else { return nil }
        }
        return result
    }

    /// 只由 ASCII 数字（可带负号）组成、能放进 Int64 的整数；其他形状为 nil。
    static func integer(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty,
            value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") })
        else { return nil }
        return Int64(value)
    }

    static func positiveInteger(_ value: String?) -> Bool {
        (integer(value) ?? 0) > 0
    }

    /// `csrf=<值>` 的百分号编码形式，在授权器内拼到已校验的表单末尾。
    static func encodedCSRFField(_ csrf: String) -> String? {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "csrf", value: csrf)]
        return components.percentEncodedQuery
    }
}

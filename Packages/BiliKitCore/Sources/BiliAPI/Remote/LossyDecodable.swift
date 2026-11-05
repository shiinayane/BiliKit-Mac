/// 单个元素解码失败时记为 nil，不让整个数组或外层对象一起失败。
struct LossyDecodable<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// 单个字段解码失败时按缺失处理，不让外层对象一起失败。
///
/// `decodeLossyBool` 另把 0／1 整数当作布尔值，其他取值按缺失处理。
extension KeyedDecodingContainer {
    func decodeLossyIfPresent<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// 数组字段逐个元素宽松解码，丢掉解码失败的元素；字段缺失或本身不是数组时抛错，由外层对象一起失败。
    func decodeLossyElements<Value: Decodable & Sendable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> [Value] {
        try decode([LossyDecodable<Value>].self, forKey: key).compactMap(\.value)
    }

    func decodeLossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            switch value {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return nil
    }
}

/// 接口字段形状不固定时的严格解码：不吞错，形状不认识就让外层对象失败。
extension KeyedDecodingContainer {
    /// 接口有时给字符串、有时给整数的标识（MID、分页偏移）：字符串原样返回，整数转十进制文本；两种都不是或
    /// 缺失时抛错，由外层对象一起失败。
    ///
    /// 只统一形状，不校验字符串内容；需要数值的调用方在结果上自行解析（视频 UP 主 MID）。
    func decodeIntegerText(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        return String(try decode(Int64.self, forKey: key))
    }
}

import BiliModels
import Foundation

/// 分段弹幕（`DanmakuPayloadDecoder`）与互动弹幕（`DanmakuCommandDecoder`）共用的 wire 值校验：ID、时间点与正文；
/// 显示位置的 `mode` 在解码与发送（`BiliAPIClient.postDanmaku`）两个方向都只在这里换算。
///
/// 只判断取值是否成立，成立时给出归一后的值；不成立时怎么办（整段失败或只跳过这一条）由各自的解码器决定。
enum DanmakuWireValues {
    /// 弹幕 ID 的字符数上限；超出视为数据异常。
    static let maximumIdentifierLength = 128
    /// 弹幕时间点上限 24 小时，超出视为数据异常。
    static let maximumTimeMilliseconds: Int32 = 86_400_000

    /// 优先取字符串 ID，没有时取正数的数字 ID；都没有或超长时为 nil。
    static func identifier(idString: String, numericID: Int64) -> String? {
        let raw = idString.isEmpty ? (numericID > 0 ? String(numericID) : nil) : idString
        guard let raw, raw.count <= maximumIdentifierLength else { return nil }
        return raw
    }

    /// 毫秒时间点换成秒；为负或超过上限时为 nil。
    static func seconds(fromMilliseconds milliseconds: Int32) -> Double? {
        guard (0...maximumTimeMilliseconds).contains(milliseconds) else { return nil }
        return Double(milliseconds) / 1_000
    }

    /// 接口的 `mode`：1–3 都按滚动，4 为底部，5 为顶部；其他模式（逆向、高级、代码弹幕）为 nil，解码时丢弃。
    static func presentationMode(_ value: Int32) -> DanmakuPresentationMode? {
        switch value {
        case 1, 2, 3: .scrolling
        case 4: .bottom
        case 5: .top
        default: nil
        }
    }

    /// 发送时的 `mode`：滚动发 1。
    static func wireMode(for mode: DanmakuPresentationMode) -> Int32 {
        switch mode {
        case .scrolling: 1
        case .bottom: 4
        case .top: 5
        }
    }

    /// 去掉首尾空白的正文；为空时为 nil，长度上限由调用方判断。
    static func trimmedText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

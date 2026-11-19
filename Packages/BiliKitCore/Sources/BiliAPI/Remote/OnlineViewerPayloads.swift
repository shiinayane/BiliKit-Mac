import Foundation

/// `/x/player/online/total` 的 `data`：全平台「正在看」人数 `total` 与是否显示它的 `show_switch.total`。
///
/// 只读这两项；`count`（只算网页端）不用。人数是服务端格式化好的文本（例如 `12`、`1000+`、`10万+`），原样显示。
struct OnlineViewerPayload: Decodable, Sendable {
    /// 人数文本的长度上限：B 站给出的是短数字与「+」「万」之类后缀，超出按异常响应丢弃，界面不显示任意长的远端文字
    /// （见 SECURITY-MODEL §3）。
    static let maximumTextLength = 16

    let total: String?
    let showSwitch: ShowSwitch?

    struct ShowSwitch: Decodable, Sendable {
        let total: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case showSwitch = "show_switch"
    }

    /// 要显示的人数文本；B 站关掉显示、文本为空、过长或含换行等控制字符时为 nil。
    func totalText() -> String? {
        guard showSwitch?.total != false,
            let text = total?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            text.count <= Self.maximumTextLength,
            text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return text
    }
}

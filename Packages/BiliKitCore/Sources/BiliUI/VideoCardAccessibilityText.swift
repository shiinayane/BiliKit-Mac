import Foundation

/// 视频卡片里由 BiliUI 拥有的读屏文案；卡片的标签与帮助由调用方给出。
///
/// 浏览网格、竖向视频行（UP 主空间投稿、相关推荐）与稍后再看卡片的读屏标签里“时长 X”这一段也只在这里，各 Feature 不另存
/// 一份译文。
package enum VideoCardAccessibilityText {
    /// 卡片处于选中状态时的读屏值。
    package static var selectedValue: String { BiliUIStrings.localized("已选择") }

    /// 读屏标签里的时长片段：「时长 12分钟34秒钟」。
    ///
    /// 封面上的「12:34」会被 VoiceOver 读成时刻，读屏改用系统带单位的完整写法；为零的单位不读，负数按 0。
    package static func duration(seconds: Int, locale: Locale = InterfaceLocale.current) -> String {
        let spoken = Duration.seconds(max(0, seconds)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale)
        )
        return BiliUIStrings.localized("时长 \(spoken)", locale: locale)
    }

    /// 不能进入播放的卡片的读屏值；具体原因在调用方给出的标签里。
    package static var unavailableValue: String { BiliUIStrings.localized("不可播放") }

    /// 卡片读屏值的唯一来源：依次列出“不可播放”与“已选择”，两者都不成立时为 nil。
    package static func value(isSelected: Bool, isActivatable: Bool) -> String? {
        let parts = [
            isActivatable ? nil : unavailableValue,
            isSelected ? selectedValue : nil
        ].compactMap(\.self)
        return parts.isEmpty ? nil : ListFormatter.localizedString(byJoining: parts)
    }
}

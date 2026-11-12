import AppKit

/// 用户名的颜色：大会员为粉色，其余用调用方给的常规色；评论作者与播放侧栏 UP 主共用这一规则。
///
/// 评论作者传次要色，让正文成为每条评论的视觉重点；UP 主名字用默认的主文字色。
enum NativeMemberNameColor {
    static func color(isVIP: Bool, regular: NSColor = .labelColor) -> NSColor {
        isVIP ? .systemPink : regular
    }
}

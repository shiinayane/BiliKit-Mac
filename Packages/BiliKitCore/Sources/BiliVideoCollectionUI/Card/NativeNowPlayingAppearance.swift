import AppKit
import QuartzCore

/// 正在播放的条目（UP 主空间投稿行、播放页横排卡片）的外观，唯一一份：整块强调色淡底色，加强调色的「▶ 正在播放」标记。
///
/// 不持有状态；底色写进调用方放在最底层的专用 layer，与 `NativeInteractiveSurface` 的悬停底色、描边互不覆盖。
/// 标记文字由调用方本地化后传入。
@MainActor
package enum NativeNowPlayingAppearance {
    /// 强调色底色的不透明度；比悬停底色明显，指针移开后仍能看出是哪一项。
    static let fillOpacity: CGFloat = 0.15
    package static let symbolName = "play.fill"
    package static let markerColor = NSColor.controlAccentColor

    /// 标记文字的字体：在调用方的基础字体上加粗。
    package static func markerFont(for base: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
    }

    /// 按 `appearance` 解析强调色后写进底色 layer；外观变化时调用方要重新调用。
    package static func applyFill(
        _ isNowPlaying: Bool,
        to layer: CALayer,
        appearance: NSAppearance
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor =
            isNowPlaying
            ? markerColor.withDynamicAlpha(fillOpacity).cgColor(for: appearance)
            : nil
        CATransaction.commit()
    }
}

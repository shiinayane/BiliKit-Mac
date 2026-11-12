import BiliUI
import SwiftUI

/// 播放页主区：视频取剩余空间里最大的 16:9，下方是固定高度的相关推荐；主区不滚动。
///
/// 标题与数据在工具栏，弹幕设置在工具栏弹出面板，简介、选集与评论在侧栏。真实页面与加载骨架
/// 共用这一份布局，加载完成时视频与推荐位置不跳动。
struct PlaybackDetailLayout<Player: View, Related: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let player: Player
    private let related: Related

    init(
        @ViewBuilder player: () -> Player,
        @ViewBuilder related: () -> Related
    ) {
        self.player = player()
        self.related = related()
    }

    var body: some View {
        VStack(spacing: PlaybackPageLayout.sectionSpacing) {
            player
                .aspectRatio(PlaybackPageLayout.playerAspectRatio, contentMode: .fit)
                // 投影画在播放器下方的同尺寸形状上：播放器是经 NSViewRepresentable 宿主的
                // AVPlayerView，直接对它用 `.shadow` 不可靠。画面没有圆角裁切，形状因此也是直角。
                .background {
                    Rectangle()
                        .fill(.black)
                        .shadow(
                            color: .black.opacity(
                                PlaybackPageLayout.playerShadowOpacity(colorScheme)
                            ),
                            radius: PlaybackPageLayout.playerShadowRadius,
                            y: PlaybackPageLayout.playerShadowOffsetY
                        )
                }
                .padding(.horizontal, PlaybackPageLayout.horizontalContentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            related
        }
        .padding(.top, PlaybackPageLayout.verticalContentPadding)
        .padding(.bottom, PlaybackPageLayout.relatedBottomPadding)
        // 骨架与内容共用这套几何，加载阶段切换只在外层交叉淡化，布局内部不参与任何动画：
        // 新建的 AppKit 视图（播放器、推荐横排）否则会从初始 frame 动画到最终位置，看起来像“飞入”。
        .transaction { $0.animation = nil }
    }
}

/// 播放页主区的几何常量，真实页面与骨架共用。
enum PlaybackPageLayout {
    static let horizontalContentPadding: CGFloat = 40
    /// 工具栏到视频、推荐卡片到窗口底边的距离。
    static let verticalContentPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    static let playerAspectRatio: CGFloat = 16.0 / 9.0
    /// 横排卡片下方已有可视区留白，页面只补足剩余部分。
    static let relatedBottomPadding = max(
        0,
        verticalContentPadding - VideoCardShelfGeometry.bottomInset
    )
    /// 视频投影的模糊半径。
    ///
    /// 加上下移量约 16pt，留在 `sectionSpacing` 之内，不压到下方推荐横排；调大前先确认间距。
    static let playerShadowRadius: CGFloat = 12
    /// 投影下移量：光源略偏上，画面像浮在背景之上；顶部只剩约 8pt 阴影，远小于顶部留白。
    static let playerShadowOffsetY: CGFloat = 4

    /// 浅色外观的投影不透明度：保持轻，只把画面边缘与背景分开。
    static let playerShadowLightOpacity: Double = 0.22
    /// 深色外观的投影不透明度。
    ///
    /// 深色背景本身接近黑色，投影要比浅色深得多才分辨得出边缘。
    static let playerShadowDarkOpacity: Double = 0.8

    static func playerShadowOpacity(_ colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? playerShadowDarkOpacity : playerShadowLightOpacity
    }
}

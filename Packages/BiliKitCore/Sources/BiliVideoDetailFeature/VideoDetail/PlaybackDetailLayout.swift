import SwiftUI

/// 播放页视频区：播放器（或加载骨架）铺满分栏布局给它的 16:9 区域，不留边距。
///
/// 真实页面与加载骨架共用这一份，加载完成时视频位置不跳动。区域的尺寸由 `PlaybackPageView` 决定，这里不测量。
struct PlaybackDetailLayout<Player: View>: View {
    private let player: Player

    init(@ViewBuilder player: () -> Player) {
        self.player = player()
    }

    var body: some View {
        player
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 骨架与内容切换只在外层交叉淡化，这里不参与任何动画：新建的 AppKit 播放器视图否则会从初始 frame 动画到
            // 最终位置，看起来像“飞入”。
            .transaction { $0.animation = nil }
    }
}

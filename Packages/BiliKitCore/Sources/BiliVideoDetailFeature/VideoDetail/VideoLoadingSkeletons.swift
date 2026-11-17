import BiliUI
import SwiftUI

/// 详情尚未到达时的播放页骨架：与真实页面共用 `PlaybackDetailLayout`，读屏只读加载说明。
struct VideoDetailSkeleton: View {
    let loadingLabel: String

    var body: some View {
        PlaybackDetailLayout {
            Rectangle()
                .fill(.black)
                .overlay {
                    PlayerLoadingIndicator()
                }
        } related: {
            RelatedVideoShelfFrame {
                PlaybackShelfHeaderSkeleton()
            } content: {
                RelatedVideoShelfLoadingRow()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }
}

/// 横排标题行的加载占位：分段控件所在位置的一条灰色胶囊，与卡片骨架同一种填充。
///
/// 骨架时还不知道有几个分页（合集要等详情），胶囊只取分段控件的大致尺寸，不求与真实控件等宽。
private struct PlaybackShelfHeaderSkeleton: View {
    /// 约等于三个分页的分段控件在中文界面下的宽度。
    private static let width: CGFloat = 200
    /// 分段控件常规尺寸的高度；不超过 `VideoCardShelfGeometry.headerHeight`。
    private static let height: CGFloat = 22

    var body: some View {
        HStack {
            Capsule()
                .fill(.quaternary)
                .frame(width: Self.width, height: Self.height)
            Spacer(minLength: 0)
        }
    }
}

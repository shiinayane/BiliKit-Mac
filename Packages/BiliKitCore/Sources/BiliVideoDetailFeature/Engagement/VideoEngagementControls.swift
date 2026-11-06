import BiliApplication
import BiliUI
import SwiftUI

/// 播放页工具栏的点赞、投币、收藏一组：图标加紧凑计数，做过的显示实心图标与强调色。
///
/// 点赞点一下就完成、再点撤回；投币打开小面板（快捷键 W 打开同一个面板）；收藏打开「收藏到…」面板。没有写入口、
/// 不满足写入门槛或还没读到互动状态时按钮禁用，计数照常显示。不拥有状态与写入：状态在 `VideoEngagementModel`，意图交给
/// 环境里的 `VideoEngagementActions`。
struct VideoEngagementControls: View {
    @Environment(\.videoEngagementActions) private var actions
    @Bindable var model: VideoEngagementModel

    var body: some View {
        likeButton
        coinButton
        favoriteButton
    }

    private var likeButton: some View {
        let isLiked = model.engagement?.isLiked == true
        return Button {
            guard let bvid = model.bvid else { return }
            actions?.setLiked(!isLiked, bvid)
        } label: {
            countLabel(
                model.likeCount,
                title: VideoDetailFeatureStrings.localized("点赞"),
                systemImage: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                isActive: isLiked
            )
        }
        .disabled(!isWritable)
        .help(VideoDetailFeatureStrings.localized("点赞（Q），长按 Q 三连"))
        .accessibilityLabel(VideoDetailFeatureStrings.localized("点赞"))
        .accessibilityValue(
            accessibilityValue(
                isLiked ? VideoDetailFeatureStrings.localized("已点赞") : nil,
                count: model.likeCount
            )
        )
    }

    private var coinButton: some View {
        let hasCoined = (model.engagement?.coinCount ?? 0) > 0
        return Button {
            model.isCoinPanelPresented.toggle()
        } label: {
            countLabel(
                model.coinCount,
                title: VideoDetailFeatureStrings.localized("投币"),
                systemImage: hasCoined ? "bitcoinsign.circle.fill" : "bitcoinsign.circle",
                isActive: hasCoined
            )
        }
        .disabled(!isWritable)
        .help(VideoDetailFeatureStrings.localized("投币（W）"))
        .accessibilityLabel(VideoDetailFeatureStrings.localized("投币"))
        .accessibilityValue(
            accessibilityValue(
                hasCoined ? VideoDetailFeatureStrings.localized("已投币") : nil,
                count: model.coinCount
            )
        )
        .popover(isPresented: $model.isCoinPanelPresented, arrowEdge: .bottom) {
            VideoCoinPanel(model: model) { count, alsoLike in
                model.isCoinPanelPresented = false
                guard let bvid = model.bvid else { return }
                actions?.addCoins(count, alsoLike, bvid)
            }
        }
    }

    private var favoriteButton: some View {
        let isFavorited = model.engagement?.isFavorited == true
        return Button {
            guard let bvid = model.bvid else { return }
            actions?.chooseFavoriteFolders(bvid)
        } label: {
            countLabel(
                model.favoriteCount,
                title: VideoDetailFeatureStrings.localized("收藏"),
                systemImage: isFavorited ? "star.fill" : "star",
                isActive: isFavorited
            )
        }
        .disabled(!isWritable)
        .help(VideoDetailFeatureStrings.localized("收藏到…（E）"))
        .accessibilityLabel(VideoDetailFeatureStrings.localized("收藏"))
        .accessibilityValue(
            accessibilityValue(
                isFavorited ? VideoDetailFeatureStrings.localized("已收藏") : nil,
                count: model.favoriteCount
            )
        )
    }

    /// 写入门槛满足且读到了互动状态。
    private var isWritable: Bool {
        model.engagement != nil && (actions?.isAvailable() ?? false)
    }

    /// 图标加紧凑计数；接口没给计数时显示动作名。
    ///
    /// 做过的图标用强调色。
    private func countLabel(
        _ count: Int64?,
        title: String,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        Label {
            Text(count.map { VideoMetadataFormatting.compactCount($0) } ?? title)
                .monospacedDigit()
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .labelStyle(.titleAndIcon)
    }

    /// 读屏的值：做过时的状态与计数，都没有时为空。
    private func accessibilityValue(_ state: String?, count: Int64?) -> String {
        let countText = count.map { VideoMetadataFormatting.compactCount($0) }
        return switch (state, countText) {
        case (let state?, let countText?):
            VideoDetailFeatureStrings.localized("\(state)，\(countText)")
        case (let state?, nil): state
        case (nil, let countText?): countText
        case (nil, nil): ""
        }
    }
}

/// 投币面板：选 1 或 2 枚（转载视频与只剩 1 枚可投时只有 1 枚），默认取能投的最多枚数；可同时点赞（已点赞时不出现）；
/// 已投满时只给说明。
///
/// 默认 2 枚是用户的选择：投币不可撤回，按 W 再按回车会直接投出 2 枚，改回 1 枚要先在分段控件里切换。
private struct VideoCoinPanel: View {
    let model: VideoEngagementModel
    let onSubmit: (_ count: Int, _ alsoLike: Bool) -> Void
    @State private var count: Int
    @State private var alsoLike = true

    init(model: VideoEngagementModel, onSubmit: @escaping (_ count: Int, _ alsoLike: Bool) -> Void)
    {
        self.model = model
        self.onSubmit = onSubmit
        // 分段控件只有能投的那几档，默认值必须是其中之一，否则控件没有选中项。
        _count = State(
            initialValue: max(1, min(VideoCoinPanelGeometry.defaultCount, model.remainingCoins))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VideoCoinPanelGeometry.spacing) {
            Text(VideoDetailFeatureStrings.localized("投币"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.remainingCoins == 0 {
                Text(VideoDetailFeatureStrings.localized("这个视频的投币已达上限。"))
                    .foregroundStyle(.secondary)
            } else {
                Picker(VideoDetailFeatureStrings.localized("硬币数量"), selection: $count) {
                    Text(VideoDetailFeatureStrings.localized("1 枚")).tag(1)
                    if model.remainingCoins >= 2 {
                        Text(VideoDetailFeatureStrings.localized("2 枚")).tag(2)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.engagement?.isLiked == false {
                    Toggle(VideoDetailFeatureStrings.localized("同时点赞"), isOn: $alsoLike)
                        .toggleStyle(.checkbox)
                }
                HStack {
                    Spacer()
                    Button(VideoDetailFeatureStrings.localized("投币")) {
                        onSubmit(
                            min(count, model.remainingCoins),
                            alsoLike && model.engagement?.isLiked == false
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(VideoCoinPanelGeometry.padding)
        .frame(width: VideoCoinPanelGeometry.width)
    }
}

/// 投币面板的几何与默认枚数。
private enum VideoCoinPanelGeometry {
    /// 打开面板时选中的枚数（能投的不足时取能投的最多枚数）。
    static let defaultCount = 2
    static let width: CGFloat = 220
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}

import SwiftUI

/// 播放页的分栏容器：视频在左上，详情与评论在视频下方，右栏是相关推荐（或盖在上面的 UP 主空间）。
///
/// 页面偏窄时右栏收进视频下方的分页。尺寸规则只在 `PlaybackPageGeometry`。
///
/// 三块内容在双栏、单栏之间切换时始终是同一棵视图树里的同一批子视图，只改位置与可见性：播放器宿主、详情区与右栏的
/// 原生列表都不会因分栏变化被拆掉重建（播放器宿主重建会让画面与弹幕时钟断开）。拥有两份界面状态：当前分栏（随尺寸
/// 变化，带滞后）与单栏时选中的分页；右栏上下文（空间）打开时切到右栏分页，让刚打开的内容可见。
///
/// `details` 与 `side` 收到“此刻是否可见”，被分页藏起时由内容自己真正隐藏原生视图（`isObscured`）。
public struct PlaybackPageView<Video: View, Details: View, Side: View>: View {
    private enum Tab: Hashable {
        case details
        case side
    }

    private let isSideContextOpen: Bool
    private let video: Video
    private let details: (Bool) -> Details
    private let side: (Bool) -> Side
    @State private var columns = PlaybackPageColumns.two
    @State private var selectedTab = Tab.details

    /// 建立分栏容器；`details` 与 `side` 的参数是此刻是否可见。
    ///
    /// `isSideContextOpen` 是右栏是否盖着上下文层（UP 主空间）：决定单栏分页的名字，打开时切到右栏分页。
    public init(
        isSideContextOpen: Bool,
        @ViewBuilder video: () -> Video,
        @ViewBuilder details: @escaping (Bool) -> Details,
        @ViewBuilder side: @escaping (Bool) -> Side
    ) {
        self.isSideContextOpen = isSideContextOpen
        self.video = video()
        self.details = details
        self.side = side
    }

    public var body: some View {
        // 两层 GeometryReader：外层按安全区（工具栏下方）布局，内层延伸到工具栏底下；两者在窗口里的顶边之差就是工具栏
        // 压住页面的高度。macOS 上延伸进工具栏的 GeometryReader 报告的 `safeAreaInsets.top` 是 0（实测），不能直接用。
        GeometryReader { safeArea in
            GeometryReader { proxy in
                page(
                    proxy: proxy,
                    topInset: safeArea.frame(in: .global).minY - proxy.frame(in: .global).minY
                )
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: isSideContextOpen) { _, isOpen in
            if isOpen { selectedTab = .side }
        }
    }

    private func page(proxy: GeometryProxy, topInset: CGFloat) -> some View {
        let contentSize = PlaybackPageGeometry.contentSize(for: proxy.size, topInset: topInset)
        // 首帧就按尺寸取分栏，不等几何回调写回状态；滞后的“当前值”仍来自状态。
        let columns = PlaybackPageGeometry.columns(for: contentSize, current: columns)
        let frames = PlaybackPageGeometry.frames(
            for: proxy.size,
            topInset: topInset,
            columns: columns
        )
        let showsDetails = columns == .two || selectedTab == .details
        let showsSide = columns == .two || selectedTab == .side
        return ZStack(alignment: .topLeading) {
            video
                .placed(in: frames.video)
            tabBar
                .placed(in: frames.tabBar)
                .opacity(columns == .single ? 1 : 0)
                .allowsHitTesting(columns == .single)
                .accessibilityHidden(columns != .single)
            separator(
                in: CGRect(
                    x: 0,
                    y: frames.tabBar.maxY,
                    width: frames.tabBar.width,
                    height: PlaybackPageGeometry.separatorThickness
                )
            )
            details(showsDetails)
                .placed(in: frames.details)
                .opacity(showsDetails ? 1 : 0)
                .allowsHitTesting(showsDetails)
                .accessibilityHidden(!showsDetails)
            side(showsSide)
                .placed(in: frames.side)
                .opacity(showsSide ? 1 : 0)
                .allowsHitTesting(showsSide)
                .accessibilityHidden(!showsSide)
            separator(in: frames.columnSeparator)
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        .onChange(of: contentSize, initial: true) { _, size in
            self.columns = PlaybackPageGeometry.columns(for: size, current: self.columns)
        }
    }

    private var tabBar: some View {
        Picker(VideoDetailFeatureStrings.localized("播放页分页"), selection: $selectedTab) {
            Text(VideoDetailFeatureStrings.localized("详情")).tag(Tab.details)
            Text(
                isSideContextOpen
                    ? VideoDetailFeatureStrings.localized("UP 主投稿")
                    : VideoDetailFeatureStrings.localized("相关推荐")
            )
            .tag(Tab.side)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func separator(in frame: CGRect) -> some View {
        Rectangle()
            .fill(.separator)
            .placed(in: frame)
    }
}

extension View {
    /// 按 `PlaybackPageGeometry` 给出的矩形摆放。
    ///
    /// 用 `position` 而不是 `offset`：子视图的布局位置就是它真正的位置，安全区（工具栏压住的高度）与 AppKit 子视图的
    /// frame 都按它计算；`offset` 只平移绘制，安全区仍按原点算。
    fileprivate func placed(in frame: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

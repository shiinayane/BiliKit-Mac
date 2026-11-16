import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 关注来源的根视图：共用的资料库外壳（登录门槛、工具栏控件与刷新）里放人物卡片网格，并把页面可见性交给列表模型。
///
/// `.task` 在内容出现时调用会话的 `activate()` 并等待当前请求；条件（选中的行、排序、关键词）变化由会话直接重新加载。离开
/// 来源的停用由 App 经来源描述通知（`FollowListSession.deactivateRoute`），空间页与播放页只是覆盖本页面，不停用。排序菜单与搜索框由 App 宿主（`toolbarControls` 与
/// `.searchable`），导航标题也在 App。点卡片交出这个人（App 压一层整页空间页）。
public struct FollowListView: View {
    /// 点卡片交出的这个人。
    public typealias Selection = (VideoOwner) -> Void

    @Environment(\.locale) private var locale
    private let session: FollowListSession
    private let accountState: AccountPresentationState
    private let gridHost: NativeVideoGridHostContext
    private let onSelect: (VideoOwner) -> Void
    private let onPresentAuthentication: () -> Void
    private let toolbarControls: AnyView

    public init(
        session: FollowListSession,
        accountState: AccountPresentationState,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (VideoOwner) -> Void,
        onPresentAuthentication: @escaping () -> Void,
        toolbarControls: AnyView
    ) {
        self.session = session
        self.accountState = accountState
        self.gridHost = gridHost
        self.onSelect = onSelect
        self.onPresentAuthentication = onPresentAuthentication
        self.toolbarControls = toolbarControls
    }

    public var body: some View {
        let model = session.model
        LibrarySourceShell(
            accountState: accountState,
            signInTitle: LibraryFeatureStrings.localized("登录后查看关注", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "关注列表只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: toolbarControls,
            isBusy: { model.isBusy },
            refresh: model.reload,
            content: {
                LibraryListContentView(
                    model: model,
                    text: text,
                    loading: {
                        // 人物卡片矮、每屏条数多，骨架占位意义不大；与空间页的第一批一样直接转圈。
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(text.loading)
                            .revealsAfterLoadingDelay()
                    },
                    grid: { users, tailState in
                        FollowPersonGrid(
                            users: users,
                            tailState: tailState,
                            showsRelation: session.isShowingAllFollowings,
                            accessibilityLabel: text.gridAccessibilityLabel,
                            gridHost: gridHost,
                            onNearEnd: model.loadMore,
                            onSelect: onSelect
                        )
                    }
                )
                .task {
                    session.activate()
                    await model.waitForCurrentTask()
                }
            }
        )
    }

    private var text: LibraryVideoListText {
        LibraryVideoListText(
            signInTitle: LibraryFeatureStrings.localized("登录后查看关注", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "关注列表只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            loading: LibraryFeatureStrings.localized("正在加载关注", locale: locale),
            emptyTitle: emptyTitle,
            emptySymbol: "person.2",
            emptyDescription: emptyDescription,
            failureTitle: LibraryFeatureStrings.localized("无法加载关注", locale: locale),
            refreshing: LibraryFeatureStrings.localized("正在刷新关注", locale: locale),
            loadingMore: LibraryFeatureStrings.localized("正在加载更多…", locale: locale),
            gridAccessibilityLabel: LibraryFeatureStrings.localized("关注的人", locale: locale),
            manualContinue: nil
        )
    }

    private var emptyTitle: String {
        if !session.isShowingAllFollowings {
            LibraryFeatureStrings.localized("这个分组里还没有人", locale: locale)
        } else if !session.appliedKeyword.isEmpty {
            LibraryFeatureStrings.localized("没有找到相关的人", locale: locale)
        } else {
            LibraryFeatureStrings.localized("还没有关注的人", locale: locale)
        }
    }

    private var emptyDescription: String {
        if !session.isShowingAllFollowings {
            LibraryFeatureStrings.localized("在分组里加入的人会显示在这里。", locale: locale)
        } else if !session.appliedKeyword.isEmpty {
            LibraryFeatureStrings.localized("试试别的名字。", locale: locale)
        } else {
            LibraryFeatureStrings.localized("在哔哩哔哩关注的人会显示在这里。", locale: locale)
        }
    }
}

/// 关注页的人物卡片网格：每人一张卡片，点卡片交出这个人；右键菜单是「已关注」菜单的三项加空间链接。
///
/// 互相关注与特别关注只在 `showsRelation`（全部关注与搜索）时显示：分组成员接口不给这两项（见 `FollowedUser`）。特别关注
/// 与菜单的状态取自窗口的关系存储（经 `VideoCardAccountWriting.followSpecialState`，它记着每一页读到的关系与写入确认的值），
/// 写入成功后不必重读这一页就会更新；存储不知道或没有注入写入口（预览、测试）时按卡片自己的分组。
private struct FollowPersonGrid: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var writing
    let users: [FollowedUser]
    let tailState: NativeVideoGridTailState
    let showsRelation: Bool
    let accessibilityLabel: String
    let gridHost: NativeVideoGridHostContext
    let onNearEnd: () -> Void
    let onSelect: (VideoOwner) -> Void
    /// 卡片展示数据按位置缓存，加载更多时只生成新追加的卡片，见 `NativeGridCardCache`。
    @State private var cards = NativeGridCardCache<CardSource, NativePersonCardPresentation>()

    /// 决定一张卡片外观的全部输入：这个人、是否显示关系与是否特别关注（取自关系存储，写入后会变）。
    struct CardSource: Equatable {
        let user: FollowedUser
        let showsRelation: Bool
        let isSpecial: Bool
    }

    var body: some View {
        NativeGridView<NativePersonCardKind>(
            items: cards.cards(
                for: users.map {
                    CardSource(
                        user: $0,
                        showsRelation: showsRelation,
                        isSpecial: showsRelation && isSpecial($0) == true
                    )
                },
                make: card
            ),
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            host: gridHost,
            onNearEnd: onNearEnd,
            onSelect: select,
            cardMenu: menu
        )
    }

    private func card(_ source: CardSource) -> NativePersonCardPresentation {
        let user = source.user
        return NativePersonCardPresentation(
            id: String(user.id),
            name: UploaderProfileUseCase.singleLine(user.name) ?? "",
            avatarURL: user.avatarURL,
            isVIP: user.isVIP,
            subtitle: subtitle(user),
            mutualBadge: source.showsRelation && user.isMutual == true
                ? LibraryFeatureStrings.localized("互相关注", locale: locale) : nil,
            specialLabel: source.isSpecial
                ? LibraryFeatureStrings.localized("特别关注", locale: locale) : nil
        )
    }

    private func isSpecial(_ user: FollowedUser) -> Bool? {
        writing?.followSpecialState(user.id) ?? user.membership?.isSpecial
    }

    /// 有认证时显示认证说明（比签名更能说明这是谁），否则显示签名；都没有就不显示这一行。
    ///
    /// 与名字一样经 `UploaderProfileUseCase.singleLine` 规整成一行（与播放页侧栏的签名同一规则）：签名常带换行，卡片只排一行。
    private func subtitle(_ user: FollowedUser) -> String? {
        UploaderProfileUseCase.singleLine(user.officialDescription)
            ?? UploaderProfileUseCase.singleLine(user.signature)
    }

    private func select(_ cardID: String) {
        guard let user = users.first(where: { String($0.id) == cardID }) else { return }
        onSelect(VideoOwner(id: user.id, name: user.name, avatarURL: user.avatarURL))
    }

    private func menu(_ card: NativePersonCardPresentation) -> NativeVideoCardMenu? {
        guard let mid = Int64(card.id), let url = UploaderSpaceWebLink.url(mid: mid) else {
            return nil
        }
        let following =
            writing.map { writing in
                NativeVideoCardMenu.Item.following(writing.followingMenu(mid: mid)) { action in
                    writing.perform(action, mid: mid)
                }
            } ?? []
        return NativeVideoCardMenu(
            sections: [
                following,
                NativeVideoCardMenu.Item.webLinks(
                    isActivatable: true,
                    webPageURL: url,
                    openURL: openURL
                )
            ]
        )
    }
}

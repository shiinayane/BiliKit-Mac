import BiliApplication
import BiliModels

/// 侧栏「收藏夹」组的呈现状态；`loaded` 是按接口顺序的收藏夹，至少含一个默认收藏夹（`FavoritesUseCase` 校验）。
public typealias FavoriteFolderListState = LibrarySidebarListState<[FavoriteFolder]>

/// 当前账户自己创建的收藏夹列表：侧栏「收藏夹」组的行、夹内页面的标题与选中回落都读它。
///
/// 加载、账户绑定与复核是侧栏各组共用的 `LibrarySidebarListModel`；选中的收藏夹与夹内内容归 `FavoriteFolderViewModel`。
public typealias FavoriteFolderListModel = LibrarySidebarListModel<[FavoriteFolder]>

extension LibrarySidebarListModel where Value == [FavoriteFolder] {
    public convenience init(
        useCase: FavoritesUseCase,
        accountScope: @escaping @MainActor () -> AccountSessionScope
    ) {
        self.init(accountScope: accountScope) { try await useCase.folders(ownerID: $0) }
    }

    /// 已加载的收藏夹；其他状态为空。
    public var folders: [FavoriteFolder] { loadedValue ?? [] }
}

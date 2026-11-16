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

    /// 收藏写入成功：加入的收藏夹各加一条、移出的各减一条。
    ///
    /// 不低于 0，列表里没有的夹忽略；宽限期后补读（见 `adjustAfterWrite`）。由 App 的写入效果路由调用。
    public func membershipDidChange(added: some Sequence<Int64>, removed: some Sequence<Int64>) {
        var deltas: [Int64: Int] = [:]
        for id in added { deltas[id, default: 0] += 1 }
        for id in removed { deltas[id, default: 0] -= 1 }
        adjustAfterWrite { folders in
            folders.map { folder in
                guard let delta = deltas[folder.id] else { return folder }
                return FavoriteFolder(
                    id: folder.id,
                    title: folder.title,
                    mediaCount: max(0, folder.mediaCount + delta),
                    isPrivate: folder.isPrivate,
                    isDefault: folder.isDefault
                )
            }
        }
    }

    /// 收藏写入成功、但改了哪些夹不知道（三连收藏进默认收藏夹，写前可能已在）：不在本地改，只等宽限期后补读。
    public func membershipDidChangeUnknown() {
        adjustAfterWrite { _ in nil }
    }
}

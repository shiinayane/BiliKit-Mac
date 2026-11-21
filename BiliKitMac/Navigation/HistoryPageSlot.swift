import BiliVideoDetailFeature
import Observation

/// 历史里一种浏览类页面（整页空间页等）的内容模型；协调器经 `HistoryPageSlot` 每种只持有一份。
///
/// 由 `AppNavigationCoordinator` 调用：显示某一项时 `openPage`，模型要被另一项占用前 `capturePage`，占用它的那一项
/// 离开历史时 `closePage`。模型自己也可能被关掉（认证会话切换），`isPageClosed` 让协调器回到这一项时重新打开。
@MainActor
protocol HistoryPageModel: AnyObject {
    associatedtype Destination: Equatable

    /// 模型已关闭：还没打开过、被协调器关掉，或被认证会话切换关掉。
    var isPageClosed: Bool { get }
    /// 按这一项记下的条件从第一批重建。
    func openPage(_ destination: Destination)
    /// 把模型此刻在页面上改过的条件（排序、搜索词等）写回这一项。
    func capturePage(into destination: inout Destination)
    func closePage()
}

/// 一种浏览类页面在历史里的那一份活模型，以及此刻占用它的历史项。
///
/// 拥有“模型属于哪一项”（`liveEntryID`）；不拥有历史栈（协调器传入快照，写回由协调器执行）与模型的请求（模型自己
/// 的 Task）。历史里同一种页面可以有不止一项（播放页 → 空间页 → 播放页 → 空间页），模型只有一份：换到另一项时先把
/// 它此刻的条件写回原来那一项，回到那一项时按写回的条件重建，所以回去时从第一批重新加载，滚动位置不保留。
@MainActor
@Observable
final class HistoryPageSlot<Model: HistoryPageModel> {
    @ObservationIgnored let model: Model
    /// 此刻占用模型的历史项；没有时为 nil。
    ///
    /// 外壳按它区分网格保活与滚动位置。
    private(set) var liveEntryID: UInt64?
    @ObservationIgnored private let extract: (AppDestination) -> Model.Destination?
    @ObservationIgnored private let embed: (Model.Destination) -> AppDestination

    /// - Parameters:
    ///   - model: 这种页面唯一的那份内容模型。
    ///   - extract: 从历史项取出这种页面的条件；不是这种页面时为 nil。
    ///   - embed: 把条件包回历史项。
    init(
        model: Model,
        extract: @escaping (AppDestination) -> Model.Destination?,
        embed: @escaping (Model.Destination) -> AppDestination
    ) {
        self.model = model
        self.extract = extract
        self.embed = embed
    }

    /// 这一项是不是这种页面。
    func owns(_ destination: AppDestination) -> Bool {
        extract(destination) != nil
    }

    /// 回到 `entryID` 那一项时是否要重建：模型属于别的项，或被会话切换关掉（不重建就只看到骨架屏）。
    func needsShowing(entryID: UInt64) -> Bool {
        liveEntryID != entryID || model.isPageClosed
    }

    /// 让模型显示这一项；`destination` 不是这种页面时不动作。
    ///
    /// 先取出模型当前的条件写回原来占用它的那一项（返回值，由调用方写进历史），再按这一项的条件重建。模型仍属于
    /// 这一项时（原地替换、关掉后重开）不写回：那一项已经是新的条件，模型里的是旧内容或已关闭的默认值。
    func show(
        _ destination: AppDestination,
        entryID: UInt64,
        history: [AppHistoryEntry]
    ) -> HistoryDestinationUpdate? {
        guard let pageDestination = extract(destination) else { return nil }
        let update = liveEntryID == entryID ? nil : capture(from: history)
        model.openPage(pageDestination)
        liveEntryID = entryID
        return update
    }

    /// 模型此刻的条件写回占用它的那一项后的样子；那一项已不在历史里或条件没变时为 nil。
    func capture(from history: [AppHistoryEntry]) -> HistoryDestinationUpdate? {
        guard let liveEntryID,
            let index = history.firstIndex(where: { $0.id == liveEntryID }),
            var pageDestination = extract(history[index].destination)
        else { return nil }
        model.capturePage(into: &pageDestination)
        let captured = embed(pageDestination)
        guard captured != history[index].destination else { return nil }
        return HistoryDestinationUpdate(index: index, destination: captured)
    }

    /// 占用模型的那一项已不在历史里（被弹出或清空）时关闭模型；外壳随 `liveEntryID` 变为 nil 丢弃保活里的那份网格。
    func closeIfUnused(history: [AppHistoryEntry]) {
        guard let liveEntryID, !history.contains(where: { $0.id == liveEntryID }) else { return }
        self.liveEntryID = nil
        model.closePage()
    }
}

/// 写回历史里某一项的条件；由协调器写进历史，`HistoryPageSlot` 不持有历史。
struct HistoryDestinationUpdate {
    let index: Int
    let destination: AppDestination
}

extension UploaderSpaceViewModel: HistoryPageModel {
    var isPageClosed: Bool { owner == nil }

    func openPage(_ destination: UploaderSpaceDestination) {
        open(
            owner: destination.owner,
            order: destination.order,
            searchKeyword: destination.searchKeyword
        )
    }

    func capturePage(into destination: inout UploaderSpaceDestination) {
        destination.order = order
        destination.searchKeyword = searchKeyword
    }

    func closePage() {
        close()
    }
}

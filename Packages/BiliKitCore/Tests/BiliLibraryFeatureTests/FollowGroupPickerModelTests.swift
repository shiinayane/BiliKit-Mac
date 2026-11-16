import BiliApplication
import BiliModels
import Testing

@testable import BiliLibraryFeature

/// 「设置分组…」面板以这个人此刻的完整分组为底：特别关注排第一、默认分组不列出；勾选与底相同、底还没读到或同一个人的写入
/// 在途时没有可提交的内容；底变了（其他窗口确认了新值）勾选回到新底；列表里没有的分组仍在提交的集合里。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FollowGroupPickerModelTests {
    fileprivate static let groups = [
        FollowGroup(id: FollowGroup.specialID, name: "特别关注", count: 1),
        FollowGroup(id: 5, name: "游戏", count: 2),
        FollowGroup(id: FollowGroup.defaultID, name: "默认分组", count: 3)
    ]

    @Test
    func submitsTheWholeSetOnlyWhenTheSelectionDiffersFromTheBase() throws {
        let state = PickerState(
            base: .loaded(FollowMembership(isSpecial: false, customGroupIDs: [5, 9]))
        )
        let picker = state.makePicker()
        let special = try #require(picker.rows.first)

        #expect(picker.rows.map(\.id) == [FollowGroup.specialID, 5])
        #expect(picker.submission == nil)

        picker.setSelected(true, row: special)
        // 列表里没有的分组 9 不显示，但不会被这次提交去掉。
        #expect(picker.submission == FollowMembership(isSpecial: true, customGroupIDs: [5, 9]))
        picker.setSelected(false, row: special)
        #expect(picker.submission == nil)
    }

    @Test
    func nothingIsSubmittedWithoutABaseOrWhileAWriteIsInFlight() throws {
        let state = PickerState(base: .unavailable)
        let picker = state.makePicker()
        let special = try #require(picker.rows.first)

        picker.setSelected(true, row: special)
        #expect(picker.selection == nil)
        #expect(picker.submission == nil)

        state.base = .loaded(.defaultGroupOnly)
        picker.setSelected(true, row: special)
        state.isWriteInFlight = true
        #expect(picker.isBlockedByWriteInFlight)
        #expect(picker.submission == nil)
    }

    /// 草稿配着它的底：底被别的写入改了，勾选回到新底，不拿旧底上的勾选覆盖别人的改动。
    @Test
    func aNewBaseDiscardsTheDraft() throws {
        let state = PickerState(base: .loaded(.defaultGroupOnly))
        let picker = state.makePicker()
        let custom = try #require(picker.rows.last)

        picker.setSelected(true, row: custom)
        let confirmed = FollowMembership(isSpecial: true, customGroupIDs: [])
        state.base = .loaded(confirmed)

        #expect(picker.selection == confirmed)
        #expect(picker.submission == nil)
    }
}

/// 面板读的外部状态：底与同一个人的写入是否在途，测试直接改它。
@MainActor
private final class PickerState {
    var base: FollowGroupPickerModel.Base
    var isWriteInFlight = false

    init(base: FollowGroupPickerModel.Base) {
        self.base = base
    }

    func makePicker() -> FollowGroupPickerModel {
        FollowGroupPickerModel(
            mid: 1,
            base: { [unowned self] in base },
            groups: { FollowGroupPickerModelTests.groups },
            isWriteInFlight: { [unowned self] in isWriteInFlight }
        )
    }
}

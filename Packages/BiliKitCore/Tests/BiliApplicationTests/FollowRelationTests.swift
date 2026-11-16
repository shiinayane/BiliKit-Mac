import BiliApplication
import BiliModels
import Testing

/// 写入之后的宽限期内按确认值纠正读到的关系、人数与分组成员，宽限期过后信任服务端。
///
/// 与确认值矛盾的单人关系按确认值、人数读取丢弃并在宽限期结束后补读、成员页去掉确认已离开的人。特别关注与设置分组只对别人
/// 发出，原样交出要设置的完整分组，效果带写前分组。
@Suite(.timeLimit(.minutes(1)))
struct FollowRelationTests {
    private static let written = ContinuousClock.now
    private static let withinGrace = written.advanced(by: .seconds(5))
    private static let afterGrace = written.advanced(by: FollowRelationLedger.relationReadLagGrace)
    private static let groupA = FollowMembership(isSpecial: false, customGroupIDs: [5])
    private static let specialAndA = FollowMembership(isSpecial: true, customGroupIDs: [5])

    /// 「设置分组…」以读到的关系为底、按完整集合覆盖：宽限期内读到旧值作底，会把刚加入的分组悄悄抹掉。
    @Test
    func readsWithinGraceTakeTheConfirmedValueAndLaterReadsTheServer() {
        var ledger = FollowRelationLedger()
        ledger.confirm(.following(Self.specialAndA), for: 1, at: Self.written)
        ledger.confirm(.notFollowing, for: 2, at: Self.written)
        ledger.confirm(.followingWithUnknownGroups(isSpecial: false), for: 3, at: Self.written)
        let stale = FollowRelation.following(Self.groupA)

        #expect(
            ledger.reconciled(stale, for: 1, at: Self.withinGrace) == .following(Self.specialAndA)
        )
        #expect(ledger.reconciled(stale, for: 2, at: Self.withinGrace) == .notFollowing)
        // 只确认了特别关注：读到的自定义分组照用，特别关注按确认值。
        #expect(
            ledger.reconciled(.following(Self.specialAndA), for: 3, at: Self.withinGrace)
                == .following(Self.groupA)
        )
        #expect(ledger.reconciled(stale, for: 4, at: Self.withinGrace) == stale)
        #expect(ledger.reconciled(stale, for: 1, at: Self.afterGrace) == stale)
    }

    /// 关注页的补读等到最近一次确认的宽限期结束：结束时刻随新的确认延后，过了就没有宽限期。
    @Test
    func theGraceEndsAfterTheLatestConfirmation() {
        var ledger = FollowRelationLedger()
        #expect(ledger.graceEnd(at: Self.written) == nil)

        ledger.confirm(.following(Self.groupA), for: 1, at: Self.written)
        ledger.confirm(.notFollowing, for: 2, at: Self.withinGrace)

        let end = Self.withinGrace.advanced(by: FollowRelationLedger.relationReadLagGrace)
        #expect(ledger.graceEnd(at: Self.afterGrace) == end)
        #expect(ledger.graceEnd(at: end) == nil)
    }

    /// 分组页去掉确认已不在这个分组的人，刚加入的人不插入；全部关注换上确认的分组、去掉已取消关注的人。
    @Test
    func pagesWithinGraceDropPeopleWhoLeftAndTakeConfirmedGroups() {
        var ledger = FollowRelationLedger()
        ledger.confirm(.following(Self.specialAndA), for: 1, at: Self.written)
        ledger.confirm(.notFollowing, for: 2, at: Self.written)
        ledger.confirm(.following(.defaultGroupOnly), for: 3, at: Self.written)
        let groupPage = [1, 2, 3, 4].map { FollowedUser(id: $0, name: "\($0)") }
        let allPage = [1, 2, 4].map {
            FollowedUser(id: $0, name: "\($0)", membership: .defaultGroupOnly)
        }

        #expect(
            ledger.reconciled(groupPage, in: .group(5), at: Self.withinGrace).map(\.id) == [1, 4]
        )
        #expect(
            ledger.reconciled(groupPage, in: .group(FollowGroup.defaultID), at: Self.withinGrace)
                .map(\.id) == [3, 4]
        )
        let all = ledger.reconciled(allPage, in: .all(.recentlyFollowed), at: Self.withinGrace)
        #expect(all.map(\.id) == [1, 4])
        #expect(all.first?.membership == Self.specialAndA)
        #expect(ledger.reconciled(groupPage, in: .group(5), at: Self.afterGrace) == groupPage)
    }

    /// 关注页的一页说明了什么：分组成员接口不给分组，默认分组与特别关注页按分组本身推出能推出的部分；更新时保留不矛盾的更多信息。
    @Test
    func pagesImplyWhatTheyCanAndMergingKeepsConsistentDetail() {
        let user = FollowedUser(id: 1, name: "甲")

        #expect(
            FollowRelation.implied(by: user, in: .group(FollowGroup.defaultID))
                == .following(.defaultGroupOnly)
        )
        #expect(
            FollowRelation.implied(by: user, in: .group(FollowGroup.specialID))
                == .followingWithUnknownGroups(isSpecial: true)
        )
        let special = FollowListQuery.group(FollowGroup.specialID)
        #expect(
            FollowRelation.merging(
                .followingWithUnknownGroups(isSpecial: true),
                over: .following(Self.specialAndA),
                in: special
            ) == .following(Self.specialAndA)
        )
        #expect(
            FollowRelation.merging(
                .followingWithUnknownGroups(isSpecial: true),
                over: .following(Self.groupA),
                in: special
            ) == .followingWithUnknownGroups(isSpecial: true)
        )
        // 自定义分组页说明这个人在这个分组里：已知的完整分组不含它就是过时的，只留下特别关注。
        #expect(
            FollowRelation.merging(
                .followingWithUnknownGroups(isSpecial: nil),
                over: .following(Self.specialAndA),
                in: .group(5)
            ) == .following(Self.specialAndA)
        )
        #expect(
            FollowRelation.merging(
                .followingWithUnknownGroups(isSpecial: nil),
                over: .following(Self.specialAndA),
                in: .group(9)
            ) == .followingWithUnknownGroups(isSpecial: true)
        )
    }

    @Test
    func writesCarryTheBeforeMembershipAndPassTheWholeSetThrough() async throws {
        let repository = FollowRelationWriteRepositoryStub()
        let useCase = FollowRelationWriteUseCase(repository: repository)
        let uploader = try #require(UploaderWriteTarget(mid: 7))

        let special = try await useCase.setSpecial(
            true,
            uploader: uploader,
            accountID: 42,
            before: Self.groupA
        )
        let groups = try await useCase.assignGroups(
            .defaultGroupOnly,
            uploader: uploader,
            accountID: 42,
            before: Self.specialAndA
        )

        #expect(
            special.change == .followSpecialChanged(uploader, isSpecial: true, before: Self.groupA)
        )
        #expect(
            groups.change
                == .followGroupsChanged(
                    uploader,
                    before: Self.specialAndA,
                    after: .defaultGroupOnly
                )
        )
        #expect(
            await repository.calls == [
                "special true 7 42", "groups \(FollowMembership.defaultGroupOnly) 7 42"
            ]
        )
    }

    @Test
    func writingYourselfOrNothingChangedSendsNothing() async throws {
        let repository = FollowRelationWriteRepositoryStub()
        let useCase = FollowRelationWriteUseCase(repository: repository)
        let yourself = try #require(UploaderWriteTarget(mid: 42))
        let other = try #require(UploaderWriteTarget(mid: 7))

        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.setSpecial(true, uploader: yourself, accountID: 42, before: nil)
        }
        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.assignGroups(
                Self.groupA,
                uploader: yourself,
                accountID: 42,
                before: .defaultGroupOnly
            )
        }
        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.assignGroups(
                Self.groupA,
                uploader: other,
                accountID: 42,
                before: Self.groupA
            )
        }
        #expect(await repository.calls.isEmpty)
    }
}

/// 关注关系写入 port 的替身：记录每次写入（分组原样记下，编码不归 use case）。
private actor FollowRelationWriteRepositoryStub: FollowRelationWriteRepository {
    private(set) var calls: [String] = []

    func setSpecial(_ isSpecial: Bool, uploader: UploaderWriteTarget, accountID: Int64) async throws
    {
        calls.append("special \(isSpecial) \(uploader.mid) \(accountID)")
    }

    func assignGroups(
        _ membership: FollowMembership,
        uploader: UploaderWriteTarget,
        accountID: Int64
    ) async throws {
        calls.append("groups \(membership) \(uploader.mid) \(accountID)")
    }
}

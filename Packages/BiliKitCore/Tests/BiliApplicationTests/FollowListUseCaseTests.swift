import BiliModels
import Testing

@testable import BiliApplication

/// 固定关注列表的读取规则：全部关注与搜索按总人数到底、分组成员按接口原始行数不满一页到底；侧栏顺序是特别关注、
/// 自定义分组、默认分组；关键词规范化后为空或超长时不发搜索。
struct FollowListUseCaseTests {
    @Test(arguments: [
        // （本页人数、总数、页码、是否到底）
        (50, 120, 1, false),
        (50, 120, 2, false),
        (20, 120, 3, true),
        (50, 100, 2, true),
        (0, 120, 2, true)
    ])
    func allFollowingsEndByTotal(count: Int, total: Int, page: Int, reachesEnd: Bool) async throws {
        let useCase = FollowListUseCase(
            repository: StubFollowListRepository(
                page: FollowListRemotePage(users: users(count), rowCount: count, totalCount: total)
            )
        )

        let result = try await useCase.page(
            FollowListCursor(query: .all(.mostVisited), page: page),
            ownerID: 7
        )

        #expect(result.totalCount == total)
        #expect(
            result.page.nextCursor
                == (reachesEnd ? nil : FollowListCursor(query: .all(.mostVisited), page: page + 1))
        )
    }

    /// 满 50 行里有被丢掉的无效行时不算到底。
    @Test(arguments: [
        // （有效人数、接口行数、是否到底）
        (50, 50, false),
        (48, 50, false),
        (49, 49, true),
        (0, 0, true)
    ])
    func groupMembersEndOnAShortPage(count: Int, rows: Int, reachesEnd: Bool) async throws {
        let useCase = FollowListUseCase(
            repository: StubFollowListRepository(
                page: FollowListRemotePage(users: users(count), rowCount: rows, totalCount: nil)
            )
        )

        let result = try await useCase.page(FollowListCursor(query: .group(5)), ownerID: 7)

        #expect(
            result.page.nextCursor
                == (reachesEnd ? nil : FollowListCursor(query: .group(5), page: 2))
        )
    }

    /// 接口把默认分组排在自定义分组之前；侧栏把它放到最后。
    @Test
    func groupsListSpecialThenCustomThenDefault() async throws {
        let useCase = FollowListUseCase(
            repository: StubFollowListRepository(groups: [
                FollowGroup(id: FollowGroup.specialID, name: "特别关注", count: 1),
                FollowGroup(id: FollowGroup.defaultID, name: "默认分组", count: 9),
                FollowGroup(id: 30, name: "游戏", count: 2),
                FollowGroup(id: 20, name: "科普", count: 3)
            ])
        )

        #expect(try await useCase.groups(ownerID: 7).map(\.id) == [-10, 30, 20, 0])
    }

    @Test(arguments: ["", "   ", String(repeating: "字", count: SearchText.maximumLength + 1)])
    func blankOrOverlongKeywordsDoNotSearch(keyword: String) {
        #expect(FollowListUseCase.searchCursor(for: keyword) == nil)
    }

    @Test
    func keywordIsNormalizedBeforeSearching() {
        #expect(
            FollowListUseCase.searchCursor(for: "  极客 ") == FollowListCursor(query: .search("极客"))
        )
    }

    private func users(_ count: Int) -> [FollowedUser] {
        (0..<count).map { FollowedUser(id: Int64($0 + 1), name: "UP \($0)") }
    }
}

/// 本 Suite 的 `FollowListRepository` 替身：返回给定的分组与一页结果。
private struct StubFollowListRepository: FollowListRepository {
    var groups: [FollowGroup] = []
    var page = FollowListRemotePage(users: [], rowCount: 0, totalCount: nil)

    func groups(ownerID: Int64) async throws -> [FollowGroup] { groups }
    func followingCount(ownerID: Int64) async throws -> Int { page.totalCount ?? 0 }
    func page(
        _ cursor: FollowListCursor,
        ownerID: Int64,
        pageSize: Int
    ) async throws
        -> FollowListRemotePage
    { page }
    func relation(to mid: Int64) async throws -> FollowMembership? { nil }
}

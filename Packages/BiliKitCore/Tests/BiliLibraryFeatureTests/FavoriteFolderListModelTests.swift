import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 收藏夹列表按窗口账户范围读取（mid 来自账户范围，已加载时不重复请求，换 mid 先丢弃），mid 未知时给说明、未登录时
/// 丢弃，范围无法确认时不动作；凭据可疑请求复核，复核后至多自动重载一次，不无限复核；已有列表时重读保留原有的行；账户
/// 变化与 `reset` 丢弃列表。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FavoriteFolderListModelTests {
    @Test
    func signedInWindowLoadsTheAccountsFoldersOnce() async {
        let repository = FavoritesRepositoryStub()
        let model = makeModel(repository, scope: .signedIn(accountID: 7))

        model.synchronize()
        await waitUntilSettled(model)
        model.synchronize()

        #expect(model.state == .loaded(standardFolders))
        #expect(await repository.ownerIDs == [7])
    }

    @Test
    func unknownAccountShowsTheExplanationWithoutReading() async {
        let repository = FavoritesRepositoryStub()
        let model = makeModel(repository, scope: .signedIn(accountID: nil))

        model.synchronize()

        #expect(model.state == .accountUnidentified)
        #expect(await repository.ownerIDs.isEmpty)
    }

    /// 账户范围无法确认（认证仍在确认、或其他窗口换号而本窗口还没复核到）：不读取，也不丢弃已有的列表。
    @Test
    func unresolvedScopeNeitherReadsNorDiscards() async {
        let repository = FavoritesRepositoryStub()
        let window = WindowScope(.signedIn(accountID: 7))
        let model = FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { window.scope }
        )
        model.synchronize()
        await waitUntilSettled(model)

        window.scope = .unresolved
        model.synchronize()
        model.reload()

        #expect(model.state == .loaded(standardFolders))
        #expect(await repository.ownerIDs == [7])
    }

    @Test
    func signingOutDiscardsTheFolders() async {
        let repository = FavoritesRepositoryStub()
        let window = WindowScope(.signedIn(accountID: 7))
        let model = FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { window.scope }
        )
        model.synchronize()
        await waitUntilSettled(model)

        window.scope = .signedOut
        model.synchronizeAuthenticationSession()

        #expect(model.state == .idle)
        #expect(model.folders.isEmpty)
        #expect(await repository.ownerIDs == [7])
    }

    @Test
    func anotherAccountReplacesTheFolders() async {
        let repository = FavoritesRepositoryStub()
        let window = WindowScope(.signedIn(accountID: 7))
        let model = FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { window.scope }
        )
        model.synchronize()
        await waitUntilSettled(model)

        window.scope = .signedIn(accountID: 8)
        model.synchronize()
        await waitUntilSettled(model)

        #expect(await repository.ownerIDs == [7, 8])
        #expect(model.state == .loaded(standardFolders))
    }

    /// 自己视角下没有默认收藏夹（Cookie 悄悄退化为访客视角）：请求复核，确认仍登录后重载一次；仍然如此时只显示可重试的
    /// 失败，不再自动重载。
    @Test
    func suspiciousListRevalidatesAndReloadsAtMostOnce() async {
        let repository = FavoritesRepositoryStub(folders: .success([]))
        let model = makeModel(repository, scope: .signedIn(accountID: 7))

        model.synchronize()
        await waitUntilSettled(model)
        #expect(model.state == .failed(.authenticationInvalid))
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.isAwaitingAuthenticationRevalidation)

        model.authenticationRevalidationSucceeded()
        await waitUntilSettled(model)
        #expect(model.authenticationRevalidationGeneration == 2)

        model.authenticationRevalidationSucceeded()
        await waitUntilSettled(model)

        #expect(await repository.ownerIDs == [7, 7])
        #expect(model.state == .failed(.authenticationInvalid))

        await repository.setFolders(.success(standardFolders))
        model.reload()
        await waitUntilSettled(model)
        #expect(model.state == .loaded(standardFolders))
    }

    /// 已有列表时重读保留原有的行：成功整体替换，普通失败保留旧列表，凭据失败放弃旧列表。
    @Test
    func reloadKeepsTheRowsUntilTheNewListArrives() async {
        let repository = FavoritesRepositoryStub()
        let model = makeModel(repository, scope: .signedIn(accountID: 7))
        model.synchronize()
        await waitUntilSettled(model)

        model.reload()
        #expect(model.state == .loaded(standardFolders))
        #expect(model.isRefreshing)
        await waitUntilSettled(model)
        #expect(await repository.ownerIDs == [7, 7])

        await repository.setFolders(.failure(.transportFailure))
        model.reload()
        await waitUntilSettled(model)
        #expect(model.state == .loaded(standardFolders))

        await repository.setFolders(.failure(.authenticationInvalid))
        model.reload()
        await waitUntilSettled(model)
        #expect(model.state == .failed(.authenticationInvalid))
        #expect(model.authenticationRevalidationGeneration == 1)
    }

    @Test
    func failedRevalidationOffersARetryableFailure() async {
        let repository = FavoritesRepositoryStub(folders: .failure(.authenticationInvalid))
        let model = makeModel(repository, scope: .signedIn(accountID: 7))
        model.synchronize()
        await waitUntilSettled(model)

        model.authenticationRevalidationFailed()

        #expect(model.state == .failed(.authenticationUnavailable))
        #expect(!model.isAwaitingAuthenticationRevalidation)
    }

    @Test
    func resetDiscardsTheListButKeepsTheRevalidationGeneration() async {
        let repository = FavoritesRepositoryStub(folders: .failure(.authenticationInvalid))
        let model = makeModel(repository, scope: .signedIn(accountID: 7))
        model.synchronize()
        await waitUntilSettled(model)

        model.reset()

        #expect(model.state == .idle)
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(!model.isAwaitingAuthenticationRevalidation)
    }

    private func makeModel(
        _ repository: FavoritesRepositoryStub,
        scope: AccountSessionScope
    ) -> FavoriteFolderListModel {
        FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { scope }
        )
    }
}

/// 测试里可改的窗口账户范围。
@MainActor
private final class WindowScope {
    var scope: AccountSessionScope

    init(_ scope: AccountSessionScope) {
        self.scope = scope
    }
}

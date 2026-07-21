import Foundation
@testable import BiliAuth

func makeFixtureCredential(
    expiresAt: Date = Date(timeIntervalSince1970: 4_102_444_800)
) throws -> WebCredential {
    try WebCredential(
        cookies: WebCredentialCookieName.allCases.map { name in
            WebCredentialCookie(
                name: name,
                value: "FIXTURE_\(name.rawValue)_VALUE",
                domain: ".bilibili.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: name == .session,
                expiresAt: expiresAt
            )
        }
    )
}

final class MemoryWebCredentialStore: WebCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: WebCredential?
    private var nextLoadError: (any Error)?
    private var nextSaveError: (any Error)?
    private var nextDeleteError: (any Error)?
    private(set) var deleteCount = 0
    private(set) var saveCount = 0

    init(
        credential: WebCredential? = nil,
        loadError: (any Error)? = nil,
        saveError: (any Error)? = nil,
        deleteError: (any Error)? = nil
    ) {
        self.credential = credential
        nextLoadError = loadError
        nextSaveError = saveError
        nextDeleteError = deleteError
    }

    func load() throws -> WebCredential? {
        try lock.withLock {
            if let nextLoadError {
                self.nextLoadError = nil
                throw nextLoadError
            }
            return credential
        }
    }

    func save(_ credential: WebCredential) throws {
        try lock.withLock {
            if let nextSaveError {
                self.nextSaveError = nil
                throw nextSaveError
            }
            self.credential = credential
            saveCount += 1
        }
    }

    func delete() throws {
        try lock.withLock {
            if let nextDeleteError {
                self.nextDeleteError = nil
                throw nextDeleteError
            }
            credential = nil
            deleteCount += 1
        }
    }
}

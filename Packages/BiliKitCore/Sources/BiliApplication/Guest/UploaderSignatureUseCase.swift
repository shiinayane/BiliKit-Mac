import Foundation

/// 取得并规范化当前视频 UP 主的可选公开签名。
public struct UploaderSignatureUseCase: Sendable {
    private let repository: any UploaderSignatureRepository

    public init(repository: any UploaderSignatureRepository) {
        self.repository = repository
    }

    public func signature(for ownerID: Int64) async throws -> String? {
        guard ownerID > 0 else {
            throw GuestApplicationError.invalidRequest
        }
        let signature = try await repository.signature(for: ownerID)
        try Task.checkCancellation()
        guard let signature else { return nil }
        let normalized =
            signature
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

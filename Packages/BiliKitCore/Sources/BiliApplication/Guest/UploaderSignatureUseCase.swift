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
        return Self.singleLine(signature)
    }

    /// 把连续空白折叠为单个空格，结果为空时视为缺省；UP 主名称与签名展示共用这一规则。
    package static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized =
            value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

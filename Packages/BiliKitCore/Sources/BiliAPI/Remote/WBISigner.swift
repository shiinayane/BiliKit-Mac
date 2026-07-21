import CryptoKit
import Foundation

struct WBIKeyMaterial: Sendable, Equatable {
    let imageKey: String
    let subKey: String

    init(imageURL: String, subURL: String) throws {
        imageKey = try Self.key(from: imageURL)
        subKey = try Self.key(from: subURL)
        guard imageKey.count == 32, subKey.count == 32 else {
            throw BiliAPIError.invalidWBIKey
        }
    }

    private static func key(from value: String) throws -> String {
        guard let url = URL(string: value) else {
            throw BiliAPIError.invalidWBIKey
        }
        let key = url.deletingPathExtension().lastPathComponent
        guard !key.isEmpty else {
            throw BiliAPIError.invalidWBIKey
        }
        return key
    }
}

struct WBISigner: Sendable {
    private static let mixinTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]
    private static let filteredCharacters = CharacterSet(charactersIn: "!'()*")
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    func sign(
        parameters: [String: String],
        keys: WBIKeyMaterial,
        timestamp: Int64
    ) throws -> String {
        let originalKey = Array(keys.imageKey + keys.subKey)
        guard originalKey.count >= 64 else {
            throw BiliAPIError.invalidWBIKey
        }
        let mixinKey = String(
            Self.mixinTable.prefix(32).map { originalKey[$0] }
        )
        var signedParameters = parameters
        signedParameters["wts"] = String(timestamp)
        let query = try signedParameters.keys.sorted().map { key in
            let filteredValue = signedParameters[key, default: ""]
                .components(separatedBy: Self.filteredCharacters)
                .joined()
            return "\(try Self.percentEncode(key))=\(try Self.percentEncode(filteredValue))"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        return "\(query)&w_rid=\(signature)"
    }

    private static func percentEncode(_ value: String) throws -> String {
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: unreservedCharacters
        ) else {
            throw BiliAPIError.signingFailed
        }
        return encoded
    }
}

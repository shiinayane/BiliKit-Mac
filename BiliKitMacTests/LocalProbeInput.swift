import Foundation

enum LocalProbeInput {
    static let environmentKey = "BILIKIT_LOCAL_PROBE_INPUT_FILE"
    private static let maximumBytes = 4 * 1_024

    static func load() throws -> [String: String]? {
        guard
            let path = ProcessInfo.processInfo.environment[environmentKey],
            !path.isEmpty
        else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard
            attributes[.type] as? FileAttributeType == .typeRegular,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o077 == 0
        else {
            throw LocalProbeInputError.insecureInputFile
        }

        let data = try Data(
            contentsOf: URL(fileURLWithPath: path, isDirectory: false),
            options: .mappedIfSafe
        )
        guard data.count <= maximumBytes else {
            throw LocalProbeInputError.inputTooLarge
        }
        return try PropertyListDecoder().decode([String: String].self, from: data)
    }
}

enum LocalProbeInputError: Error {
    case insecureInputFile
    case inputTooLarge
}

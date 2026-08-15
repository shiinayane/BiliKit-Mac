import Foundation

/// 把远端列表接口中的 HTML-escaped 视频标题一次性规范为语义纯文本。
enum RemoteVideoTitleNormalizer {
    static func plainText(_ value: String) -> String {
        decodingHTMLEntities(in: value)
    }

    static func searchResult(_ value: String) -> String {
        decodingHTMLEntities(in: strippingTags(from: value))
    }

    private static func decodingHTMLEntities(in value: String) -> String {
        guard value.contains("&") else { return value }

        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&" else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }

            let entityStart = value.index(after: index)
            let maximumEnd =
                value.index(
                    entityStart,
                    offsetBy: 32,
                    limitedBy: value.endIndex
                ) ?? value.endIndex
            guard
                let semicolon = value[entityStart..<maximumEnd]
                    .firstIndex(of: ";"),
                let decoded = decodedEntity(value[entityStart..<semicolon])
            else {
                result.append("&")
                index = entityStart
                continue
            }

            result.append(decoded)
            index = value.index(after: semicolon)
        }
        return result
    }

    private static func decodedEntity(_ entity: Substring) -> String? {
        switch entity {
        case "amp":
            return "&"
        case "apos":
            return "'"
        case "gt":
            return ">"
        case "lt":
            return "<"
        case "nbsp":
            return "\u{00A0}"
        case "quot":
            return "\""
        default:
            return decodedNumericEntity(entity)
        }
    }

    private static func decodedNumericEntity(_ entity: Substring) -> String? {
        guard entity.first == "#" else { return nil }
        let numeric = entity.dropFirst()
        let radix: Int
        let digits: Substring
        if numeric.first == "x" || numeric.first == "X" {
            radix = 16
            digits = numeric.dropFirst()
        } else {
            radix = 10
            digits = numeric
        }
        guard
            !digits.isEmpty,
            let value = UInt32(digits, radix: radix),
            let scalar = UnicodeScalar(value),
            scalar.properties.generalCategory != .control
        else {
            return nil
        }
        return String(scalar)
    }

    private static func strippingTags(from value: String) -> String {
        var result = ""
        var isInsideTag = false
        for character in value {
            switch character {
            case "<":
                isInsideTag = true
            case ">":
                isInsideTag = false
            default:
                if !isInsideTag {
                    result.append(character)
                }
            }
        }
        return result
    }
}

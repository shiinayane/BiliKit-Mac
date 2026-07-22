import BiliModels
import Foundation
import SwiftProtobuf

enum DanmakuPayloadDecoder {
    private static let maximumEventCount = 20_000
    private static let maximumTextLength = 1_000_000
    private static let maximumEventTextLength = 4_096
    private static let maximumTimeMilliseconds = 86_400_000

    static func events(from data: Data) throws -> [DanmakuEvent] {
        let payload: Bilikit_Danmaku_SegmentReply
        do {
            payload = try Bilikit_Danmaku_SegmentReply(serializedBytes: data)
        } catch {
            throw BiliAPIError.invalidDanmakuData
        }
        guard payload.elements.count <= maximumEventCount else {
            throw BiliAPIError.invalidDanmakuData
        }

        var totalTextLength = 0
        return try payload.elements.compactMap { element in
            guard let mode = presentationMode(element.mode) else {
                return nil
            }
            let text = element.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let id = element.idString.isEmpty
                ? (element.id > 0 ? String(element.id) : nil)
                : element.idString
            guard let id,
                  id.count <= 128,
                  element.progressMilliseconds >= 0,
                  element.progressMilliseconds <= maximumTimeMilliseconds,
                  !text.isEmpty,
                  text.count <= maximumEventTextLength,
                  element.colorRgb <= 0xFF_FF_FF
            else {
                throw BiliAPIError.invalidDanmakuData
            }
            totalTextLength += text.count
            guard totalTextLength <= maximumTextLength else {
                throw BiliAPIError.invalidDanmakuData
            }
            return DanmakuEvent(
                id: id,
                timeSeconds: Double(element.progressMilliseconds) / 1_000,
                mode: mode,
                text: text,
                fontSize: normalizedFontSize(element.fontSize),
                colorRGB: element.colorRgb,
                weight: Int(element.weight)
            )
        }
    }

    private static func presentationMode(
        _ value: Int32
    ) -> DanmakuPresentationMode? {
        switch value {
        case 1, 2, 3:
            .scrolling
        case 4:
            .bottom
        case 5:
            .top
        default:
            nil
        }
    }

    private static func normalizedFontSize(_ value: Int32) -> Double {
        Double(min(max(value, 12), 64))
    }
}

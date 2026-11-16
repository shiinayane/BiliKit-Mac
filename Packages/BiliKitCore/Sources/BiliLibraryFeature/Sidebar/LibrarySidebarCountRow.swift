import Foundation
import SwiftUI

/// 侧栏里带条数的一行：图标、标题与行尾的条数；收藏夹与关注分组共用。
///
/// 标题过长时由标题自己截断，条数固定宽度、始终完整；条数用等宽数字、次要颜色，对读屏隐藏，改与调用方给的状态
/// （如“私密”）一起作为行的值读出。条数为 nil（还没读到）时不占位。
struct LibrarySidebarCountRow<Title: View>: View {
    /// 标题与条数之间的最小间距。
    private static var titleCountSpacing: CGFloat { 4 }

    @Environment(\.locale) private var locale
    let systemImage: String
    let count: Int?
    /// 标题里只画成图标、读屏读不到的状态，依次排在条数之前读出。
    var accessibilityStates: [String] = []
    @ViewBuilder let title: Title

    var body: some View {
        Label {
            HStack(spacing: 0) {
                title
                Spacer(minLength: Self.titleCountSpacing)
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let parts =
            accessibilityStates + (count.map { [$0.formatted(.number.locale(locale))] } ?? [])
        return ListFormatter.localizedString(byJoining: parts)
    }
}

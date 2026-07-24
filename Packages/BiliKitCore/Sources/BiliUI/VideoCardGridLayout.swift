import SwiftUI

package enum VideoCardGridLayout {
    package static let horizontalSpacing: CGFloat = 20
    package static let verticalSpacing: CGFloat = 28
    package static let contentPadding: CGFloat = 24

    package static func columns(for width: CGFloat) -> [GridItem] {
        let usableWidth = max(0, width - contentPadding * 2)
        let naturalCount = Int(
            (usableWidth + horizontalSpacing) / (240 + horizontalSpacing)
        )
        let columnCount = min(5, max(2, naturalCount))
        return Array(
            repeating: GridItem(
                .flexible(minimum: 200),
                spacing: horizontalSpacing
            ),
            count: columnCount
        )
    }
}

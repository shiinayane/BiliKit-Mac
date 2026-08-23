import Foundation

enum LibraryFeatureStrings {
    static let bundle = Bundle.module

    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale = .current
    ) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}

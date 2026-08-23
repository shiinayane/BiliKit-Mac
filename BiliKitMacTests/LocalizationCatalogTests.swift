import Foundation
import Testing

struct LocalizationCatalogTests {
    private let supportedLanguages = ["zh-Hans", "zh-Hant", "ja", "en"]

    @Test
    func everyProductionCatalogHasFourCompleteLocalizations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogPaths = [
            "BiliKitMac/Localizable.xcstrings",
            "Packages/BiliKitCore/Sources/BiliBrowseFeature/Resources/Localizable.xcstrings",
            "Packages/BiliKitCore/Sources/BiliAuthFeature/Resources/Localizable.xcstrings",
            "Packages/BiliKitCore/Sources/BiliLibraryFeature/Resources/Localizable.xcstrings",
        ]

        for catalogPath in catalogPaths {
            let catalog = try loadCatalog(repositoryRoot.appending(path: catalogPath))
            #expect(catalog.sourceLanguage == "zh-Hans")
            #expect(!catalog.strings.isEmpty)

            for (key, entry) in catalog.strings {
                #expect(
                    Set(entry.localizations.keys) == Set(supportedLanguages),
                    "\(catalogPath): \(key) must define exactly four languages"
                )
                for language in supportedLanguages {
                    let stringUnit = try #require(
                        entry.localizations[language]?.stringUnit,
                        "\(catalogPath): \(key) is missing \(language)"
                    )
                    #expect(
                        stringUnit.state == "translated",
                        "\(catalogPath): \(key) is not translated for \(language)"
                    )
                    let value = stringUnit.value
                    #expect(
                        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(catalogPath): \(key) has an empty \(language) translation"
                    )
                    #expect(
                        try placeholders(in: value) == placeholders(in: key),
                        "\(catalogPath): \(key) changes placeholders in \(language)"
                    )
                }
            }
        }
    }

    @Test
    func builtAppContainsFourLocalizedResourceSets() throws {
        let appBundle = Bundle.main
        #expect(appBundle.bundleIdentifier == "com.shiinayane.BiliKit")
        try expectFourLocalizations(in: appBundle, label: "BiliKit.app")

        let featureBundleNames = [
            "BiliKitCore_BiliAuthFeature",
            "BiliKitCore_BiliBrowseFeature",
            "BiliKitCore_BiliLibraryFeature",
        ]
        for name in featureBundleNames {
            let url = try #require(
                appBundle.resourceURL?.appending(path: "\(name).bundle")
            )
            let bundle = try #require(Bundle(url: url), "Missing \(name).bundle")
            try expectFourLocalizations(in: bundle, label: name)
        }
    }

    private func loadCatalog(_ url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func expectFourLocalizations(
        in bundle: Bundle,
        label: String
    ) throws {
        #expect(
            Set(bundle.localizations) == Set(supportedLanguages),
            "\(label) must contain exactly four localizations"
        )
        #expect(bundle.developmentLocalization == "zh-Hans")
        for language in supportedLanguages {
            let resource = bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: language
            )
            #expect(resource != nil, "\(label) is missing \(language).lproj/Localizable.strings")
        }
    }

    private func placeholders(in value: String) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: #"%(?:\d+\$)?(?:lld|llu|ld|lu|[df@])"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            guard let matchRange = Range($0.range, in: value) else { return nil }
            return String(value[matchRange])
                .replacingOccurrences(
                    of: #"%\d+\$"#,
                    with: "%",
                    options: .regularExpression
                )
        }.sorted()
    }
}

private struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    let localizations: [String: CatalogLocalization]
}

private struct CatalogLocalization: Decodable {
    let stringUnit: CatalogStringUnit
}

private struct CatalogStringUnit: Decodable {
    let state: String
    let value: String
}

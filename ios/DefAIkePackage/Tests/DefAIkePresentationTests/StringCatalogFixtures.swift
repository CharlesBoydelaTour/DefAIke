import Foundation

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Synthetic String Catalogs for the catalog-validation tests.
//
// Nothing here is approved copy. The values are obviously synthetic sentences chosen to
// exercise one structural rule each, and none of them is addressed by any release
// artifact. The shipping catalog's own contents are asserted separately, against the file
// as authored, in ``EnglishStringCatalogTests``.
//
// The builders take one clean catalog and let a test break exactly one thing, so a
// failure names the rule that fired rather than a whole malformed file.

enum CatalogFixture {
    static let english = "en"

    // MARK: - Leaves

    static func unit(
        _ value: String,
        state: String = StringCatalog.requiredTranslationState
    ) -> StringCatalogStringUnit {
        StringCatalogStringUnit(state: state, value: value)
    }

    // MARK: - Entries

    static func entry(
        _ value: String,
        state: String = StringCatalog.requiredTranslationState,
        language: String = english,
        extractionState: String? = StringCatalog.requiredExtractionState,
        shouldTranslate: Bool? = nil
    ) -> StringCatalogEntry {
        StringCatalogEntry(
            comment: "Synthetic test value. Not approved copy.",
            extractionState: extractionState,
            shouldTranslate: shouldTranslate,
            localizations: [
                language: StringCatalogLocalization(stringUnit: unit(value, state: state))
            ]
        )
    }

    /// An entry that varies by plural category, so a count-bearing sentence keeps its
    /// grammar inside the catalog instead of being assembled by the caller.
    static func pluralEntry(
        categories: [String: String],
        language: String = english
    ) -> StringCatalogEntry {
        StringCatalogEntry(
            comment: "Synthetic test value. Not approved copy.",
            extractionState: StringCatalog.requiredExtractionState,
            localizations: [
                language: StringCatalogLocalization(
                    variations: StringCatalogVariations(
                        plural: categories.mapValues {
                            StringCatalogLocalization(stringUnit: unit($0))
                        }
                    )
                )
            ]
        )
    }

    /// An entry whose sentence references a named substitution.
    static func substitutedEntry(
        value: String = "Recorded %#@dimensions@ for this image",
        substitution name: String = "dimensions",
        argumentNumber: Int = 1,
        formatSpecifier: String = "lld",
        categories: [String: String] = [
            "one": "%lld dimension",
            "other": "%lld dimensions",
        ],
        language: String = english
    ) -> StringCatalogEntry {
        StringCatalogEntry(
            comment: "Synthetic test value. Not approved copy.",
            extractionState: StringCatalog.requiredExtractionState,
            localizations: [
                language: StringCatalogLocalization(
                    stringUnit: unit(value),
                    substitutions: [
                        name: StringCatalogSubstitution(
                            argNum: argumentNumber,
                            formatSpecifier: formatSpecifier,
                            variations: StringCatalogVariations(
                                plural: categories.mapValues {
                                    StringCatalogLocalization(stringUnit: unit($0))
                                }
                            )
                        )
                    ]
                )
            ]
        )
    }

    // MARK: - Catalogs

    static func catalog(
        sourceLanguage: String = english,
        version: String = "1.0",
        _ strings: [String: StringCatalogEntry]
    ) -> StringCatalog {
        StringCatalog(version: version, sourceLanguage: sourceLanguage, strings: strings)
    }

    /// A clean catalog with a plain entry, a plural entry, and a substituted entry.
    static var valid: StringCatalog {
        catalog([
            "copy.synthetic.plain": entry("Analysis finished for this image"),
            "copy.synthetic.plural": pluralEntry(
                categories: [
                    "one": "One recorded dimension",
                    "other": "Several recorded dimensions",
                ]
            ),
            "copy.synthetic.substituted": substitutedEntry(),
        ])
    }

    /// ``valid`` with one entry replaced.
    static func valid(
        replacing key: String,
        with entry: StringCatalogEntry
    ) -> StringCatalog {
        var strings = valid.strings
        strings[key] = entry
        return catalog(strings)
    }

    /// ``valid`` with one plain value replaced, so a value-level rule fires alone.
    static func valid(plainValue value: String) -> StringCatalog {
        valid(replacing: "copy.synthetic.plain", with: entry(value))
    }

    // MARK: - Coverage

    /// A catalog covering every localization key `binding` can resolve.
    static func covering(
        _ binding: ApprovedCopyBinding,
        state: String = StringCatalog.requiredTranslationState,
        value: String = "Synthetic approved value"
    ) -> StringCatalog {
        var strings: [String: StringCatalogEntry] = [:]
        for key in resolvableKeys(of: binding) {
            strings[key.rawValue] = entry(value, state: state)
        }
        return catalog(strings)
    }

    /// Every localization key one binding can resolve, in stable order.
    static func resolvableKeys(of binding: ApprovedCopyBinding) -> [ApprovedCopyKey] {
        binding.reachableSurfaces.surfaces
            .compactMap { binding.localizationKey(for: $0) }
            .sorted { $0.rawValue < $1.rawValue }
    }
}

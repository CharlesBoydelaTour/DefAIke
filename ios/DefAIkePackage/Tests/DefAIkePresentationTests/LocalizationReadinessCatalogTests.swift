import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// The Localization Readiness Suite's four test catalogs.
//
// Requirements 12.15 and 12.16 both start from the same event: readiness test copy
// replaces English user-facing copy. These tests check that the replacement is actually
// possible and actually a replacement.
//
//   * Possible, because each catalog carries exactly the keys the English catalog carries.
//     A key the app addresses and a readiness catalog omits would resolve to nothing, and
//     the suite would be testing a missing label rather than a translated one.
//   * Actually a replacement, because none of them repeats an English value. A catalog
//     that quietly kept the English string would pass a layout test it never exercised.
//
// Each variant is then checked for the specific pressure it exists to apply, so a catalog
// cannot be edited into a harmless copy of English and still count as coverage.
//
// The last test is the one that keeps Requirement 8.18 intact: every readiness catalog is
// refused by the shipping-catalog rules. A file that could pass both would be a second
// user-facing language waiting to be shipped by accident.

@Suite("Localization Readiness Suite catalogs")
struct LocalizationReadinessCatalogTests {

    static func englishCatalog() throws -> StringCatalog {
        try EnglishStringCatalog.loadShippedCatalog()
    }

    /// Every value one readiness catalog supplies, keyed by localization key.
    static func values(
        _ variant: LocalizationReadinessVariant
    ) throws -> [String: String] {
        let catalog = try LocalizationReadinessCatalogs.load(variant)
        return Dictionary(
            uniqueKeysWithValues: catalog.keys.compactMap { key in
                catalog.singleValue(forKey: key, language: variant.languageTag)
                    .map { (key, $0) }
            }
        )
    }

    @Test("All four variants exist")
    func allFourVariantsExist() {
        #expect(LocalizationReadinessVariant.allCases.count == 4)
        #expect(
            Set(LocalizationReadinessVariant.allCases.map(\.languageTag)).count == 4
        )
    }

    @Test("Each catalog loads", arguments: LocalizationReadinessVariant.allCases)
    func catalogLoads(variant: LocalizationReadinessVariant) throws {
        let catalog = try LocalizationReadinessCatalogs.load(variant)

        #expect(catalog.strings.isEmpty == false)
        #expect(catalog.sourceLanguage == variant.languageTag)
        #expect(catalog.languageTags == [variant.languageTag])
    }

    @Test(
        "Each catalog carries exactly the English key set",
        arguments: LocalizationReadinessVariant.allCases
    )
    func keySetsMatchEnglish(variant: LocalizationReadinessVariant) throws {
        // The substitution mechanism is the key set: the app addresses copy by key, so a
        // readiness catalog with the same keys and different values exercises every layout
        // and every accessibility semantic without touching view code.
        let english = try Self.englishCatalog()
        let readiness = try LocalizationReadinessCatalogs.load(variant)

        #expect(readiness.keys == english.keys)
    }

    @Test(
        "Every value is present, approved, and non-blank",
        arguments: LocalizationReadinessVariant.allCases
    )
    func everyValueIsUsable(variant: LocalizationReadinessVariant) throws {
        let catalog = try LocalizationReadinessCatalogs.load(variant)
        let values = try Self.values(variant)

        #expect(values.count == catalog.keys.count)
        for leaf in catalog.leaves {
            #expect(leaf.unit.state == StringCatalog.requiredTranslationState, "\(leaf.address)")
            #expect(leaf.unit.value.isEmpty == false, "\(leaf.address)")
        }
    }

    @Test(
        "No value repeats its English original",
        arguments: LocalizationReadinessVariant.allCases
    )
    func noValueRepeatsEnglish(variant: LocalizationReadinessVariant) throws {
        let english = try Self.englishCatalog()
        let language = EnglishStringCatalog.requiredLanguageTag

        for (key, value) in try Self.values(variant) {
            let original = english.singleValue(forKey: key, language: language)
            #expect(value != original, "\(variant.rawValue) left \(key) in English")
        }
    }

    @Test("No readiness catalog carries a required pixel label string")
    func readinessCopyNeverCarriesAFixedLabel() throws {
        // Requirement 8.2 fixes the three strings for the *release*. The readiness suite
        // deliberately replaces them, which is why the exactness check runs against the
        // English catalog and not against substituted copy.
        for variant in LocalizationReadinessVariant.allCases {
            for value in try Self.values(variant).values {
                #expect(
                    FixedPixelLabelText(exact: value) == nil,
                    "\(variant.rawValue) ships an unreplaced fixed label"
                )
            }
        }
    }

    @Test("Expansion copy is at least twice as long as English")
    func expansionIsLonger() throws {
        let english = try Self.englishCatalog()
        let language = EnglishStringCatalog.requiredLanguageTag

        for (key, value) in try Self.values(.expansion) {
            let original = try #require(english.singleValue(forKey: key, language: language))
            #expect(
                value.count >= 2 * original.count,
                "\(key): \(value.count) characters against \(original.count)"
            )
        }
    }

    @Test("Long-word copy carries an unbreakable token")
    func longWordCarriesAnUnbreakableToken() throws {
        // A layout that only fits because English words are short fails here rather than
        // in front of a user.
        let minimumTokenLength = 40

        for (key, value) in try Self.values(.longWord) {
            let longest = value
                .split(whereSeparator: \.isWhitespace)
                .map(\.count)
                .max() ?? 0
            #expect(longest >= minimumTokenLength, "\(key): longest token is \(longest)")
        }
    }

    @Test("Bidirectional copy is isolated right-to-left text")
    func bidirectionalCopyIsRightToLeft() throws {
        let rightToLeftIsolate: Character = "\u{2067}"
        let popDirectionalIsolate: Character = "\u{2069}"
        let arabicBlock = Unicode.Scalar(0x0600)!.value...Unicode.Scalar(0x06FF)!.value

        for (key, value) in try Self.values(.bidirectional) {
            #expect(value.first == rightToLeftIsolate, "\(key)")
            #expect(value.last == popDirectionalIsolate, "\(key)")
            #expect(
                value.unicodeScalars.contains { arabicBlock.contains($0.value) },
                "\(key) carries no right-to-left script"
            )
        }
    }

    @Test("Pseudolocalized copy is bracketed and accented")
    func pseudolocalizedCopyIsBracketedAndAccented() throws {
        // The brackets make clipping visible: a truncated value loses its closing
        // bracket, so a snapshot shows the defect rather than a plausible sentence.
        for (key, value) in try Self.values(.pseudolocalized) {
            #expect(value.hasPrefix("["), "\(key)")
            #expect(value.hasSuffix("]"), "\(key)")
            #expect(value.contains { !$0.isASCII }, "\(key) carries no accented character")
        }
    }

    @Test(
        "No readiness catalog can pass as the shipping catalog",
        arguments: LocalizationReadinessVariant.allCases
    )
    func readinessCatalogIsRefusedAsShipping(variant: LocalizationReadinessVariant) throws {
        // Requirement 8.18. A readiness catalog that satisfied the shipping rules would be
        // a second user-facing language one build setting away from shipping.
        let catalog = try LocalizationReadinessCatalogs.load(variant)
        let defects = catalog.englishSourceDefects

        #expect(
            defects.contains(
                .unsupportedSourceLanguage(
                    expected: EnglishStringCatalog.requiredLanguageTag,
                    found: variant.languageTag
                )
            ),
            "\(defects)"
        )
        #expect(defects.contains(.additionalUserFacingLanguages([variant.languageTag])))
        #expect(
            defects.contains(
                .missingRequiredLanguage(EnglishStringCatalog.requiredLanguageTag)
            )
        )
        #expect(throws: StringCatalogError.self) {
            try EnglishStringCatalog.validate(catalog)
        }
    }
}

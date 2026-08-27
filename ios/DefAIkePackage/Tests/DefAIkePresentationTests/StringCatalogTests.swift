import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// The catalog model and its fail-closed rules.
//
// Two groups of tests. The first checks that a String Catalog decodes and that every
// value is reachable, including values one level down inside a plural variation or a
// substitution - a rule that only walks top-level entries can be evaded by hiding a
// sentence in a variation. The second checks that each rule refuses what it says it
// refuses, and that a clean catalog passes.
//
// Each defect test breaks exactly one thing in an otherwise valid catalog, so a failure
// names the rule rather than a malformed file.

@Suite("String Catalog decoding and structure")
struct StringCatalogDecodingTests {

    @Test("A well-formed catalog decodes")
    func decodesWellFormedCatalog() throws {
        let json = """
            {
              "sourceLanguage" : "en",
              "version" : "1.0",
              "strings" : {
                "copy.synthetic.plain" : {
                  "comment" : "Synthetic",
                  "extractionState" : "manual",
                  "localizations" : {
                    "en" : {
                      "stringUnit" : { "state" : "translated", "value" : "Plain value" }
                    }
                  }
                }
              }
            }
            """

        let catalog = try EnglishStringCatalog.decode(Data(json.utf8))

        #expect(catalog.sourceLanguage == "en")
        #expect(catalog.version == "1.0")
        #expect(catalog.keys == ["copy.synthetic.plain"])
        #expect(catalog.singleValue(forKey: "copy.synthetic.plain", language: "en") == "Plain value")
        #expect(catalog.strings["copy.synthetic.plain"]?.comment == "Synthetic")
    }

    @Test("Malformed bytes fail closed rather than decoding to an empty catalog")
    func malformedBytesFailClosed() {
        #expect(throws: StringCatalogError.self) {
            try EnglishStringCatalog.decode(Data("not a catalog".utf8))
        }
    }

    @Test("Plural and substitution values are reachable as leaves")
    func leavesIncludeVariationsAndSubstitutions() {
        let leaves = CatalogFixture.valid.leaves
        let addresses = Set(leaves.map(\.address))

        #expect(addresses.contains("copy.synthetic.plain/en"))
        #expect(addresses.contains("copy.synthetic.plural/en/plural:one"))
        #expect(addresses.contains("copy.synthetic.plural/en/plural:other"))
        #expect(addresses.contains("copy.synthetic.substituted/en"))
        #expect(
            addresses.contains("copy.synthetic.substituted/en/substitution:dimensions/plural:one")
        )
        #expect(leaves.allSatisfy { !$0.unit.value.isEmpty })
    }

    @Test("A varying entry reports no single value")
    func varyingEntryHasNoSingleValue() {
        let catalog = CatalogFixture.valid

        #expect(catalog.singleValue(forKey: "copy.synthetic.plural", language: "en") == nil)
        #expect(catalog.singleValue(forKey: "copy.synthetic.plain", language: "en") != nil)
        #expect(catalog.singleValue(forKey: "copy.absent", language: "en") == nil)
        #expect(catalog.singleValue(forKey: "copy.synthetic.plain", language: "fr") == nil)
    }

    @Test("Language tags are gathered from entries, not from the source language")
    func languageTagsComeFromEntries() {
        let catalog = CatalogFixture.catalog(
            sourceLanguage: "en",
            ["copy.synthetic.plain": CatalogFixture.entry("Valeur", language: "fr")]
        )

        #expect(catalog.languageTags == ["fr"])
    }

    @Test("Keys are reported in sorted order so a report is diffable")
    func keysAreSorted() {
        let catalog = CatalogFixture.catalog([
            "copy.b": CatalogFixture.entry("B value"),
            "copy.a": CatalogFixture.entry("A value"),
        ])

        #expect(catalog.keys == ["copy.a", "copy.b"])
    }
}

@Suite("English source catalog rules")
struct StringCatalogValidationTests {

    @Test("A clean catalog passes")
    func cleanCatalogPasses() throws {
        #expect(CatalogFixture.valid.englishSourceDefects.isEmpty)
        try CatalogFixture.valid.validateAsEnglishSourceCatalog()
    }

    @Test("An empty catalog is refused")
    func emptyCatalogRefused() {
        #expect(throws: StringCatalogError.emptyCatalog) {
            try CatalogFixture.catalog([:]).validateAsEnglishSourceCatalog()
        }
    }

    @Test("A non-English source language is refused")
    func nonEnglishSourceLanguageRefused() {
        let catalog = CatalogFixture.catalog(
            sourceLanguage: "fr",
            ["copy.synthetic.plain": CatalogFixture.entry("Valeur", language: "fr")]
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .unsupportedSourceLanguage(expected: "en", found: "fr")
            )
        )
    }

    @Test("A second user-facing language is refused")
    func additionalLanguageRefused() {
        // Requirement 8.18: Version 1 ships one user-facing language. A second
        // localization is a different release, not a partly translated one.
        let entry = StringCatalogEntry(
            extractionState: StringCatalog.requiredExtractionState,
            localizations: [
                "en": StringCatalogLocalization(stringUnit: CatalogFixture.unit("Value")),
                "fr": StringCatalogLocalization(stringUnit: CatalogFixture.unit("Valeur")),
            ]
        )
        let catalog = CatalogFixture.catalog(["copy.synthetic.plain": entry])

        #expect(
            catalog.englishSourceDefects.contains(.additionalUserFacingLanguages(["fr"]))
        )
    }

    @Test("A catalog with no English values at all is refused")
    func missingRequiredLanguageRefused() {
        let catalog = CatalogFixture.catalog(
            ["copy.synthetic.plain": CatalogFixture.entry("Valeur", language: "fr")]
        )

        #expect(catalog.englishSourceDefects.contains(.missingRequiredLanguage("en")))
    }

    @Test(
        "A noncanonical key is refused",
        arguments: ["copy.has space", "copy.smart’quote", "", "copy.\u{00E9}"]
    )
    func noncanonicalKeyRefused(key: String) {
        // Keys share the domain's identifier syntax, so an address cannot carry display
        // text, whitespace, or non-ASCII content.
        let catalog = CatalogFixture.catalog([key: CatalogFixture.entry("Value")])

        #expect(catalog.englishSourceDefects.contains(.noncanonicalKey(key)))
    }

    @Test("A canonical key is accepted", arguments: ["copy.a-b_c", "copy.pixel-label.x"])
    func canonicalKeyAccepted(key: String) {
        let catalog = CatalogFixture.catalog([key: CatalogFixture.entry("Value")])

        #expect(catalog.englishSourceDefects.isEmpty)
    }

    @Test("An unapproved review state is refused", arguments: ["new", "needs_review", "stale"])
    func untranslatedValueRefused(state: String) {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.plain",
            with: CatalogFixture.entry("Value", state: state)
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .untranslatedValue(address: "copy.synthetic.plain/en", state: state)
            )
        )
    }

    @Test("A blank value is refused", arguments: ["", " ", "\u{00A0}"])
    func blankValueRefused(value: String) {
        let catalog = CatalogFixture.valid(plainValue: value)

        #expect(
            catalog.englishSourceDefects.contains(
                .emptyValue(address: "copy.synthetic.plain/en")
            )
        )
    }

    @Test(
        "An entry not authored by hand is refused",
        arguments: [nil, "extracted_with_value"] as [String?]
    )
    func unexpectedExtractionStateRefused(state: String?) {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.plain",
            with: CatalogFixture.entry("Value", extractionState: state)
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .unexpectedExtractionState(key: "copy.synthetic.plain", state: state)
            )
        )
    }

    @Test("An entry exempt from translation is refused")
    func nonTranslatableEntryRefused() {
        // An entry the Localization Readiness Suite cannot replace would be exempt from
        // Requirements 12.15 and 12.16.
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.plain",
            with: CatalogFixture.entry("Value", shouldTranslate: false)
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .nonTranslatableEntry(key: "copy.synthetic.plain")
            )
        )
    }

    // MARK: - Concatenation

    @Test(
        "A glue fragment is refused",
        arguments: [
            (" leading space", ConcatenationDefect.surroundingWhitespace),
            ("trailing space ", ConcatenationDefect.surroundingWhitespace),
            (", ", ConcatenationDefect.separatorOnly),
            ("- ", ConcatenationDefect.separatorOnly),
            ("%@", ConcatenationDefect.specifierOnly),
            ("%lld", ConcatenationDefect.specifierOnly),
        ]
    )
    func concatenationFragmentRefused(value: String, defect: ConcatenationDefect) {
        // A sentence assembled from pieces fixes English word order and grammar in the
        // code, where no translation and no readiness substitution can reach it.
        let catalog = CatalogFixture.valid(plainValue: value)

        #expect(
            catalog.englishSourceDefects.contains(
                .concatenationFragment(address: "copy.synthetic.plain/en", reason: defect)
            ),
            "\(catalog.englishSourceDefects)"
        )
    }

    @Test("A whole sentence carrying one argument is accepted")
    func sentenceWithOneArgumentAccepted() {
        let catalog = CatalogFixture.valid(plainValue: "Recorded input dimensions %@")

        #expect(catalog.englishSourceDefects.isEmpty, "\(catalog.englishSourceDefects)")
    }

    @Test("Two unnumbered arguments are refused")
    func nonpositionalArgumentsRefused() {
        // Unnumbered arguments pin argument order to the English sentence's order.
        let catalog = CatalogFixture.valid(plainValue: "Recorded %@ by %@ pixels")

        #expect(
            catalog.englishSourceDefects.contains(
                .nonpositionalArguments(address: "copy.synthetic.plain/en", argumentCount: 2)
            )
        )
    }

    @Test("Two numbered arguments are accepted")
    func positionalArgumentsAccepted() {
        let catalog = CatalogFixture.valid(plainValue: "Recorded %1$@ by %2$@ pixels")

        #expect(catalog.englishSourceDefects.isEmpty, "\(catalog.englishSourceDefects)")
    }

    @Test("An escaped percent is not an argument")
    func escapedPercentIsNotAnArgument() {
        let catalog = CatalogFixture.valid(plainValue: "Reported as 100%% on device")

        #expect(catalog.englishSourceDefects.isEmpty, "\(catalog.englishSourceDefects)")
    }

    @Test("A substitution the entry does not declare is refused")
    func undeclaredSubstitutionRefused() {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.substituted",
            with: CatalogFixture.substitutedEntry(
                value: "Recorded %#@missing@ for this image",
                substitution: "dimensions"
            )
        )
        let defects = catalog.englishSourceDefects

        #expect(
            defects.contains(
                .undeclaredSubstitution(
                    address: "copy.synthetic.substituted/en",
                    name: "missing"
                )
            ),
            "\(defects)"
        )
        #expect(
            defects.contains(
                .unusedSubstitution(
                    key: "copy.synthetic.substituted",
                    language: "en",
                    name: "dimensions"
                )
            )
        )
    }

    // MARK: - Fixed width

    @Test(
        "A value that assumes a rendered width is refused",
        arguments: [
            ("Label:\tvalue", FixedWidthDefect.tabAlignment),
            ("Label:  value", FixedWidthDefect.spacePadding),
            ("First line\nsecond line", FixedWidthDefect.embeddedLineBreak),
            ("Recorded %-12s pixels", FixedWidthDefect.specifierFieldWidth),
            ("Recorded %.2f pixels", FixedWidthDefect.specifierFieldWidth),
            ("Recorded %8lld pixels", FixedWidthDefect.specifierFieldWidth),
        ]
    )
    func fixedWidthAssumptionRefused(value: String, defect: FixedWidthDefect) {
        // Layouts reflow for Dynamic Type through the largest accessibility sizes
        // (Requirement 12.8), so a value asserting a width is asserting a layout the app
        // does not have.
        let catalog = CatalogFixture.valid(plainValue: value)

        #expect(
            catalog.englishSourceDefects.contains(
                .fixedWidthAssumption(address: "copy.synthetic.plain/en", reason: defect)
            ),
            "\(catalog.englishSourceDefects)"
        )
    }

    // MARK: - Plurals

    @Test("A plural variation without `other` is refused")
    func missingPluralOtherRefused() {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.plural",
            with: CatalogFixture.pluralEntry(categories: ["one": "One dimension"])
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .missingPluralOtherCategory(address: "copy.synthetic.plural/en")
            )
        )
    }

    @Test("An invented plural category is refused")
    func unknownPluralCategoryRefused() {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.plural",
            with: CatalogFixture.pluralEntry(
                categories: ["other": "Several dimensions", "plenty": "Plenty of dimensions"]
            )
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .unknownPluralCategory(address: "copy.synthetic.plural/en", category: "plenty")
            )
        )
    }

    @Test("A value hidden in a plural variation is still checked")
    func variationValuesAreChecked() {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.plural",
            with: CatalogFixture.pluralEntry(
                categories: ["one": "One dimension", "other": "Several dimensions "]
            )
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .concatenationFragment(
                    address: "copy.synthetic.plural/en/plural:other",
                    reason: .surroundingWhitespace
                )
            ),
            "\(catalog.englishSourceDefects)"
        )
    }

    @Test("A value hidden in a substitution variation is still checked")
    func substitutionValuesAreChecked() {
        let catalog = CatalogFixture.valid(
            replacing: "copy.synthetic.substituted",
            with: CatalogFixture.substitutedEntry(
                categories: ["one": "%lld dimension", "other": "%lld  dimensions"]
            )
        )

        #expect(
            catalog.englishSourceDefects.contains(
                .fixedWidthAssumption(
                    address: "copy.synthetic.substituted/en/substitution:dimensions/plural:other",
                    reason: .spacePadding
                )
            ),
            "\(catalog.englishSourceDefects)"
        )
    }

    @Test("Defect order is deterministic")
    func defectOrderIsDeterministic() {
        let catalog = CatalogFixture.catalog([
            "copy.b": CatalogFixture.entry(" b "),
            "copy.a": CatalogFixture.entry(" a "),
        ])

        let first = catalog.englishSourceDefects
        let second = catalog.englishSourceDefects

        #expect(first == second)
        #expect(
            first.first
                == .concatenationFragment(address: "copy.a/en", reason: .surroundingWhitespace)
        )
    }

    @Test("Validation throws the first defect it reports")
    func validationThrowsFirstDefect() {
        let catalog = CatalogFixture.valid(plainValue: " leading ")

        #expect(throws: catalog.englishSourceDefects.first!) {
            try catalog.validateAsEnglishSourceCatalog()
        }
    }
}

@Suite("Catalog value format scanning")
struct StringCatalogFormatTests {

    @Test("A plain sentence consumes no argument")
    func plainSentenceHasNoArguments() {
        #expect(StringCatalogFormat.argumentSpecifiers(in: "No strong signal detected").isEmpty)
    }

    @Test("An escaped percent is literal text")
    func escapedPercentIsLiteral() {
        #expect(StringCatalogFormat.argumentSpecifiers(in: "100%% on device").isEmpty)
        #expect(StringCatalogFormat.literalText(in: "100%% on device") == "100% on device")
    }

    @Test("An unnumbered specifier carries no argument number")
    func unnumberedSpecifier() {
        let specifiers = StringCatalogFormat.argumentSpecifiers(in: "Recorded %@ pixels")

        #expect(specifiers.count == 1)
        #expect(specifiers.first?.argumentNumber == nil)
        #expect(specifiers.first?.hasFieldWidthOrPrecision == false)
    }

    @Test("A numbered specifier carries its argument number")
    func numberedSpecifier() {
        let specifiers = StringCatalogFormat.argumentSpecifiers(in: "%2$@ by %1$@")

        #expect(specifiers.map(\.argumentNumber) == [2, 1])
    }

    @Test("A length modifier is not an argument number")
    func lengthModifierIsNotAnArgumentNumber() {
        let specifiers = StringCatalogFormat.argumentSpecifiers(in: "Recorded %lld pixels")

        #expect(specifiers.count == 1)
        #expect(specifiers.first?.hasFieldWidthOrPrecision == false)
    }

    @Test(
        "A width or precision field is reported",
        arguments: ["%-12s", "%08lld", "%.3f", "%1$-6@"]
    )
    func widthFieldReported(specifier: String) {
        let specifiers = StringCatalogFormat.argumentSpecifiers(in: "Recorded \(specifier) here")

        #expect(specifiers.first?.hasFieldWidthOrPrecision == true, "\(specifiers)")
    }

    @Test("A substitution reference is named and treated as reorderable")
    func substitutionReference() {
        let value = "Recorded %#@dimensions@ for this image"

        #expect(StringCatalogFormat.substitutionReferences(in: value) == ["dimensions"])
        #expect(StringCatalogFormat.argumentSpecifiers(in: value).count == 1)
        #expect(StringCatalogFormat.argumentSpecifiers(in: value).first?.argumentNumber == 0)
        #expect(StringCatalogFormat.literalText(in: value) == "Recorded  for this image")
    }

    @Test("An unterminated construct is reported rather than ignored")
    func unterminatedConstructReported() {
        // Failing closed on something the scanner cannot classify is the point: a
        // construct it does not understand is not one it has cleared.
        for value in ["Trailing percent %", "Unterminated %#@name", "Unknown %~"] {
            let specifiers = StringCatalogFormat.argumentSpecifiers(in: value)
            #expect(specifiers.contains { $0.argumentNumber == nil }, "\(value)")
        }
    }

    @Test("Scanning terminates on adversarial values")
    func scanningTerminates() {
        for value in ["%", "%%", "%%%", "%#@", "%#@@", "%1$", "%-", "%.", "%ll", "%%%@"] {
            _ = StringCatalogFormat.scan(value)
        }
    }
}

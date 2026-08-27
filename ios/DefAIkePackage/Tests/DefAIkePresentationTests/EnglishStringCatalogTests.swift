import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// The one catalog this module ships.
//
// The catalog is read twice on purpose. Once from the resource bundle, which is how the
// app reads it, and once from the file as authored in the source tree, which is what a
// reviewer reads. Both have to decode to the same catalog and both have to satisfy every
// rule, so a resource that was declared wrong, copied wrong, or edited in one place and
// not the other cannot pass.
//
// What the catalog contains, and why it is short. Requirement 8.2 fixes three display
// strings character for character, so those three are here. The rest of Version 1's
// user-facing wording is external approved content - the unresolved Approved Verdict Copy
// decision - and the repository holds no placeholder for an unresolved approved input.
// ``StringCatalogCoverageTests`` covers what happens when a release addresses a key this
// catalog has no value for: a named release-validation failure, not a blank label and not
// a rendered key.

@Suite("The shipped English String Catalog")
struct EnglishStringCatalogTests {

    /// The catalog as the app reads it.
    static func bundled() throws -> StringCatalog {
        try EnglishStringCatalog.loadShippedCatalog()
    }

    /// The catalog as authored, read from the source tree.
    static func authored() throws -> StringCatalog {
        let root = try #require(
            PackageSourceTree.packageRoot,
            "the package source tree is required to validate the catalog as authored"
        )
        let url = root.appending(path: PackageSourceTree.shippedCatalogRelativePath)
        return try EnglishStringCatalog.decode(Data(contentsOf: url))
    }

    @Test("It loads from the resource bundle and passes every rule")
    func bundledCatalogLoadsAndValidates() throws {
        let catalog = try Self.bundled()

        #expect(catalog.strings.isEmpty == false)
        #expect(catalog.englishSourceDefects.isEmpty, "\(catalog.englishSourceDefects)")
    }

    @Test("The authored file and the bundled resource are the same catalog")
    func authoredAndBundledAgree() throws {
        let authored = try Self.authored()
        let bundled = try Self.bundled()

        #expect(authored == bundled)
    }

    @Test("English is the only language in it")
    func englishIsTheOnlyLanguage() throws {
        // Requirement 8.18. Checked on the entries rather than only on the declared
        // source language, because a second shipped language arrives as an extra
        // localization on an entry.
        let catalog = try Self.authored()

        #expect(catalog.sourceLanguage == EnglishStringCatalog.requiredLanguageTag)
        #expect(catalog.languageTags == [EnglishStringCatalog.requiredLanguageTag])
    }

    @Test("Every key is a canonical approved copy key")
    func keysAreCanonical() throws {
        for key in try Self.authored().keys {
            #expect(ApprovedCopyKey(key) != nil, "\(key)")
        }
    }

    @Test("Every entry is hand authored and translatable")
    func entriesAreAuthoredAndTranslatable() throws {
        for (key, entry) in try Self.authored().strings {
            #expect(entry.extractionState == StringCatalog.requiredExtractionState, "\(key)")
            #expect(entry.shouldTranslate != false, "\(key)")
            #expect(entry.comment?.isEmpty == false, "\(key) needs a translator comment")
        }
    }

    @Test("Every value is approved and non-blank")
    func valuesAreApprovedAndNonBlank() throws {
        for leaf in try Self.authored().leaves {
            #expect(leaf.unit.state == StringCatalog.requiredTranslationState, "\(leaf.address)")
            #expect(leaf.unit.value.isEmpty == false, "\(leaf.address)")
        }
    }

    @Test("The three fixed pixel labels are present, exactly as required")
    func fixedPixelLabelsAreExact() throws {
        // Requirement 8.2 fixes these three strings character for character, and
        // `FixedPixelLabelText` stays the single authority on what they are.
        let catalog = try Self.authored()

        try EnglishStringCatalog.validateFixedPixelLabels(in: catalog)

        for label in PixelLabelKey.allCases {
            let key = try #require(EnglishStringCatalog.fixedPixelLabelKeys[label])
            let value = catalog.singleValue(
                forKey: key.rawValue,
                language: EnglishStringCatalog.requiredLanguageTag
            )
            #expect(value == FixedPixelLabelText(label: label).value)
        }
    }

    @Test("The fixed pixel label keys follow the one key convention")
    func keyConventionIsShared() {
        // Task 11.1's fixtures derive a key from the surface's stable identifier. Pinning
        // the same derivation here is what keeps one naming scheme rather than two: the
        // catalogue artifact remains the authority on which key addresses which surface,
        // and code names only the three keys whose values a requirement fixes.
        for label in PixelLabelKey.allCases {
            #expect(
                EnglishStringCatalog.fixedPixelLabelKeys[label]
                    == CopyFixture.localizationKey(for: .pixelLabel(label))
            )
        }
    }

    @Test("A changed pixel label value fails closed")
    func changedPixelLabelFailsClosed() throws {
        let label = PixelLabelKey.notEnoughSignal
        let key = try #require(EnglishStringCatalog.fixedPixelLabelKeys[label])
        var strings = try Self.authored().strings
        strings[key.rawValue] = CatalogFixture.entry("Probably not AI")

        #expect(
            throws: StringCatalogError.fixedPixelLabelMismatch(
                label: label,
                expected: "Not enough signal",
                found: "Probably not AI"
            )
        ) {
            try EnglishStringCatalog.validateFixedPixelLabels(in: CatalogFixture.catalog(strings))
        }
    }

    @Test("A missing pixel label value fails closed")
    func missingPixelLabelFailsClosed() throws {
        let label = PixelLabelKey.noStrongSignalDetected
        let key = try #require(EnglishStringCatalog.fixedPixelLabelKeys[label])
        var strings = try Self.authored().strings
        strings[key.rawValue] = nil

        #expect(throws: StringCatalogError.fixedPixelLabelMissing(label: label, key: key)) {
            try EnglishStringCatalog.validateFixedPixelLabels(in: CatalogFixture.catalog(strings))
        }
    }

    @Test("A pluralized pixel label fails closed")
    func varyingPixelLabelFailsClosed() throws {
        // A fixed string has no plural form. An entry that varies has no single value to
        // check against the requirement, so it is refused rather than checked against
        // whichever variation came first.
        let label = PixelLabelKey.signalsConsistentWithAIGeneration
        let key = try #require(EnglishStringCatalog.fixedPixelLabelKeys[label])
        var strings = try Self.authored().strings
        strings[key.rawValue] = CatalogFixture.pluralEntry(
            categories: [
                "one": "Signals consistent with AI generation",
                "other": "Signals consistent with AI generation",
            ]
        )

        #expect(throws: StringCatalogError.fixedPixelLabelVaries(label: label, key: key)) {
            try EnglishStringCatalog.validateFixedPixelLabels(in: CatalogFixture.catalog(strings))
        }
    }

    @Test("No value carries a probability, confidence, or percentage reading")
    func noValueReadsAsAMagnitude() throws {
        // Requirement 8.13 removes probability and confidence representations from every
        // user-facing surface, so the check belongs to the catalog and not only to the
        // three fixed labels.
        let prohibited = [
            "%", "probab", "confidence", "certain", "likelihood", "chance", "score",
            "accuracy", "guarantee",
        ]

        for leaf in try Self.authored().leaves {
            #expect(
                leaf.unit.value.contains(where: \.isNumber) == false,
                "\(leaf.address) contains a digit"
            )
            for fragment in prohibited {
                #expect(
                    leaf.unit.value.lowercased().contains(fragment) == false,
                    "\(leaf.address) contains \(fragment)"
                )
            }
        }
    }

    @Test("No value assumes a rendered width or is a concatenation fragment")
    func noValueAssumesAWidth() throws {
        // The design's one sentence for Requirements 12.15 and 12.16: no string
        // concatenation, no fixed-width text assumptions, no semantic logic based on
        // displayed English.
        for leaf in try Self.authored().leaves {
            for defect in ConcatenationDefect.allCases {
                #expect(defect.matches(leaf.unit.value) == false, "\(leaf.address) \(defect)")
            }
            for defect in FixedWidthDefect.allCases {
                #expect(defect.matches(leaf.unit.value) == false, "\(leaf.address) \(defect)")
            }
        }
    }

    @Test("The resource name and extension address the shipped file")
    func resourceNameAddressesTheShippedFile() throws {
        let root = try #require(PackageSourceTree.packageRoot)
        let url = root.appending(path: PackageSourceTree.shippedCatalogRelativePath)

        #expect(url.deletingPathExtension().lastPathComponent == EnglishStringCatalog.resourceName)
        #expect(url.pathExtension == EnglishStringCatalog.resourceExtension)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

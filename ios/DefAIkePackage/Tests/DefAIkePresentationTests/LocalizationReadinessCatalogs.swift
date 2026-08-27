import Foundation

@testable import DefAIkePresentation

// The Localization Readiness Suite's four test catalogs.
//
// Requirement 12.15 and Requirement 12.16 both begin "WHEN Localization_Readiness_Suite
// test copy replaces English user-facing copy". Replacement is the mechanism: the app
// addresses copy by ``ApprovedCopyKey``, so substituting a catalog that carries the same
// keys and different values exercises every layout and every accessibility semantic
// without changing one line of view code.
//
// Each variant attacks a different English-specific assumption:
//
// | Variant | What it breaks |
// |---|---|
// | Expansion | a layout sized for English's length |
// | Long word | a layout that relies on word wrapping to fit |
// | Bidirectional | a layout or reading order that assumes left to right |
// | Pseudolocalized | a clipped, truncated, or hard-coded English string |
//
// They live in the test target, and that is the whole of the "no additional Version 1
// user-facing language" guarantee: a test target belongs to no product, so nothing
// linkable into the app or the Share Extension can reach these files. Their language tags
// carry BCP 47 private-use subtags (`-x-`) as a second, readable signal that none of them
// is a locale anyone ships.
//
// Loading them here goes through `Bundle.module`, which holds them verbatim because
// `Package.swift` declares them with `.copy`.

/// One Localization Readiness Suite catalog.
enum LocalizationReadinessVariant: String, CaseIterable, Sendable {
    /// Roughly twice the English length.
    case expansion

    /// One unbreakable token.
    case longWord

    /// Right-to-left isolate around mixed-direction text.
    case bidirectional

    /// Accented characters inside boundary brackets.
    case pseudolocalized

    /// The catalog file's base name.
    var resourceName: String {
        switch self {
        case .expansion: "Expansion"
        case .longWord: "LongWord"
        case .bidirectional: "Bidirectional"
        case .pseudolocalized: "Pseudolocalized"
        }
    }

    /// The private-use language tag this variant's values are filed under.
    ///
    /// A private-use subtag is a valid BCP 47 tag that no locale registry assigns, so it
    /// cannot be mistaken for a shipping localization.
    var languageTag: String {
        switch self {
        case .expansion: "en-x-expand"
        case .longWord: "en-x-longword"
        case .bidirectional: "ar-x-bidi"
        case .pseudolocalized: "en-x-pseudo"
        }
    }
}

enum LocalizationReadinessCatalogs {
    /// Subdirectory the catalogs occupy inside the test resource bundle.
    static let bundleSubdirectory = "LocalizationReadiness"

    enum LoadFailure: Error, CustomStringConvertible {
        case resourceMissing(String)
        case unreadable(String)

        var description: String {
            switch self {
            case let .resourceMissing(name):
                "\(name).xcstrings is not in the test resource bundle"
            case let .unreadable(name):
                "\(name).xcstrings could not be read"
            }
        }
    }

    /// Decodes one readiness catalog from the test resource bundle.
    ///
    /// Deliberately not validated as an English source catalog: it is not one, and
    /// ``LocalizationReadinessCatalogTests`` asserts that it is refused as one.
    static func load(_ variant: LocalizationReadinessVariant) throws -> StringCatalog {
        guard
            let url = Bundle.module.url(
                forResource: variant.resourceName,
                withExtension: EnglishStringCatalog.resourceExtension,
                subdirectory: bundleSubdirectory
            )
        else {
            throw LoadFailure.resourceMissing(variant.resourceName)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw LoadFailure.unreadable(variant.resourceName)
        }
        return try EnglishStringCatalog.decode(data)
    }

    /// The value one readiness catalog supplies for `key`.
    static func value(
        _ variant: LocalizationReadinessVariant,
        forKey key: String
    ) throws -> String? {
        try load(variant).singleValue(forKey: key, language: variant.languageTag)
    }
}

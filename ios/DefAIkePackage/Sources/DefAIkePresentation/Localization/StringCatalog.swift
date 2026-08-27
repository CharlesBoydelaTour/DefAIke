import Foundation

// A parsed, typed view of one String Catalog (`.xcstrings`).
//
// The catalogue artifact (`ApprovedVerdictCopyCatalog`) says which localization *key*
// each user-facing surface is addressed by. This type is the other half: the English
// *values* those keys resolve to. Requirement 8.18 makes English the only Version 1
// user-facing language, and the design fixes where the values live - "Version 1 ships
// only English values in a String Catalog, with no string concatenation, fixed-width
// text assumptions, or semantic logic based on displayed English."
//
// Why a parser at all, when iOS can read a catalog for us:
//
//   * a compiled catalog answers "what does this key render as" but cannot answer
//     "does every addressed key have an approved value", and a missing value has to be
//     a release-validation failure rather than a rendered key
//     (see ``ResolvedCopyReference``);
//   * the rules Requirements 12.15 and 12.16 depend on - no concatenation fragments,
//     no fixed-width assumptions, reorderable arguments - are properties of the
//     catalog's *contents*, checkable before anything is built or rendered; and
//   * the compilation step belongs to Xcode, so a check that needs Xcode to have run
//     cannot gate a change.
//
// So this file models the format and nothing more. It renders no text, selects no
// plural form, and applies no substitution: it decodes, exposes every leaf value, and
// lets ``StringCatalog/validateAsEnglishSourceCatalog()`` refuse a catalog that would
// not survive localization. Rendering is the view layer's, and the platform's, job.

/// One decoded String Catalog.
///
/// Field names match Apple's on-disk `.xcstrings` schema so a catalog edited in Xcode
/// round-trips without a translation layer.
public struct StringCatalog: Hashable, Sendable, Codable {
    /// Catalog format version, as written by Xcode.
    public let version: String

    /// The language the values are authored in. `en` for every shipping catalog
    /// (Requirement 8.18).
    public let sourceLanguage: String

    /// Every entry, keyed by its localization key.
    public let strings: [String: StringCatalogEntry]

    public init(
        version: String,
        sourceLanguage: String,
        strings: [String: StringCatalogEntry]
    ) {
        self.version = version
        self.sourceLanguage = sourceLanguage
        self.strings = strings
    }

    /// Every localization key in the catalog, sorted, so a report is deterministic.
    public var keys: [String] { strings.keys.sorted() }

    /// Every language tag that appears anywhere in the catalog.
    ///
    /// Gathered from the entries rather than from ``sourceLanguage``, because an extra
    /// shipped language arrives as an extra localization on an entry, not as a change
    /// to the source language.
    public var languageTags: Set<String> {
        Set(strings.values.flatMap(\.localizations.keys))
    }

    /// The localization for one key and language, or `nil` when absent.
    public func localization(
        forKey key: String,
        language: String
    ) -> StringCatalogLocalization? {
        strings[key]?.localizations[language]
    }

    /// The single string value for one key and language.
    ///
    /// `nil` when the key is absent, the language is absent, or the entry varies by
    /// plural or device - a varying entry has no one value, and quietly returning the
    /// first variation would hide that.
    public func singleValue(forKey key: String, language: String) -> String? {
        guard let localization = localization(forKey: key, language: language) else {
            return nil
        }
        guard localization.variations == nil else { return nil }
        return localization.stringUnit?.value
    }

    /// Every leaf string unit in the catalog, in deterministic order.
    ///
    /// A plural or device variation, and every substitution variation, contributes its
    /// own leaf. Validation walks leaves rather than top-level entries so a rule
    /// cannot be evaded by hiding a value one level down.
    public var leaves: [StringCatalogLeaf] {
        keys.flatMap { key in
            let entry = strings[key]!
            return entry.localizations.keys.sorted().flatMap { language in
                entry.localizations[language]!.leaves(
                    key: key,
                    language: language,
                    path: []
                )
            }
        }
    }
}

/// One key's entry.
public struct StringCatalogEntry: Hashable, Sendable, Codable {
    /// Translator-facing note. Never user-facing.
    public let comment: String?

    /// How the entry entered the catalog. Every DefAIke entry is `manual`: the code
    /// carries ``ApprovedCopyKey`` values rather than literal strings, so nothing is
    /// extracted from source.
    public let extractionState: String?

    /// Xcode's "don't localize this" marker.
    ///
    /// Modelled so it can be refused. An entry exempt from translation could not be
    /// replaced by Localization Readiness Suite test copy, which is exactly what
    /// Requirements 12.15 and 12.16 exercise.
    public let shouldTranslate: Bool?

    /// One localization per language tag.
    public let localizations: [String: StringCatalogLocalization]

    public init(
        comment: String? = nil,
        extractionState: String? = nil,
        shouldTranslate: Bool? = nil,
        localizations: [String: StringCatalogLocalization]
    ) {
        self.comment = comment
        self.extractionState = extractionState
        self.shouldTranslate = shouldTranslate
        self.localizations = localizations
    }
}

/// One key's value in one language: a single unit, a set of variations, or a unit with
/// named substitutions.
public struct StringCatalogLocalization: Hashable, Sendable, Codable {
    public let stringUnit: StringCatalogStringUnit?
    public let variations: StringCatalogVariations?

    /// Named substitutions referenced from ``stringUnit`` as `%#@name@`.
    ///
    /// This is how a sentence carries a pluralized part without being assembled from
    /// pieces at runtime: the whole sentence, including word order and the plural
    /// forms, stays inside the catalog.
    public let substitutions: [String: StringCatalogSubstitution]?

    public init(
        stringUnit: StringCatalogStringUnit? = nil,
        variations: StringCatalogVariations? = nil,
        substitutions: [String: StringCatalogSubstitution]? = nil
    ) {
        self.stringUnit = stringUnit
        self.variations = variations
        self.substitutions = substitutions
    }

    /// Every leaf reachable from this localization.
    func leaves(key: String, language: String, path: [String]) -> [StringCatalogLeaf] {
        var found: [StringCatalogLeaf] = []
        if let stringUnit {
            found.append(
                StringCatalogLeaf(key: key, language: language, path: path, unit: stringUnit)
            )
        }
        if let variations {
            found += variations.leaves(key: key, language: language, path: path)
        }
        for name in (substitutions ?? [:]).keys.sorted() {
            found += substitutions![name]!.variations.leaves(
                key: key,
                language: language,
                path: path + ["substitution:\(name)"]
            )
        }
        return found
    }
}

/// Plural and device variations of one localization.
public struct StringCatalogVariations: Hashable, Sendable, Codable {
    /// Plural categories, keyed by CLDR category (`zero`, `one`, `two`, `few`,
    /// `many`, `other`).
    public let plural: [String: StringCatalogLocalization]?

    /// Device variations, keyed by device class.
    public let device: [String: StringCatalogLocalization]?

    public init(
        plural: [String: StringCatalogLocalization]? = nil,
        device: [String: StringCatalogLocalization]? = nil
    ) {
        self.plural = plural
        self.device = device
    }

    func leaves(key: String, language: String, path: [String]) -> [StringCatalogLeaf] {
        var found: [StringCatalogLeaf] = []
        for category in (plural ?? [:]).keys.sorted() {
            found += plural![category]!.leaves(
                key: key,
                language: language,
                path: path + ["plural:\(category)"]
            )
        }
        for deviceClass in (device ?? [:]).keys.sorted() {
            found += device![deviceClass]!.leaves(
                key: key,
                language: language,
                path: path + ["device:\(deviceClass)"]
            )
        }
        return found
    }
}

/// One named substitution and the format specifier it stands in for.
public struct StringCatalogSubstitution: Hashable, Sendable, Codable {
    /// Which format argument this substitution consumes, one-based.
    public let argNum: Int

    /// The specifier the argument arrives as, without the leading `%`.
    public let formatSpecifier: String

    /// The substitution's own variations. A substitution exists to vary, so this is
    /// not optional.
    public let variations: StringCatalogVariations

    public init(argNum: Int, formatSpecifier: String, variations: StringCatalogVariations) {
        self.argNum = argNum
        self.formatSpecifier = formatSpecifier
        self.variations = variations
    }
}

/// One translatable value and its review state.
public struct StringCatalogStringUnit: Hashable, Sendable, Codable {
    /// Review state, as written by Xcode. `translated` is the only state a shipping
    /// value may carry.
    public let state: String

    /// The value itself.
    public let value: String

    public init(state: String, value: String) {
        self.state = state
        self.value = value
    }
}

/// One value in the catalog, addressed well enough to name it in a failure.
public struct StringCatalogLeaf: Hashable, Sendable {
    public let key: String
    public let language: String

    /// Variation and substitution steps taken to reach this value, outermost first.
    /// Empty for a plain entry.
    public let path: [String]

    public let unit: StringCatalogStringUnit

    /// Stable address of this value, for deterministic failure reports.
    public var address: String {
        ([key, language] + path).joined(separator: "/")
    }
}

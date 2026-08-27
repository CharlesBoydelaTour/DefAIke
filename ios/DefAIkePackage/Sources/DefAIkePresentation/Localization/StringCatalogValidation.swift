import DefAIkeDomain
import Foundation

// The rules a shipping English String Catalog has to satisfy.
//
// Three requirements meet here, and each contributes rules that are checkable on a
// catalog's contents alone:
//
//   * Requirement 8.18 - English is the only Version 1 user-facing language. So the
//     source language is `en`, and `en` is the only localization anywhere in the file.
//     A second localization is not a partially translated release, it is a different
//     release.
//   * Requirement 12.15 - Localization Readiness Suite test copy replaces English copy
//     and every label, explanation, warning, progress state, and action stays visible
//     and reachable without overlap, clipping, or truncation. So no value may assume a
//     rendered width: no tab alignment, no space padding, no embedded line break, and
//     no format specifier that pads or truncates to a fixed size.
//   * Requirement 12.16 - substituted test copy preserves meaning, reading order,
//     labels, values, and traits. So a sentence has to survive being rewritten whole:
//     no value may be a fragment that the code glues to a neighbour, and a value with
//     two or more arguments has to number them so a translation can reorder them.
//
// The design states the same three constraints as one sentence: "no string
// concatenation, fixed-width text assumptions, or semantic logic based on displayed
// English."
//
// Two things this validator does not do. It does not approve wording - content approval
// is a human gate recorded on the catalogue artifact, and no rule here substitutes for
// it. And it does not repair: a defect is reported, never trimmed, padded, or
// normalized away, because a repaired sentence is a sentence nobody approved.

extension StringCatalog {
    /// CLDR plural categories. Anything else is a typo or an invented category, and
    /// either way it selects nothing.
    public static let pluralCategories: Set<String> = [
        "zero", "one", "two", "few", "many", "other",
    ]

    /// The extraction state every DefAIke entry carries.
    ///
    /// The code addresses copy by ``ApprovedCopyKey`` and holds no user-facing literal,
    /// so nothing is extracted from source. Any other state means the catalog and the
    /// code disagree about where copy lives.
    public static let requiredExtractionState = "manual"

    /// The only review state an approved value may carry.
    public static let requiredTranslationState = "translated"

    /// Refuses this catalog unless it is a valid shipping English source catalog.
    ///
    /// Throws the first defect in deterministic order. Use ``englishSourceDefects`` when
    /// a report wants every defect at once.
    public func validateAsEnglishSourceCatalog() throws(StringCatalogError) {
        if let first = englishSourceDefects.first { throw first }
    }

    /// Every reason this catalog is not a valid shipping English source catalog, in
    /// deterministic order.
    ///
    /// Deterministic because a release report has to be diffable: entries are visited in
    /// sorted key order and, within an entry, in sorted language order.
    public var englishSourceDefects: [StringCatalogError] {
        var defects: [StringCatalogError] = []
        let required = ApprovedVerdictCopyCatalog.requiredLanguageTag

        guard !strings.isEmpty else { return [.emptyCatalog] }

        if sourceLanguage != required {
            defects.append(
                .unsupportedSourceLanguage(expected: required, found: sourceLanguage)
            )
        }

        let tags = languageTags
        let additional = tags.subtracting([required]).sorted()
        if !additional.isEmpty {
            defects.append(.additionalUserFacingLanguages(additional))
        }
        if !tags.contains(required) {
            defects.append(.missingRequiredLanguage(required))
        }

        for key in keys {
            if ApprovedCopyKey(key) == nil {
                defects.append(.noncanonicalKey(key))
            }

            let entry = strings[key]!
            if entry.extractionState != Self.requiredExtractionState {
                defects.append(
                    .unexpectedExtractionState(key: key, state: entry.extractionState)
                )
            }
            if entry.shouldTranslate == false {
                defects.append(.nonTranslatableEntry(key: key))
            }

            for language in entry.localizations.keys.sorted() {
                let localization = entry.localizations[language]!
                defects += Self.defects(
                    in: localization,
                    key: key,
                    language: language,
                    path: []
                )

                let declared = Set((localization.substitutions ?? [:]).keys)
                let referenced = localization.referencedSubstitutionNames
                for name in referenced.subtracting(declared).sorted() {
                    defects.append(
                        .undeclaredSubstitution(
                            address: StringCatalogLeaf.address(key: key, language: language),
                            name: name
                        )
                    )
                }
                for name in declared.subtracting(referenced).sorted() {
                    defects.append(
                        .unusedSubstitution(key: key, language: language, name: name)
                    )
                }
            }
        }

        return defects
    }

    /// Defects inside one localization, including every variation and substitution.
    private static func defects(
        in localization: StringCatalogLocalization,
        key: String,
        language: String,
        path: [String]
    ) -> [StringCatalogError] {
        var defects: [StringCatalogError] = []

        if let unit = localization.stringUnit {
            defects += Self.defects(
                in: unit,
                address: StringCatalogLeaf.address(key: key, language: language, path: path)
            )
        }

        if let variations = localization.variations {
            defects += Self.defects(
                in: variations,
                key: key,
                language: language,
                path: path
            )
        }

        for name in (localization.substitutions ?? [:]).keys.sorted() {
            defects += Self.defects(
                in: localization.substitutions![name]!.variations,
                key: key,
                language: language,
                path: path + ["substitution:\(name)"]
            )
        }

        return defects
    }

    private static func defects(
        in variations: StringCatalogVariations,
        key: String,
        language: String,
        path: [String]
    ) -> [StringCatalogError] {
        var defects: [StringCatalogError] = []

        if let plural = variations.plural {
            let address = StringCatalogLeaf.address(key: key, language: language, path: path)
            if !plural.keys.contains("other") {
                defects.append(.missingPluralOtherCategory(address: address))
            }
            for category in plural.keys.sorted() where !pluralCategories.contains(category) {
                defects.append(.unknownPluralCategory(address: address, category: category))
            }
            for category in plural.keys.sorted() {
                defects += Self.defects(
                    in: plural[category]!,
                    key: key,
                    language: language,
                    path: path + ["plural:\(category)"]
                )
            }
        }

        for deviceClass in (variations.device ?? [:]).keys.sorted() {
            defects += Self.defects(
                in: variations.device![deviceClass]!,
                key: key,
                language: language,
                path: path + ["device:\(deviceClass)"]
            )
        }

        return defects
    }

    /// Defects in one value.
    private static func defects(
        in unit: StringCatalogStringUnit,
        address: String
    ) -> [StringCatalogError] {
        var defects: [StringCatalogError] = []

        if unit.state != requiredTranslationState {
            defects.append(.untranslatedValue(address: address, state: unit.state))
        }

        let value = unit.value
        guard
            !value.isEmpty,
            !value.allSatisfy(\.isWhitespace)
        else {
            return defects + [.emptyValue(address: address)]
        }

        for defect in ConcatenationDefect.allCases where defect.matches(value) {
            defects.append(.concatenationFragment(address: address, reason: defect))
        }
        for defect in FixedWidthDefect.allCases where defect.matches(value) {
            defects.append(.fixedWidthAssumption(address: address, reason: defect))
        }

        // One argument may be non-positional: there is no order to get wrong. Two or
        // more have to be numbered, or the sentence's argument order is English's.
        let specifiers = StringCatalogFormat.argumentSpecifiers(in: value)
        if specifiers.count > 1, specifiers.contains(where: { $0.argumentNumber == nil }) {
            defects.append(
                .nonpositionalArguments(address: address, argumentCount: specifiers.count)
            )
        }

        return defects
    }
}

extension StringCatalogLocalization {
    /// Substitution names this localization's own values reference.
    ///
    /// Values *inside* substitutions are excluded: a substitution's variations supply
    /// the substituted text and do not reference further substitutions.
    var referencedSubstitutionNames: Set<String> {
        var names: Set<String> = []
        if let stringUnit {
            names.formUnion(StringCatalogFormat.substitutionReferences(in: stringUnit.value))
        }
        if let variations {
            names.formUnion(variations.referencedSubstitutionNames)
        }
        return names
    }
}

extension StringCatalogVariations {
    var referencedSubstitutionNames: Set<String> {
        var names: Set<String> = []
        for localization in (plural ?? [:]).values {
            names.formUnion(localization.referencedSubstitutionNames)
        }
        for localization in (device ?? [:]).values {
            names.formUnion(localization.referencedSubstitutionNames)
        }
        return names
    }
}

extension StringCatalogLeaf {
    /// The stable address of one value, without needing a leaf to exist yet.
    static func address(key: String, language: String, path: [String] = []) -> String {
        ([key, language] + path).joined(separator: "/")
    }
}

extension ConcatenationDefect {
    /// Whether `value` carries this defect's mechanical signature.
    ///
    /// These are signatures, not a judgement about prose. A value that reads oddly is a
    /// content-approval question; a value that cannot stand alone is a structural one,
    /// and only the second is decidable here.
    func matches(_ value: String) -> Bool {
        switch self {
        case .surroundingWhitespace:
            return value.first?.isWhitespace == true || value.last?.isWhitespace == true

        case .separatorOnly:
            return value.allSatisfy { character in
                character.isWhitespace || character.isPunctuation || character.isSymbol
            }

        case .specifierOnly:
            let specifiers = StringCatalogFormat.argumentSpecifiers(in: value)
            guard !specifiers.isEmpty else { return false }
            return StringCatalogFormat.literalText(in: value).allSatisfy(\.isWhitespace)
        }
    }
}

extension FixedWidthDefect {
    /// Whether `value` carries this defect's mechanical signature.
    func matches(_ value: String) -> Bool {
        switch self {
        case .tabAlignment:
            return value.contains("\t")

        case .spacePadding:
            return value.contains("  ")

        case .embeddedLineBreak:
            return value.contains(where: \.isNewline)

        case .specifierFieldWidth:
            return StringCatalogFormat
                .argumentSpecifiers(in: value)
                .contains(where: \.hasFieldWidthOrPrecision)
        }
    }
}

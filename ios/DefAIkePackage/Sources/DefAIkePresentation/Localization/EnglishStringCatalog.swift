import DefAIkeDomain
import Foundation

// The one English String Catalog this module ships.
//
// Requirement 8.18 makes English the only Version 1 user-facing language, and the design
// puts the values in a String Catalog. This type is that catalog's identity: where the
// resource lives, which language it must be authored in, and the three keys whose values
// Requirement 8.2 fixes character for character.
//
// Why the catalog is read rather than resolved through `NSLocalizedString`. A
// localization lookup that misses returns the key, so the user sees `copy.evidence-scope`
// where an approved sentence belongs. ``ResolvedCopyReference`` states the opposite rule -
// "a lookup that finds no value there is a release-validation failure, never a reason to
// show this key to a user" - and a mechanism whose documented miss behavior is to render
// the key cannot implement that rule. So the catalog is carried verbatim, parsed, and
// validated, and a missing value is an error before anything renders. That is also why
// `Package.swift` declares the resource with `.copy` rather than `.process`: the bytes
// have to stay readable at runtime under both build systems, not be compiled into a
// lookup table with a silent fallback.
//
// What this type does not contain: any approved wording beyond the three fixed pixel
// labels. The rest of Version 1's user-facing text is external approved content (the
// unresolved Approved Verdict Copy decision), so the shipping catalog carries what the
// requirements fix and nothing invented. ``StringCatalogCoverage`` is what turns a gap
// into a named release-validation failure instead of a blank screen.

public enum EnglishStringCatalog: Sendable {
    /// The catalog resource's base name.
    public static let resourceName = "Localizable"

    /// The catalog resource's extension.
    public static let resourceExtension = "xcstrings"

    /// The subdirectory the catalog occupies inside the module's resource bundle.
    ///
    /// `Package.swift` copies this whole directory rather than the catalog file, because a
    /// `.xcstrings` named directly in a resource phase is claimed by Xcode's String Catalog
    /// compiler whatever rule declared it — see the comment there. A directory resource is
    /// copied verbatim by both build systems, so the bytes survive, and the price is that
    /// the lookup has to name the subdirectory.
    ///
    /// Not `Resources`: a `.bundle` with a top-level `Resources` directory reads to
    /// `codesign` as a framework-style bundle and is refused outright, which breaks every
    /// signed build.
    public static let resourceSubdirectory = "ApprovedCopy"

    /// The only user-facing language Version 1 ships (Requirement 8.18).
    ///
    /// Taken from the domain's catalogue schema rather than restated, so the artifact
    /// layer and the String Catalog cannot drift apart.
    public static var requiredLanguageTag: String {
        ApprovedVerdictCopyCatalog.requiredLanguageTag
    }

    /// The localization keys carrying the three display strings Requirement 8.2 fixes.
    ///
    /// These are the only keys named in code. The Approved Verdict Copy catalogue
    /// artifact remains the authority on which key addresses which surface; these three
    /// are pinned because the requirement fixes their *values*, and a value cannot be
    /// checked without knowing where it lives. The naming follows the same convention as
    /// every other key - `copy.` followed by the surface's stable identifier - so there
    /// is one scheme rather than two.
    public static let fixedPixelLabelKeys: [PixelLabelKey: ApprovedCopyKey] = Dictionary(
        uniqueKeysWithValues: PixelLabelKey.allCases.map { label in
            (label, conventionalKey(for: .pixelLabel(label)))
        }
    )

    /// The key convention: `copy.` followed by the surface's stable identifier, with the
    /// surface separator flattened to a dot.
    ///
    /// Force-unwrap is sound: a surface identifier is built from lowercase ASCII letters,
    /// digits, and hyphens, and dots are permitted in a canonical identifier, so the
    /// rejection conditions cannot hold.
    private static func conventionalKey(for surface: VerdictCopySurface) -> ApprovedCopyKey {
        ApprovedCopyKey("copy." + surface.description.replacingOccurrences(of: "/", with: "."))!
    }

    // MARK: - Loading

    /// Decodes a String Catalog from `data` without validating it.
    ///
    /// Separate from ``validate(_:)`` so a failure names one layer: malformed bytes and a
    /// well-formed catalog that breaks a localization rule are different findings.
    public static func decode(_ data: Data) throws(StringCatalogError) -> StringCatalog {
        do {
            return try JSONDecoder().decode(StringCatalog.self, from: data)
        } catch {
            throw .undecodable(description: String(describing: error))
        }
    }

    /// Loads and validates the catalog this module ships.
    ///
    /// Throws rather than returning an empty catalog: a build whose own approved copy is
    /// missing or invalid has nothing safe to render.
    public static func loadShippedCatalog() throws(StringCatalogError) -> StringCatalog {
        guard
            let url = Bundle.module.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: resourceSubdirectory
            ),
            let data = try? Data(contentsOf: url)
        else {
            throw .undecodable(
                description: """
                    \(resourceSubdirectory)/\(resourceName).\(resourceExtension) is not \
                    readable from the DefAIkePresentation resource bundle
                    """
            )
        }

        let catalog = try decode(data)
        try validate(catalog)
        // Chrome coverage is audited here rather than inside `validate(_:)` on purpose.
        // `validate(_:)` states what makes a *well-formed English source catalog*, and the
        // Localization Readiness Suite substitutes expansion, long-word, bidirectional, and
        // pseudolocalized catalogs through it to show that layout and semantics survive
        // (Requirements 12.15 and 12.16). Requiring chrome coverage there would make every one
        // of those catalogs also a complete approved-copy set, which is a different claim.
        //
        // What the *shipped* catalog owes is different and stricter: every chrome surface is
        // reachable in every composition, so a shipped catalog missing one cannot render a
        // named control. Refusing here means that build blocks startup with
        // `approvedCopyUnreadable` instead of presenting an unlabelled button.
        try ChromeCopyCoverage.audit(catalog)
        return catalog
    }

    // MARK: - Validation

    /// Refuses `catalog` unless it is a valid shipping English source catalog carrying
    /// the three required pixel-label strings exactly.
    public static func validate(_ catalog: StringCatalog) throws(StringCatalogError) {
        try catalog.validateAsEnglishSourceCatalog()
        try validateFixedPixelLabels(in: catalog)
    }

    /// Checks the three display strings Requirement 8.2 fixes character for character.
    ///
    /// ``FixedPixelLabelText`` stays the single authority on the strings themselves, so
    /// this reads the catalog and hands the value to that type rather than restating any
    /// literal. A mismatch fails closed: a copy edit, a plural rule, or a substitution
    /// cannot quietly turn a qualified label into a different claim.
    public static func validateFixedPixelLabels(
        in catalog: StringCatalog
    ) throws(StringCatalogError) {
        for label in PixelLabelKey.allCases {
            // Force-unwrap is sound: the dictionary is built from `allCases`.
            let key = fixedPixelLabelKeys[label]!

            guard catalog.strings[key.rawValue] != nil else {
                throw .fixedPixelLabelMissing(label: label, key: key)
            }
            guard
                let value = catalog.singleValue(
                    forKey: key.rawValue,
                    language: requiredLanguageTag
                )
            else {
                throw .fixedPixelLabelVaries(label: label, key: key)
            }

            do {
                try FixedPixelLabelText.validate(rendered: value, for: label)
            } catch {
                guard case let .pixelLabelTextMismatch(_, expected, found) = error else {
                    throw .fixedPixelLabelMismatch(
                        label: label,
                        expected: FixedPixelLabelText(label: label).value,
                        found: value
                    )
                }
                throw .fixedPixelLabelMismatch(label: label, expected: expected, found: found)
            }
        }
    }
}

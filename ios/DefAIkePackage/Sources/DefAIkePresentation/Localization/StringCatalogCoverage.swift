import DefAIkeDomain

// The join between the two halves of Approved Verdict Copy.
//
// ``ApprovedCopyBinding`` already refused a release whose catalogue omits a reachable
// surface, so after binding every reachable surface has a *key*. That is a different
// question from whether the key has an approved English *value*, and Requirement 8.1
// needs both: version-controlled copy for every reachable label, provenance state,
// unavailable state, Combined Summary, warning, and Analysis Error.
//
// So this is the second gate, and it is the one ``ResolvedCopyReference`` names: "a
// lookup that finds no value there is a release-validation failure, never a reason to
// show this key to a user." It runs against a bound catalogue rather than against a
// hard-coded key list, because which keys a release addresses is the approved artifact's
// decision, and which surfaces are reachable depends on the capability composition.
//
// Nothing here approves wording, and nothing here fills a gap. A missing value is
// reported by key so an audit can name it, and the report carries no substitute text.

public enum StringCatalogCoverage: Sendable {
    /// Localization keys `binding` can resolve that `catalog` has no approved value for,
    /// in stable order.
    ///
    /// A key counts as covered only when the required language carries a value whose
    /// review state is `translated` and whose text is not blank. A `new` or
    /// `needs_review` entry is unapproved wording, and an approved blank sentence does
    /// not exist.
    public static func missingValues(
        in catalog: StringCatalog,
        for binding: ApprovedCopyBinding
    ) -> [ApprovedCopyKey] {
        let language = EnglishStringCatalog.requiredLanguageTag

        let addressed = binding.reachableSurfaces.surfaces
            .compactMap { binding.localizationKey(for: $0) }

        let missing = Set(addressed).filter { key in
            !isCovered(key: key.rawValue, language: language, in: catalog)
        }

        return missing.sorted { $0.rawValue < $1.rawValue }
    }

    /// Refuses `catalog` unless it has an approved value for every key `binding` can
    /// resolve.
    public static func audit(
        _ catalog: StringCatalog,
        for binding: ApprovedCopyBinding
    ) throws(StringCatalogError) {
        let missing = missingValues(in: catalog, for: binding)
        guard missing.isEmpty else {
            throw .missingApprovedValues(missing)
        }
    }

    /// Whether one key has at least one approved, non-blank value in `language`.
    ///
    /// Every leaf counts, so a pluralized or substituted entry is covered by its
    /// variations rather than being treated as absent for lacking a single value.
    private static func isCovered(
        key: String,
        language: String,
        in catalog: StringCatalog
    ) -> Bool {
        guard let entry = catalog.strings[key],
            let localization = entry.localizations[language]
        else {
            return false
        }
        let leaves = localization.leaves(key: key, language: language, path: [])
        guard !leaves.isEmpty else { return false }
        return leaves.allSatisfy { leaf in
            leaf.unit.state == StringCatalog.requiredTranslationState
                && !leaf.unit.value.allSatisfy(\.isWhitespace)
                && !leaf.unit.value.isEmpty
        }
    }
}

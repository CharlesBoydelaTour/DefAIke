import DefAIkeDomain

// The chrome half of "an approved key is not an approved value".
//
// `StringCatalogCoverage` answers that question for verdict copy, and it has to take an
// `ApprovedCopyBinding` to do it, because which verdict surfaces are reachable depends on the
// capability composition and on the active fusion rule. Chrome has no such conditionality:
// every surface in `ChromeCopySurface` is reachable in every composition, because the picker
// control, the two status sentences, the cancel control, and the cancelled terminal exist in
// every build. So the required set is `allCases`, and the audit needs no binding.
//
// The consequence is stricter than the verdict path, deliberately. A verdict-copy gap is
// reported against a bound catalogue during release validation; a chrome gap is refused at
// launch, inside `EnglishStringCatalog.loadShippedCatalog()`. That is the right asymmetry:
// a build with no approved wording for its own cancel button cannot render a usable screen at
// all, so it should refuse to start rather than present an unnamed control.
//
// Nothing here approves wording and nothing substitutes text. A missing value is reported by
// key.

public enum ChromeCopyCoverage: Sendable {
    /// Chrome keys `catalog` has no approved value for, in stable order.
    ///
    /// A key counts as covered on exactly the terms `StringCatalogCoverage` uses: the required
    /// language carries a value whose review state is `translated` and whose text is not blank.
    /// A `new` or `needs_review` entry is unapproved wording, and an approved blank sentence
    /// does not exist.
    public static func missingValues(in catalog: StringCatalog) -> [ApprovedCopyKey] {
        ChromeCopySurface.requiredLocalizationKeys.filter { key in
            !isCovered(key: key.rawValue, in: catalog)
        }
    }

    /// Refuses `catalog` unless every chrome surface has an approved value.
    public static func audit(_ catalog: StringCatalog) throws(StringCatalogError) {
        let missing = missingValues(in: catalog)
        guard missing.isEmpty else {
            throw .missingApprovedValues(missing)
        }
    }

    /// Whether one key has a single approved, non-blank value in the required language.
    ///
    /// Single-valued rather than leaf-wise, unlike the verdict audit. No chrome surface takes
    /// an argument, so a plural or device variation at one of these keys has no selector and
    /// `AccessibleTextResolver` would refuse it at render time. Refusing it here instead keeps
    /// the launch-time audit and the render-time rule identical.
    private static func isCovered(key: String, in catalog: StringCatalog) -> Bool {
        let language = EnglishStringCatalog.requiredLanguageTag
        guard let unit = catalog.localization(forKey: key, language: language)?.stringUnit,
            catalog.singleValue(forKey: key, language: language) != nil
        else {
            return false
        }
        return unit.state == StringCatalog.requiredTranslationState
            && !unit.value.isEmpty
            && !unit.value.allSatisfy(\.isWhitespace)
    }
}

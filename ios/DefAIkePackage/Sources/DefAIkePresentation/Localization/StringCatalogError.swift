import DefAIkeDomain

// The fail-closed error vocabulary for String Catalog validation.
//
// Same three absences as ``PresentationCopyError``, for the same reason: no `unknown`
// case, so every refusal names one cause an audit can read back; no case carries
// replacement or degraded text, so "render the raw key" and "render a generated
// sentence" stay unrepresentable; and no case is recoverable by relaxing a check.
//
// Every case addresses the offending value by its stable catalog address rather than by
// quoting a sentence, so a failure report is diffable and does not turn into a second
// place approved copy is written down.

/// Why a String Catalog was refused.
public enum StringCatalogError: Error, Hashable, Sendable {
    // MARK: - Decoding

    /// The bytes are not a decodable String Catalog.
    ///
    /// Carries a description rather than the underlying `DecodingError`, so the error
    /// stays `Hashable` and `Sendable` and a failure cannot smuggle catalog bytes.
    case undecodable(description: String)

    // MARK: - Language

    /// The catalog is not authored in the single Version 1 user-facing language
    /// (Requirement 8.18).
    case unsupportedSourceLanguage(expected: String, found: String)

    /// The catalog carries user-facing values in a language other than English, in
    /// stable order.
    ///
    /// Version 1 ships exactly one user-facing language. A second localization is not
    /// a partially translated release, it is a different release, so it fails rather
    /// than being ignored at render time (Requirement 8.18).
    case additionalUserFacingLanguages([String])

    /// The catalog has no values at all for the required language.
    case missingRequiredLanguage(String)

    // MARK: - Keys

    /// A localization key is not a canonical ``ApprovedCopyKey``.
    ///
    /// Keys share the domain's identifier syntax, so a key cannot carry whitespace,
    /// non-ASCII text, or anything else that would let display or path semantics ride
    /// in on an address.
    case noncanonicalKey(String)

    /// The catalog has no entries.
    case emptyCatalog

    // MARK: - Values

    /// A value's review state is not `translated`, so it is not approved wording.
    case untranslatedValue(address: String, state: String)

    /// A value is empty or whitespace only. There is no such thing as an approved
    /// blank sentence; an absent value is the honest representation.
    case emptyValue(address: String)

    /// An entry entered the catalog by some path other than deliberate authoring.
    ///
    /// The code carries ``ApprovedCopyKey`` values rather than literal strings, so a
    /// non-`manual` extraction state means the catalog and the code disagree about
    /// where copy lives.
    case unexpectedExtractionState(key: String, state: String?)

    /// An entry is marked as not translatable.
    ///
    /// Such an entry could not be replaced by Localization Readiness Suite test copy,
    /// which would exempt it from Requirements 12.15 and 12.16.
    case nonTranslatableEntry(key: String)

    // MARK: - Concatenation

    /// A value is a fragment meant to be glued to another value at runtime.
    ///
    /// The design forbids string concatenation for user-facing text: a sentence
    /// assembled from pieces fixes English word order and grammar in the code, where no
    /// translation and no Localization Readiness Suite substitution can reach it.
    case concatenationFragment(address: String, reason: ConcatenationDefect)

    /// A value uses two or more arguments without positional specifiers.
    ///
    /// Non-positional arguments fix argument order to the English sentence's order,
    /// which is the same fixed-word-order assumption in a different disguise.
    case nonpositionalArguments(address: String, argumentCount: Int)

    /// A value references a substitution the entry does not declare.
    case undeclaredSubstitution(address: String, name: String)

    /// An entry declares a substitution its value never references.
    case unusedSubstitution(key: String, language: String, name: String)

    // MARK: - Fixed width

    /// A value assumes a specific rendered width or line count.
    case fixedWidthAssumption(address: String, reason: FixedWidthDefect)

    // MARK: - Plurals

    /// A plural variation omits the `other` category, which every language requires
    /// and English resolves most counts to.
    case missingPluralOtherCategory(address: String)

    /// A plural variation uses a category that is not a CLDR plural category.
    case unknownPluralCategory(address: String, category: String)

    // MARK: - Coverage

    /// Localization keys an approved catalogue addresses that have no approved English
    /// value, in stable order.
    ///
    /// This is the release-validation failure ``ResolvedCopyReference`` names: a
    /// reachable surface resolved to a key, and the key resolved to nothing. It is not
    /// a reason to render the key.
    case missingApprovedValues([ApprovedCopyKey])

    /// A pixel label whose display string Requirement 8.2 fixes has no catalog entry.
    case fixedPixelLabelMissing(label: PixelLabelKey, key: ApprovedCopyKey)

    /// A pixel label's catalog value is not the exact required string
    /// (Requirement 8.2).
    case fixedPixelLabelMismatch(label: PixelLabelKey, expected: String, found: String)

    /// A pixel label's entry varies by plural or device, so it has no single value and
    /// cannot be checked against a fixed required string.
    case fixedPixelLabelVaries(label: PixelLabelKey, key: ApprovedCopyKey)
}

/// The mechanical signatures of a value built for concatenation.
public enum ConcatenationDefect: String, Hashable, Sendable, CaseIterable {
    /// Leading or trailing whitespace, which exists only to join to a neighbour.
    case surroundingWhitespace = "surrounding-whitespace"

    /// Punctuation and whitespace only, such as a separator or list glue entry.
    case separatorOnly = "separator-only"

    /// The whole value is one format specifier, making the entry a slot rather than a
    /// sentence.
    case specifierOnly = "specifier-only"
}

/// The mechanical signatures of a value that assumes a rendered width.
public enum FixedWidthDefect: String, Hashable, Sendable, CaseIterable {
    /// A tab character, used to align columns.
    case tabAlignment = "tab-alignment"

    /// A run of two or more spaces, used to pad to a column.
    case spacePadding = "space-padding"

    /// A line break. Layouts reflow for Dynamic Type through the largest accessibility
    /// sizes (Requirement 12.8), so a value that hard-wraps itself is asserting a width
    /// the layout does not have.
    case embeddedLineBreak = "embedded-line-break"

    /// A format specifier with a width or precision field, which pads or truncates the
    /// substituted value to a fixed size.
    case specifierFieldWidth = "specifier-field-width"
}

import DefAIkeDomain

// Turning an approved address into the text a view renders and an assistive technology speaks.
//
// This is the only place in the module where an address becomes a `String`, and it is a
// deliberately narrow one. Everything upstream carries ``AccessibilitySemanticSource`` values, so
// the accessibility semantics are the same under every catalog; everything downstream is a view.
// The resolver is what joins them, and it takes the catalog as a parameter rather than reading a
// global one, for two reasons:
//
//   * the Localization Readiness Suite needs to substitute expansion, long-word, bidirectional,
//     and pseudolocalized catalogs for the English one and observe that layout and semantics
//     survive (Requirements 12.15 and 12.16). A resolver that read the shipped catalog directly
//     could not be pointed at a test catalog without changing the code under test.
//   * a missing value has to be a failure, not a fallback. Foundation's own localized-string
//     lookup returns the key when it misses, and ``ResolvedCopyReference`` forbids ever showing a
//     key to a user, so the lookup has to be one this module performs and can refuse.
//
// Refusal is the whole design. There is no default string, no key echo, no partial render, and no
// English literal anywhere below - except the three display strings Requirement 8.2 fixes, which
// come from ``FixedPixelLabelText`` and need no catalog at all. A view that cannot resolve an
// element's text renders nothing for that element, which is the same rule the view-state and
// report layers already follow for an unapproved surface.

/// Resolves approved addresses into displayed text against one catalog.
///
/// A value type over an immutable catalog, so resolving is pure and a test can hold two resolvers
/// over two catalogs at once. It renders nothing itself: it answers "what does this address say",
/// and the view decides what to do with the answer.
public struct AccessibleTextResolver: Hashable, Sendable {
    /// The catalog values are read from.
    public let catalog: StringCatalog

    /// The language tag values are read under.
    public let languageTag: String

    /// A resolver over one catalog and language.
    public init(catalog: StringCatalog, languageTag: String) {
        self.catalog = catalog
        self.languageTag = languageTag
    }

    /// A resolver over one catalog, in the single Version 1 user-facing language.
    public init(catalog: StringCatalog) {
        self.init(catalog: catalog, languageTag: EnglishStringCatalog.requiredLanguageTag)
    }

    /// A resolver over the catalog this module ships.
    ///
    /// Validates the catalog on the way in, so a build whose own approved copy is malformed fails
    /// here rather than at the first label it cannot render.
    public static func shipped() throws(StringCatalogError) -> AccessibleTextResolver {
        AccessibleTextResolver(catalog: try EnglishStringCatalog.loadShippedCatalog())
    }

    /// The text one address resolves to.
    ///
    /// Throws when the catalog has no approved value for the key, when the value is not in the
    /// `translated` review state, or when it is blank. Each of those is the release-validation
    /// failure ``ResolvedCopyReference`` names, and none of them yields substitute text.
    ///
    /// A varying entry - one with plural or device variations - has no single value and is refused
    /// rather than resolved to an arbitrary variation. No approved surface in this module needs
    /// one; if a future one does, it needs the argument the variation selects on, which is a
    /// change to the caller rather than a relaxation here.
    public func text(
        for source: AccessibilitySemanticSource
    ) throws(StringCatalogError) -> String {
        switch source {
        case let .requiredPixelLabelText(fixed):
            // Requirement 8.2 fixes these three character for character, and
            // `FixedPixelLabelText` is their single authority. The catalog carries the same value
            // and `EnglishStringCatalog.validateFixedPixelLabels(in:)` refuses a catalog where the
            // two disagree, so reading the required value here cannot diverge from what a
            // validated catalog holds.
            return fixed.value

        case let .approvedCopy(reference):
            return try approvedValue(at: reference.localizationKey)

        case let .approvedChromeCopy(reference):
            // The identical lookup, deliberately. A chrome address and a verdict address differ
            // in what approved them, not in how a value is read or in what an absent value
            // means, so one refusal path serves both and a chrome miss cannot degrade into a
            // rendered key.
            return try approvedValue(at: reference.localizationKey)
        }
    }

    /// The approved value at one catalog key, or the reason there is none.
    ///
    /// `singleValue` is `nil` for an absent key, an absent language, and a varying entry alike.
    /// All three mean there is no one approved value at this address, and all three are
    /// reported the same way, because the answer a caller needs is the same in each case:
    /// nothing may be rendered here.
    private func approvedValue(
        at key: ApprovedCopyKey
    ) throws(StringCatalogError) -> String {
        let raw = key.rawValue
        guard let unit = catalog.localization(forKey: raw, language: languageTag)?.stringUnit,
            catalog.singleValue(forKey: raw, language: languageTag) != nil
        else {
            throw .missingApprovedValues([key])
        }
        guard unit.state == StringCatalog.requiredTranslationState else {
            throw .untranslatedValue(address: address(of: raw), state: unit.state)
        }
        guard !unit.value.isEmpty, !unit.value.allSatisfy(\.isWhitespace) else {
            throw .emptyValue(address: address(of: raw))
        }
        return unit.value
    }

    /// The catalog address of one key under this resolver's language, for failure reports.
    private func address(of key: String) -> String { "\(key)/\(languageTag)" }

    /// The text one address resolves to, or `nil` when it cannot be resolved.
    ///
    /// The form a view uses. A view has nothing useful to do with the reason, and rendering
    /// nothing is the required behaviour for every reason, so the reason is dropped here and kept
    /// by ``text(for:)`` for the release audit that needs it.
    public func resolvedText(for source: AccessibilitySemanticSource) -> String? {
        try? text(for: source)
    }

    /// Whether every address this element needs resolves.
    ///
    /// The view's own gate: an element whose label does not resolve is not rendered, because a
    /// control with no name and a field with no text are both worse than an absence.
    public func canRender(_ element: AccessibleElement) -> Bool {
        guard resolvedText(for: element.label) != nil else { return false }
        guard let value = element.value else { return true }
        return resolvedText(for: value) != nil
    }

    /// Every element in `snapshot` this resolver can render, in reading order.
    ///
    /// The reading order of the renderable subset is the reading order of the whole, filtered, so
    /// an unresolvable element cannot reorder the ones around it (Requirement 12.4).
    public func renderableElements(
        in snapshot: AccessibilitySemanticsSnapshot
    ) -> [AccessibleElement] {
        snapshot.elements.filter(canRender)
    }

    /// Elements `snapshot` exposes that this catalog cannot supply text for, in reading order.
    ///
    /// The release-validation finding, as a list. A nonempty result means the catalog and the
    /// approved catalogue disagree about which keys have values, which blocks distribution rather
    /// than degrading a screen.
    public func unresolvableElements(
        in snapshot: AccessibilitySemanticsSnapshot
    ) -> [AccessibleElement] {
        snapshot.elements.filter { !canRender($0) }
    }
}

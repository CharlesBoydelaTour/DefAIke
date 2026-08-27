import DefAIkeDomain

// The three exact user-facing pixel labels.
//
// Requirement 8.2 fixes the display strings themselves, character for character:
// `Signals consistent with AI generation`, `No strong signal detected`, or
// `Not enough signal`. That makes them different in kind from every other string in
// the app. All other wording is an unresolved release decision approved outside the
// code and stored in the English String Catalog; these three are a requirement, so
// they are stated here and the String Catalog value is checked against them.
//
// This is not a second source of truth competing with the catalogue. The catalogue
// still owns the *address* of each label, and spec task 11.5 still puts the values in
// the String Catalog. This type owns the assertion that what comes back for a pixel
// label surface is exactly the required string, so a copy edit, a localization pass,
// or a pluralization rule cannot quietly turn a qualified label into a different
// claim.
//
// The strings carry no probability, percentage, or confidence word, which is what
// makes a fixed qualified vocabulary compatible with Requirement 8.13.

/// One of exactly three permitted pixel-label display strings.
///
/// There is no initializer that accepts arbitrary text. A value is either derived
/// from a ``PixelLabelKey`` or recovered from a string that matches one of the three
/// exactly, so a fourth label is unrepresentable.
public struct FixedPixelLabelText: Hashable, Sendable, CustomStringConvertible {
    /// The Positive Pixel Label, in probabilistic-consistency framing
    /// (Requirement 8.3).
    public static let signalsConsistentWithAIGeneration = "Signals consistent with AI generation"

    /// The Non Positive Pixel Label. "No strong signal" is not an authenticity
    /// result (Requirement 8.4).
    public static let noStrongSignalDetected = "No strong signal detected"

    /// The Insufficient Evidence Outcome. A lack of usable signal, not an authentic
    /// image (Requirement 8.5).
    public static let notEnoughSignal = "Not enough signal"

    /// Every permitted pixel-label string.
    public static let allTexts: Set<String> = Set(
        PixelLabelKey.allCases.map { FixedPixelLabelText(label: $0).value }
    )

    /// The label this text belongs to.
    public let label: PixelLabelKey

    /// The exact required display string for ``label``.
    public var value: String {
        switch label {
        case .signalsConsistentWithAIGeneration: Self.signalsConsistentWithAIGeneration
        case .noStrongSignalDetected: Self.noStrongSignalDetected
        case .notEnoughSignal: Self.notEnoughSignal
        }
    }

    /// The required text for one pixel label. Total: every label has exactly one.
    public init(label: PixelLabelKey) {
        self.label = label
    }

    /// The required text for one runtime pixel evidence value.
    public init(evidence: PixelEvidence) {
        self.init(label: evidence.labelKey)
    }

    /// Recovers the label from an exact display string, or `nil` for anything else.
    ///
    /// Exact means exact: no trimming, no case folding, no whitespace collapsing, no
    /// punctuation normalization. A near miss is a different string and a different
    /// claim, so it is rejected rather than repaired.
    public init?(exact text: String) {
        guard
            let label = PixelLabelKey.allCases.first(where: {
                FixedPixelLabelText(label: $0).value == text
            })
        else {
            return nil
        }
        self.label = label
    }

    /// Checks a rendered string against the exact requirement for `label`.
    ///
    /// Called at the boundary where a String Catalog value becomes user-facing text.
    /// A mismatch is fail-closed: no fallback string, no rendered key, no
    /// best-effort substitution.
    public static func validate(
        rendered: String,
        for label: PixelLabelKey
    ) throws(PresentationCopyError) {
        let required = FixedPixelLabelText(label: label)
        guard rendered == required.value else {
            throw PresentationCopyError.pixelLabelTextMismatch(
                label: label,
                expected: required.value,
                found: rendered
            )
        }
    }

    public var description: String { value }
}

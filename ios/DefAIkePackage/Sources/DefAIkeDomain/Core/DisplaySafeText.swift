// Bounded, display-safe text for provenance detail projections.

/// A bounded single-line string that came from outside the application.
///
/// Provenance summaries project validator output for display. That output is
/// attacker-influenced, so it is length-bounded and stripped of anything that
/// could break a line, inject bidirectional or control behavior into a label, or
/// render as blank. Which fields may be displayed at all, and any stricter limit,
/// is decided by the signed Provenance Policy; the ceiling here is a structural
/// safety bound rather than an approved policy value.
///
/// Display-safe text is never a claim, a verdict, or approved copy. Approved copy
/// is addressed by ``ApprovedCopyKey``.
public struct DisplaySafeText: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Structural ceiling on length. A safety bound, not an approved value.
    public static let maximumCharacterCount = 256

    public let rawValue: String

    /// Creates display-safe text, or `nil` when `rawValue` is empty, overlong, or
    /// contains a line break, control character, or bidirectional control.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= Self.maximumCharacterCount else {
            return nil
        }
        guard rawValue.allSatisfy(Self.isDisplaySafe) else { return nil }
        // Reject text that is only whitespace: it would render as a blank field
        // beside an approved label and read as missing rather than present.
        guard rawValue.contains(where: { !$0.isWhitespace }) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    private static func isDisplaySafe(_ character: Character) -> Bool {
        if character.isNewline { return false }
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate,
                 .privateUse, .unassigned:
                return false
            default:
                return true
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let text = DisplaySafeText(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: """
                    Rejected text that is empty, longer than \
                    \(Self.maximumCharacterCount) characters, or not display-safe.
                    """
            )
        }
        self = text
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One labeled display-safe detail.
///
/// The label is an Approved Verdict Copy key, so a validator cannot supply both
/// the label and the value and thereby write its own user-facing sentence.
public struct DisplaySafeField: Hashable, Codable, Sendable {
    public let labelKey: ApprovedCopyKey
    public let value: DisplaySafeText

    public init(labelKey: ApprovedCopyKey, value: DisplaySafeText) {
        self.labelKey = labelKey
        self.value = value
    }
}

// Shared syntax and coding behavior for the domain's opaque identifiers.
//
// Spec task 1.2 owns every type in `Sources/DefAIkeDomain/Core/`. Later tasks
// that need to name a policy or release artifact reference it through one of
// these opaque identifiers instead of importing its schema type, so the artifact
// schemas (task 1.3) stay behind an identifier boundary.
//
// The design states that every identifier is "opaque, non-user-derived, versioned".
// A value therefore carries no user content, no file name, and no derivation from
// image bytes: it names an immutable artifact or session version and nothing else.
// The domain does not mint identifiers; a randomness or clock port supplies them.
//
// No Foundation import: `Encoder`, `Decoder`, and `DecodingError` are stdlib.

/// Canonical syntax shared by every opaque domain identifier.
///
/// Identifiers are ASCII, bounded, and free of whitespace and control characters
/// so that a canonical bounded encoding is always possible and a hostile or
/// malformed artifact cannot smuggle display or path semantics through an
/// identifier field.
public enum CanonicalIdentifierSyntax: Sendable {
    /// Structural ceiling on identifier length.
    ///
    /// This is a safety bound that keeps encodings bounded, not an approved
    /// release value. No policy, budget, deadline, or gate decision is expressed
    /// or implied by it.
    public static let defaultMaximumCharacterCount = 256

    /// Punctuation permitted inside an identifier.
    ///
    /// `/` is permitted because a model checkpoint identity is namespaced
    /// (for example `Thermostatic/community-forensics-low-quality-detector-2026-08`).
    /// Identifiers are never resolved as file-system paths; artifact paths use
    /// ``CanonicalRelativePath``.
    private static let allowedPunctuation: Set<Character> = [".", "-", "_", ":", "/", "+", "@"]

    /// Reports whether `rawValue` is a canonical identifier of at most
    /// `maximumCharacterCount` characters.
    public static func isCanonical(
        _ rawValue: String,
        maximumCharacterCount: Int = defaultMaximumCharacterCount
    ) -> Bool {
        guard !rawValue.isEmpty, rawValue.count <= maximumCharacterCount else {
            return false
        }
        return rawValue.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter
                || character.isNumber
                || allowedPunctuation.contains(character)
        }
    }
}

/// An opaque, non-user-derived, versioned identifier.
///
/// Conforming types get validated construction, canonical single-string coding,
/// fail-closed decoding, and keyed-dictionary coding for free. A conforming type
/// declares its own validating initializer, which suppresses the synthesized
/// memberwise initializer: there is no way to build an identifier that skipped
/// validation, including from inside this module.
public protocol CanonicalIdentifier:
    Hashable, Codable, Sendable, LosslessStringConvertible, CodingKeyRepresentable
{
    /// Structural ceiling on this identifier's length.
    static var maximumCharacterCount: Int { get }

    /// The validated canonical identifier text.
    var rawValue: String { get }

    /// Creates an identifier, or `nil` when `rawValue` is not canonical.
    init?(_ rawValue: String)
}

extension CanonicalIdentifier {
    public static var maximumCharacterCount: Int {
        CanonicalIdentifierSyntax.defaultMaximumCharacterCount
    }

    public var description: String { rawValue }

    /// Decodes a single canonical string and rejects anything else.
    ///
    /// Decoding is fail-closed: a noncanonical, empty, or overlong identifier is
    /// a decoding error rather than a silently accepted or truncated value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identifier = Self(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: """
                    \(Self.self) rejected a noncanonical identifier of \
                    \(rawValue.count) character(s).
                    """
            )
        }
        self = identifier
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: any CodingKey { StringCodingKey(stringValue: rawValue) }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(codingKey.stringValue)
    }
}

/// Coding key for dictionaries whose keys are ``CanonicalIdentifier`` values.
struct StringCodingKey: CodingKey {
    let stringValue: String

    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

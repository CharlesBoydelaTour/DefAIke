import Foundation

/// Why a versioned release artifact is not schema-valid.
///
/// This vocabulary is deliberately separate from the closed `AnalysisError` set.
/// An artifact that fails validation is a release-configuration fault, not an
/// analysis outcome, and it must never reach a user-facing evidence surface.
///
/// Every case names the offending field so a release audit can point at one
/// artifact position rather than reporting "invalid policy".
public enum ArtifactSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A required string, collection, or set is empty.
    case emptyValue(field: String)

    /// A required value is present but is a placeholder rather than a decision.
    /// Presence is never approval (Requirements 11.1, 14.1, and 14.15).
    case placeholderValue(field: String, value: String)

    /// A value is outside the canonical form the schema accepts.
    case noncanonicalValue(field: String, value: String)

    /// A value is well formed but outside the permitted range.
    case valueOutOfRange(field: String, value: String, allowed: String)

    /// A numeric limit, deadline, count, or budget is zero or negative.
    /// Zero-as-unknown is not a usable release value (Requirement 11.1).
    case nonPositiveValue(field: String, value: String)

    /// A floating-point field is NaN or infinite (Requirement 5.7).
    case nonFiniteValue(field: String, value: String)

    /// The same key appears more than once in a bounded entry list.
    case duplicateEntry(field: String, key: String)

    /// A total map omits keys the schema requires it to cover.
    case missingRequiredEntries(field: String, keys: [String])

    /// A total map carries keys outside the required set.
    case unexpectedEntries(field: String, keys: [String])

    /// A value the requirements fix does not match the fixed value.
    case fixedValueMismatch(field: String, expected: String, found: String)

    /// A representable value the requirements forbid for this field.
    case forbiddenValue(field: String, value: String, reason: String)

    /// Two fields that must reference the same artifact version disagree.
    case inconsistentReference(field: String, expected: String, found: String)

    public var description: String {
        switch self {
        case let .emptyValue(field):
            return "\(field) is empty"
        case let .placeholderValue(field, value):
            return "\(field) holds the placeholder \"\(value)\"; a release artifact needs a decided value"
        case let .noncanonicalValue(field, value):
            return "\(field) value \"\(value)\" is not in canonical form"
        case let .valueOutOfRange(field, value, allowed):
            return "\(field) value \(value) is outside \(allowed)"
        case let .nonPositiveValue(field, value):
            return "\(field) value \(value) must be greater than zero"
        case let .nonFiniteValue(field, value):
            return "\(field) value \(value) must be finite"
        case let .duplicateEntry(field, key):
            return "\(field) declares \"\(key)\" more than once"
        case let .missingRequiredEntries(field, keys):
            return "\(field) is missing required entries \(keys)"
        case let .unexpectedEntries(field, keys):
            return "\(field) declares entries outside its required set: \(keys)"
        case let .fixedValueMismatch(field, expected, found):
            return "\(field) must be \(expected), found \(found)"
        case let .forbiddenValue(field, value, reason):
            return "\(field) value \(value) is not permitted: \(reason)"
        case let .inconsistentReference(field, expected, found):
            return "\(field) must reference \(expected), found \(found)"
        }
    }
}

/// Shared schema-level validation used by every release-artifact model.
///
/// These helpers enforce the artifact-authoring rules that apply everywhere:
/// canonical identifiers, bounded text, no placeholder stand-ins, no duplicate
/// keys, total coverage of a required key set, and agreement between two fields
/// that name the same artifact.
///
/// The layer *below* this one is separate: ``ArtifactEncodingProfile`` and
/// ``BoundedArtifactDecoder`` bound the encoded bytes before any field is read, and
/// they report through ``ArtifactDecodingError``. Signature verification is separate
/// again, and its algorithm and keys come from the approved
/// ``BundleVerificationPolicy``.
public enum ArtifactSchemaValidation {
    /// Tokens that mark a field as not yet decided.
    ///
    /// An artifact may not use one of these in place of an approved device,
    /// budget, deadline, boundary, trust rule, mapping, key, legal conclusion, or
    /// governance decision. Matching is case-insensitive over the trimmed value.
    public static let placeholderTokens: Set<String> = [
        "-",
        "??",
        "changeme",
        "dummy",
        "example",
        "fixme",
        "n/a",
        "na",
        "nil",
        "none",
        "null",
        "placeholder",
        "sample",
        "tbc",
        "tbd",
        "temp",
        "todo",
        "undecided",
        "undefined",
        "unset",
        "xxx",
    ]

    /// Rejects a value that is empty, whitespace-padded, or a placeholder token.
    public static func requireDecidedValue(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArtifactSchemaError.emptyValue(field: field) }
        guard trimmed == value else {
            throw ArtifactSchemaError.noncanonicalValue(field: field, value: value)
        }
        guard !placeholderTokens.contains(trimmed.lowercased()) else {
            throw ArtifactSchemaError.placeholderValue(field: field, value: value)
        }
    }

    /// Rejects a required artifact reference that holds a placeholder token.
    ///
    /// The core identifier layer fixes identifier *syntax*: `tbd` is a
    /// syntactically canonical identifier. The artifact layer additionally
    /// requires that a reference name a decided artifact, so a policy cannot ship
    /// with `"tbd"` where an approved device, key, plan, or record belongs.
    public static func requireDecidedReference(
        _ identifier: some CanonicalIdentifier,
        field: String
    ) throws {
        try requireDecidedValue(identifier.rawValue, field: field)
    }

    /// Validates bounded, display-safe artifact text such as a checkpoint name.
    public static func boundedText(
        _ value: String,
        field: String,
        maximumLength: Int = 256
    ) throws -> String {
        try requireDecidedValue(value, field: field)
        guard value.count <= maximumLength else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: field,
                value: "length \(value.count)",
                allowed: "1...\(maximumLength) characters"
            )
        }
        guard value.unicodeScalars.allSatisfy({ !isControlScalar($0) }) else {
            throw ArtifactSchemaError.noncanonicalValue(field: field, value: value)
        }
        return value
    }

    /// Rejects an empty required collection.
    public static func requireNonEmpty<C: Collection>(_ collection: C, field: String) throws {
        guard !collection.isEmpty else { throw ArtifactSchemaError.emptyValue(field: field) }
    }

    /// Rejects duplicate keys in a bounded entry list.
    ///
    /// Bounded entry lists are used instead of dictionaries wherever a key is not
    /// a string, so that a duplicate key is a detectable schema fault rather than
    /// a silently discarded entry.
    public static func requireUniqueKeys(_ keys: [String], field: String) throws {
        var seen = Set<String>()
        for key in keys where !seen.insert(key).inserted {
            throw ArtifactSchemaError.duplicateEntry(field: field, key: key)
        }
    }

    /// Requires an entry list to cover a required key set exactly once each.
    ///
    /// Total coverage is how the schema makes an "implicit default" unrepresentable:
    /// a map that omits a state cannot be constructed at all.
    public static func requireExactCoverage(
        _ keys: [String],
        required: Set<String>,
        field: String
    ) throws {
        try requireUniqueKeys(keys, field: field)
        let present = Set(keys)
        let missing = required.subtracting(present)
        guard missing.isEmpty else {
            throw ArtifactSchemaError.missingRequiredEntries(field: field, keys: missing.sorted())
        }
        let unexpected = present.subtracting(required)
        guard unexpected.isEmpty else {
            throw ArtifactSchemaError.unexpectedEntries(field: field, keys: unexpected.sorted())
        }
    }

    /// Requires two fields that name the same artifact version to agree.
    ///
    /// This is the cross-artifact counterpart to the per-field checks above: one
    /// artifact's own identifier compared against the identifier another artifact
    /// uses to name it. A release configuration whose references do not resolve to
    /// what they name is not a configuration, it is two configurations
    /// (Requirements 5.13, 10.7, 10.8, and 14.1).
    public static func requireMatchingReference(
        _ found: some CanonicalIdentifier,
        matches expected: some CanonicalIdentifier,
        field: String
    ) throws {
        guard found.rawValue == expected.rawValue else {
            throw ArtifactSchemaError.inconsistentReference(
                field: field,
                expected: expected.rawValue,
                found: found.rawValue
            )
        }
    }

    /// Requires a finite `Double`, rejecting NaN and infinity.
    public static func requireFinite(_ value: Double, field: String) throws {
        guard value.isFinite else {
            throw ArtifactSchemaError.nonFiniteValue(field: field, value: "\(value)")
        }
    }

    /// Requires a strictly positive `Decimal`. A NaN value fails this comparison.
    public static func requirePositive(_ value: Decimal, field: String) throws {
        guard value > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(field: field, value: "\(value)")
        }
    }

    private static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}

extension ArtifactSchemaError {
    /// Surfaces a schema violation as a decoding failure.
    ///
    /// Types whose invariants span several fields decode by delegating to their
    /// validating initializer, so a signed artifact cannot introduce a combination
    /// that in-process construction would reject.
    public func asDecodingError(codingPath: [any CodingKey]) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: description,
                underlyingError: self
            )
        )
    }
}

extension ArtifactSchemaValidation {
    /// Runs a validating initializer inside a decoder, converting a schema
    /// violation into a `DecodingError` at the current coding path.
    public static func decoding<Value>(
        at codingPath: [any CodingKey],
        _ build: () throws -> Value
    ) throws -> Value {
        do {
            return try build()
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: codingPath)
        }
    }
}

/// A schema value that encodes as one canonical scalar and validates on decode.
///
/// Decoding goes through the same validation as in-process construction, so a
/// signed artifact cannot introduce a value that the initializer would reject.
public protocol ValidatedScalarSchemaValue: Codable, Sendable, Hashable {
    associatedtype RawSchemaValue: Codable & Sendable & Hashable

    /// The canonical encoded form.
    var rawSchemaValue: RawSchemaValue { get }

    /// Validates and stores `raw`, or throws `ArtifactSchemaError`.
    init(validating raw: RawSchemaValue) throws
}

extension ValidatedScalarSchemaValue {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(RawSchemaValue.self)
        do {
            try self.init(validating: raw)
        } catch let error as ArtifactSchemaError {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: error.description,
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawSchemaValue)
    }
}

// Why an *encoded* release artifact could not be turned into a validated value.
//
// Three failure vocabularies meet at the artifact boundary, and keeping them
// separate is what makes a release audit able to name one cause:
//
//   * ``ArtifactDecodingError`` (here): the bytes are not a readable artifact.
//     Either they violate the bounded encoding profile, or a required field is
//     absent, null, the wrong type, or names something this build cannot interpret.
//   * ``ArtifactSchemaError``: the bytes decoded, but the artifact is not valid.
//   * ``ReleaseArtifactError``: no artifact could be supplied at all.
//
// None of them is ever an ``AnalysisError``. A build that cannot read its own
// policies keeps ingest unavailable; it does not synthesize a user-facing evidence
// error, and it never falls back to a compiled-in value.
//
// No Foundation import: `CodingKey` and `DecodingError` are stdlib, and a decode fault
// carries no framework error type across this boundary.

/// A structural bound the encoding profile enforces.
///
/// Every bound here is a safety ceiling that keeps decoding bounded before any
/// allocation. None is an approved release value, and none expresses a policy,
/// budget, deadline, or gate decision.
public enum ArtifactStructuralBound: String, Sendable, Hashable, CaseIterable,
    CustomStringConvertible
{
    case objectEntries = "object entries"
    case arrayElements = "array elements"
    case stringScalars = "string unicode scalars"
    case numberTokenLength = "number token length"

    public var description: String { rawValue }
}

/// Why an encoded artifact could not be decoded.
///
/// The cases divide into the bounded-encoding profile (payload size, encoding
/// validity, duplicate keys, nesting, structural bounds) and the schema mapping
/// (absent, null, mistyped, uninterpretable, or invalid values). A test can
/// therefore assert *which* fail-closed reason fired rather than only that
/// something failed.
public enum ArtifactDecodingError: Error, Sendable, Equatable, CustomStringConvertible {
    // MARK: Bounded encoding profile

    /// The payload is larger than the byte ceiling the caller supplied.
    ///
    /// The ceiling comes from an approved artifact, so this is a policy-bounded
    /// rejection rather than a compiled-in size opinion (Requirement 10.8).
    case payloadTooLarge(limitBytes: UInt64, actualBytes: UInt64)

    /// The payload contains no bytes.
    case emptyPayload

    /// The payload is not valid UTF-8 at this byte offset.
    case invalidUTF8(byteOffset: Int)

    /// The payload violates the encoding grammar at this byte offset.
    case malformedEncoding(byteOffset: Int, reason: String)

    /// The top-level value is not an object.
    ///
    /// Every artifact encodes as one keyed object, so a bare scalar or array at the
    /// root is refused before any field is read.
    case topLevelValueNotAnObject(byteOffset: Int)

    /// The same key appears more than once inside one object.
    ///
    /// A general-purpose decoder resolves duplicates silently, which would let two
    /// encodings of the same signed bytes disagree about a budget, a deadline, or a
    /// trusted key. Duplicates are refused before decoding (Requirement 10.8).
    case duplicateKey(path: String, key: String)

    /// Nesting exceeds the structural depth ceiling.
    case nestingTooDeep(limit: Int, byteOffset: Int)

    /// A container, string, or number exceeds its structural ceiling.
    case structuralBoundExceeded(path: String, bound: ArtifactStructuralBound, limit: Int)

    // MARK: Schema mapping

    /// A required field is absent. Nothing substitutes a default for it.
    case missingRequiredField(path: String)

    /// A required field is present but null. Null is not a decided value.
    case nullRequiredField(path: String)

    /// A field holds the wrong kind of value.
    case typeMismatch(path: String, expected: String)

    /// The field decoded but the artifact layer rejected it.
    ///
    /// Carries the exact schema fault, so a malformed version, a placeholder value,
    /// a nonpositive duration, or an inconsistent reference is reported as itself.
    case schemaViolation(path: String, error: ArtifactSchemaError)

    /// A required value names something this build cannot interpret.
    ///
    /// This is the closed-vocabulary and canonical-syntax case: an unknown member of
    /// a required closed vocabulary, a noncanonical identifier, or a noncanonical
    /// artifact path. All three are one audit finding — the artifact asks for
    /// semantics this source revision does not implement — and all three fail closed
    /// rather than resolving to a nearest known value.
    case valueRejected(path: String, detail: String)

    public var description: String {
        switch self {
        case let .payloadTooLarge(limit, actual):
            return "payload of \(actual) byte(s) exceeds the approved ceiling of \(limit)"
        case .emptyPayload:
            return "payload is empty"
        case let .invalidUTF8(offset):
            return "payload is not valid UTF-8 at byte \(offset)"
        case let .malformedEncoding(offset, reason):
            return "malformed encoding at byte \(offset): \(reason)"
        case let .topLevelValueNotAnObject(offset):
            return "top-level value at byte \(offset) is not an object"
        case let .duplicateKey(path, key):
            return "\(path) declares the key \"\(key)\" more than once"
        case let .nestingTooDeep(limit, offset):
            return "nesting at byte \(offset) exceeds the depth ceiling of \(limit)"
        case let .structuralBoundExceeded(path, bound, limit):
            return "\(path) exceeds the ceiling of \(limit) \(bound)"
        case let .missingRequiredField(path):
            return "\(path) is required and absent"
        case let .nullRequiredField(path):
            return "\(path) is required and null"
        case let .typeMismatch(path, expected):
            return "\(path) is not \(expected)"
        case let .schemaViolation(path, error):
            return "\(path) is invalid: \(error.description)"
        case let .valueRejected(path, detail):
            return "\(path) holds a value this build cannot interpret: \(detail)"
        }
    }
}

extension ArtifactDecodingError {
    /// Maps a decoder failure onto this vocabulary.
    ///
    /// A schema fault raised from inside a validating initializer is recovered from
    /// the decoding error's underlying error, so it is reported as the schema
    /// violation it is rather than as a generic "corrupt data". Anything the
    /// framework reports that is not a `DecodingError` becomes
    /// ``ArtifactDecodingError/valueRejected(path:detail:)`` at the root, because a
    /// framework error type never escapes the artifact boundary.
    public static func from(_ error: any Error) -> ArtifactDecodingError {
        guard let decodingError = error as? DecodingError else {
            if let schemaError = error as? ArtifactSchemaError {
                return .schemaViolation(path: rootPath, error: schemaError)
            }
            return .valueRejected(path: rootPath, detail: "\(error)")
        }
        switch decodingError {
        case let .keyNotFound(key, context):
            return .missingRequiredField(path: path(context.codingPath, appending: key))
        case let .valueNotFound(_, context):
            return .nullRequiredField(path: path(context.codingPath))
        case let .typeMismatch(type, context):
            return .typeMismatch(path: path(context.codingPath), expected: "\(type)")
        case let .dataCorrupted(context):
            if let schemaError = context.underlyingError as? ArtifactSchemaError {
                return .schemaViolation(path: path(context.codingPath), error: schemaError)
            }
            return .valueRejected(
                path: path(context.codingPath),
                detail: context.debugDescription
            )
        @unknown default:
            return .valueRejected(path: rootPath, detail: "\(decodingError)")
        }
    }

    /// Display name of the document root.
    public static let rootPath = "<root>"

    /// Renders a coding path in the same dot-and-bracket form the schema layer uses
    /// for its `field:` values, so one artifact position reads the same way whether
    /// it was reported by the decoder or by a validating initializer.
    static func path(_ codingPath: [any CodingKey], appending key: (any CodingKey)? = nil) -> String {
        var rendered = ""
        for component in codingPath + (key.map { [$0] } ?? []) {
            if let index = component.intValue {
                rendered += "[\(index)]"
            } else if rendered.isEmpty {
                rendered = component.stringValue
            } else {
                rendered += ".\(component.stringValue)"
            }
        }
        return rendered.isEmpty ? rootPath : rendered
    }
}

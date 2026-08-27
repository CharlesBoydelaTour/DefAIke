import Foundation

// The one way encoded release artifacts become validated values.
//
// Decoding happens in two passes, and the order matters:
//
//   1. ``ArtifactEncodingProfile`` validates the bytes against the bounded encoding
//      profile — payload ceiling, encoding validity, duplicate keys, nesting, and
//      structural ceilings — before anything is allocated per field.
//   2. The schema type decodes, and every one of them decodes through its own
//      validating initializer, so a signed artifact cannot introduce a value that
//      in-process construction would reject.
//
// Every fault from either pass surfaces as ``ArtifactDecodingError``. There is no
// lenient mode, no repair, no normalization, and no member that returns a value when
// the payload is unreadable: an unreadable policy keeps ingest unavailable rather
// than falling back to a compiled-in number.
//
// The byte ceiling is supplied, never chosen here. ``init(manifestLimitsFrom:)``
// takes it from the approved Bundle Verification Policy, which is the artifact that
// owns it (Requirement 10.8).

/// Decodes bounded release artifacts from encoded bytes.
public struct BoundedArtifactDecoder: Sendable {
    /// The bounds this decoder enforces.
    public let limits: ArtifactEncodingLimits

    /// Creates a decoder from explicit limits.
    public init(limits: ArtifactEncodingLimits) {
        self.limits = limits
    }

    /// Creates a decoder whose payload ceiling comes from an approved policy.
    ///
    /// Requirement 10.8 requires manifest parsing to be bounded before allocation,
    /// and ``BundleVerificationPolicy/maximumManifestByteCount`` is where that number
    /// is decided. Reading it here is the whole point: the ceiling travels with the
    /// signed policy instead of living in source.
    public init(manifestLimitsFrom policy: BundleVerificationPolicy) {
        self.init(limits: ArtifactEncodingLimits(
            maximumByteCount: policy.maximumManifestByteCount
        ))
    }

    /// Validates the bounded encoding profile without interpreting any field.
    ///
    /// Useful where the structural question is separate from the schema question: a
    /// release audit can report that a payload is within its approved ceiling and
    /// free of duplicate keys even when the schema it must satisfy is decided later.
    @discardableResult
    public func validateProfile(
        _ bytes: [UInt8]
    ) throws(ArtifactDecodingError) -> ArtifactEncodingReport {
        try ArtifactEncodingProfile.validate(bytes, limits: limits)
    }

    /// Validates the bounded encoding profile of a `Data` payload.
    @discardableResult
    public func validateProfile(
        _ data: Data
    ) throws(ArtifactDecodingError) -> ArtifactEncodingReport {
        try validateProfile(Array(data))
    }

    /// Decodes one artifact from `bytes`, enforcing the profile first.
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        from bytes: [UInt8]
    ) throws(ArtifactDecodingError) -> Value {
        try validateProfile(bytes)
        do {
            return try JSONDecoder().decode(type, from: Data(bytes))
        } catch {
            throw ArtifactDecodingError.from(error)
        }
    }

    /// Decodes one artifact from `data`, enforcing the profile first.
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws(ArtifactDecodingError) -> Value {
        try decode(type, from: Array(data))
    }
}

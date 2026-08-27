// The retained encoded bytes, as a handle rather than as data.
//
// Requirements 2.12 and 2.13 require the *identical* retained encoded-byte sequence
// to reach the Input Validator and, when the capability is enabled, the Provenance
// Analyzer. "Identical" is guaranteed structurally here: both consumers receive the
// same ``EncodedAssetHandle``, which names one finalized immutable object in the
// ephemeral store. There is no second copy to diverge, no byte array to mutate, and
// no way to hand one consumer a transformed representation.

/// A provider's declared content type, kept as a hint only.
///
/// The hint is attacker-influenced and is never used to decide whether an input is
/// supported: classification sniffs the actual container with Uniform Type
/// Identifiers and Image I/O (Requirement 3.1 and the design's Input Validator). It
/// is retained for diagnostics and for recording what the provider claimed.
public struct ContentTypeHint: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Structural ceiling on length. A safety bound, not an approved value.
    public static let maximumCharacterCount = 128

    public let rawValue: String

    /// Creates a hint, or `nil` when `rawValue` is empty, overlong, or not a bounded
    /// printable-ASCII token.
    ///
    /// Reverse-DNS type identifiers such as `public.jpeg` are the expected shape.
    /// Whitespace and control characters are rejected so a hint cannot smuggle
    /// display or path semantics.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= Self.maximumCharacterCount else {
            return nil
        }
        guard rawValue.allSatisfy({ character in
            guard let ascii = character.asciiValue else { return false }
            return ascii > 0x20 && ascii < 0x7F
        }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let hint = ContentTypeHint(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Rejected a content-type hint that is empty, overlong, or not a bounded ASCII token."
            )
        }
        self = hint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A handle to the exact encoded bytes retained for one Analysis Session.
///
/// The handle carries the measurements taken during the single streaming copy, not
/// the bytes: `byteCount` and `sha256` are what the store measured while writing, so
/// they describe the object the handle names and cannot drift from it. Everything
/// downstream that needs the bytes reads them through the store using ``storageKey``.
public struct EncodedAssetHandle: Hashable, Sendable {
    /// The session that owns these bytes. Ownership decides who deletes them.
    public let sessionID: AnalysisSessionID

    /// The finalized object in the ephemeral store.
    public let storageKey: EphemeralStorageKey

    /// Byte count measured while copying.
    public let byteCount: UInt64

    /// SHA-256 computed while copying.
    public let sha256: SHA256Digest

    /// The iOS data-protection level applied to the object (Requirement 9.6).
    public let protection: FileProtectionLevel

    /// Creates a handle, or `nil` for an empty object.
    ///
    /// A zero-byte retained representation is not an analyzable image, and accepting
    /// one would let an empty copy reach validation as though bytes had been
    /// preserved.
    public init?(
        sessionID: AnalysisSessionID,
        storageKey: EphemeralStorageKey,
        byteCount: UInt64,
        sha256: SHA256Digest,
        protection: FileProtectionLevel
    ) {
        guard byteCount > 0 else { return nil }
        self.sessionID = sessionID
        self.storageKey = storageKey
        self.byteCount = byteCount
        self.sha256 = sha256
        self.protection = protection
    }

    /// Creates a handle from the receipt the store produced while writing.
    ///
    /// The preferred path: it is impossible for the handle's measurements to disagree
    /// with what was actually written, and the scope proves the object belongs to
    /// this session.
    public init?(sessionID: AnalysisSessionID, receipt: EphemeralWriteReceipt) {
        guard case .session(let owner) = receipt.scope, owner == sessionID else { return nil }
        self.init(
            sessionID: sessionID,
            storageKey: receipt.key,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            protection: receipt.protection
        )
    }
}

/// One accepted ingest: the retained bytes plus what is known about them.
///
/// This is the sole value the Ingest Coordinator produces, and both routes produce
/// the same shape (Requirement 2.14): a Photos import and a completed Share handoff
/// of byte-identical input are indistinguishable downstream except for ``route``.
///
/// `byteCount` and `sha256` forward to the handle rather than being stored again, so
/// a mutation check compares one authoritative measurement instead of two fields that
/// could be altered independently.
public struct ImportedEncodedAsset: Hashable, Sendable {
    /// The single recorded ingest route for the session (Requirement 2.8).
    public let route: InputRoute

    /// The retained encoded bytes.
    public let handle: EncodedAssetHandle

    /// What is known about preservation of these bytes.
    public let preservationStatus: BytePreservationStatus

    /// Why that status was selected.
    public let preservationBasis: PreservationBasis

    /// What the provider claimed the content type was. Never trusted.
    public let contentTypeHint: ContentTypeHint?

    /// Creates an accepted ingest, or `nil` when the status is not supported by its
    /// basis.
    ///
    /// This is the structural half of "conservative status": a basis maps to exactly
    /// one most conservative status, so a pair claiming ``BytePreservationStatus/originalBytes``
    /// from a basis that only establishes a current representation cannot be built —
    /// including by a tampered Share ticket whose two fields were changed
    /// independently (Requirements 2.9 through 2.11).
    public init?(
        route: InputRoute,
        handle: EncodedAssetHandle,
        preservationStatus: BytePreservationStatus,
        preservationBasis: PreservationBasis,
        contentTypeHint: ContentTypeHint?
    ) {
        guard preservationBasis.supports(preservationStatus) else { return nil }
        self.route = route
        self.handle = handle
        self.preservationStatus = preservationStatus
        self.preservationBasis = preservationBasis
        self.contentTypeHint = contentTypeHint
    }

    /// The session these bytes belong to.
    public var sessionID: AnalysisSessionID { handle.sessionID }

    /// Byte count measured while copying.
    public var byteCount: UInt64 { handle.byteCount }

    /// SHA-256 computed while copying.
    public var sha256: SHA256Digest { handle.sha256 }
}

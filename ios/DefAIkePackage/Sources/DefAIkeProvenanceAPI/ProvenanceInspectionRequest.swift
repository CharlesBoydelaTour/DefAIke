import DefAIkeDomain

// The normalized input side of the provenance contract.
//
// Requirement 6.6 requires a validator to inspect "the exact encoded representation
// retained for an Analysis Session before any byte-changing transformation", and
// Requirement 6.8 requires validation to complete with networking disabled. Both are
// structural here rather than documented conventions:
//
//   * the request names one finalized object in the ephemeral store by opaque key and
//     carries the byte count and digest measured while that object was written, so a
//     validator cannot be pointed at a transformed copy, a re-encoded buffer, or a
//     file-system path; and
//   * there is no URL, host, session configuration, cache, or trust-resolution member,
//     so an offline validator has nothing to reach the network with.
//
// The request is also the reason this module needs no byte-reading seam of its own: the
// bytes are read through `EphemeralFileStoring` in `DefAIkeDomain`, using
// ``ProvenanceInspectionRequest/storageKey``.

/// The bounded, vendor-independent description of one provenance inspection.
///
/// Every field is derived from the accepted ingest and the signed Provenance Policy, so
/// a caller cannot pass limits that disagree with the policy the session was bound to,
/// and cannot describe bytes other than the ones ingest retained.
public struct ProvenanceInspectionRequest: Hashable, Sendable {
    /// The session that owns the inspected bytes.
    public let sessionID: AnalysisSessionID

    /// The finalized ephemeral object holding the exact retained encoded bytes.
    public let storageKey: EphemeralStorageKey

    /// Byte count measured while the object was written.
    public let byteCount: UInt64

    /// SHA-256 measured while the object was written.
    public let sha256: SHA256Digest

    /// What is known about preservation of the inspected bytes.
    ///
    /// Carried because provenance findings describe *these* bytes: a transformed or
    /// unknown status adds a required presentation limitation (Requirement 6.15), and a
    /// validator result must never be read as describing the source representation.
    public let preservationStatus: BytePreservationStatus

    /// The Provenance Policy version that governs this inspection.
    public let policyID: ArtifactID

    /// The policy's bounded processing limits.
    public let limits: ProvenanceProcessingLimits

    /// Derives a request from one accepted ingest and the policy bound to its session.
    public init(asset: ImportedEncodedAsset, policy: ProvenancePolicy) {
        self.sessionID = asset.sessionID
        self.storageKey = asset.handle.storageKey
        self.byteCount = asset.byteCount
        self.sha256 = asset.sha256
        self.preservationStatus = asset.preservationStatus
        self.policyID = policy.id
        self.limits = policy.processingLimits
    }

    /// Reports whether the bytes an adapter actually read are the retained bytes.
    ///
    /// An adapter calls this after reading and treats a `false` answer as a failure to
    /// inspect the retained representation, never as a validation result: reporting a
    /// state for bytes other than the retained ones would break Requirement 6.6.
    public func inspectsExactly(byteCount: UInt64, sha256: SHA256Digest) -> Bool {
        self.byteCount == byteCount && self.sha256 == sha256
    }
}

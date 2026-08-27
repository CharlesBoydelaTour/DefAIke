import DefAIkeDomain

// The one thing this module reaches out for, and nothing else.
//
// Content Credential validation is a decision over three inputs: the exact retained
// encoded bytes, the signed Provenance Policy, and whatever the validator reports.
// Only the third needs a library, so only the third arrives through a seam. Everything
// after it — status normalization, limit enforcement, and the projection onto one
// enabled state — is a pure function this module can exercise with no native binary,
// no trust anchors, and no iPhone.
//
// The seam has **no default implementation** here. That is the point: a build that has
// not been given a validator and approved trust material cannot validate anything,
// instead of falling back to something this module chose (Requirements 6.7 and 6.9,
// and the design's "This design does not choose those policies").
//
// Deliberately absent from every member below: any URL, host, session configuration,
// cache, timeout, deadline, or trust-resolution member. An offline validator has
// nothing here to reach the network with, which is what makes Requirement 6.8
// structural rather than a convention.

// MARK: - The approved offline trust material

/// The offline trust anchors one inspection evaluates signatures against.
///
/// The anchors are approved external content. This value carries them alongside the
/// policy's ``ProvenanceTrustStoreDescriptor``, so a validator is always configured
/// from the store the signed policy named and never from a library's built-in list, a
/// system trust store, or an empty store.
///
/// What this type deliberately does not do: verify the anchor bytes against
/// ``EvidenceSource/contentDigest``. That check belongs where the approved artifact is
/// installed and where a real SHA-256 implementation lives; this module's dependency
/// rule is `DefAIkeDomain` and `DefAIkeProvenanceAPI` only. A caller hands over
/// bytes it has already verified.
public struct C2PAOfflineTrustMaterial: Hashable, Sendable {
    /// The policy's descriptor for the store these anchors came from.
    public let descriptor: ProvenanceTrustStoreDescriptor

    /// The approved trust anchors, as the bytes the artifact contained.
    public let anchorBytes: [UInt8]

    /// Creates trust material, or `nil` when it could not configure an offline
    /// validator.
    ///
    /// Rejects empty anchor bytes: a store the policy declares as holding at least one
    /// anchor cannot be represented by no anchors, and an empty store would silently
    /// make every signature untrusted for a reason no artifact stated.
    public init?(descriptor: ProvenanceTrustStoreDescriptor, anchorBytes: [UInt8]) {
        guard !anchorBytes.isEmpty else { return nil }
        self.descriptor = descriptor
        self.anchorBytes = anchorBytes
    }
}

// MARK: - What a validator reports

/// What the validator determined about the claim's hard binding to the inspected
/// bytes.
///
/// Mirrors ``NormalizedBindingOutcome`` rather than reusing it so the seam stays a
/// statement about the library's findings, and so the normalizer is the single place
/// the two vocabularies meet.
public enum C2PABindingFinding: Hashable, Sendable {
    /// A hard-binding check succeeded over the inspected bytes.
    case boundToInspectedBytes
    /// A hard-binding check failed over the inspected bytes.
    case notBound
    /// No hard-binding check reached a conclusion, or none was performed.
    case notDetermined
}

/// The single condition a validator reached, in the adapter's normalized vocabulary.
///
/// Two families, deliberately kept apart. A ``libraryStatus`` is a code the validator
/// itself reported; a ``readerCondition`` is something the adapter observed about the
/// read that no status code describes. Both become a
/// ``ProvenanceValidatorStatusID`` the signed policy maps, and neither carries a state.
public enum C2PAStatusFinding: Hashable, Sendable {
    /// A validation status code the library reported, in its own spelling.
    case libraryStatus(String)
    /// A condition of the read itself, named by the adapter.
    case readerCondition(C2PAReaderCondition)
}

/// One bounded detail the validator read, before it is checked for display safety.
///
/// The value is still a raw `String`: it came from an attacker-influenced manifest, so
/// it is not display-safe until ``DisplaySafeText`` accepts it. Keeping it raw here is
/// what lets the normalizer report *which field* was unsafe as a gate finding instead
/// of silently dropping it.
public struct C2PARawDetail: Hashable, Sendable {
    public let field: ProvenanceDisplayField
    public let rawValue: String

    public init(field: ProvenanceDisplayField, rawValue: String) {
        self.field = field
        self.rawValue = rawValue
    }
}

/// One validator read, projected to the facts the policy's mapping needs.
///
/// A projection rather than the library's manifest objects, so normalization is a pure
/// total function over a value a test can build by hand. Nothing here is an evidence
/// state, a probability, a score, or a trust conclusion.
public struct C2PAReadOutcome: Hashable, Sendable {
    /// The single condition this read reached.
    public let status: C2PAStatusFinding

    /// What the read determined about hard binding to the inspected bytes.
    public let binding: C2PABindingFinding

    /// Which kind of check failed, when the library reported a failure this adapter
    /// classifies.
    ///
    /// `nil` whenever no failure was reported, or when the reported failure code is
    /// outside the adapter's classification table. A `nil` here is never repaired: if
    /// the policy maps the status to `invalid`, the vendor-independent mapper refuses
    /// to invent a category and the condition becomes a gate finding.
    public let failedCheck: InvalidityCategory?

    /// Exact size of the manifest the validator parsed, or `nil` when it parsed none.
    public let manifestByteCount: UInt64?

    /// Deepest nesting observed in that manifest, or `nil` when it parsed none.
    public let manifestNestingDepth: Int?

    /// Signer-side details the read produced, at most one per field.
    public let signerDetails: [C2PARawDetail]

    /// Assertion labels the read produced, in the order the validator read them.
    public let assertionLabels: [String]

    /// Features the validator does not support. May be empty even for an unsupported
    /// result: a validator can know something is outside its capability set without
    /// being able to name it (Requirement 6.13).
    public let unsupportedFeatures: [String]

    public init(
        status: C2PAStatusFinding,
        binding: C2PABindingFinding,
        failedCheck: InvalidityCategory? = nil,
        manifestByteCount: UInt64? = nil,
        manifestNestingDepth: Int? = nil,
        signerDetails: [C2PARawDetail] = [],
        assertionLabels: [String] = [],
        unsupportedFeatures: [String] = []
    ) {
        self.status = status
        self.binding = binding
        self.failedCheck = failedCheck
        self.manifestByteCount = manifestByteCount
        self.manifestNestingDepth = manifestNestingDepth
        self.signerDetails = signerDetails
        self.assertionLabels = assertionLabels
        self.unsupportedFeatures = unsupportedFeatures
    }
}

// MARK: - Reading the exact retained bytes

/// Why a read produced no outcome at all.
///
/// Only two conditions qualify, and neither is a finding about the image, which is why
/// both leave as errors rather than as a status the policy maps. Everything else a
/// library can reach — a refused input, a missing manifest, a parser fault, an
/// unresolvable revocation question — is an outcome.
public enum C2PAReadFault: Error, Hashable, Sendable {
    /// A limit the signed policy declared was exceeded.
    case limitExceeded(ProvenanceLimitBreach)

    /// The validator could not be configured with the approved offline trust material.
    ///
    /// An unconfigured validator has not evaluated the approved trust store, so none of
    /// its answers describe the policy that was supposed to be in force. Reporting a
    /// state here would attribute a finding to trust anchors that were never applied.
    case validatorNotConfigurable
}

/// Validates Content Credentials in one immutable byte sequence, offline.
///
/// The byte sequence is passed by value and never re-read, so an implementation cannot
/// inspect a different representation than the one it was handed. There is no member
/// that takes a path, a URL, a file handle, or a storage key: resolving the retained
/// object is the adapter's job, so an implementation has nothing to resolve.
public protocol C2PAManifestReading: Sendable {
    /// Reads and validates `bytes` under `limits`, against `trust`.
    ///
    /// Returns exactly one ``C2PAReadOutcome``, or one ``C2PAReadFault``.
    func read(
        exactBytes bytes: [UInt8],
        limits: ProvenanceProcessingLimits,
        trust: C2PAOfflineTrustMaterial
    ) throws(C2PAReadFault) -> C2PAReadOutcome
}

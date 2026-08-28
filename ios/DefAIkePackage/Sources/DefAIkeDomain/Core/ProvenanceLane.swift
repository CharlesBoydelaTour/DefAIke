// The provenance source lane: five enabled evidence states, plus the separate
// unavailable state used when the installed release has no validator.

/// The five mutually exclusive enabled provenance states, without their payloads.
///
/// This is the fusion key half and the presentation discriminator. `unavailable`
/// is deliberately absent: it is not one of the five enabled states, it lies
/// outside the 3 × 5 fusion table, and it always forces fusion omission
/// (Requirements 6.9, 6.21, and 7.10).
public enum ProvenanceCategory: String, Codable, Sendable, CaseIterable {
    case validated
    case invalid
    case absent
    case unsupported
    case indeterminate
}

/// Why the provenance source lane is unavailable.
///
/// Unavailable means the installed release cannot validate Content Credentials at
/// all. It is never a finding about the image, and it must not be presented as
/// absent, invalid, or authentic (Requirement 8.8).
///
/// Three reasons, and they are three different *places* the chain from linked bytes to
/// usable validator can break, in the order a build encounters them: the module graph,
/// then the signed manifest, then the approved decisions the adapter needs. Keeping
/// them apart matters because the application composition links the validator
/// unconditionally, so "no validator was compiled in" stopped being the answer that
/// covers every unavailable lane and would be a false statement about the shipped
/// module graph if reused for the other two.
///
/// All three resolve to the same user-facing surface — one approved
/// `provenanceUnavailable` copy entry — because the distinction is for a release audit
/// rather than for a reader. A user is told the installed release cannot check Content
/// Credentials; which link in the chain is missing is not their problem.
public enum UnavailableReason: String, Codable, Sendable, CaseIterable {
    /// This capability composition links no Content Credential validator.
    ///
    /// A compile-time fact about the module graph, and the one reason that outranks
    /// the signed manifest: a manifest cannot enable a capability whose implementation
    /// is absent from the binary. The shipped application composition links the
    /// adapter, so this reason describes the Share Extension's closure and any future
    /// composition built without it — not the installed app.
    case validatorNotCompiledIntoRelease

    /// A validator is compiled in, but the signed Release Capability Manifest does
    /// not enable the capability for this build.
    ///
    /// Also the answer when the manifest enables provenance but does not name this
    /// policy version, this adapter implementation version, or an approved Provenance
    /// Feasibility decision. Such a manifest has not enabled provenance for *this*
    /// configuration, which is not the same as having enabled it.
    case capabilityNotEnabledByReleaseCapabilityManifest

    /// A validator is compiled in and the signed manifest enables the capability, but
    /// no approved decision supplies an analyzer, so nothing can inspect the retained
    /// bytes.
    ///
    /// This is the honest state of a build whose linked adapter cannot yet conform to
    /// `ProvenanceAnalyzing`: `analyze(_:policy:)` returns evidence unconditionally, so
    /// a conformance would have to resolve an unanswerable condition by *selecting* a
    /// state, and no signed artifact says which state answers one. Reporting it as
    /// `validatorNotCompiledIntoRelease` would misstate the module graph, and reporting
    /// it as `capabilityNotEnabledByReleaseCapabilityManifest` would misstate the
    /// manifest; this reason misstates neither.
    ///
    /// It is emphatically not `indeterminate`. Indeterminate is an enabled validator's
    /// finding about specific bytes (Requirements 6.14 and 6.21); this is the absence of
    /// a validator that can run at all, so it belongs outside the five enabled states.
    case validatorEnablementUnapproved
}

/// Binding status reported by a cryptographically validated claim.
///
/// One case by construction. Byte-binding failure is an invalid result
/// (Requirement 6.12), so an unbound claim cannot be represented as validated.
public enum ClaimBindingStatus: String, Codable, Sendable, CaseIterable {
    /// The claim is cryptographically bound to the exact inspected bytes.
    case boundToInspectedBytes
}

/// Which kind of validation failed (Requirement 6.12).
public enum InvalidityCategory: String, Codable, Sendable, CaseIterable {
    case cryptographic
    case structural
    case byteBinding
}

/// A validated Content Credential, projected for display.
///
/// Cryptographic validation establishes claim binding. It does not establish that
/// any signed assertion is factually true, and nothing in this summary may be
/// presented as such (Requirements 6.17 and 8.6). Which signer and assertion
/// fields are safe to display is decided by the referenced Provenance Policy.
public struct ValidatedClaimSummary: Hashable, Codable, Sendable {
    /// The Provenance Policy version that mapped the validator output.
    public let provenancePolicyID: ArtifactID
    public let bindingStatus: ClaimBindingStatus
    public let signerFields: [DisplaySafeField]
    public let assertionFields: [DisplaySafeField]

    public init(
        provenancePolicyID: ArtifactID,
        bindingStatus: ClaimBindingStatus,
        signerFields: [DisplaySafeField],
        assertionFields: [DisplaySafeField]
    ) {
        self.provenancePolicyID = provenancePolicyID
        self.bindingStatus = bindingStatus
        self.signerFields = signerFields
        self.assertionFields = assertionFields
    }
}

/// A Content Credential that failed validation, projected for display.
public struct InvaliditySummary: Hashable, Codable, Sendable {
    public let provenancePolicyID: ArtifactID
    public let category: InvalidityCategory
    /// Approved explanation for this failure, selected by the Provenance Policy.
    public let explanationKey: ApprovedCopyKey

    public init(
        provenancePolicyID: ArtifactID,
        category: InvalidityCategory,
        explanationKey: ApprovedCopyKey
    ) {
        self.provenancePolicyID = provenancePolicyID
        self.category = category
        self.explanationKey = explanationKey
    }
}

/// A Content Credential requiring a feature outside the validator's supported set
/// (Requirement 6.13).
public struct UnsupportedFeatureSummary: Hashable, Codable, Sendable {
    public let provenancePolicyID: ArtifactID
    public let explanationKey: ApprovedCopyKey
    /// The unsupported features, as bounded display-safe text.
    public let unsupportedFeatures: [DisplaySafeText]

    public init(
        provenancePolicyID: ArtifactID,
        explanationKey: ApprovedCopyKey,
        unsupportedFeatures: [DisplaySafeText]
    ) {
        self.provenancePolicyID = provenancePolicyID
        self.explanationKey = explanationKey
        self.unsupportedFeatures = unsupportedFeatures
    }
}

/// An inconclusive validator result (Requirement 6.14).
///
/// Indeterminate is an enabled-validator processing result, reported distinctly
/// from the unavailable lane state (Requirement 6.21). A missing offline
/// revocation answer resolves here or to unsupported according to the approved
/// mapping; it can never be reported as validated.
public struct IndeterminateSummary: Hashable, Codable, Sendable {
    public let provenancePolicyID: ArtifactID
    public let explanationKey: ApprovedCopyKey

    public init(provenancePolicyID: ArtifactID, explanationKey: ApprovedCopyKey) {
        self.provenancePolicyID = provenancePolicyID
        self.explanationKey = explanationKey
    }
}

/// Exactly one mutually exclusive enabled provenance state.
///
/// `absent` carries no payload: "no Content Credential was found in the inspected
/// bytes" needs no detail, and adding one would risk presenting absence as
/// evidence of authenticity (Requirements 6.11, 7.6, and 8.7).
public enum ProvenanceEvidence: Hashable, Codable, Sendable {
    case validated(ValidatedClaimSummary)
    case invalid(InvaliditySummary)
    case absent
    case unsupported(UnsupportedFeatureSummary)
    case indeterminate(IndeterminateSummary)

    /// This state's fusion-key category. Total and mutually exclusive.
    public var category: ProvenanceCategory {
        switch self {
        case .validated: return .validated
        case .invalid: return .invalid
        case .absent: return .absent
        case .unsupported: return .unsupported
        case .indeterminate: return .indeterminate
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case validated
        case invalid
        case unsupported
        case indeterminate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ProvenanceCategory.self, forKey: .state) {
        case .validated:
            self = .validated(
                try container.decode(ValidatedClaimSummary.self, forKey: .validated))
        case .invalid:
            self = .invalid(
                try container.decode(InvaliditySummary.self, forKey: .invalid))
        case .absent:
            self = .absent
        case .unsupported:
            self = .unsupported(
                try container.decode(UnsupportedFeatureSummary.self, forKey: .unsupported))
        case .indeterminate:
            self = .indeterminate(
                try container.decode(IndeterminateSummary.self, forKey: .indeterminate))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .state)
        switch self {
        case .validated(let summary):
            try container.encode(summary, forKey: .validated)
        case .invalid(let summary):
            try container.encode(summary, forKey: .invalid)
        case .absent:
            break
        case .unsupported(let summary):
            try container.encode(summary, forKey: .unsupported)
        case .indeterminate(let summary):
            try container.encode(summary, forKey: .indeterminate)
        }
    }
}

/// The provenance source lane of an Evidence Report.
///
/// A release whose Content Credential validation is not enabled and usable always
/// reports ``unavailable``, carrying which link in the chain is missing; a
/// provenance-enabled release reports ``available`` with exactly one of the five
/// enabled states (Requirements 6.4, 6.9, and 6.20).
public enum ProvenanceLane: Hashable, Codable, Sendable {
    case unavailable(UnavailableReason)
    case available(ProvenanceEvidence)

    /// The enabled evidence state, or `nil` when the lane is unavailable.
    public var evidence: ProvenanceEvidence? {
        switch self {
        case .unavailable: return nil
        case .available(let evidence): return evidence
        }
    }

    /// The fusion-key category, or `nil` when the lane is unavailable.
    ///
    /// `nil` is the fusion bypass: an unavailable lane is outside the 3 × 5 table
    /// and always omits the Combined Summary (Requirement 7.10).
    public var category: ProvenanceCategory? { evidence?.category }

    /// Whether an enabled validator produced a result for this session.
    public var isAvailable: Bool { evidence != nil }

    /// Why the lane is unavailable, or `nil` when it is available.
    public var unavailableReason: UnavailableReason? {
        switch self {
        case .unavailable(let reason): return reason
        case .available: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case lane
        case unavailableReason
        case evidence
    }

    private enum LaneKind: String, Codable {
        case unavailable
        case available
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(LaneKind.self, forKey: .lane) {
        case .unavailable:
            self = .unavailable(
                try container.decode(UnavailableReason.self, forKey: .unavailableReason))
        case .available:
            self = .available(
                try container.decode(ProvenanceEvidence.self, forKey: .evidence))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let reason):
            try container.encode(LaneKind.unavailable, forKey: .lane)
            try container.encode(reason, forKey: .unavailableReason)
        case .available(let evidence):
            try container.encode(LaneKind.available, forKey: .lane)
            try container.encode(evidence, forKey: .evidence)
        }
    }
}

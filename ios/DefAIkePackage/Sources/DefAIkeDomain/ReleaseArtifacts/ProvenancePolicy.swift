import Foundation

// The signed Provenance Policy.
//
// Content Credential validation is conditional (Requirements 6.1 through 6.3), and
// every substantive question about it is decision D5: which trust anchors are
// accepted, what happens when revocation cannot be checked offline, which claim and
// signer fields are safe to display, which specification features are supported, and
// how the validator's statuses map onto the five exclusive evidence states.
//
// None of that is answered here. The schema requires each answer as a field, and
// forbids exactly two representable-but-unsafe answers:
//
//   * network access during validation, because validation is offline
//     (Requirement 6.8); and
//   * treating an unavailable revocation answer as `validated`, because a missing
//     answer is not a cryptographic success.

// MARK: - Trust and revocation

/// The offline trust store a validator evaluates signatures against.
///
/// The anchors themselves are external approved content. This record binds a policy
/// to exact bytes and requires the store to be non-empty and offline-only, so a
/// build cannot fall back to a system store or an empty store.
public struct ProvenanceTrustStoreDescriptor: Hashable, Codable, Sendable {
    /// The approved trust-store artifact.
    public let store: EvidenceSource

    /// How many trust anchors the store contains.
    public let anchorCount: PositiveCount

    /// Always true: no network trust resolution is permitted.
    public let isOfflineOnly: Bool

    public init(store: EvidenceSource, anchorCount: PositiveCount, isOfflineOnly: Bool) throws {
        guard isOfflineOnly else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "trustStore.isOfflineOnly",
                value: "false",
                reason: "Content Credential validation completes with networking disabled"
            )
        }
        self.store = store
        self.anchorCount = anchorCount
        self.isOfflineOnly = isOfflineOnly
    }

    private enum CodingKeys: String, CodingKey {
        case store, anchorCount, isOfflineOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                store: container.decode(EvidenceSource.self, forKey: .store),
                anchorCount: container.decode(PositiveCount.self, forKey: .anchorCount),
                isOfflineOnly: container.decode(Bool.self, forKey: .isOfflineOnly)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// What the adapter reports when revocation status cannot be established offline.
///
/// The approved answer is a release decision among `invalid`, `unsupported`, and
/// `indeterminate`. `validated` is representable so the schema can reject it by name:
/// an unanswered revocation question must never read as a cryptographic success
/// (Requirement 6.9 and the design's provenance mapping rule).
public struct ProvenanceRevocationBehavior: Hashable, Codable, Sendable {
    /// Always false: revocation is never resolved over the network.
    public let permitsNetworkRevocationCheck: Bool

    /// The state reported when no offline revocation answer exists.
    public let unavailableAnswerState: ProvenanceStateKey

    /// The release record that approved this behavior.
    public let approval: ApprovalRecord

    public init(
        permitsNetworkRevocationCheck: Bool,
        unavailableAnswerState: ProvenanceStateKey,
        approval: ApprovalRecord
    ) throws {
        guard !permitsNetworkRevocationCheck else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "revocation.permitsNetworkRevocationCheck",
                value: "true",
                reason: "validation completes with network connectivity disabled"
            )
        }
        guard unavailableAnswerState != .validated else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "revocation.unavailableAnswerState",
                value: unavailableAnswerState.rawValue,
                reason: "a missing revocation answer is not cryptographic validation"
            )
        }
        guard unavailableAnswerState != .absent else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "revocation.unavailableAnswerState",
                value: unavailableAnswerState.rawValue,
                reason: "absent means no manifest was found, not an unresolved check"
            )
        }
        self.permitsNetworkRevocationCheck = permitsNetworkRevocationCheck
        self.unavailableAnswerState = unavailableAnswerState
        self.approval = approval
    }

    private enum CodingKeys: String, CodingKey {
        case permitsNetworkRevocationCheck, unavailableAnswerState, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                permitsNetworkRevocationCheck: container.decode(
                    Bool.self,
                    forKey: .permitsNetworkRevocationCheck
                ),
                unavailableAnswerState: container.decode(
                    ProvenanceStateKey.self,
                    forKey: .unavailableAnswerState
                ),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Display and limits

/// A bounded field the Result Presenter may show from a validated manifest.
///
/// The five cases are display-safe projections, not raw manifest content: a
/// validated credential reports binding and available signer information without
/// asserting that any signed statement is factually true (Requirements 6.10 and 6.17).
public enum ProvenanceDisplayField: String, Codable, Sendable, Hashable, CaseIterable {
    case signerIdentity = "signer-identity"
    case claimGenerator = "claim-generator"
    case bindingStatus = "binding-status"
    case assertionLabels = "assertion-labels"
    case validationTime = "validation-time"
}

/// Bounded processing limits for offline validation.
///
/// Every limit is required and positive so a malformed or hostile manifest meets a
/// declared ceiling rather than an unbounded parse.
public struct ProvenanceProcessingLimits: Hashable, Codable, Sendable {
    public let maximumManifestByteCount: PositiveByteCount
    public let maximumAssertionCount: PositiveCount
    public let maximumNestingDepth: PositiveCount
    public let maximumProcessingDuration: ValidatedDuration

    public init(
        maximumManifestByteCount: PositiveByteCount,
        maximumAssertionCount: PositiveCount,
        maximumNestingDepth: PositiveCount,
        maximumProcessingDuration: ValidatedDuration
    ) {
        self.maximumManifestByteCount = maximumManifestByteCount
        self.maximumAssertionCount = maximumAssertionCount
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumProcessingDuration = maximumProcessingDuration
    }
}

// MARK: - Status mapping

/// One normalized validator status and the single state it maps to.
public struct ProvenanceStatusMapping: Hashable, Codable, Sendable {
    public let status: ProvenanceValidatorStatusID
    public let state: ProvenanceStateKey

    public init(status: ProvenanceValidatorStatusID, state: ProvenanceStateKey) {
        self.status = status
        self.state = state
    }
}

// MARK: - Policy

/// The versioned policy that governs conditional Content Credential validation.
public struct ProvenancePolicy: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The capability this policy configures. Always content-credential validation.
    public let capability: CapabilityID

    /// The exact reviewed validator implementation version.
    public let validatorImplementationVersion: CapabilityImplementationVersion

    /// Digest of the reviewed validator binary (Requirement 14.5 and the design's
    /// exact-pinning rule).
    public let validatorBinaryDigest: SHA256Digest

    /// The supported C2PA specification and feature set record.
    public let supportedSpecification: EvidenceSource

    public let trustStore: ProvenanceTrustStoreDescriptor
    public let revocationBehavior: ProvenanceRevocationBehavior

    /// Assertion labels the validator supports, as an approved bounded set.
    public let supportedAssertionLabels: Set<ArtifactText>

    /// Fields the Result Presenter may show for a validated credential.
    public let displayableFields: Set<ProvenanceDisplayField>

    public let processingLimits: ProvenanceProcessingLimits

    /// Resource budget the validator runs under.
    public let resourceBudget: ArtifactID

    /// The complete mapping from normalized validator status to evidence state.
    public let statusMappings: [ProvenanceStatusMapping]

    /// The Provenance Feasibility Gate decision that permitted this policy.
    public let feasibilityApproval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        capability: CapabilityID,
        validatorImplementationVersion: CapabilityImplementationVersion,
        validatorBinaryDigest: SHA256Digest,
        supportedSpecification: EvidenceSource,
        trustStore: ProvenanceTrustStoreDescriptor,
        revocationBehavior: ProvenanceRevocationBehavior,
        supportedAssertionLabels: Set<ArtifactText>,
        displayableFields: Set<ProvenanceDisplayField>,
        processingLimits: ProvenanceProcessingLimits,
        resourceBudget: ArtifactID,
        statusMappings: [ProvenanceStatusMapping],
        feasibilityApproval: ApprovalRecord
    ) throws {
        guard capability == .contentCredentialValidation else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "provenancePolicy.capability",
                expected: CapabilityID.contentCredentialValidation.rawValue,
                found: capability.rawValue
            )
        }
        try ArtifactSchemaValidation.requireNonEmpty(
            displayableFields,
            field: "displayableFields"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            statusMappings.map(\.status.rawValue),
            field: "statusMappings"
        )
        try ArtifactSchemaValidation.requireNonEmpty(statusMappings, field: "statusMappings")
        self.id = id
        self.schemaVersion = schemaVersion
        self.capability = capability
        self.validatorImplementationVersion = validatorImplementationVersion
        self.validatorBinaryDigest = validatorBinaryDigest
        self.supportedSpecification = supportedSpecification
        self.trustStore = trustStore
        self.revocationBehavior = revocationBehavior
        self.supportedAssertionLabels = supportedAssertionLabels
        self.displayableFields = displayableFields
        self.processingLimits = processingLimits
        self.resourceBudget = resourceBudget
        self.statusMappings = statusMappings
        self.feasibilityApproval = feasibilityApproval
    }

    /// The single state for a normalized validator status, or `nil` when the policy
    /// does not map it.
    ///
    /// An unmapped status is a policy gap. The adapter fails closed rather than
    /// choosing a state, which is why this returns `nil` instead of a default.
    public func state(for status: ProvenanceValidatorStatusID) -> ProvenanceStateKey? {
        statusMappings.first { $0.status == status }?.state
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, capability, validatorImplementationVersion, validatorBinaryDigest
        case supportedSpecification, trustStore, revocationBehavior, supportedAssertionLabels
        case displayableFields, processingLimits, resourceBudget, statusMappings
        case feasibilityApproval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                capability: container.decode(CapabilityID.self, forKey: .capability),
                validatorImplementationVersion: container.decode(
                    CapabilityImplementationVersion.self,
                    forKey: .validatorImplementationVersion
                ),
                validatorBinaryDigest: container.decode(
                    SHA256Digest.self,
                    forKey: .validatorBinaryDigest
                ),
                supportedSpecification: container.decode(
                    EvidenceSource.self,
                    forKey: .supportedSpecification
                ),
                trustStore: container.decode(
                    ProvenanceTrustStoreDescriptor.self,
                    forKey: .trustStore
                ),
                revocationBehavior: container.decode(
                    ProvenanceRevocationBehavior.self,
                    forKey: .revocationBehavior
                ),
                supportedAssertionLabels: container.decode(
                    Set<ArtifactText>.self,
                    forKey: .supportedAssertionLabels
                ),
                displayableFields: container.decode(
                    Set<ProvenanceDisplayField>.self,
                    forKey: .displayableFields
                ),
                processingLimits: container.decode(
                    ProvenanceProcessingLimits.self,
                    forKey: .processingLimits
                ),
                resourceBudget: container.decode(ArtifactID.self, forKey: .resourceBudget),
                statusMappings: container.decode(
                    [ProvenanceStatusMapping].self,
                    forKey: .statusMappings
                ),
                feasibilityApproval: container.decode(
                    ApprovalRecord.self,
                    forKey: .feasibilityApproval
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

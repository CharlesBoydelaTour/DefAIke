import Foundation

// How the artifact layer represents evidence sources, gate outcomes, conditional
// applicability, and external approvals.
//
// Three rules shape every type here, and they are the reason none of them has a
// default value:
//
//   * Presence is not approval. An artifact that names a legal, governance, trust,
//     or device record still has to carry that record's explicit decision.
//   * Missing is not pass. A gate that was never executed is representable and is
//     never counted as passing.
//   * Not applicable is a decision, not an absence. A conditional gate carries an
//     approved applicability decision, so a capability cannot become disabled (or
//     silently enabled) by a field simply being absent.

/// Immutable identity of one piece of release evidence.
///
/// Requirement 14.1 requires every mandatory gate to name its source artifact
/// identifiers, artifact versions, and result. This type carries the first two,
/// with a digest so the reference is to fixed content rather than to a mutable
/// document at the same identifier.
public struct EvidenceSource: Hashable, Codable, Sendable {
    /// The artifact this evidence came from.
    public let artifact: ArtifactID

    /// The exact version of that artifact.
    public let version: SchemaSemanticVersion

    /// Digest of the referenced content, binding the reference to fixed bytes.
    public let contentDigest: SHA256Digest

    public init(
        artifact: ArtifactID,
        version: SchemaSemanticVersion,
        contentDigest: SHA256Digest
    ) {
        self.artifact = artifact
        self.version = version
        self.contentDigest = contentDigest
    }
}

/// The recorded result of one release or device gate.
///
/// `notExecuted` exists so that "no result" is representable and auditable.
/// Only ``passed`` satisfies a gate; every other value blocks whatever depends on
/// it (Requirements 12.14, 13.19, and 14.15).
public enum GateOutcome: String, Codable, Sendable, CaseIterable {
    /// The gate ran and passed.
    case passed
    /// The gate ran and failed.
    case failed
    /// The gate did not run, or its result was not imported.
    case notExecuted = "not-executed"

    /// Whether this outcome satisfies the gate. Never true for a missing result.
    public var isPassing: Bool { self == .passed }
}

/// Whether an external decision approved or rejected something.
///
/// Legal, data-rights, governance, red-team, trust, fusion, and manual
/// accessibility conclusions are supplied here as decisions. No code path derives
/// one, and no code path treats a present record as a favorable record.
public enum ApprovalDecision: String, Codable, Sendable, CaseIterable {
    case approved
    case rejected

    public var isApproved: Bool { self == .approved }
}

/// One externally supplied, immutable approval record.
///
/// Used wherever the requirements reserve a conclusion for a human owner: the
/// repository license and dataset terms, the Lowq governance and red-team
/// decision, signing-key governance, the Provenance Feasibility decision, fusion
/// approval, approved copy, and any approved manual accessibility result.
public struct ApprovalRecord: Hashable, Codable, Sendable {
    /// The immutable record that carries the decision.
    public let source: EvidenceSource

    /// The decision that record contains. Required: presence is not approval.
    public let decision: ApprovalDecision

    /// The role or owner that decided.
    public let approver: ApproverID

    /// When the decision was recorded, for audit ordering only.
    public let decidedAt: Date

    public init(
        source: EvidenceSource,
        decision: ApprovalDecision,
        approver: ApproverID,
        decidedAt: Date
    ) {
        self.source = source
        self.decision = decision
        self.approver = approver
        self.decidedAt = decidedAt
    }

    /// Whether this record approves. False for a rejection, and unreachable
    /// without a record at all.
    public var isApproved: Bool { decision.isApproved }
}

/// Whether a conditional gate applies to a release, as an explicit decision.
///
/// A conditional gate such as provenance feasibility or fusion approval is either
/// applicable, in which case it must pass, or explicitly declared not applicable
/// by an approved decision. There is no third "absent" state, so a capability
/// cannot silently become enabled or waived (Requirements 14.1 and 14.17).
public enum GateApplicability: Hashable, Codable, Sendable {
    /// The gate applies to this release and must pass.
    case applicable

    /// The gate does not apply, by the carried approved decision.
    case notApplicable(decision: ApprovalRecord)

    public var isApplicable: Bool {
        switch self {
        case .applicable: true
        case .notApplicable: false
        }
    }

    /// The decision that made this gate inapplicable, when there is one.
    public var inapplicabilityDecision: ApprovalRecord? {
        switch self {
        case .applicable: nil
        case let .notApplicable(decision): decision
        }
    }
}

/// A binding to a conditional artifact, or an approved decision not to use one.
///
/// The optional artifacts in the design (Provenance Policy, Evidence Fusion Rule)
/// use this instead of `Optional`, because "no provenance policy" has to be a
/// recorded release decision rather than a missing field.
public enum ConditionalArtifactBinding<Reference: Hashable & Codable & Sendable>:
    Hashable, Codable, Sendable
{
    /// The conditional artifact is bound at this exact version.
    case bound(Reference)

    /// The capability is not part of this release, by the carried decision.
    case notApplicable(decision: ApprovalRecord)

    /// The bound reference, or `nil` when the capability is not applicable.
    public var boundReference: Reference? {
        switch self {
        case let .bound(reference): reference
        case .notApplicable: nil
        }
    }

    public var isBound: Bool { boundReference != nil }
}

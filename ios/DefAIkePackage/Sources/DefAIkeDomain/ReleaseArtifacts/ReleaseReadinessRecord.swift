import Foundation

// The signed Release Readiness Record and the claim records it binds.
//
// Requirement 14.1 requires a versioned, auditable record mapping every applicable
// mandatory gate to its source artifact identifiers, versions, and pass or fail result.
// Requirement 14.15 blocks distribution when any applicable mandatory entry is missing or
// failing, and Requirements 14.16 and 14.17 make the signed Initial Model Bundle and the
// Lowq governance decision hard blockers.
//
// The record contains no conclusions of its own. Legal, data-rights, and governance
// entries are approval records supplied from outside, conditional gates carry explicit
// applicability, and a gate with no result is representable and never counted as a pass.
// ``unresolvedMandatoryGates`` and ``failingMandatoryGates`` report what blocks a release;
// the eligibility decision itself belongs to the release validator, not to this schema.

/// One mandatory release-readiness gate.
public enum ReleaseGate: String, Codable, Sendable, Hashable, CaseIterable {
    // Evidence and calibration (Requirements 5.19 through 5.23).
    case calibrationSliceBudgets = "calibration-slice-budgets"
    case contemporaryPhoneCameraSlice = "contemporary-phone-camera-slice"
    case populationSeparation = "population-separation"
    case corpusIdentifierCorrection = "corpus-identifier-correction"
    case duplicateHashDisposition = "duplicate-hash-disposition"
    case benchmarkClaimBindings = "benchmark-claim-bindings"

    // Bundle integrity (Requirements 10.1 through 10.13 and 14.13).
    case initialModelBundleSignature = "initial-model-bundle-signature"
    case initialModelBundleSelfTests = "initial-model-bundle-self-tests"
    case bundleActivation = "bundle-activation"
    case bundleRollback = "bundle-rollback"

    // Privacy, security, dependencies (Requirements 9.18, 14.5, and 14.6).
    case privacyAudit = "privacy-audit"
    case archiveAudit = "archive-audit"
    case dependencyNotices = "dependency-notices"
    case corpusExclusion = "corpus-exclusion"

    // Accessibility and localization (Requirements 12.14 and 12.18).
    case accessibilityMatrix = "accessibility-matrix"
    case localizationReadinessMatrix = "localization-readiness-matrix"

    // Devices (Requirements 13.18 through 13.22).
    case deviceAllowlist = "device-allowlist"
    case fixtureSuiteCompleteness = "fixture-suite-completeness"
    case capabilityManifestMatch = "capability-manifest-match"

    // Legal and governance (Requirements 14.2 through 14.4, 14.9, 14.10, and 14.14).
    case repositoryCodeLicense = "repository-code-license"
    case dataDistributionRights = "data-distribution-rights"
    case modelGovernanceDecision = "model-governance-decision"
    case activeLimitationsPublication = "active-limitations-publication"
    case correctionChannel = "correction-channel"

    // Conditional capabilities (Requirements 6.1 through 6.3 and 7.14 through 7.16).
    case provenanceFeasibility = "provenance-feasibility"
    case fusionRuleApproval = "fusion-rule-approval"

    /// Whether this gate may be declared not applicable by an approved decision.
    ///
    /// Only the two capability gates are conditional. Every other gate is mandatory for
    /// every distribution, including a pixel-only one.
    public var isConditional: Bool {
        switch self {
        case .provenanceFeasibility, .fusionRuleApproval: true
        default: false
        }
    }

    /// Gates that block distribution when missing or failing, and cannot be waived.
    public static var unconditionalGates: Set<ReleaseGate> {
        Set(allCases.filter { !$0.isConditional })
    }
}

/// One gate's entry in the release-readiness record.
public struct ReleaseGateRecord: Hashable, Codable, Sendable {
    public let gate: ReleaseGate
    public let applicability: GateApplicability
    public let outcome: GateOutcome

    /// The immutable evidence this outcome came from.
    public let evidence: EvidenceSource

    public init(
        gate: ReleaseGate,
        applicability: GateApplicability,
        outcome: GateOutcome,
        evidence: EvidenceSource
    ) throws {
        if !gate.isConditional, !applicability.isApplicable {
            throw ArtifactSchemaError.forbiddenValue(
                field: "releaseGate[\(gate.rawValue)].applicability",
                value: "not-applicable",
                reason: "this gate is mandatory for every distribution and cannot be waived"
            )
        }
        if !applicability.isApplicable, outcome != .notExecuted {
            throw ArtifactSchemaError.inconsistentReference(
                field: "releaseGate[\(gate.rawValue)].outcome",
                expected: GateOutcome.notExecuted.rawValue,
                found: outcome.rawValue
            )
        }
        self.gate = gate
        self.applicability = applicability
        self.outcome = outcome
        self.evidence = evidence
    }

    /// Whether this gate is satisfied: it passed, or an approved decision declared it
    /// inapplicable. A missing result is never satisfied.
    public var isSatisfied: Bool {
        switch applicability {
        case .applicable: outcome.isPassing
        case let .notApplicable(decision): decision.isApproved
        }
    }

    private enum CodingKeys: String, CodingKey {
        case gate, applicability, outcome, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                gate: container.decode(ReleaseGate.self, forKey: .gate),
                applicability: container.decode(GateApplicability.self, forKey: .applicability),
                outcome: container.decode(GateOutcome.self, forKey: .outcome),
                evidence: container.decode(EvidenceSource.self, forKey: .evidence)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - External conclusions

/// The distribution-rights records a public release requires.
///
/// Requirement 14.4 blocks distribution while either is unresolved, which is why both are
/// approval records with explicit decisions rather than booleans.
public struct DistributionRightsRecord: Hashable, Codable, Sendable {
    /// The root repository code-license decision (Requirement 14.2).
    public let repositoryCodeLicense: ApprovalRecord

    /// The written dataset and benchmark terms decision (Requirement 14.3).
    public let datasetDistributionTerms: ApprovalRecord

    public init(
        repositoryCodeLicense: ApprovalRecord,
        datasetDistributionTerms: ApprovalRecord
    ) {
        self.repositoryCodeLicense = repositoryCodeLicense
        self.datasetDistributionTerms = datasetDistributionTerms
    }

    /// Whether both rights questions are approved.
    public var isResolved: Bool {
        repositoryCodeLicense.isApproved && datasetDistributionTerms.isApproved
    }
}

/// The inherited red-team status of a checkpoint.
public enum InheritedRedTeamStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case validReportInherited = "valid-report-inherited"
    case invalidNoReportInherited = "invalid-no-report-inherited"
}

/// The model governance and red-team decision record.
///
/// Requirement 14.9 requires the independent non-peer-reviewed status and
/// `redteam_validation_valid: false` to be disclosed, and Requirement 14.10 requires a
/// recorded release-owner decision. The disclosure fields are required data; the decision
/// is an approval record. Nothing derives the decision from the disclosures.
public struct ModelGovernanceDecisionRecord: Hashable, Codable, Sendable {
    public let modelIdentity: ModelIdentity

    /// Whether the checkpoint is an independent non-peer-reviewed fine-tune.
    public let isIndependentNonPeerReviewed: Bool

    /// The upstream `redteam_validation_valid` value, disclosed as measured.
    public let redTeamValidationValid: Bool

    public let inheritedRedTeamStatus: InheritedRedTeamStatus

    /// The release-owner governance and red-team risk decision.
    public let decision: ApprovalRecord

    public init(
        modelIdentity: ModelIdentity,
        isIndependentNonPeerReviewed: Bool,
        redTeamValidationValid: Bool,
        inheritedRedTeamStatus: InheritedRedTeamStatus,
        decision: ApprovalRecord
    ) throws {
        if !redTeamValidationValid, inheritedRedTeamStatus == .validReportInherited {
            throw ArtifactSchemaError.inconsistentReference(
                field: "governance.inheritedRedTeamStatus",
                expected: InheritedRedTeamStatus.invalidNoReportInherited.rawValue,
                found: inheritedRedTeamStatus.rawValue
            )
        }
        self.modelIdentity = modelIdentity
        self.isIndependentNonPeerReviewed = isIndependentNonPeerReviewed
        self.redTeamValidationValid = redTeamValidationValid
        self.inheritedRedTeamStatus = inheritedRedTeamStatus
        self.decision = decision
    }

    private enum CodingKeys: String, CodingKey {
        case modelIdentity, isIndependentNonPeerReviewed, redTeamValidationValid
        case inheritedRedTeamStatus, decision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                modelIdentity: container.decode(ModelIdentity.self, forKey: .modelIdentity),
                isIndependentNonPeerReviewed: container.decode(
                    Bool.self,
                    forKey: .isIndependentNonPeerReviewed
                ),
                redTeamValidationValid: container.decode(
                    Bool.self,
                    forKey: .redTeamValidationValid
                ),
                inheritedRedTeamStatus: container.decode(
                    InheritedRedTeamStatus.self,
                    forKey: .inheritedRedTeamStatus
                ),
                decision: container.decode(ApprovalRecord.self, forKey: .decision)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Benchmark claims

/// One published benchmark or evidence claim and every binding it requires.
///
/// Requirement 8.16 and Requirement 14.12 list the required bindings. All of them are
/// non-optional fields, so a claim missing any one of them cannot be represented, let
/// alone published.
public struct BenchmarkClaimRecord: Hashable, Codable, Sendable {
    public let id: ArtifactID

    /// The dataset the claim is measured on, and its composition.
    public let dataset: EvidenceSource
    public let datasetComposition: EvidenceSource

    /// The degradation condition the measurement used.
    public let degradationCondition: EvidenceSource

    public let modelIdentity: ModelIdentity
    public let modelBundle: ModelBundleID
    public let calibrationPolicy: ArtifactID

    /// Sample counts and coverage behind the claim.
    public let counts: SliceOutcomeCounts
    public let coverage: UnitInterval

    /// The metric definition and the evidence run that produced the value.
    public let metricDefinition: EvidenceSource
    public let evidenceProvenance: EvidenceSource

    /// The reported uncertainty interval.
    public let uncertaintyInterval: ConfidenceIntervalResult

    /// Active limitations and the correction channel published with the claim.
    public let activeLimitations: EvidenceSource
    public let correctionChannel: EvidenceSource

    public init(
        id: ArtifactID,
        dataset: EvidenceSource,
        datasetComposition: EvidenceSource,
        degradationCondition: EvidenceSource,
        modelIdentity: ModelIdentity,
        modelBundle: ModelBundleID,
        calibrationPolicy: ArtifactID,
        counts: SliceOutcomeCounts,
        coverage: UnitInterval,
        metricDefinition: EvidenceSource,
        evidenceProvenance: EvidenceSource,
        uncertaintyInterval: ConfidenceIntervalResult,
        activeLimitations: EvidenceSource,
        correctionChannel: EvidenceSource
    ) {
        self.id = id
        self.dataset = dataset
        self.datasetComposition = datasetComposition
        self.degradationCondition = degradationCondition
        self.modelIdentity = modelIdentity
        self.modelBundle = modelBundle
        self.calibrationPolicy = calibrationPolicy
        self.counts = counts
        self.coverage = coverage
        self.metricDefinition = metricDefinition
        self.evidenceProvenance = evidenceProvenance
        self.uncertaintyInterval = uncertaintyInterval
        self.activeLimitations = activeLimitations
        self.correctionChannel = correctionChannel
    }
}

// MARK: - Record

/// The signed, auditable release-readiness record.
public struct ReleaseReadinessRecord: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    public let appBuild: AppBuildID
    public let capabilityManifest: ArtifactID
    public let modelBundle: ModelBundleID
    public let deviceAllowlist: ArtifactID

    /// One record per mandatory gate, each gate exactly once.
    public let gateRecords: [ReleaseGateRecord]

    public let distributionRights: DistributionRightsRecord
    public let modelGovernance: ModelGovernanceDecisionRecord

    /// Claims approved for publication with this release, possibly none.
    public let benchmarkClaims: [BenchmarkClaimRecord]

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        appBuild: AppBuildID,
        capabilityManifest: ArtifactID,
        modelBundle: ModelBundleID,
        deviceAllowlist: ArtifactID,
        gateRecords: [ReleaseGateRecord],
        distributionRights: DistributionRightsRecord,
        modelGovernance: ModelGovernanceDecisionRecord,
        benchmarkClaims: [BenchmarkClaimRecord]
    ) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            gateRecords.map(\.gate.rawValue),
            required: Set(ReleaseGate.allCases.map(\.rawValue)),
            field: "release.gateRecords"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            benchmarkClaims.map(\.id.rawValue),
            field: "release.benchmarkClaims"
        )
        // A fusion rule cannot be applicable while provenance is not: an unavailable
        // provenance lane can never support a Combined Summary (Requirement 7.10).
        let provenanceApplicable = gateRecords
            .first { $0.gate == .provenanceFeasibility }?
            .applicability.isApplicable ?? false
        let fusionApplicable = gateRecords
            .first { $0.gate == .fusionRuleApproval }?
            .applicability.isApplicable ?? false
        guard !fusionApplicable || provenanceApplicable else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "release.gateRecords[fusion-rule-approval].applicability",
                expected: "not applicable while provenance feasibility is not applicable",
                found: "applicable"
            )
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.appBuild = appBuild
        self.capabilityManifest = capabilityManifest
        self.modelBundle = modelBundle
        self.deviceAllowlist = deviceAllowlist
        self.gateRecords = gateRecords
        self.distributionRights = distributionRights
        self.modelGovernance = modelGovernance
        self.benchmarkClaims = benchmarkClaims
    }

    /// The record for one gate. Total by construction.
    public func record(for gate: ReleaseGate) -> ReleaseGateRecord {
        // Safe: the initializer proved every gate appears exactly once.
        gateRecords.first { $0.gate == gate }!
    }

    /// Applicable mandatory gates whose result is missing.
    public var unresolvedMandatoryGates: Set<ReleaseGate> {
        Set(
            gateRecords
                .filter { $0.applicability.isApplicable && $0.outcome == .notExecuted }
                .map(\.gate)
        )
    }

    /// Applicable mandatory gates that failed, plus conditional gates whose
    /// inapplicability decision was rejected.
    public var failingMandatoryGates: Set<ReleaseGate> {
        Set(
            gateRecords
                .filter { !$0.isSatisfied && $0.outcome != .notExecuted }
                .map(\.gate)
        )
            .union(
                gateRecords
                    .filter { !$0.applicability.isApplicable && !$0.isSatisfied }
                    .map(\.gate)
            )
    }

    /// Whether provenance is part of this release, by explicit applicability.
    public var enablesProvenance: Bool {
        record(for: .provenanceFeasibility).applicability.isApplicable
    }

    /// Whether a Combined Summary is part of this release, by explicit applicability.
    public var enablesFusion: Bool {
        record(for: .fusionRuleApproval).applicability.isApplicable
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, appBuild, capabilityManifest, modelBundle, deviceAllowlist
        case gateRecords, distributionRights, modelGovernance, benchmarkClaims
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                appBuild: container.decode(AppBuildID.self, forKey: .appBuild),
                capabilityManifest: container.decode(ArtifactID.self, forKey: .capabilityManifest),
                modelBundle: container.decode(ModelBundleID.self, forKey: .modelBundle),
                deviceAllowlist: container.decode(ArtifactID.self, forKey: .deviceAllowlist),
                gateRecords: container.decode([ReleaseGateRecord].self, forKey: .gateRecords),
                distributionRights: container.decode(
                    DistributionRightsRecord.self,
                    forKey: .distributionRights
                ),
                modelGovernance: container.decode(
                    ModelGovernanceDecisionRecord.self,
                    forKey: .modelGovernance
                ),
                benchmarkClaims: container.decode(
                    [BenchmarkClaimRecord].self,
                    forKey: .benchmarkClaims
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

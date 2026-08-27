import Foundation

@testable import DefAIkeDomain

// A coherent synthetic Release Readiness Record and published claim, and one knob per
// thing that can go wrong.
//
// The shape every test here takes is: build a capability manifest, a validated
// accessibility matrix, a gate record for every mandatory gate, the external legal and
// governance records, an optional claim, and an evidence index that all agree; change
// exactly one of them; and require validation to refuse. That only works if the baseline
// is genuinely coherent, so as much as possible is derived — the evidence index follows
// from the identifiers the record cites, the matrix gates cite the matrix that was
// validated, and a claim's limitations and channel follow from the record's own published
// ones — and a knob is exposed only for the single field a test means to break.
//
// The baseline shares its identifiers with ``AccessibilityMatrixSample``, so the validated
// matrix that fixture produces is the one this record answers for rather than a
// coincidentally similar one.
//
// None of these values is an approved distribution, legal conclusion, governance decision,
// or measured benchmark. Every approval is a synthetic record whose decision the test sets,
// and every count and interval bound is a round placeholder number.

enum ReleaseReadinessSample {
    static let recordIdentifier = "record.release-readiness"
    static let manifestIdentifier = AccessibilityMatrixSample.manifestIdentifier
    static let allowlistIdentifier = AccessibilityMatrixSample.allowlistIdentifier
    static let matrixIdentifier = AccessibilityMatrixSample.matrixIdentifier
    static let appBuildIdentifier = AccessibilityMatrixSample.appBuildIdentifier
    static let bundleIdentifier = "bundle.sample"
    static let calibrationPolicyIdentifier = "policy.calibration"

    /// The approval every unlabelled synthetic record carries: the capability manifest's
    /// own approval, the allowlist's, and each conditional gate's waiver.
    static let sharedApprovalIdentifier = "approval.sample"

    static let codeLicenseApprovalIdentifier = "approval.code-license"
    static let datasetTermsApprovalIdentifier = "approval.dataset-terms"
    static let governanceApprovalIdentifier = "approval.governance"

    static let claimIdentifier = "claim.sample"
    static let datasetIdentifier = "evidence.dataset"
    static let compositionIdentifier = "evidence.composition"
    static let degradationIdentifier = "evidence.degradation"
    static let metricIdentifier = "evidence.metric"
    static let runIdentifier = "evidence.run"

    // MARK: - Gate evidence

    /// The evidence identifier the baseline record cites for one gate.
    ///
    /// The two matrix gates cite the accessibility matrix itself, because that is the
    /// artifact the validated matrix resolves to; every other gate cites its own result
    /// record.
    static func gateEvidenceIdentifier(_ gate: ReleaseGate) -> String {
        switch gate {
        case .accessibilityMatrix, .localizationReadinessMatrix: matrixIdentifier
        default: "evidence.release.\(gate.rawValue)"
        }
    }

    /// The record's published active limitations, which a claim has to be bound to.
    static var limitationsIdentifier: String {
        gateEvidenceIdentifier(.activeLimitationsPublication)
    }

    /// The record's published correction channel, which a claim has to be bound to.
    static var correctionChannelIdentifier: String {
        gateEvidenceIdentifier(.correctionChannel)
    }

    // MARK: - Evidence index

    /// Every artifact identifier the coherent baseline cites, each one once.
    static var baselineEvidenceIdentifiers: [String] {
        var identifiers: [String] = []
        for candidate in ReleaseGate.allCases.map(gateEvidenceIdentifier)
            + [
                sharedApprovalIdentifier,
                codeLicenseApprovalIdentifier,
                datasetTermsApprovalIdentifier,
                governanceApprovalIdentifier,
                AccessibilityMatrixSample.accessibilityEvidenceIdentifier,
                AccessibilityMatrixSample.localizationEvidenceIdentifier,
                AccessibilityMatrixSample.manualApprovalIdentifier,
                datasetIdentifier,
                compositionIdentifier,
                degradationIdentifier,
                metricIdentifier,
                runIdentifier,
            ]
        where !identifiers.contains(candidate) {
            identifiers.append(candidate)
        }
        return identifiers
    }

    /// The release evidence the coherent baseline cites, minus whatever a test removes.
    ///
    /// `omitting` is how a test makes one citation unresolvable without touching the record
    /// that cites it, which is the difference between "this reference names nothing" and
    /// "this record names something else".
    static func evidenceIndex(
        omitting omitted: Set<String> = [],
        adding added: [EvidenceSource] = []
    ) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: baselineEvidenceIdentifiers
                .filter { !omitted.contains($0) }
                .map { Sample.evidence($0) } + added
        )
    }

    // MARK: - Gate records

    /// One record per mandatory gate, every applicable one passing.
    ///
    /// `applicability` and `outcomes` are keyed by gate so a test names exactly the entry it
    /// changes. The conditional gates default to not applicable, which is the pixel-only
    /// release the sample capability manifest describes.
    static func gateRecords(
        provenanceApplicable: Bool = false,
        fusionApplicable: Bool = false,
        outcomes: [ReleaseGate: GateOutcome] = [:],
        waiverDecisions: [ReleaseGate: ApprovalDecision] = [:],
        waiverEvidence: String = ReleaseReadinessSample.sharedApprovalIdentifier,
        evidenceIdentifiers: [ReleaseGate: String] = [:],
        gates: [ReleaseGate] = ReleaseGate.allCases
    ) throws -> [ReleaseGateRecord] {
        try gates.map { gate in
            let applicable: Bool
            switch gate {
            case .provenanceFeasibility: applicable = provenanceApplicable
            case .fusionRuleApproval: applicable = fusionApplicable
            default: applicable = true
            }
            let waiver = Sample.approval(
                waiverDecisions[gate] ?? .approved,
                identifier: waiverEvidence
            )
            return try ReleaseGateRecord(
                gate: gate,
                applicability: applicable ? .applicable : .notApplicable(decision: waiver),
                outcome: applicable ? (outcomes[gate] ?? .passed) : .notExecuted,
                evidence: Sample.evidence(
                    evidenceIdentifiers[gate] ?? gateEvidenceIdentifier(gate)
                )
            )
        }
    }

    // MARK: - Benchmark claims

    /// One completely bound published claim, unless a test breaks a single binding.
    static func claim(
        identifier: String = ReleaseReadinessSample.claimIdentifier,
        modelIdentity: ModelIdentity = RequiredPixelModel.identity,
        modelBundle: String = ReleaseReadinessSample.bundleIdentifier,
        calibrationPolicy: String = ReleaseReadinessSample.calibrationPolicyIdentifier,
        counts: SliceOutcomeCounts? = nil,
        coverage: Decimal = Decimal(sign: .plus, exponent: -1, significand: 8),
        dataset: String = ReleaseReadinessSample.datasetIdentifier,
        composition: String = ReleaseReadinessSample.compositionIdentifier,
        degradation: String = ReleaseReadinessSample.degradationIdentifier,
        metricDefinition: String = ReleaseReadinessSample.metricIdentifier,
        evidenceProvenance: String = ReleaseReadinessSample.runIdentifier,
        interval: ConfidenceIntervalResult? = nil,
        activeLimitations: String? = nil,
        correctionChannel: String? = nil
    ) throws -> BenchmarkClaimRecord {
        BenchmarkClaimRecord(
            id: Sample.artifact(identifier),
            dataset: Sample.evidence(dataset),
            datasetComposition: Sample.evidence(composition),
            degradationCondition: Sample.evidence(degradation),
            modelIdentity: modelIdentity,
            modelBundle: Sample.bundle(modelBundle),
            calibrationPolicy: Sample.artifact(calibrationPolicy),
            counts: try counts ?? outcomeCounts(),
            coverage: Sample.ratio(coverage),
            metricDefinition: Sample.evidence(metricDefinition),
            evidenceProvenance: Sample.evidence(evidenceProvenance),
            uncertaintyInterval: try interval ?? uncertaintyInterval(),
            activeLimitations: Sample.evidence(activeLimitations ?? limitationsIdentifier),
            correctionChannel: Sample.evidence(correctionChannel ?? correctionChannelIdentifier)
        )
    }

    /// Counts behind the baseline claim: 100 eligible images, 80 of them decisive, so the
    /// baseline coverage of 0.8 is the fraction Requirement 5.18 defines.
    static func outcomeCounts(
        eligibleReal: Int = 60,
        eligibleSynthetic: Int = 40,
        realDecisive: Int = 50,
        syntheticDecisive: Int = 30
    ) throws -> SliceOutcomeCounts {
        try SliceOutcomeCounts(
            eligibleRealImages: Sample.nonNegative(eligibleReal),
            eligibleSyntheticImages: Sample.nonNegative(eligibleSynthetic),
            realPositiveLabels: Sample.nonNegative(0),
            realNonPositiveLabels: Sample.nonNegative(realDecisive),
            realInsufficientLabels: Sample.nonNegative(eligibleReal - realDecisive),
            syntheticPositiveLabels: Sample.nonNegative(syntheticDecisive),
            syntheticNonPositiveLabels: Sample.nonNegative(0),
            syntheticInsufficientLabels: Sample.nonNegative(
                eligibleSynthetic - syntheticDecisive
            ),
            errorCount: Sample.nonNegative(0)
        )
    }

    /// The baseline uncertainty interval: a real interval at a real confidence level.
    static func uncertaintyInterval(
        level: Decimal = FalseAccusationPassRule.requiredConfidenceLevel,
        lowerBound: Decimal = 0,
        upperBound: Decimal = Decimal(sign: .plus, exponent: -2, significand: 1)
    ) throws -> ConfidenceIntervalResult {
        try ConfidenceIntervalResult(
            method: .wilsonScore,
            confidenceLevel: Sample.ratio(level),
            lowerBound: Sample.ratio(lowerBound),
            upperBound: Sample.ratio(upperBound)
        )
    }

    // MARK: - Record

    static func governance(
        modelIdentity: ModelIdentity = RequiredPixelModel.identity,
        isIndependentNonPeerReviewed: Bool = true,
        redTeamValidationValid: Bool = false,
        decision: ApprovalDecision = .approved
    ) throws -> ModelGovernanceDecisionRecord {
        try ModelGovernanceDecisionRecord(
            modelIdentity: modelIdentity,
            isIndependentNonPeerReviewed: isIndependentNonPeerReviewed,
            redTeamValidationValid: redTeamValidationValid,
            inheritedRedTeamStatus: redTeamValidationValid
                ? .validReportInherited
                : .invalidNoReportInherited,
            decision: Sample.approval(decision, identifier: governanceApprovalIdentifier)
        )
    }

    static func distributionRights(
        code: ApprovalDecision = .approved,
        data: ApprovalDecision = .approved
    ) -> DistributionRightsRecord {
        DistributionRightsRecord(
            repositoryCodeLicense: Sample.approval(
                code,
                identifier: codeLicenseApprovalIdentifier
            ),
            datasetDistributionTerms: Sample.approval(
                data,
                identifier: datasetTermsApprovalIdentifier
            )
        )
    }

    /// The coherent baseline record, unless a test replaces one field.
    static func record(
        identifier: String = ReleaseReadinessSample.recordIdentifier,
        appBuild: String = ReleaseReadinessSample.appBuildIdentifier,
        capabilityManifest: String = ReleaseReadinessSample.manifestIdentifier,
        modelBundle: String = ReleaseReadinessSample.bundleIdentifier,
        deviceAllowlist: String = ReleaseReadinessSample.allowlistIdentifier,
        gateRecords replacement: [ReleaseGateRecord]? = nil,
        distributionRights rights: DistributionRightsRecord? = nil,
        modelGovernance: ModelGovernanceDecisionRecord? = nil,
        benchmarkClaims: [BenchmarkClaimRecord] = []
    ) throws -> ReleaseReadinessRecord {
        try ReleaseReadinessRecord(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            appBuild: Sample.appBuild(appBuild),
            capabilityManifest: Sample.artifact(capabilityManifest),
            modelBundle: Sample.bundle(modelBundle),
            deviceAllowlist: Sample.artifact(deviceAllowlist),
            gateRecords: try replacement ?? gateRecords(),
            distributionRights: rights ?? distributionRights(),
            modelGovernance: try modelGovernance ?? governance(),
            benchmarkClaims: benchmarkClaims
        )
    }

    // MARK: - Capability manifest

    /// The signed manifest the baseline record answers for.
    ///
    /// A provenance-enabled manifest needs the conditional policy bindings the manifest
    /// schema couples to the compiled capability set, so both are derived from one flag
    /// rather than being separate knobs a test could leave inconsistent.
    static func capabilityManifest(
        provenanceEnabled: Bool = false,
        fusionEnabled: Bool = false,
        approval: ApprovalDecision = .approved,
        approvalEvidence: String = ReleaseReadinessSample.sharedApprovalIdentifier
    ) throws -> ReleaseCapabilityManifest {
        var capabilities: Set<CapabilityID> = [.pixelAnalysis]
        if provenanceEnabled { capabilities.insert(.contentCredentialValidation) }
        if fusionEnabled { capabilities.insert(.evidenceFusion) }
        return try ReleaseCapabilityManifest(
            id: Sample.artifact(manifestIdentifier),
            schemaVersion: .v1,
            appBuild: Sample.appBuild(appBuildIdentifier),
            compositionIdentifier: Sample.text(
                provenanceEnabled ? "pixel-plus-provenance" : "pixel-only"
            ),
            compiledCapabilities: capabilities,
            implementationVersions: capabilities.sorted { $0.rawValue < $1.rawValue }
                .map { CapabilityImplementationEntry(capability: $0, version: Sample.version()) },
            approvedConfigurationAllowlist: Sample.artifact(allowlistIdentifier),
            approvedBundleCatalog: [Sample.bundle(bundleIdentifier)],
            policyCompatibility: try Sample.policyCompatibility(
                provenance: provenanceEnabled
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval()),
                fusion: fusionEnabled
                    ? .bound(Sample.artifact("rule.fusion"))
                    : .notApplicable(decision: Sample.approval())
            ),
            approval: Sample.approval(approval, identifier: approvalEvidence)
        )
    }

    // MARK: - Validation

    /// The validated baseline, or the same validation with one input replaced.
    static func validated(
        record replacement: ReleaseReadinessRecord? = nil,
        manifest: ReleaseCapabilityManifest? = nil,
        accessibilityMatrix matrix: ValidatedAccessibilityGateMatrix? = nil,
        evidence index: ReleaseEvidenceIndex? = nil
    ) throws -> EligibleRelease {
        let resolvedManifest = try manifest ?? capabilityManifest()
        return try EligibleRelease(
            validating: try replacement ?? record(),
            capabilityManifest: resolvedManifest,
            accessibilityMatrix: try matrix ?? validatedMatrix(manifest: resolvedManifest),
            evidence: try index ?? evidenceIndex()
        )
    }

    /// The validated accessibility matrix the baseline record's two matrix gates cite.
    static func validatedMatrix(
        manifest: ReleaseCapabilityManifest? = nil,
        allowlist: ReleaseApprovedDeviceAllowlist? = nil
    ) throws -> ValidatedAccessibilityGateMatrix {
        try AccessibilityMatrixSample.validated(
            allowlist: allowlist,
            manifest: try manifest ?? capabilityManifest(),
            evidence: try evidenceIndex()
        )
    }
}

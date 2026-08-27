import DefAIkeDomain
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic samples for release-record assembly and allowlist generation.
//
// Every value here is deliberately synthetic. None of these is an approved capability manifest,
// an approved allowlist decision, an approved licence or governance record, an approved
// calibration release, an approved fixture suite, or a real physical-device result. The tests
// build a structurally complete assembly and then change one thing at a time.
//
// Two things a reader could mistake for a claim this suite is not making.
//
// **One plan, one tuple, one manifest.** The three device runners are bound to the *same*
// `DeviceValidationPlan` and the *same* `ValidationVersionTuple` here, because that is what
// `CoherentDeviceEvidence` requires and what Requirement 13.20 means. `Sample.resourcePlan()` is
// reused as the joined plan because it is the only sample plan that declares both a complete
// comparison set and a complete measurement set for both targets.
//
// **A sample observation or sample series that says `.physicalIPhone` is a claim, not evidence.**
// It lets the comparison and limit arithmetic run on a host. What it cannot do is make a gate
// pass: every runner's gate result consults `ObservedParityEnvironment.current`, compiled from
// the platform with no parameter, so every device gate in this repository fails and the
// generated allowlist is empty. These samples assert that as the correct reported state rather
// than working around it.

extension Sample {

    // MARK: The joined plan, tuple, and manifest

    /// The one plan all three device runners are bound to.
    static func joinedPlan(
        planIdentifier: String = "plan.device-validation",
        extraConfigurations: [CandidateDeviceConfiguration] = []
    ) throws -> DeviceValidationPlan {
        try resourcePlan(
            planIdentifier: planIdentifier,
            extraConfigurations: extraConfigurations
        )
    }

    /// The one version tuple all three device runners ran under.
    static func joinedTuple(
        provenanceEnabled: Bool = false,
        appBuild overrideBuild: AppBuildID? = nil,
        implementationVersion: String = "1.0.0"
    ) throws -> ValidationVersionTuple {
        let capabilities: Set<CapabilityID> = provenanceEnabled
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        return try ValidationVersionTuple(
            appBuild: overrideBuild ?? appBuild(),
            modelBundle: bundle(),
            fixtureSuite: artifact("suite.fixtures"),
            validationPlan: artifact("plan.device-validation"),
            capabilityManifest: artifact("manifest.capability"),
            capabilities: capabilities,
            capabilityImplementationVersions: capabilities
                .sorted { $0.rawValue < $1.rawValue }
                .map {
                    CapabilityImplementationEntry(
                        capability: $0,
                        version: version(implementationVersion)
                    )
                }
        )
    }

    /// The signed capability manifest the record answers for.
    ///
    /// Its compiled capability set and implementation versions are what
    /// ``CoherentDeviceEvidence`` reconciles every tuple against, so a test that changes one of
    /// them here is changing the release's own statement of what it built.
    static func releaseManifest(
        provenanceEnabled: Bool = false,
        fusionEnabled: Bool = false,
        appBuild overrideBuild: AppBuildID? = nil,
        implementationVersion: String = "1.0.0",
        approvedBundles: [ModelBundleID]? = nil,
        approval overrideApproval: ApprovalRecord? = nil
    ) throws -> ReleaseCapabilityManifest {
        var capabilities: Set<CapabilityID> = [.pixelAnalysis]
        if provenanceEnabled { capabilities.insert(.contentCredentialValidation) }
        if fusionEnabled { capabilities.insert(.evidenceFusion) }
        return try ReleaseCapabilityManifest(
            id: artifact("manifest.capability"),
            schemaVersion: .v1,
            appBuild: overrideBuild ?? appBuild(),
            compositionIdentifier: text("sample-composition"),
            compiledCapabilities: capabilities,
            implementationVersions: capabilities
                .sorted { $0.rawValue < $1.rawValue }
                .map {
                    CapabilityImplementationEntry(
                        capability: $0,
                        version: version(implementationVersion)
                    )
                },
            approvedConfigurationAllowlist: artifact("allowlist.approved-configurations"),
            approvedBundleCatalog: approvedBundles ?? [bundle()],
            policyCompatibility: PolicyCompatibilitySet(
                preprocessingContract: artifact("policy.preprocessing"),
                calibrationPolicy: artifact("policy.calibration"),
                lifecyclePolicy: artifact("policy.lifecycle"),
                extensionExecutionPolicy: artifact("policy.extension-execution"),
                mainApplicationResourceBudget: artifact("budget.main-application"),
                shareExtensionResourceBudget: artifact("budget.share-extension"),
                bundleVerificationPolicy: artifact("policy.bundle-verification"),
                verdictCopyCompatibility: artifact("copy.compatibility"),
                provenancePolicy: provenanceEnabled
                    ? .bound(artifact("policy.provenance"))
                    : .notApplicable(decision: approval(identifier: "approval.no-provenance")),
                fusionRule: fusionEnabled
                    ? .bound(artifact("rule.fusion"))
                    : .notApplicable(decision: approval(identifier: "approval.no-fusion"))
            ),
            approval: overrideApproval ?? approval(identifier: "approval.capability-manifest")
        )
    }

    // MARK: One configuration's coherent device evidence

    /// A parity report for one configuration under the joined plan and tuple.
    static func joinedParityReport(
        plan: DeviceValidationPlan,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple,
        provenanceApplicable: Bool = false,
        agreeing: Bool = true
    ) throws -> ParityRunReport {
        let binding = try ParityRunBinding(
            plan: plan,
            catalog: catalog(provenanceApplicable: provenanceApplicable),
            configuration: configuration,
            versionTuple: versionTuple
        )
        let store = agreeing
            ? FakeParityObservationStore.agreeing(with: binding)
            : FakeParityObservationStore.empty(for: binding)
        return ParityRunner(observations: store).run(binding)
    }

    /// A resource report for one configuration under the joined plan and tuple.
    static func joinedResourceReport(
        plan: DeviceValidationPlan,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple,
        complete: Bool = true
    ) throws -> ResourceValidationReport {
        let binding = try ResourceValidationRunBinding(
            plan: plan,
            budgets: resourceBudgets(),
            configuration: configuration,
            versionTuple: versionTuple
        )
        let store = complete
            ? FakeResourceSampleStore.complete(for: binding)
            : FakeResourceSampleStore.empty(for: binding.mainApplication)
        return ResourceMeasurementRunner(samples: store).run(binding)
    }

    /// A matrix report for the whole coverage under the joined plan and tuple.
    static func joinedMatrixReport(
        plan: DeviceValidationPlan,
        versionTuple: ValidationVersionTuple,
        complete: Bool = true
    ) throws -> AccessibilityMatrixReport {
        let coverage = try AccessibilityMatrixCoverageBinding(
            plan: plan,
            versionTuple: versionTuple
        )
        let store = complete
            ? FakeMatrixObservationStore.complete(for: coverage)
            : FakeMatrixObservationStore.empty(for: coverage.bindings[0])
        return AccessibilityMatrixRunner(observations: store).run(coverage)
    }

    /// One configuration's coherent device evidence, joined from all three runners.
    static func coherentDeviceEvidence(
        configurationID: String = "configuration.sample",
        plan overridePlan: DeviceValidationPlan? = nil,
        configuration overrideConfiguration: CandidateDeviceConfiguration? = nil,
        versionTuple overrideTuple: ValidationVersionTuple? = nil,
        capabilityManifest overrideManifest: ReleaseCapabilityManifest? = nil,
        provenanceApplicable: Bool = false,
        parityVersionTuple overrideParityTuple: ValidationVersionTuple? = nil,
        resourceVersionTuple overrideResourceTuple: ValidationVersionTuple? = nil,
        matrixVersionTuple overrideMatrixTuple: ValidationVersionTuple? = nil
    ) throws -> CoherentDeviceEvidence {
        let plan = try overridePlan ?? joinedPlan()
        let tuple = try overrideTuple ?? joinedTuple(provenanceEnabled: provenanceApplicable)
        let configuration = try overrideConfiguration ?? plan.candidateConfigurations[0]
        let manifest = try overrideManifest
            ?? releaseManifest(provenanceEnabled: provenanceApplicable)
        let whole = try joinedMatrixReport(
            plan: plan,
            versionTuple: overrideMatrixTuple ?? tuple
        )
        guard let scoped = whole.report(for: configuration) else {
            throw SampleFault.matrixReportMissing
        }
        return try CoherentDeviceEvidence(
            configurationID: ApprovedConfigurationID(configurationID)!,
            parity: try joinedParityReport(
                plan: plan,
                configuration: configuration,
                versionTuple: overrideParityTuple ?? tuple,
                provenanceApplicable: provenanceApplicable
            ),
            resources: try joinedResourceReport(
                plan: plan,
                configuration: configuration,
                versionTuple: overrideResourceTuple ?? tuple
            ),
            matrix: scoped,
            catalog: try catalog(provenanceApplicable: provenanceApplicable),
            capabilityManifest: manifest,
            parityResult: matrixEvidence("result.parity", digest: 0xD1),
            resourceResult: matrixEvidence("result.resource", digest: 0xD2),
            matrixResult: matrixEvidence("result.matrix", digest: 0xD3)
        )
    }

    // MARK: Archive audit evidence

    /// An archive-audit report whose four gates all pass, with nothing owed.
    ///
    /// Not the state of this repository: task 14.6's audit correctly exits 1 with six notice
    /// gaps and six owed inputs. This value exists so a test can vary the archive half by one
    /// finding and observe the record change, which an already-failing report cannot show.
    static func archiveAuditReport(
        inspected: Bool = true,
        findings: [ArchiveAuditFinding] = [],
        owed: [UnprovisionedArchiveAuditInput] = []
    ) -> ArchiveAuditReport {
        var gates: [ArchiveAuditGateEvidence] = []
        for gate in ArchiveAuditFailingInputClass.producedGates
            .sorted(by: { $0.rawValue < $1.rawValue })
        {
            gates.append(
                ArchiveAuditGateEvidence(
                    gate: gate,
                    findings: findings.filter { $0.failingInputClass.gate == gate },
                    unprovisionedInputs: gate == .archiveAudit ? owed : [],
                    archivesInspected: inspected
                )
            )
        }
        return ArchiveAuditReport(
            schemaVersion: 1,
            archivesInspected: inspected,
            gates: gates,
            observations: [],
            bundleFileCounts: ["pixel-only": ["DefAIke.app": 42]]
        )
    }

    // MARK: The record evidence

    /// A record-evidence set with every gate citation present and the two conditional
    /// applicability decisions supplied.
    ///
    /// The optional evidence kinds default to their real state in this repository — absent — so a
    /// test has to opt into supplying one. That direction is deliberate: the default assembly is
    /// the honest one.
    static func recordEvidence(
        capabilityManifest overrideManifest: ReleaseCapabilityManifest? = nil,
        modelBundle overrideBundle: ModelBundleID? = nil,
        calibration: ApprovedCalibrationRelease? = nil,
        corpus: CorpusRemediation? = nil,
        bundle overrideBundleEvidence: BundleActivationEvidence? = nil,
        archive: ArchiveAuditReport? = nil,
        matrix: AccessibilityMatrixReport? = nil,
        deviceEvidence: [CoherentDeviceEvidence] = [],
        distributionRights: DistributionRightsRecord? = nil,
        modelGovernance: ModelGovernanceDecisionRecord? = nil,
        activeLimitations: EvidenceSource? = nil,
        correctionChannel: EvidenceSource? = nil,
        benchmarkClaims: [BenchmarkClaimRecord] = [],
        conditionalApplicability: [ReleaseGate: GateApplicability]? = nil,
        gateCitations: [ReleaseGate: EvidenceSource]? = nil,
        allowlistApproval overrideAllowlistApproval: ApprovalRecord? = nil
    ) throws -> ReleaseRecordEvidence {
        let manifest = try overrideManifest ?? releaseManifest()
        var citations: [ReleaseGate: EvidenceSource] = [:]
        for gate in ReleaseGate.allCases {
            citations[gate] = matrixEvidence("result.\(gate.rawValue)", digest: 0xC0)
        }
        var applicability: [ReleaseGate: GateApplicability] = [:]
        applicability[.provenanceFeasibility] = manifest.enablesProvenance
            ? .applicable
            : notApplicable()
        applicability[.fusionRuleApproval] = manifest.enablesFusion
            ? .applicable
            : notApplicable()
        return ReleaseRecordEvidence(
            recordID: artifact("record.release-readiness"),
            schemaVersion: .v1,
            capabilityManifest: manifest,
            modelBundle: overrideBundle ?? bundle(),
            calibration: calibration,
            corpus: corpus,
            bundle: overrideBundleEvidence,
            archive: archive,
            matrix: matrix,
            deviceEvidence: deviceEvidence,
            distributionRights: distributionRights,
            modelGovernance: modelGovernance,
            activeLimitations: activeLimitations,
            correctionChannel: correctionChannel,
            benchmarkClaims: benchmarkClaims,
            conditionalApplicability: conditionalApplicability ?? applicability,
            gateCitations: gateCitations ?? citations,
            allowlistApproval: overrideAllowlistApproval
                ?? approval(identifier: "approval.device-allowlist")
        )
    }

    /// A distribution-rights record whose two decisions are supplied independently.
    static func distributionRights(
        codeLicense: ApprovalDecision = .approved,
        datasetTerms: ApprovalDecision = .approved
    ) -> DistributionRightsRecord {
        DistributionRightsRecord(
            repositoryCodeLicense: matrixApproval(
                "approval.repository-code-license",
                digest: 0xB1,
                decision: codeLicense
            ),
            datasetDistributionTerms: matrixApproval(
                "approval.dataset-terms",
                digest: 0xB2,
                decision: datasetTerms
            )
        )
    }
}

/// Why a sample could not be built. Not a product vocabulary; scaffolding only.
enum SampleFault: Error, Equatable {
    /// A matrix run produced no report for a configuration its own plan enumerates.
    case matrixReportMissing
}

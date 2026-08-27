import DefAIkeDomain
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic release evidence for the release-pipeline gate and audit probes (task 14.10).
//
// # Everything here is obviously synthetic, and says so
//
// **No value in this file is a real legal, trust, governance, device, or fusion approval.**
// Every `ApprovalRecord` is a synthetic record whose decision a caller sets; every artifact
// identifier is a `.sample`-shaped placeholder; every digest is `Sample.digest(index)` over a
// small integer; every count is a round placeholder; every device configuration is a plan entry
// nobody approved; and both conditional-capability decisions are synthetic waivers. Nothing here
// selects a signing key, and nothing here declares that a distribution may proceed.
//
// **The signature stand-in available in this repository is `sha256(keyMaterial ‖ message)`.** One
// such value verifies under every `SignatureAlgorithm` the schema can name, so it is not a
// scheme. No test in task 14.10 verifies a signature, and a verification pass over one of these
// values would establish that bytes are the bytes measured and nothing about who produced them.
// ``UnobservableReleaseRecordEvidence/signatureStandInVerifiesUnderEveryDeclaredAlgorithm`` is the
// vocabulary case that records this, and every assembled record here carries it.
//
// # What these samples can and cannot make pass
//
// Task 14.8 closed its assembly with three gaps, and two of them are what this file exists to
// fill: no calibration or bundle evidence had ever been exercised as a *present* value, and no
// successful `releaseOutput()` existed anywhere. So the builders below produce
//
//   * ``PipelineSample/approvedCalibration(_:)`` — a genuine ``ApprovedCalibrationRelease``,
//     built through the domain's own approval gate over a validated policy, two predeclared
//     mandatory slices (one of them the Requirement 5.20 contemporary phone-camera real slice),
//     two reconciled reports, a three-pair dataset lineage record, and an evidence index in which
//     every citation resolves. The approval refuses rather than reporting a status, so holding
//     the value *is* the Requirement 5.22 budget result; and
//   * ``PipelineSample/bundleEvidence(...)`` — a ``BundleActivationEvidence`` whose six recorded
//     gates a caller sets one at a time, constructed through the module-internal initialiser.
//     **This is a synthetic record of a verification that did not happen.** No signed Model
//     Bundle exists in this repository, and a bundle assembled from synthetic staged content
//     stops at Requirement 10.4's approved weight blob by design (task 14.5 measured that
//     ceiling and named it ``ProducedBundleVerification/stoppedAtApprovedWeightBlob``). What the
//     value is for is exercising the record's *join*: which record gate reads which of the six
//     recorded results, and what one failing result does to it.
//
// What no builder here does is make a device gate pass. Every runner's gate result consults
// ``ObservedParityEnvironment/current``, compiled from the platform with no parameter, so on a
// host `swift test` run the three device-shaped record gates — `device-allowlist`,
// `accessibility-matrix`, and `localization-readiness-matrix` — fail whatever is measured, the
// generated allowlist is empty, and Requirement 13.22 blocks. That is asserted as the correct
// reported state rather than worked around, and it is why the honest maximum for a synthetic
// record here is 21 of the 24 unconditional record gates passing.
//
// The one place a payload is reached at all is
// ``PipelineSample/allowlistAdmittedOnlyByThePinnedWaiverDefect()``, whose name is the whole
// disclosure: it exists to demonstrate that ``ReleaseReadinessRecord`` construction and
// ``CanonicalArtifactEncoding`` work over a complete record, and it reaches
// ``GeneratedDeviceAllowlist/permitsDistribution`` only through a defect this task pins and does
// not fix. It is not evidence that any iPhone configuration passes anything.

// MARK: - Namespace

/// Synthetic release evidence for the release-pipeline probes.
///
/// A separate namespace from ``Sample`` on purpose. ``Sample`` is shared by six sibling suites
/// and this task adds no member to it, so nothing here can change a value another suite depends
/// on.
enum PipelineSample {

    // MARK: Identifiers the baseline cites

    static let recordIdentifier = "record.release-readiness"
    static let calibrationPolicyIdentifier = "policy.calibration"
    static let phoneCameraSliceIdentifier = "slice.phone-camera"
    static let generalSliceIdentifier = "slice.general"
    static let lineageIdentifier = "record.dataset-lineage"

    static let calibrationEvidenceIdentifier = "evidence.calibration"
    static let compositionIdentifier = "evidence.composition"
    static let separationIdentifier = "evidence.separation"
    static let sliceSpecificationIdentifier = "evidence.slice-specification"
    static let limitationsIdentifier = "document.active-limitations"
    static let correctionChannelIdentifier = "document.correction-channel"
    static let claimIdentifier = "claim.sample"
    static let rollbackBundleIdentifier = "bundle.previous"

    /// Every evidence artifact the calibration approval cites.
    ///
    /// Listed rather than derived because the calibration index is the one place a test makes a
    /// citation unresolvable by *removing* it, and a derived list would grow back whatever a test
    /// took out.
    static let calibrationEvidenceIdentifiers = [
        calibrationEvidenceIdentifier,
        "evidence.eligibility",
        "evidence.outcome-mapping",
        "evidence.metric",
        compositionIdentifier,
        "evidence.degradation",
        separationIdentifier,
        "evidence.identifier-correction",
        "evidence.duplicate-hashes",
        sliceSpecificationIdentifier,
    ]

    // MARK: Small primitives the sibling samples do not carry

    static func nonNegative(_ value: Int) -> NonNegativeCount {
        // Safe: every call site passes a literal at or above zero.
        try! NonNegativeCount(validating: value)
    }

    /// A stable key for one unordered population pair.
    ///
    /// Sorted, so the same two populations produce one key whichever order a caller lists them
    /// in. Spelled out here rather than reused because the domain's own `pairKey` is internal to
    /// `DefAIkeDomain`; the two agree on the sorted-join rule, which is the only thing a probe
    /// keyed by pair depends on.
    static func pairKey(_ first: CalibrationPopulation, _ second: CalibrationPopulation) -> String {
        [first.rawValue, second.rawValue].sorted().joined(separator: "|")
    }

    static func slice(_ value: String) -> ReleaseSliceID {
        // Safe: every call site passes a well-formed dotted identifier.
        ReleaseSliceID(value)!
    }

    /// An evidence source at a digest derived from its identifier.
    ///
    /// Distinct per artifact, so an index that resolved the wrong artifact would disagree on the
    /// digest rather than silently matching. Deliberately not ``Sample/evidence(_:)``, which gives
    /// every reference one digest.
    static func evidence(_ identifier: String) -> EvidenceSource {
        EvidenceSource(
            artifact: Sample.artifact(identifier),
            version: Sample.version(),
            contentDigest: Sample.digest(digestIndex(of: identifier))
        )
    }

    /// A synthetic approval record at a digest derived from its identifier.
    ///
    /// The decision is a parameter with no default toward approval at the call sites that vary
    /// it. Nothing here is a real legal, governance, or trust decision.
    static func approval(
        _ decision: ApprovalDecision = .approved,
        identifier: String
    ) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(identifier),
            decision: decision,
            approver: Sample.approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func notApplicable(
        _ decision: ApprovalDecision = .approved,
        identifier: String
    ) -> GateApplicability {
        .notApplicable(decision: approval(decision, identifier: identifier))
    }

    /// A stable small digest index for one identifier.
    ///
    /// Bounded to 0...4095 so two identifiers collide only if they hash into the same bucket, and
    /// the index is reproducible across processes — `hashValue` is not, and a digest that changed
    /// per run would make the canonical bytes unreproducible for the wrong reason.
    static func digestIndex(of identifier: String) -> Int {
        var accumulator = 17
        for byte in identifier.utf8 {
            accumulator = (accumulator &* 31 &+ Int(byte)) % 4093
        }
        return accumulator
    }

    // MARK: - Calibration: the policy and the bundle manifest it activates against

    /// A synthetic Calibration Policy that activates.
    ///
    /// `requiredQualityFeatures` is empty, so activation turns on the boundary schedule and the
    /// evidence citations rather than on rule coverage. Every number is a placeholder: the 0.5%
    /// budget is half the 1.0% ceiling Requirement 5.1 fixes and is not an approved product
    /// budget, and the boundary position and half-width are the schema minimum rather than a
    /// calibrated value.
    static func calibrationPolicy(
        identifier: String = calibrationPolicyIdentifier,
        budgetRate: Decimal = Decimal(sign: .plus, exponent: -3, significand: 5),
        evidenceRecords: [EvidenceSource]? = nil
    ) throws -> CalibrationPolicy {
        try CalibrationPolicy(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            compatibleModel: RequiredPixelModel.identity,
            compatiblePreprocessing: Sample.artifact("contract.preprocessing"),
            compatibleVerdictCopy: Sample.artifact("copy.compatibility"),
            falseAccusationBudget: try FalseAccusationBudget(validating: budgetRate),
            releasePassRule: try FalseAccusationPassRule(
                statistic: .observedRateAndIntervalUpperBound,
                intervalMethod: .wilsonScore,
                confidenceLevel: Sample.ratio(FalseAccusationPassRule.requiredConfidenceLevel)
            ),
            outputLabels: Set(PixelLabelKey.allCases),
            metricCategories: PixelLabelKey.allCases.map {
                MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
            },
            boundaries: [
                try CategoryBoundary(
                    rawLogitBoundary: 2.5,
                    abstentionHalfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
                    lowerDecision: .noStrongSignalDetected,
                    upperDecision: .signalsConsistentWithAIGeneration
                )
            ],
            minimumShortEdge: CalibrationPolicy.requiredMinimumShortEdge,
            belowMinimumShortEdgeLabel: .notEnoughSignal,
            requiredQualityFeatures: [],
            qualityRules: [],
            uncoveredQualityInputBehavior: .calibrationInputError,
            evidence: evidenceRecords ?? [evidence(calibrationEvidenceIdentifier)],
            upstreamBoundaryMetadata: Sample.upstreamMetadata()
        )
    }

    /// The Model Bundle manifest the policy is activated against.
    ///
    /// Its `bundleID` is ``Sample/bundle()``, which is also the bundle the record distributes and
    /// the one entry in the manifest's approved catalogue — so the calibration gate's
    /// bundle-identity check has something to agree with.
    static func bundleManifest(
        bundleID: ModelBundleID? = nil,
        calibrationPolicy identifier: String = calibrationPolicyIdentifier
    ) throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: bundleID ?? Sample.bundle(),
            modelIdentity: RequiredPixelModel.identity,
            modelFormat: ModelFormatDescriptor(
                programKind: .mlProgram,
                computePrecision: .float16,
                minimumOS: .iOS17
            ),
            inputContract: Sample.modelInput(),
            outputContract: Sample.modelOutput(),
            componentVersions: BundleComponentVersions(
                coreMLModel: Sample.artifact("component.coreml"),
                preprocessingContract: Sample.artifact("contract.preprocessing"),
                calibrationPolicy: Sample.artifact(identifier),
                evidenceScope: Sample.artifact("component.scope"),
                verdictCopyCompatibility: Sample.artifact("copy.compatibility"),
                selfTestSpecification: Sample.artifact("component.self-tests")
            ),
            artifacts: [
                ArtifactDigestRecord(
                    path: Sample.path("artifacts/model.mlmodelc"),
                    kind: .directoryTree,
                    byteCount: 4096,
                    digest: Sample.digest(0xA1)
                )
            ],
            compatibility: try CompatibilityMatrix(
                compatibleAppBuilds: [Sample.appBuild()],
                requiredCapabilities: [.pixelAnalysis],
                minimumOS: .iOS17
            ),
            upstreamBoundaryMetadata: Sample.upstreamMetadata(),
            signingKey: Sample.signingKey()
        )
    }

    static func validatedPolicy(
        policy: CalibrationPolicy? = nil,
        bundleID: ModelBundleID? = nil,
        index: ReleaseEvidenceIndex? = nil
    ) throws -> ValidatedCalibrationPolicy {
        let resolved = try policy ?? calibrationPolicy()
        return try ValidatedCalibrationPolicy(
            activating: resolved,
            for: try bundleManifest(bundleID: bundleID, calibrationPolicy: resolved.id.rawValue),
            evidence: try index ?? calibrationIndex()
        )
    }

    // MARK: - Calibration: the evidence index

    /// The release evidence the calibration approval cites, minus whatever a probe removes.
    ///
    /// `omitting` is how a probe makes exactly one citation unresolvable without touching the
    /// record that cites it — the difference between "this reference names nothing" and "this
    /// record names something else".
    static func calibrationIndex(
        omitting omitted: Set<String> = [],
        adding added: [EvidenceSource] = []
    ) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: calibrationEvidenceIdentifiers
                .filter { !omitted.contains($0) }
                .map { evidence($0) } + added
        )
    }

    // MARK: - Calibration: slices, counts, measurements, reports, lineage

    /// One predeclared mandatory Release Gating Slice.
    ///
    /// Every reference is a parameter so a probe can point exactly one of them somewhere else.
    /// The confidence level is pinned by the schema, so it is not a knob.
    static func gatingSlice(
        _ identifier: String,
        isContemporaryPhoneCamera: Bool = false,
        eligibilityRule: String = "evidence.eligibility",
        outcomeMapping: String = "evidence.outcome-mapping",
        metricDefinition: String = "evidence.metric",
        datasetComposition: String = compositionIdentifier,
        degradationCondition: String = "evidence.degradation"
    ) throws -> ReleaseGatingSliceSpecification {
        try ReleaseGatingSliceSpecification(
            id: slice(identifier),
            schemaVersion: .v1,
            eligibilityRule: evidence(eligibilityRule),
            outcomeMapping: evidence(outcomeMapping),
            metricDefinition: evidence(metricDefinition),
            datasetComposition: evidence(datasetComposition),
            degradationCondition: evidence(degradationCondition),
            intervalMethod: .wilsonScore,
            confidenceLevel: Sample.ratio(FalseAccusationPassRule.requiredConfidenceLevel),
            isContemporaryPhoneCameraSlice: isContemporaryPhoneCamera
        )
    }

    /// The baseline counts: 1,000 eligible real images with 2 positive labels and 100
    /// abstentions, and 200 eligible synthetic images with 150 positive labels.
    ///
    /// 2 of 1,000 is 0.2%, inside the 0.5% placeholder budget, and neither rate sits at an
    /// endpoint — so the reported rates below are genuinely rounded numbers rather than values
    /// the counts pin exactly. Placeholder counts, not a measured evaluation.
    static func sliceCounts(
        realPositive: Int = 2,
        realNonPositive: Int = 898,
        realInsufficient: Int = 100,
        syntheticPositive: Int = 150,
        syntheticNonPositive: Int = 20,
        syntheticInsufficient: Int = 30,
        errors: Int = 0
    ) throws -> SliceOutcomeCounts {
        try SliceOutcomeCounts(
            eligibleRealImages: nonNegative(
                realPositive + realNonPositive + realInsufficient
            ),
            eligibleSyntheticImages: nonNegative(
                syntheticPositive + syntheticNonPositive + syntheticInsufficient
            ),
            realPositiveLabels: nonNegative(realPositive),
            realNonPositiveLabels: nonNegative(realNonPositive),
            realInsufficientLabels: nonNegative(realInsufficient),
            syntheticPositiveLabels: nonNegative(syntheticPositive),
            syntheticNonPositiveLabels: nonNegative(syntheticNonPositive),
            syntheticInsufficientLabels: nonNegative(syntheticInsufficient),
            errorCount: nonNegative(errors)
        )
    }

    /// The predeclared interval on the baseline false-positive rate: 0.001 through 0.004.
    ///
    /// Both bounds are exact decimals built with `Decimal(sign:exponent:significand:)` rather
    /// than literals, so no `JSONSerialization` round trip can perturb them.
    static func sliceInterval(
        lowerThousandths: Int = 1,
        upperThousandths: Int = 4
    ) throws -> ConfidenceIntervalResult {
        try ConfidenceIntervalResult(
            method: .wilsonScore,
            confidenceLevel: Sample.ratio(FalseAccusationPassRule.requiredConfidenceLevel),
            lowerBound: Sample.ratio(
                Decimal(sign: .plus, exponent: -3, significand: Decimal(lowerThousandths))
            ),
            upperBound: Sample.ratio(
                Decimal(sign: .plus, exponent: -3, significand: Decimal(upperThousandths))
            )
        )
    }

    static func measurement(
        _ specification: ReleaseGatingSliceSpecification,
        counts: SliceOutcomeCounts? = nil,
        interval: ConfidenceIntervalResult? = nil,
        against policy: ValidatedCalibrationPolicy
    ) throws -> ReleaseSliceMeasurement {
        try ReleaseSliceMeasurement(
            slice: specification,
            counts: try counts ?? sliceCounts(),
            falsePositiveRateInterval: try interval ?? sliceInterval(),
            measuredAgainst: policy
        )
    }

    /// 0.002, the exact false-positive rate the baseline counts produce (2 of 1,000).
    static let baselineFalsePositiveRate = Decimal(sign: .plus, exponent: -3, significand: 2)

    /// 0.75, the exact true-positive rate the baseline counts produce (150 of 200).
    static let baselineTruePositiveRate = Decimal(sign: .plus, exponent: -2, significand: 75)

    /// 0.8917, a rounded report of the baseline coverage 1,070/1,200.
    ///
    /// Deliberately not exact: the recorded report states a rounded number and the approval gate
    /// may not recompute it, which is the behaviour the domain documents and this exercises.
    static let baselineCoverage = Decimal(sign: .plus, exponent: -4, significand: 8917)

    /// One recorded report of `measurement`, agreeing with it unless a probe changes one field.
    static func sliceReport(
        of measurement: ReleaseSliceMeasurement,
        specification: String = sliceSpecificationIdentifier,
        counts: SliceOutcomeCounts? = nil,
        falsePositiveRate: Decimal = baselineFalsePositiveRate,
        truePositiveRate: Decimal = baselineTruePositiveRate,
        coverage: Decimal = baselineCoverage,
        interval: ConfidenceIntervalResult? = nil,
        budgetOutcome: GateOutcome? = nil
    ) -> CalibrationSliceResult {
        let derived: GateOutcome =
            switch measurement.budgetOutcome {
            case let .evaluated(outcome): outcome
            case .noObservedFalsePositiveRate: .notExecuted
            }
        return CalibrationSliceResult(
            slice: measurement.slice,
            specification: evidence(specification),
            modelBundle: measurement.modelBundle,
            calibrationPolicy: measurement.calibrationPolicy,
            counts: counts ?? measurement.counts,
            falsePositiveRate: Sample.ratio(falsePositiveRate),
            truePositiveRate: Sample.ratio(truePositiveRate),
            coverage: Sample.ratio(coverage),
            falsePositiveRateInterval: interval ?? measurement.falsePositiveRateInterval,
            budgetOutcome: budgetOutcome ?? derived
        )
    }

    /// All three unordered population pairs Requirement 5.5 names, each recorded as separated.
    ///
    /// A synthetic *record* of a verification, not a verification. This repository holds no
    /// corpus, and the approval gate's own documentation is explicit that it checks the record
    /// rather than re-performing the content comparison.
    static func separationResults(
        sampleLevel: [String: GateOutcome] = [:],
        contentLevel: [String: GateOutcome] = [:],
        pairs: [(CalibrationPopulation, CalibrationPopulation)]? = nil,
        evidenceIdentifier: String = separationIdentifier
    ) throws -> [PopulationSeparationResult] {
        let required: [(CalibrationPopulation, CalibrationPopulation)] = pairs ?? [
            (.knownModelTraining, .heldOutCalibration),
            (.knownModelTraining, .productThresholdEvaluation),
            (.heldOutCalibration, .productThresholdEvaluation),
        ]
        var results: [PopulationSeparationResult] = []
        for (first, second) in required {
            let key = pairKey(first, second)
            results.append(
                try PopulationSeparationResult(
                    firstPopulation: first,
                    secondPopulation: second,
                    sampleLevelOutcome: sampleLevel[key] ?? .passed,
                    contentLevelOutcome: contentLevel[key] ?? .passed,
                    evidence: evidence(evidenceIdentifier)
                )
            )
        }
        return results
    }

    static func lineage(
        results: [PopulationSeparationResult]? = nil,
        identifierCorrection: String = "evidence.identifier-correction",
        duplicateHashDisposition: String = "evidence.duplicate-hashes"
    ) throws -> DatasetLineageRecord {
        try DatasetLineageRecord(
            id: Sample.artifact(lineageIdentifier),
            schemaVersion: .v1,
            separationResults: try results ?? separationResults(),
            identifierCorrection: evidence(identifierCorrection),
            duplicateHashDisposition: evidence(duplicateHashDisposition)
        )
    }

    // MARK: - Calibration: the approval

    /// A coherent, approvable synthetic calibration release.
    ///
    /// Two predeclared mandatory slices, one of them the Requirement 5.20 contemporary
    /// phone-camera real slice, both measured, both reported, all three population pairs recorded
    /// as separated, every citation resolvable. Everything a probe does not override is derived
    /// from what it does, so a probe that changes one field cannot leave a second disagreement
    /// behind and refuse for the wrong reason.
    struct CalibrationBaseline {
        let policy: ValidatedCalibrationPolicy
        let slices: [ReleaseGatingSliceSpecification]
        let measurements: [ReleaseSliceMeasurement]
        let reports: [CalibrationSliceResult]
        let lineage: DatasetLineageRecord
        let index: ReleaseEvidenceIndex

        init(
            policy: ValidatedCalibrationPolicy? = nil,
            slices: [ReleaseGatingSliceSpecification]? = nil,
            measurements: [ReleaseSliceMeasurement]? = nil,
            reports: [CalibrationSliceResult]? = nil,
            lineage: DatasetLineageRecord? = nil,
            index: ReleaseEvidenceIndex? = nil
        ) throws {
            let resolvedPolicy = try policy ?? PipelineSample.validatedPolicy()
            let resolvedSlices = try slices ?? [
                PipelineSample.gatingSlice(
                    PipelineSample.phoneCameraSliceIdentifier,
                    isContemporaryPhoneCamera: true
                ),
                PipelineSample.gatingSlice(PipelineSample.generalSliceIdentifier),
            ]
            let resolvedMeasurements = try measurements
                ?? resolvedSlices.map {
                    try PipelineSample.measurement($0, against: resolvedPolicy)
                }
            self.policy = resolvedPolicy
            self.slices = resolvedSlices
            self.measurements = resolvedMeasurements
            self.reports = reports
                ?? resolvedMeasurements.map { PipelineSample.sliceReport(of: $0) }
            self.lineage = try lineage ?? PipelineSample.lineage()
            self.index = try index ?? PipelineSample.calibrationIndex()
        }

        /// Approves this baseline, throwing whatever the domain gate refuses on.
        func approve() throws -> ApprovedCalibrationRelease {
            try ApprovedCalibrationRelease(
                approving: policy,
                predeclaredMandatorySlices: slices,
                measurements: measurements,
                recordedReports: reports,
                lineage: lineage,
                evidence: index
            )
        }
    }

    /// The approved synthetic calibration release the baseline record carries.
    static func approvedCalibration(
        _ baseline: CalibrationBaseline? = nil
    ) throws -> ApprovedCalibrationRelease {
        try (baseline ?? CalibrationBaseline()).approve()
    }

    // MARK: - Bundle evidence

    /// A synthetic record of one produced bundle's verification.
    ///
    /// **Not a verification.** Constructed through the module-internal initialiser, so it records
    /// outcomes no verifier produced. Task 14.5 owns the real path, and a bundle built from
    /// synthetic staged content stops at Requirement 10.4's approved weight blob — which this
    /// value cannot represent and does not claim to.
    static func bundleVerification(
        bundleID: ModelBundleID? = nil,
        releaseSignature: GateOutcome = .passed,
        perArtifactDigests: GateOutcome = .passed,
        compatibility: GateOutcome = .passed
    ) -> ProducedBundleVerification {
        ProducedBundleVerification(
            bundleID: bundleID ?? Sample.bundle(),
            releaseSignature: releaseSignature,
            perArtifactDigests: perArtifactDigests,
            compatibility: compatibility,
            finding: nil,
            verifiedManifestDigest: Sample.digest(0xB0),
            verifiedArtifactDigests: [],
            signingKey: nil
        )
    }

    /// A synthetic ``BundleActivationEvidence`` with one knob per recorded gate.
    ///
    /// `signingKey` on the verification is deliberately `nil`: this value selects no key and
    /// records no signature verification, and a key identifier here would read as one.
    static func bundleEvidence(
        bundleID: ModelBundleID? = nil,
        releaseSignature: GateOutcome = .passed,
        perArtifactDigests: GateOutcome = .passed,
        compatibility: GateOutcome = .passed,
        releaseSelfTests: GateOutcome = .passed,
        atomicActivation: GateOutcome = .passed,
        verifiedRollback: GateOutcome = .passed
    ) -> BundleActivationEvidence {
        BundleActivationEvidence(
            verification: bundleVerification(
                bundleID: bundleID,
                releaseSignature: releaseSignature,
                perArtifactDigests: perArtifactDigests,
                compatibility: compatibility
            ),
            releaseSelfTests: releaseSelfTests,
            atomicActivation: atomicActivation,
            verifiedRollback: verifiedRollback,
            rollbackTarget: ModelBundleID(rollbackBundleIdentifier)!,
            activated: nil,
            rolledBack: nil,
            activationFault: nil,
            rollbackFault: nil
        )
    }

    // MARK: - Legal, governance, publication, and claims

    /// A synthetic distribution-rights record. **Neither decision is a real legal conclusion.**
    static func distributionRights(
        codeLicense: ApprovalDecision = .approved,
        datasetTerms: ApprovalDecision = .approved
    ) -> DistributionRightsRecord {
        DistributionRightsRecord(
            repositoryCodeLicense: approval(
                codeLicense,
                identifier: "approval.repository-code-license"
            ),
            datasetDistributionTerms: approval(
                datasetTerms,
                identifier: "approval.dataset-terms"
            )
        )
    }

    /// A synthetic governance record. **The decision is not a real governance approval.**
    ///
    /// The two disclosure fields carry the values Requirement 14.9 requires disclosed — an
    /// independent non-peer-reviewed fine-tune with `redteam_validation_valid: false` — because
    /// those are measured facts about the upstream checkpoint rather than decisions. The decision
    /// beside them is synthetic.
    static func governance(
        decision: ApprovalDecision = .approved,
        isIndependentNonPeerReviewed: Bool = true,
        redTeamValidationValid: Bool = false
    ) throws -> ModelGovernanceDecisionRecord {
        try ModelGovernanceDecisionRecord(
            modelIdentity: RequiredPixelModel.identity,
            isIndependentNonPeerReviewed: isIndependentNonPeerReviewed,
            redTeamValidationValid: redTeamValidationValid,
            inheritedRedTeamStatus: redTeamValidationValid
                ? .validReportInherited
                : .invalidNoReportInherited,
            decision: approval(decision, identifier: "approval.model-governance")
        )
    }

    static func activeLimitations() -> EvidenceSource { evidence(limitationsIdentifier) }

    static func correctionChannel() -> EvidenceSource { evidence(correctionChannelIdentifier) }

    /// One completely bound synthetic published claim.
    ///
    /// Every binding defaults to the release's own artifact, so a probe that redirects one is
    /// changing exactly the binding it names. The counts and interval are placeholders.
    static func benchmarkClaim(
        identifier: String = claimIdentifier,
        modelBundle: ModelBundleID? = nil,
        calibrationPolicy: String = calibrationPolicyIdentifier,
        activeLimitations limitations: EvidenceSource? = nil,
        correctionChannel channel: EvidenceSource? = nil
    ) throws -> BenchmarkClaimRecord {
        BenchmarkClaimRecord(
            id: Sample.artifact(identifier),
            dataset: evidence("evidence.dataset"),
            datasetComposition: evidence(compositionIdentifier),
            degradationCondition: evidence("evidence.degradation"),
            modelIdentity: RequiredPixelModel.identity,
            modelBundle: modelBundle ?? Sample.bundle(),
            calibrationPolicy: Sample.artifact(calibrationPolicy),
            counts: try sliceCounts(),
            coverage: Sample.ratio(baselineCoverage),
            metricDefinition: evidence("evidence.metric"),
            evidenceProvenance: evidence("evidence.run"),
            uncertaintyInterval: try sliceInterval(),
            activeLimitations: limitations ?? activeLimitations(),
            correctionChannel: channel ?? correctionChannel()
        )
    }
}

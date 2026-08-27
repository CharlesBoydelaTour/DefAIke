import Foundation
import Testing

@testable import DefAIkeDomain

// The calibration release-approval gate.
//
// Every artifact in this file is individually valid: the policy activates, each slice is
// schema-valid and predeclared, and each measurement satisfies Requirements 5.16 through
// 5.19. Those checks belong to `CalibrationPolicyActivationTests` and
// `ReleaseSliceMetricTests`. What is under test here is what one valid artifact and one
// valid slice cannot see:
//
//   * a dataset lineage record that verified separation for the pair someone cared about
//     and not for the other two;
//   * a mandatory slice set missing the contemporary phone-camera real slice, missing a
//     predeclared slice, or carrying one nobody predeclared;
//   * a predeclaration edited after the fact, or a measurement taken against another
//     policy or bundle;
//   * a recorded report that does not describe the run it names;
//   * a slice that failed the predeclared budget rule, or one the rule could not be
//     applied to at all.
//
// No value here is an approved budget, boundary, slice, dataset, interval, or separation
// result. Each test builds a coherent baseline and breaks exactly one condition, and every
// refusal is asserted against a named field so the assertion cannot pass because something
// unrelated failed. Where a refusal could be mistaken for a blanket rejection, a positive
// control asserts the coherent case is still approved.

// MARK: - Fixtures

/// Synthetic release evidence for one bundle-policy combination.
enum ApprovalSample {

    // MARK: Identifiers

    static let phoneCameraSliceIdentifier = "slice.phone-camera"
    static let generalSliceIdentifier = "slice.general"
    static let lineageIdentifier = "record.dataset-lineage"

    static let calibrationEvidenceIdentifier = "evidence.calibration"
    static let compositionIdentifier = "evidence.composition"
    static let separationIdentifier = "evidence.separation"
    static let sliceSpecificationIdentifier = "evidence.slice-specification"

    /// Every evidence artifact the coherent baseline cites.
    static let baselineEvidenceIdentifiers = [
        calibrationEvidenceIdentifier,
        "evidence.quality",
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

    /// The three unordered population pairs Requirement 5.5 names, listed rather than
    /// derived so they can serve as the control for `requiredSeparationPairs`.
    static let requiredPairs: [(CalibrationPopulation, CalibrationPopulation)] = [
        (.knownModelTraining, .heldOutCalibration),
        (.knownModelTraining, .productThresholdEvaluation),
        (.heldOutCalibration, .productThresholdEvaluation),
    ]

    // MARK: Numbers the baseline needs

    /// 0.002, the exact false-positive rate the baseline counts produce (2 of 1,000).
    static let baselineFalsePositiveRate = Decimal(sign: .plus, exponent: -3, significand: 2)

    /// 0.75, the exact true-positive rate the baseline counts produce (150 of 200).
    static let baselineTruePositiveRate = Decimal(sign: .plus, exponent: -2, significand: 75)

    /// 0.8917, a rounded report of the baseline coverage 1,070/1,200. Deliberately not
    /// exact: the recorded report states a rounded number and the gate may not recompute it.
    static let baselineCoverage = Decimal(sign: .plus, exponent: -4, significand: 8917)

    // MARK: Evidence index

    /// The release evidence the baseline cites, minus whatever a test removes.
    ///
    /// `omitting` is how a test makes one citation unresolvable without touching the record
    /// that cites it, which is the difference between "this reference names nothing" and
    /// "this record names something else".
    static func index(
        omitting omitted: Set<String> = [],
        adding added: [EvidenceSource] = []
    ) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: baselineEvidenceIdentifiers
                .filter { !omitted.contains($0) }
                .map { Sample.evidence($0) } + added
        )
    }

    // MARK: Slices

    /// One predeclared mandatory slice. Every reference is a parameter so a test can point
    /// exactly one of them somewhere else.
    static func slice(
        _ identifier: String,
        isContemporaryPhoneCamera: Bool = false,
        eligibilityRule: String = "evidence.eligibility",
        outcomeMapping: String = "evidence.outcome-mapping",
        metricDefinition: String = "evidence.metric",
        datasetComposition: String = compositionIdentifier,
        degradationCondition: String = "evidence.degradation"
    ) throws -> ReleaseGatingSliceSpecification {
        try ReleaseGatingSliceSpecification(
            id: Sample.slice(identifier),
            schemaVersion: .v1,
            eligibilityRule: Sample.evidence(eligibilityRule),
            outcomeMapping: Sample.evidence(outcomeMapping),
            metricDefinition: Sample.evidence(metricDefinition),
            datasetComposition: Sample.evidence(datasetComposition),
            degradationCondition: Sample.evidence(degradationCondition),
            intervalMethod: .wilsonScore,
            confidenceLevel: Sample.ratio(FalseAccusationPassRule.requiredConfidenceLevel),
            isContemporaryPhoneCameraSlice: isContemporaryPhoneCamera
        )
    }

    // MARK: Counts

    /// The baseline counts: 1,000 eligible real images with 2 positive labels and 100
    /// abstentions, and 200 eligible synthetic images with 150 positive labels.
    ///
    /// 2 of 1,000 is 0.2%, inside the 0.5% sample budget, and neither rate sits at an
    /// endpoint, so the reported rates below are genuinely rounded numbers rather than
    /// values the counts pin exactly.
    static func counts(
        realPositive: Int = 2,
        realNonPositive: Int = 898,
        realInsufficient: Int = 100,
        syntheticPositive: Int = 150,
        syntheticNonPositive: Int = 20,
        syntheticInsufficient: Int = 30,
        errors: Int = 0
    ) throws -> SliceOutcomeCounts {
        try Sample.sliceCounts(
            realPositive: realPositive,
            realNonPositive: realNonPositive,
            realInsufficient: realInsufficient,
            syntheticPositive: syntheticPositive,
            syntheticNonPositive: syntheticNonPositive,
            syntheticInsufficient: syntheticInsufficient,
            errors: errors
        )
    }

    /// The predeclared interval on the baseline false-positive rate: 0.001 to 0.004, whose
    /// upper bound is inside the 0.5% sample budget.
    static func interval() throws -> ConfidenceIntervalResult {
        try Sample.interval(
            lower: Decimal(sign: .plus, exponent: -3, significand: 1),
            upper: Decimal(sign: .plus, exponent: -3, significand: 4)
        )
    }

    // MARK: Policy

    static func policy(
        identifier: String = "policy.calibration",
        bundleID: String = "bundle.sample",
        budget: FalseAccusationBudget? = nil,
        passRule: FalseAccusationPassRule? = nil,
        qualityRules: [QualityDecisionRule] = [],
        requiredQualityFeatures: Set<QualityFeatureID> = [],
        evidenceRecords: [EvidenceSource] = [Sample.evidence(calibrationEvidenceIdentifier)]
    ) throws -> ValidatedCalibrationPolicy {
        try Sample.activate(
            try Sample.activatablePolicy(
                identifier: identifier,
                qualityRules: qualityRules,
                requiredQualityFeatures: requiredQualityFeatures,
                budget: budget,
                passRule: passRule,
                evidenceRecords: evidenceRecords
            ),
            bundle: try PreflightSample.bundleManifest(
                bundleID: bundleID,
                componentVersions: PreflightSample.componentVersions(
                    calibrationPolicy: identifier
                )
            )
        )
    }

    // MARK: Measurements and reports

    static func measurement(
        _ slice: ReleaseGatingSliceSpecification,
        counts sliceCounts: SliceOutcomeCounts? = nil,
        interval sliceInterval: ConfidenceIntervalResult? = nil,
        against policy: ValidatedCalibrationPolicy
    ) throws -> ReleaseSliceMeasurement {
        try ReleaseSliceMeasurement(
            slice: slice,
            counts: try sliceCounts ?? counts(),
            falsePositiveRateInterval: try sliceInterval ?? interval(),
            measuredAgainst: policy
        )
    }

    /// One recorded report of `measurement`, agreeing with it unless a test changes a field.
    static func report(
        of measurement: ReleaseSliceMeasurement,
        slice: ReleaseSliceID? = nil,
        specification: String = sliceSpecificationIdentifier,
        modelBundle: ModelBundleID? = nil,
        calibrationPolicy: ArtifactID? = nil,
        counts reportedCounts: SliceOutcomeCounts? = nil,
        falsePositiveRate: Decimal = baselineFalsePositiveRate,
        truePositiveRate: Decimal = baselineTruePositiveRate,
        coverage: Decimal = baselineCoverage,
        interval reportedInterval: ConfidenceIntervalResult? = nil,
        budgetOutcome: GateOutcome? = nil
    ) -> CalibrationSliceResult {
        let derived: GateOutcome =
            switch measurement.budgetOutcome {
            case let .evaluated(outcome): outcome
            case .noObservedFalsePositiveRate: .notExecuted
            }
        return CalibrationSliceResult(
            slice: slice ?? measurement.slice,
            specification: Sample.evidence(specification),
            modelBundle: modelBundle ?? measurement.modelBundle,
            calibrationPolicy: calibrationPolicy ?? measurement.calibrationPolicy,
            counts: reportedCounts ?? measurement.counts,
            falsePositiveRate: Sample.ratio(falsePositiveRate),
            truePositiveRate: Sample.ratio(truePositiveRate),
            coverage: Sample.ratio(coverage),
            falsePositiveRateInterval: reportedInterval ?? measurement.falsePositiveRateInterval,
            budgetOutcome: budgetOutcome ?? derived
        )
    }

    // MARK: Lineage

    static func separationResults(
        pairs: [(CalibrationPopulation, CalibrationPopulation)] = requiredPairs,
        sampleLevel: [String: GateOutcome] = [:],
        contentLevel: [String: GateOutcome] = [:],
        evidence: String = separationIdentifier
    ) throws -> [PopulationSeparationResult] {
        try pairs.map { first, second in
            let key = CalibrationPopulation.pairKey([first, second])
            return try PopulationSeparationResult(
                firstPopulation: first,
                secondPopulation: second,
                sampleLevelOutcome: sampleLevel[key] ?? .passed,
                contentLevelOutcome: contentLevel[key] ?? .passed,
                evidence: Sample.evidence(evidence)
            )
        }
    }

    static func lineage(
        identifier: String = lineageIdentifier,
        results: [PopulationSeparationResult]? = nil,
        identifierCorrection: String = "evidence.identifier-correction",
        duplicateHashDisposition: String = "evidence.duplicate-hashes"
    ) throws -> DatasetLineageRecord {
        try DatasetLineageRecord(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            separationResults: try results ?? separationResults(),
            identifierCorrection: Sample.evidence(identifierCorrection),
            duplicateHashDisposition: Sample.evidence(duplicateHashDisposition)
        )
    }
}

/// A coherent, approvable release: two mandatory slices, one of them the contemporary
/// phone-camera real slice, both measured, both reported, all three population pairs
/// separated.
///
/// Everything a test does not override is derived from what it does, so a test that changes
/// one field cannot leave a second disagreement behind and pass for the wrong reason.
struct ApprovalBaseline {
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
        let policy = try policy ?? ApprovalSample.policy()
        let slices =
            try slices
            ?? [
                ApprovalSample.slice(
                    ApprovalSample.phoneCameraSliceIdentifier,
                    isContemporaryPhoneCamera: true
                ),
                ApprovalSample.slice(ApprovalSample.generalSliceIdentifier),
            ]
        let measurements =
            try measurements
            ?? slices.map { try ApprovalSample.measurement($0, against: policy) }
        self.policy = policy
        self.slices = slices
        self.measurements = measurements
        self.reports = reports ?? measurements.map { ApprovalSample.report(of: $0) }
        self.lineage = try lineage ?? ApprovalSample.lineage()
        self.index = try index ?? ApprovalSample.index()
    }

    /// Approves this baseline, throwing whatever the gate refuses on.
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

/// Asserts that `build` fails with a schema error naming `field`.
private func rejects(
    _ field: String,
    _ build: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        try build()
        Issue.record(
            "approval accepted calibration evidence it must refuse",
            sourceLocation: sourceLocation
        )
    } catch let error as ArtifactSchemaError {
        #expect(
            error.description.contains(field),
            "\(error.description) does not name \(field)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - The coherent baseline

@Suite("Calibration release approval")
struct CalibrationReleaseApprovalTests {

    @Test("Complete, uncontaminated, passing calibration evidence approves")
    func coherentEvidenceApproves() throws {
        let baseline = try ApprovalBaseline()
        let approved = try baseline.approve()

        #expect(approved.policy == baseline.policy)
        #expect(approved.calibrationPolicy == baseline.policy.id)
        #expect(approved.modelBundle == Sample.bundle())
        #expect(approved.datasetLineage == Sample.artifact(ApprovalSample.lineageIdentifier))
        #expect(approved.lineage == baseline.lineage)

        // Requirement 5.21's inputs are read from the policy, never written here.
        #expect(approved.falseAccusationBudget == baseline.policy.policy.falseAccusationBudget)
        #expect(approved.releasePassRule == baseline.policy.policy.releasePassRule)

        #expect(
            approved.mandatorySlices.map(\.rawValue) == [
                ApprovalSample.generalSliceIdentifier,
                ApprovalSample.phoneCameraSliceIdentifier,
            ]
        )
        #expect(approved.heldOutCalibrationEvidence == baseline.policy.policy.evidence)
        #expect(
            approved.evaluationDatasetCompositions
                == [Sample.evidence(ApprovalSample.compositionIdentifier)]
        )
    }

    @Test("Every mandatory slice is reachable with its measurement and its report")
    func everySliceIsReadable() throws {
        let approved = try ApprovalBaseline().approve()
        let phoneCamera = Sample.slice(ApprovalSample.phoneCameraSliceIdentifier)

        let measurement = try #require(approved.measurement(for: phoneCamera))
        #expect(measurement.isContemporaryPhoneCameraSlice)
        #expect(measurement.budgetOutcome == .evaluated(.passed))
        #expect(try #require(approved.report(for: phoneCamera)).slice == phoneCamera)

        #expect(approved.contemporaryPhoneCameraSlices.map(\.slice) == [phoneCamera])
        #expect(approved.measurement(for: Sample.slice("slice.absent")) == nil)
        #expect(approved.report(for: Sample.slice("slice.absent")) == nil)

        for (first, second) in ApprovalSample.requiredPairs {
            let separation = try #require(approved.separation(between: first, and: second))
            #expect(separation.isSeparated)
            // Unordered: the same pair resolves whichever way it is asked for.
            #expect(approved.separation(between: second, and: first) == separation)
        }
        #expect(approved.separation(between: .heldOutCalibration, and: .heldOutCalibration) == nil)
    }

    @Test("Measurements and reports are held in a reproducible order")
    func orderingIsReproducible() throws {
        // Swift `Set` iteration order is not stable across processes, so an audit trail
        // assembled from these has to be ordered by something. Reversing the inputs must not
        // change the result.
        let baseline = try ApprovalBaseline()
        let reversed = try ApprovalBaseline(
            policy: baseline.policy,
            slices: baseline.slices.reversed(),
            measurements: baseline.measurements.reversed(),
            reports: baseline.reports.reversed(),
            lineage: baseline.lineage,
            index: baseline.index
        )

        let forward = try baseline.approve()
        let backward = try reversed.approve()
        #expect(forward.measurements == backward.measurements)
        #expect(forward.reports == backward.reports)
        #expect(forward.mandatorySlices == backward.mandatorySlices)
    }
}

// MARK: - Population separation

@Suite("Calibration population separation")
struct CalibrationPopulationSeparationTests {

    @Test("All three population pairs are required, and they are the three that exist")
    func everyPairIsRequired() throws {
        // The control for the derived pair set: three populations have exactly three
        // unordered pairs, and the required set is those three rather than a hand-picked
        // subset.
        #expect(CalibrationPopulation.allCases.count == 3)
        #expect(
            Set(CalibrationPopulation.requiredSeparationPairs.map(CalibrationPopulation.pairKey))
                == Set(
                    ApprovalSample.requiredPairs.map { CalibrationPopulation.pairKey([$0, $1]) }
                )
        )
        #expect(CalibrationPopulation.requiredSeparationPairs.count == 3)

        // Removing any one pair leaves the record incomplete, and the missing pair is named.
        for omitted in ApprovalSample.requiredPairs {
            let remaining = ApprovalSample.requiredPairs.filter {
                CalibrationPopulation.pairKey([$0, $1])
                    != CalibrationPopulation.pairKey([omitted.0, omitted.1])
            }
            rejects(CalibrationPopulation.pairKey([omitted.0, omitted.1])) {
                _ = try ApprovalBaseline(
                    lineage: try ApprovalSample.lineage(
                        results: try ApprovalSample.separationResults(pairs: remaining)
                    )
                ).approve()
            }
        }
    }

    @Test("A pair verified twice is refused, whichever order each result lists it in")
    func repeatedPairIsRefused() throws {
        // Two results for one pair let a contradictory verification sit beside a passing
        // one, and swapping the two populations does not make it a different pair.
        rejects("more than once") {
            _ = try ApprovalBaseline(
                lineage: try ApprovalSample.lineage(
                    results: try ApprovalSample.separationResults(
                        pairs: ApprovalSample.requiredPairs + [
                            (.productThresholdEvaluation, .heldOutCalibration)
                        ]
                    )
                )
            ).approve()
        }
    }

    @Test("A failing or unrun outcome at either level blocks approval")
    func eitherLevelBlocks() throws {
        // Requirement 5.23 treats missing and failed the same way, so `not-executed` blocks
        // exactly as `failed` does: an unrun comparison is not a passed one.
        for (first, second) in ApprovalSample.requiredPairs {
            let key = CalibrationPopulation.pairKey([first, second])
            for outcome in GateOutcome.allCases where !outcome.isPassing {
                rejects("sampleLevelOutcome") {
                    _ = try ApprovalBaseline(
                        lineage: try ApprovalSample.lineage(
                            results: try ApprovalSample.separationResults(
                                sampleLevel: [key: outcome]
                            )
                        )
                    ).approve()
                }
                rejects("contentLevelOutcome") {
                    _ = try ApprovalBaseline(
                        lineage: try ApprovalSample.lineage(
                            results: try ApprovalSample.separationResults(
                                contentLevel: [key: outcome]
                            )
                        )
                    ).approve()
                }
            }
        }
    }

    @Test("A recorded separation pass with no findable evidence is not evidence")
    func separationEvidenceMustResolve() throws {
        // The recorded outcome and the artifact behind it are two different things. This
        // module cannot re-perform the content comparison, so an unresolvable citation is
        // the difference between a verified separation and an assertion of one.
        rejects(ApprovalSample.separationIdentifier) {
            _ = try ApprovalBaseline(
                index: try ApprovalSample.index(omitting: [ApprovalSample.separationIdentifier])
            ).approve()
        }
        // A citation at the wrong version names other content, which is a different audit
        // finding from a citation that names nothing.
        let atAnotherVersion = try PopulationSeparationResult(
            firstPopulation: .knownModelTraining,
            secondPopulation: .heldOutCalibration,
            sampleLevelOutcome: .passed,
            contentLevelOutcome: .passed,
            evidence: EvidenceSource(
                artifact: Sample.artifact(ApprovalSample.separationIdentifier),
                version: Sample.version("2.0.0"),
                contentDigest: Sample.digest()
            )
        )
        let remaining = try ApprovalSample.separationResults(
            pairs: Array(ApprovalSample.requiredPairs.dropFirst())
        )
        rejects("version") {
            _ = try ApprovalBaseline(
                lineage: try ApprovalSample.lineage(results: [atAnotherVersion] + remaining)
            ).approve()
        }
    }

    @Test("The corrected-identifier and duplicate-hash records must resolve")
    func contentLevelSupportingRecordsMustResolve() throws {
        // Requirements 14.7 and 14.8. These two are what make a content-level separation
        // claim checkable by anyone at all, so an unresolvable one leaves the claim
        // unbacked.
        for identifier in ["evidence.identifier-correction", "evidence.duplicate-hashes"] {
            rejects(identifier) {
                _ = try ApprovalBaseline(
                    index: try ApprovalSample.index(omitting: [identifier])
                ).approve()
            }
        }
    }

    @Test("A lineage record with an undecided identifier is refused")
    func undecidedLineageIdentifierIsRefused() throws {
        rejects("datasetLineage.id") {
            _ = try ApprovalBaseline(
                lineage: try ApprovalSample.lineage(identifier: "tbd")
            ).approve()
        }
    }
}

// MARK: - Held-out calibration versus product-threshold evaluation

@Suite("Held-out calibration separation")
struct HeldOutCalibrationSeparationTests {

    @Test("One artifact cannot be both held-out calibration evidence and an evaluation set")
    func oneArtifactCannotServeBothPopulations() throws {
        // Requirement 5.6 in artifact terms: the policy's boundaries were derived from
        // `evidence.calibration`, so a mandatory slice whose dataset composition is that
        // same artifact means one record describes both populations.
        let slices = [
            try ApprovalSample.slice(
                ApprovalSample.phoneCameraSliceIdentifier,
                isContemporaryPhoneCamera: true,
                datasetComposition: ApprovalSample.calibrationEvidenceIdentifier
            ),
            try ApprovalSample.slice(ApprovalSample.generalSliceIdentifier),
        ]

        rejects(ApprovalSample.calibrationEvidenceIdentifier) {
            _ = try ApprovalBaseline(slices: slices).approve()
        }
    }

    @Test("The policy's held-out calibration evidence must resolve in this release's index")
    func heldOutCalibrationEvidenceMustResolveHere() throws {
        // Not a repeat of activation. `ValidatedCalibrationPolicy` required this citation to
        // resolve against the index it was handed and keeps no record of which index that
        // was, so a policy activated against one release's evidence can be presented for
        // approval beside another's. The policy below activates and is still refused,
        // which is the whole point of checking again here.
        let policy = try ApprovalSample.policy()
        #expect(policy.policy.evidence.map(\.artifact.rawValue)
            == [ApprovalSample.calibrationEvidenceIdentifier])

        rejects("calibrationPolicy.evidence[0]") {
            _ = try ApprovalBaseline(
                policy: policy,
                index: try ApprovalSample.index(
                    omitting: [ApprovalSample.calibrationEvidenceIdentifier]
                )
            ).approve()
        }
    }

    @Test("Evidence behind an additional quality rule must resolve in this release's index")
    func qualityRuleEvidenceMustResolveHere() throws {
        // Requirements 5.11 and 5.12 for the same reason. The rule's evidence is not
        // compared against any population — it is release-validation evidence rather than a
        // dataset — but it still has to be evidence this release carries.
        let policy = try ApprovalSample.policy(
            qualityRules: [try Sample.qualityRule()],
            requiredQualityFeatures: [Sample.qualityFeature()]
        )

        rejects("qualityRules[rule.quality].evidence[0]") {
            _ = try ApprovalBaseline(
                policy: policy,
                index: try ApprovalSample.index(omitting: ["evidence.quality"])
            ).approve()
        }

        // The positive control: with the rule's evidence in the index the release approves,
        // so the refusal is about the missing citation rather than about having a rule.
        let approved = try ApprovalBaseline(policy: policy).approve()
        #expect(approved.policy == policy)
    }

    @Test("Sharing a metric definition between the two populations is not contamination")
    func sharedDefinitionIsNotContamination() throws {
        // The positive control for the narrowness of the check above. A definition is not a
        // population: the same metric measured on both sides is what makes the two
        // comparable, and rejecting it would refuse an honest release.
        let slices = [
            try ApprovalSample.slice(
                ApprovalSample.phoneCameraSliceIdentifier,
                isContemporaryPhoneCamera: true,
                metricDefinition: ApprovalSample.calibrationEvidenceIdentifier
            ),
            try ApprovalSample.slice(ApprovalSample.generalSliceIdentifier),
        ]

        let approved = try ApprovalBaseline(slices: slices).approve()
        #expect(approved.mandatorySlices.count == 2)
    }
}

// MARK: - The mandatory slice set

@Suite("Mandatory calibration slice set")
struct MandatoryCalibrationSliceSetTests {

    @Test("A predeclared slice with no measurement blocks approval")
    func everyPredeclaredSliceMustBeMeasured() throws {
        let baseline = try ApprovalBaseline()
        rejects(ApprovalSample.generalSliceIdentifier) {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements.filter {
                    $0.slice.rawValue != ApprovalSample.generalSliceIdentifier
                },
                reports: baseline.reports.filter {
                    $0.slice.rawValue != ApprovalSample.generalSliceIdentifier
                }
            ).approve()
        }
    }

    @Test("A measured slice nobody predeclared is refused")
    func unpredeclaredSliceIsRefused() throws {
        // Requirement 5.15: the mandatory set is fixed before evaluation begins, so a slice
        // that appears only in the results was chosen after seeing them.
        let baseline = try ApprovalBaseline()
        let extra = try ApprovalSample.slice("slice.after-the-fact")
        let measurement = try ApprovalSample.measurement(extra, against: baseline.policy)

        rejects("slice.after-the-fact") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements + [measurement],
                reports: baseline.reports + [ApprovalSample.report(of: measurement)]
            ).approve()
        }
    }

    @Test("An empty or repeated mandatory set is refused")
    func unusableMandatorySetIsRefused() throws {
        let baseline = try ApprovalBaseline()
        rejects("mandatorySlices is empty") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: [],
                measurements: [],
                reports: []
            ).approve()
        }
        rejects("more than once") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices + [baseline.slices[0]],
                measurements: baseline.measurements,
                reports: baseline.reports
            ).approve()
        }
    }

    @Test("The contemporary phone-camera slice must be present, read from the specification")
    func phoneCameraSliceMustBePresent() throws {
        // Requirement 5.20. The designation is a predeclared field, so a slice named
        // "slice.phone-camera" that does not carry it is not that slice, and the refusal
        // does not depend on any dataset name.
        let slices = [
            try ApprovalSample.slice(ApprovalSample.phoneCameraSliceIdentifier),
            try ApprovalSample.slice(ApprovalSample.generalSliceIdentifier),
        ]

        rejects("contemporary phone-camera") {
            _ = try ApprovalBaseline(slices: slices).approve()
        }
    }

    @Test("A phone-camera slice with no eligible real image is that slice in name only")
    func phoneCameraSliceNeedsARealPopulation() throws {
        let baseline = try ApprovalBaseline()
        let phoneCamera = try ApprovalSample.slice(
            ApprovalSample.phoneCameraSliceIdentifier,
            isContemporaryPhoneCamera: true
        )
        let syntheticOnly = try ApprovalSample.measurement(
            phoneCamera,
            counts: try ApprovalSample.counts(
                realPositive: 0,
                realNonPositive: 0,
                realInsufficient: 0
            ),
            against: baseline.policy
        )

        rejects("counts.eligibleRealImages") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [syntheticOnly] + baseline.measurements.dropFirst(),
                reports: Array(baseline.reports.dropFirst())
            ).approve()
        }
    }

    @Test("Two phone-camera slices under different conditions are both permitted")
    func severalPhoneCameraSlicesArePermitted() throws {
        // Requirement 5.20 designates the subset as mandatory; it does not cap it at one.
        // Two contamination-controlled phone-camera slices under different degradation
        // conditions are both legitimate, so requiring exactly one would refuse an honest
        // release.
        let slices = [
            try ApprovalSample.slice(
                ApprovalSample.phoneCameraSliceIdentifier,
                isContemporaryPhoneCamera: true
            ),
            try ApprovalSample.slice(
                "slice.phone-camera-degraded",
                isContemporaryPhoneCamera: true,
                degradationCondition: "evidence.metric"
            ),
        ]

        let approved = try ApprovalBaseline(slices: slices).approve()
        #expect(approved.contemporaryPhoneCameraSlices.count == 2)
    }

    @Test("A predeclaration edited after evaluation is refused")
    func editedPredeclarationIsRefused() throws {
        // Same slice identifier, different degradation condition. Both references resolve,
        // so nothing but the comparison against the predeclared specification can catch it,
        // and this is the fault Requirement 5.15 exists to prevent.
        let baseline = try ApprovalBaseline()
        let edited = try ApprovalSample.slice(
            ApprovalSample.generalSliceIdentifier,
            degradationCondition: "evidence.metric"
        )
        let measurement = try ApprovalSample.measurement(edited, against: baseline.policy)

        rejects("specification") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [baseline.measurements[0], measurement],
                reports: [baseline.reports[0], ApprovalSample.report(of: measurement)]
            ).approve()
        }
    }

    @Test("Every predeclared reference on every slice must resolve")
    func predeclaredReferencesMustResolve() throws {
        // A predeclaration nobody can find is not a predeclaration. The composition record
        // is left out of this sweep because removing it from the index would also change
        // nothing about the Requirement 5.6 check that runs on it separately.
        for identifier in [
            "evidence.eligibility", "evidence.outcome-mapping", "evidence.metric",
            ApprovalSample.compositionIdentifier, "evidence.degradation",
        ] {
            rejects(identifier) {
                _ = try ApprovalBaseline(
                    index: try ApprovalSample.index(omitting: [identifier])
                ).approve()
            }
        }
    }

    @Test("A measurement taken against another policy or another bundle is refused")
    func measurementMustAnswerForThisRelease() throws {
        let baseline = try ApprovalBaseline()
        let otherPolicy = try ApprovalSample.policy(identifier: "policy.other")
        let otherBundle = try ApprovalSample.policy(bundleID: "bundle.other")

        for (field, policy) in [
            ("calibrationPolicy", otherPolicy),
            ("modelBundle", otherBundle),
        ] {
            let measurements = try baseline.slices.map {
                try ApprovalSample.measurement($0, against: policy)
            }
            rejects(field) {
                _ = try ApprovalBaseline(
                    policy: baseline.policy,
                    slices: baseline.slices,
                    measurements: measurements,
                    reports: measurements.map { ApprovalSample.report(of: $0) }
                ).approve()
            }
        }
    }

    @Test("One identifier carrying two different policies is refused")
    func sameIdentifierDifferentContentIsRefused() throws {
        // The worst of the three: the identifiers agree, so a reader sees a coherent
        // release, while the budget the slices were measured against is not the budget this
        // release ships.
        let baseline = try ApprovalBaseline()
        let sameIdentifier = try ApprovalSample.policy(
            budget: try Sample.budget(Decimal(sign: .plus, exponent: -4, significand: 5))
        )
        #expect(sameIdentifier.id == baseline.policy.id)
        #expect(sameIdentifier != baseline.policy)

        let measurements = try baseline.slices.map {
            try ApprovalSample.measurement($0, against: sameIdentifier)
        }
        rejects("slice[\(ApprovalSample.generalSliceIdentifier)].policy") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: measurements,
                reports: measurements.map { ApprovalSample.report(of: $0) }
            ).approve()
        }
    }
}

// MARK: - Recorded report reconciliation

@Suite("Recorded calibration slice reports")
struct RecordedCalibrationReportTests {

    @Test("A slice whose report can state its measurement must carry one")
    func everyReportableSliceIsReported() throws {
        let baseline = try ApprovalBaseline()
        rejects(ApprovalSample.generalSliceIdentifier) {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: baseline.reports.filter {
                    $0.slice.rawValue != ApprovalSample.generalSliceIdentifier
                }
            ).approve()
        }
    }

    @Test("A report for a slice with an absent rate is refused rather than fabricated")
    func reportForAnAbsentRateIsRefused() throws {
        // Requirement 5.20 makes a real-image-only slice mandatory, and its true-positive
        // rate does not exist: no synthetic image was examined. `CalibrationSliceResult`
        // states each rate as a required `UnitInterval`, so any number in that position is
        // not a measurement. The record is refused; the measurement is the complete report.
        let baseline = try ApprovalBaseline()
        let realOnly = try ApprovalSample.measurement(
            baseline.slices[0],
            counts: try ApprovalSample.counts(
                syntheticPositive: 0,
                syntheticNonPositive: 0,
                syntheticInsufficient: 0
            ),
            against: baseline.policy
        )
        #expect(realOnly.truePositiveRate == nil)
        #expect(realOnly.falsePositiveRate != nil)

        rejects("truePositiveRate") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [realOnly] + baseline.measurements.dropFirst(),
                reports: [ApprovalSample.report(of: realOnly)] + baseline.reports.dropFirst()
            ).approve()
        }

        // The positive control: with no record for that slice the release approves, and the
        // slice is still completely reported by its measurement.
        let approved = try ApprovalBaseline(
            policy: baseline.policy,
            slices: baseline.slices,
            measurements: [realOnly] + baseline.measurements.dropFirst(),
            reports: Array(baseline.reports.dropFirst())
        ).approve()
        #expect(approved.report(for: realOnly.slice) == nil)
        let reported = try #require(approved.measurement(for: realOnly.slice))
        #expect(reported.truePositiveRate == nil)
        #expect(reported.coverage.denominator.value == realOnly.counts.eligibleImageCount)
        #expect(reported.errorCount == realOnly.counts.errorCount)
    }

    @Test("A report cannot state a budget outcome for a rule that could not run")
    func reportCannotStateAnUnrunBudgetRule() throws {
        // A slice with no eligible held-out real image has no observed false-positive rate,
        // so the predeclared rule produced no result. `CalibrationSliceResult.budgetOutcome`
        // has three values and none of them says that: two report a result that does not
        // exist, and `not-executed` reports a gate someone skipped. Every one is refused.
        let baseline = try ApprovalBaseline()
        let syntheticOnly = try ApprovalSample.measurement(
            baseline.slices[1],
            counts: try ApprovalSample.counts(
                realPositive: 0,
                realNonPositive: 0,
                realInsufficient: 0
            ),
            against: baseline.policy
        )
        #expect(syntheticOnly.budgetOutcome == .noObservedFalsePositiveRate)

        for stated in GateOutcome.allCases {
            rejects("budgetOutcome") {
                _ = try ApprovalBaseline(
                    policy: baseline.policy,
                    slices: baseline.slices,
                    measurements: [baseline.measurements[0], syntheticOnly],
                    reports: [
                        baseline.reports[0],
                        ApprovalSample.report(of: syntheticOnly, budgetOutcome: stated),
                    ]
                ).approve()
            }
        }
    }

    @Test("A report for a slice outside the mandatory set is refused")
    func reportForANonMandatorySliceIsRefused() throws {
        let baseline = try ApprovalBaseline()
        rejects("slice.elsewhere") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: baseline.reports + [
                    ApprovalSample.report(
                        of: baseline.measurements[0],
                        slice: Sample.slice("slice.elsewhere")
                    )
                ]
            ).approve()
        }
    }

    @Test("Two reports for one slice are refused")
    func duplicateReportIsRefused() throws {
        let baseline = try ApprovalBaseline()
        rejects("more than once") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: baseline.reports + [baseline.reports[0]]
            ).approve()
        }
    }

    @Test("Every count is compared, and the first one that differs is named")
    func everyCountMustMatch() throws {
        // The counts are integers, so this needs no tolerance and admits no rounding, and
        // it is where the reconciliation gets its force: every rate in the report is a
        // function of these nine numbers.
        //
        // Seven perturbations rather than nine, and that is a fact about
        // `SliceOutcomeCounts` rather than a gap. It pins each eligible population to the
        // labels that population received, so no count set can differ from another in an
        // insufficient count *alone* — changing one always moves either the eligible total
        // or a decisive count, both of which the reconciliation compares first. The two
        // insufficient counts are still compared; they simply cannot be the first
        // disagreement. The `Mirror` check is what fails if a tenth count appears.
        let baseline = try ApprovalBaseline()
        let measured = baseline.measurements[0]
        #expect(
            Mirror(reflecting: measured.counts).children.count == 9,
            "a count was added to SliceOutcomeCounts; the reconciliation has to name it too"
        )

        let perturbations: [(String, SliceOutcomeCounts)] = [
            ("eligibleRealImages", try ApprovalSample.counts(realNonPositive: 899)),
            ("eligibleSyntheticImages", try ApprovalSample.counts(syntheticNonPositive: 21)),
            (
                "realPositiveLabels",
                try ApprovalSample.counts(realPositive: 3, realNonPositive: 897)
            ),
            (
                "realNonPositiveLabels",
                try ApprovalSample.counts(realNonPositive: 899, realInsufficient: 99)
            ),
            (
                "syntheticPositiveLabels",
                try ApprovalSample.counts(syntheticPositive: 151, syntheticNonPositive: 19)
            ),
            (
                "syntheticNonPositiveLabels",
                try ApprovalSample.counts(
                    syntheticNonPositive: 21,
                    syntheticInsufficient: 29
                )
            ),
            ("errorCount", try ApprovalSample.counts(errors: 4)),
        ]
        for (field, reported) in perturbations {
            rejects("counts.\(field)") {
                _ = try ApprovalBaseline(
                    policy: baseline.policy,
                    slices: baseline.slices,
                    measurements: baseline.measurements,
                    reports: [
                        ApprovalSample.report(of: measured, counts: reported)
                    ] + baseline.reports.dropFirst()
                ).approve()
            }
        }
    }

    @Test("The reported interval must be the predeclared one that was measured against")
    func reportedIntervalMustBeTheMeasuredOne() throws {
        let baseline = try ApprovalBaseline()
        rejects("falsePositiveRateInterval") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: [
                    ApprovalSample.report(
                        of: baseline.measurements[0],
                        interval: try Sample.interval(
                            lower: Decimal(sign: .plus, exponent: -3, significand: 1),
                            upper: Decimal(sign: .plus, exponent: -3, significand: 3)
                        )
                    )
                ] + baseline.reports.dropFirst()
            ).approve()
        }
    }

    @Test("The reported budget outcome must be the one the counts and the rule produced")
    func reportedBudgetOutcomeMustBeDerived() throws {
        // Both directions. A record cannot declare a pass the measurement does not support,
        // and it cannot record a failure the measurement did not produce either — the second
        // would let a release look stricter than it was.
        let baseline = try ApprovalBaseline()
        for stated in GateOutcome.allCases where stated != .passed {
            rejects("budgetOutcome") {
                _ = try ApprovalBaseline(
                    policy: baseline.policy,
                    slices: baseline.slices,
                    measurements: baseline.measurements,
                    reports: [
                        ApprovalSample.report(of: baseline.measurements[0], budgetOutcome: stated)
                    ] + baseline.reports.dropFirst()
                ).approve()
            }
        }

        // 60 positive labels in 1,000 eligible real images is 6%, well past the 0.5% sample
        // budget, so the derived outcome is a failure and a record claiming a pass is
        // refused before the budget sweep is reached.
        let failing = try ApprovalSample.measurement(
            baseline.slices[0],
            counts: try ApprovalSample.counts(realPositive: 60, realNonPositive: 840),
            against: baseline.policy
        )
        #expect(failing.budgetOutcome == .evaluated(.failed))
        rejects("budgetOutcome") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [failing] + baseline.measurements.dropFirst(),
                reports: [
                    ApprovalSample.report(
                        of: failing,
                        falsePositiveRate: Decimal(sign: .plus, exponent: -2, significand: 6),
                        budgetOutcome: .passed
                    )
                ] + baseline.reports.dropFirst()
            ).approve()
        }
    }

    @Test("A reported rate of exactly 0 or exactly 1 has to be the measured one")
    func endpointsAreReconciledExactly() throws {
        // The two positions the counts pin exactly. Between them the reported decimal is a
        // rounding this gate may not second-guess, but a reported 0 for a rate that is not
        // zero claims a measured absence, and a reported 1 claims every eligible image fell
        // in the category.
        let baseline = try ApprovalBaseline()
        let measured = baseline.measurements[0]

        for (field, report) in [
            (
                "falsePositiveRate must reference above 0",
                ApprovalSample.report(of: measured, falsePositiveRate: 0)
            ),
            (
                "truePositiveRate must reference below 1",
                ApprovalSample.report(of: measured, truePositiveRate: 1)
            ),
            ("coverage must reference below 1", ApprovalSample.report(of: measured, coverage: 1)),
        ] {
            rejects(field) {
                _ = try ApprovalBaseline(
                    policy: baseline.policy,
                    slices: baseline.slices,
                    measurements: baseline.measurements,
                    reports: [report] + baseline.reports.dropFirst()
                ).approve()
            }
        }

        // The other direction: a slice that really did assign no positive label to a real
        // image, and really did give every eligible image a decisive label, has to say so.
        let clean = try ApprovalSample.measurement(
            baseline.slices[0],
            counts: try ApprovalSample.counts(
                realPositive: 0,
                realNonPositive: 1_000,
                realInsufficient: 0,
                syntheticPositive: 200,
                syntheticNonPositive: 0,
                syntheticInsufficient: 0
            ),
            against: baseline.policy
        )
        #expect(try #require(clean.falsePositiveRate).isZero)
        #expect(clean.coverage.isOne)
        #expect(try #require(clean.truePositiveRate).isOne)

        for (field, expected, rate) in [
            ("falsePositiveRate", "0", Decimal(sign: .plus, exponent: -4, significand: 1)),
            ("coverage", "1", Decimal(sign: .plus, exponent: -4, significand: 9_999)),
        ] {
            rejects("\(field) must reference \(expected), the measured") {
                _ = try ApprovalBaseline(
                    policy: baseline.policy,
                    slices: baseline.slices,
                    measurements: [clean] + baseline.measurements.dropFirst(),
                    reports: [
                        ApprovalSample.report(
                            of: clean,
                            falsePositiveRate: field == "falsePositiveRate" ? rate : 0,
                            truePositiveRate: 1,
                            coverage: field == "coverage" ? rate : 1
                        )
                    ] + baseline.reports.dropFirst()
                ).approve()
            }
        }

        // The honest record for that slice approves, so the refusals above are about the
        // disagreement rather than about the endpoints themselves.
        let approved = try ApprovalBaseline(
            policy: baseline.policy,
            slices: baseline.slices,
            measurements: [clean] + baseline.measurements.dropFirst(),
            reports: [
                ApprovalSample.report(
                    of: clean,
                    falsePositiveRate: 0,
                    truePositiveRate: 1,
                    coverage: 1
                )
            ] + baseline.reports.dropFirst()
        ).approve()
        #expect(try #require(approved.report(for: clean.slice)).coverage == .one)
    }

    @Test("A reported rate cannot answer the budget question differently from the measurement")
    func reportedRateMustAgreeAboutTheBudget() throws {
        // Between the endpoints one comparison against the reported decimal is still exact
        // and is the one that matters: whether it satisfies the budget. A published 2%
        // beside a measured 0.2% would have failed a gate the measurement passes, and the
        // reverse would have passed one it fails.
        let baseline = try ApprovalBaseline()
        let measured = baseline.measurements[0]
        #expect(
            try #require(measured.falsePositiveRate)
                .isAtMost(baseline.policy.policy.falseAccusationBudget.rate)
        )

        // The expected message names the budget, so this assertion cannot pass because an
        // endpoint check happened to refuse the same field.
        rejects("budget, like the measured 2/1000") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: [
                    ApprovalSample.report(
                        of: measured,
                        falsePositiveRate: Decimal(sign: .plus, exponent: -2, significand: 2)
                    )
                ] + baseline.reports.dropFirst()
            ).approve()
        }

        // The reverse: a slice that exceeds the budget, reported as though it did not.
        let failing = try ApprovalSample.measurement(
            baseline.slices[0],
            counts: try ApprovalSample.counts(realPositive: 60, realNonPositive: 840),
            against: baseline.policy
        )
        rejects("above the 0.005 budget, like the measured 60/1000") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [failing] + baseline.measurements.dropFirst(),
                reports: [
                    ApprovalSample.report(
                        of: failing,
                        falsePositiveRate: ApprovalSample.baselineFalsePositiveRate,
                        budgetOutcome: .failed
                    )
                ] + baseline.reports.dropFirst()
            ).approve()
        }
    }

    @Test("A report naming another bundle, policy, or specification is refused")
    func reportBindingsMustResolveToThisRelease() throws {
        let baseline = try ApprovalBaseline()
        let measured = baseline.measurements[0]

        rejects("modelBundle") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: [
                    ApprovalSample.report(of: measured, modelBundle: Sample.bundle("bundle.other"))
                ] + baseline.reports.dropFirst()
            ).approve()
        }
        rejects("calibrationPolicy") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: baseline.measurements,
                reports: [
                    ApprovalSample.report(
                        of: measured,
                        calibrationPolicy: Sample.artifact("policy.other")
                    )
                ] + baseline.reports.dropFirst()
            ).approve()
        }
        rejects(ApprovalSample.sliceSpecificationIdentifier) {
            _ = try ApprovalBaseline(
                index: try ApprovalSample.index(
                    omitting: [ApprovalSample.sliceSpecificationIdentifier]
                )
            ).approve()
        }
    }
}

// MARK: - The budget sweep

@Suite("Calibration budget sweep")
struct CalibrationBudgetSweepTests {

    @Test("Any mandatory slice that fails the predeclared rule blocks approval")
    func anyFailingSliceBlocks() throws {
        // Requirement 5.22. The failure is stated as a forbidden outcome, and the message
        // carries the policy's own budget and statistic so an audit sees which approved rule
        // refused rather than a number written here.
        let baseline = try ApprovalBaseline()
        let failing = try ApprovalSample.measurement(
            baseline.slices[1],
            counts: try ApprovalSample.counts(realPositive: 60, realNonPositive: 840),
            against: baseline.policy
        )
        #expect(failing.budgetOutcome == .evaluated(.failed))

        rejects("slice[\(ApprovalSample.generalSliceIdentifier)].budgetOutcome") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [baseline.measurements[0], failing],
                reports: [
                    baseline.reports[0],
                    ApprovalSample.report(
                        of: failing,
                        falsePositiveRate: Decimal(sign: .plus, exponent: -2, significand: 6),
                        budgetOutcome: .failed
                    ),
                ]
            ).approve()
        }
    }

    @Test("A mandatory slice the budget could not be applied to blocks as missing evidence")
    func noObservedRateBlocksAsMissingEvidence() throws {
        // The decision this gate had to make. Requirement 5.1 scopes the budget to mandatory
        // slices containing held-out real images, so a slice with none of them neither
        // exceeds the budget nor fails the interval rule — the rule cannot run at all. An
        // unrun test is not a passed test, so it blocks, and it is reported as missing
        // evidence rather than as a failure so the two findings stay distinguishable.
        let baseline = try ApprovalBaseline()
        let syntheticOnly = try ApprovalSample.measurement(
            baseline.slices[1],
            counts: try ApprovalSample.counts(
                realPositive: 0,
                realNonPositive: 0,
                realInsufficient: 0
            ),
            against: baseline.policy
        )
        #expect(syntheticOnly.budgetOutcome == .noObservedFalsePositiveRate)
        #expect(!syntheticOnly.budgetOutcome.isPassing)

        rejects("an observed false-positive rate") {
            _ = try ApprovalBaseline(
                policy: baseline.policy,
                slices: baseline.slices,
                measurements: [baseline.measurements[0], syntheticOnly],
                reports: [baseline.reports[0]]
            ).approve()
        }
    }

    @Test("The budget and the statistic that decide approval come from the policy")
    func budgetAndStatisticComeFromThePolicy() throws {
        // Nothing here chooses either. The same counts and the same predeclared interval
        // approve or block purely on which statistic the policy predeclared: the observed
        // rate 2/1,000 is inside a 0.3% budget while the interval's upper bound 0.004 is
        // not.
        let budget = try Sample.budget(Decimal(sign: .plus, exponent: -3, significand: 3))
        let expectations: [BudgetPassStatistic: Bool] = [
            .observedRate: true,
            .intervalUpperBound: false,
            .observedRateAndIntervalUpperBound: false,
        ]
        for statistic in BudgetPassStatistic.allCases {
            let policy = try ApprovalSample.policy(
                budget: budget,
                passRule: try Sample.passRule(statistic: statistic)
            )
            let baseline = try ApprovalBaseline(policy: policy)
            guard let approves = expectations[statistic] else {
                throw UnlistedStatistic()
            }

            if approves {
                let approved = try baseline.approve()
                #expect(approved.falseAccusationBudget == budget)
                #expect(approved.releasePassRule.statistic == statistic)
            } else {
                rejects("budgetOutcome") { _ = try baseline.approve() }
            }
        }
    }

    /// Raised when a statistic is added without this test stating what it should decide.
    private struct UnlistedStatistic: Error {}
}

// MARK: - Nothing invented

@Suite("Calibration approval invents no release value")
struct CalibrationApprovalInventsNothingTests {

    @Test("The approval gate contains no interval, budget, threshold, or quality rule")
    func noReleaseValueIsWrittenInTheGate() throws {
        // The structural half of "invent nothing". Four facts about the approval source,
        // each stated as an absence with the positive control that the file was read at all.
        let sources = try DomainSourceFiles.byName(from: #filePath)
        let source = try #require(
            sources["CalibrationReleaseApproval.swift"],
            "the approval source was not found"
        )
        #expect(source.contains("struct ApprovedCalibrationRelease"))

        for constructed in [
            "ConfidenceIntervalResult(",
            "FalseAccusationBudget(",
            "FalseAccusationPassRule(",
            "CategoryBoundary(",
            "QualityDecisionRule(",
        ] {
            #expect(
                !source.contains(constructed),
                "the approval gate constructs \(constructed), which is a release decision"
            )
        }

        // Every interval method case name stays inside the vocabulary that declares them.
        // `ReleaseSliceMetricTests` asserts that for the whole domain; this repeats it for
        // this file alone so the reason is stated where the file is.
        for name in [
            "wilsonScore", "clopperPearson", "agrestiCoull", "jeffreys", "bootstrapPercentile",
        ] {
            #expect(!source.contains(name), "the approval gate names the \(name) method")
        }
    }
}

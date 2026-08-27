import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 15: Calibration Policy validity is fail-closed.
//
// The design states it as: for any candidate Calibration Policy, activation succeeds
// only when it has exactly one False Accusation Budget no greater than 1%, exactly the
// three fixed output labels and metric categories, every category-changing boundary has
// finite half-width at least 0.131, every additional quality rule has valid release
// evidence, the sub-440 rule is present, the upstream `1.390625` value remains metadata,
// and model/preprocessing compatibility is exact.
//
// Quantified here as one property with eight arms over every generated shape:
//
//   * valid — a coherent generated policy activates, every governed value reads back as
//     the one the shape declared, and its canonical payload decodes to the identical
//     policy. Without this arm the property would pass by refusing everything;
//   * budget — a rate above 1%, at zero, or negative is refused, a *second* budget in
//     the same payload is refused, and a pass rule at any level other than 95% is
//     refused;
//   * labels — a label set other than the three fixed labels, an incomplete, repeated,
//     or misassigned metric category, and a decisive label in the below-minimum slot are
//     refused;
//   * boundaries — a half-width below 0.131, a nonfinite position or half-width, a
//     boundary whose two sides carry one label, an empty set, two boundaries at one
//     position, bands that touch, and adjacent boundaries that disagree are refused;
//   * evidence — an abstention rule with no evidence list, and any citation the release
//     does not carry at exactly the version and content named, are refused;
//   * short edge — a minimum short edge other than 440, a decisive below-minimum label,
//     and an uncovered required value that abstains instead of erroring are refused;
//   * metadata — an upstream value other than `1.390625`, and that value carried in the
//     product-boundary role, are refused, while a differently written but numerically
//     identical value is accepted;
//   * compatibility — a bundle naming another policy, and a policy naming another
//     preprocessing contract, verdict-copy record, or model, are refused.
//
// `CalibrationPolicyActivationTests` and `CalibrationPolicyPayloadMutationTests` pin
// individual refusals at one field with one example. This file quantifies the same
// statement over generated shapes. The neighbouring calibration properties belong to
// their own tasks: Property 16 is evaluation totality, Property 17 is release metric
// semantics, and Property 18 is release-approval evidence completeness.
//
// ## Why payload text splicing, not re-serialization
//
// Four of the conditions under test are exact numbers: a budget no greater than 1%, a
// predeclared 95% level, a 0.131 half-width, and `1.390625`. A `JSONSerialization` round
// trip perturbs exact decimals, so a payload mutated through one is refused whether or
// not the mutation mattered, and an assertion over it holds vacuously. Every payload
// mutation here splices the member's *text* through `JSONMemberSplice` and its companion
// `PolicyPayloadSplice`, which leaves every other byte identical, and every splice arm
// carries a positive control: the untouched text, and a re-rendered but numerically
// identical text, both decode back to the same policy.
//
// No value in this file is an approved budget, boundary, half-width, quality rule,
// interval method, evidence record, or model. Every number is generated from a synthetic
// range, every identifier carries the generated seed, and the whole shape exists so that
// validation can be asked to refuse it.

extension Tag {
    /// Design Property 15.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property15CalibrationPolicyValidity: Self
}

@Suite(
    "Property 15: Calibration Policy validity is fail-closed",
    .tags(.property15CalibrationPolicyValidity)
)
struct CalibrationPolicyValidityPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 5.1, 5.2, 5.3, 5.7, 5.11, 5.12, 5.13, 5.14**
    @Test("Policy validity is fail-closed over generated candidate policies")
    func calibrationPolicyValidityIsFailClosed() async {
        let witness = CalibrationPolicyVariationWitness()

        await propertyCheck(input: CalibrationPolicyShape.generator) { shape in
            witness.record(shape)
            let scenario = CalibrationPolicyScenario(shape: shape)

            scenario.checkCoherentPolicyActivates()
            scenario.checkBudgetCeilingIsEnforced()
            scenario.checkLabelSetAndMetricCategoriesAreFixed()
            scenario.checkBoundariesAreFiniteAndUnambiguous()
            scenario.checkQualityRuleEvidenceMustResolve()
            scenario.checkShortEdgeRuleIsFixed()
            scenario.checkUpstreamValueStaysMetadata()
            scenario.checkCompatibilityIsExact()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// One generated category-changing boundary, as plain data.
///
/// The half-width is an offset above the fixed 0.131 minimum rather than an absolute
/// number, so an offset of zero generates the minimum itself and the arm that steps below
/// it always has a legal baseline to step down from. The gap is the clearance beyond the
/// two adjacent half-widths, which is what keeps closed bands disjoint.
private struct BoundaryShape: Sendable {
    /// Thousandths of a raw-logit unit above ``CategoryBoundary/minimumAbstentionHalfWidth``.
    let halfWidthOffsetThousandths: Int

    /// Thousandths of a raw-logit unit of clearance from the previous band. Never zero:
    /// touching bands leave the region between two boundaries empty.
    let gapThousandths: Int
}

/// Which member of each enumerable set a mutation arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one label
/// or one boundary, and so 100 cases spread across the sets instead of every case paying
/// for all of them.
private struct Selectors: Sendable {
    let label: Int
    let boundary: Int
    let evidence: Int
    let feature: Int

    /// Ten-thousandths added to the generated rate to clear the 1% ceiling.
    let overCeilingTenThousandths: Int

    /// Hundredths for a confidence level other than the predeclared 95%.
    let confidenceHundredths: Int

    /// Thousandths to step the half-width below the 0.131 minimum.
    let subMinimumThousandths: Int

    /// Pixels to move the minimum short edge off 440, in either direction.
    let shortEdgeDelta: Int

    /// Millionths to move the upstream value off `1.390625`, in either direction.
    let upstreamOffsetMillionths: Int
}

/// Everything the Calibration Policy layer reads, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property
/// body, where a construction that unexpectedly throws is recorded as a failure rather
/// than escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example
/// a hundred times over, so every dimension the arms depend on is generated rather than
/// fixed:
///
///   * the False Accusation Budget, as its own exact decimal in `(0, 1%]`, including the
///     1% ceiling itself;
///   * the budget pass statistic and the predeclared interval method, over both closed
///     vocabularies, so no arm depends on one release's choice;
///   * one to three chained boundaries, each with its own half-width at or above the
///     0.131 minimum and its own clearance from the previous band, and the direction of
///     the decisive labels, so the same generated set appears both ways round;
///   * one or two required quality features, each covered by two abstention rules and
///     optionally a third rule that produces the input error, with a generated threshold;
///   * one or two held-out calibration evidence records;
///   * every identifier, version, and content digest, from ``seed``. Deriving the whole
///     reference set from one number keeps it coherent without a cross-reference table
///     while still varying each reference between cases.
///
/// ``CalibrationPolicyVariationWitness`` checks after the run that this actually happened.
private struct CalibrationPolicyShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, version, and digest, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    let seed: Int

    /// Ten-thousandths of the budget rate, so every rate is an exact decimal in
    /// `(0, 1%]`. 100 is the 1% ceiling Requirement 5.1 fixes.
    let budgetTenThousandths: Int

    let statisticIndex: Int
    let intervalMethodIndex: Int

    /// Thousandths of a raw-logit unit for the first boundary's position, signed so
    /// boundaries land on both sides of zero.
    let firstPositionThousandths: Int

    let boundaryShapes: [BoundaryShape]

    /// Whether the non-positive label sits below the first boundary or above it.
    let nonPositiveBelowFirstBoundary: Bool

    let featureCount: Int

    /// Hundredths for the measured-value threshold an abstention rule matches at or below.
    let thresholdHundredths: Int

    /// Whether each feature also carries an unusable-value rule producing the input error.
    let carriesInvalidValueRule: Bool

    let evidenceRecordCount: Int

    let selectors: Selectors

    /// The two labels a decisive region may carry. The insufficient outcome is excluded:
    /// it comes from a band, the sub-440 rule, or an evidenced quality rule, never from a
    /// decisive region, and the boundary arm generates it deliberately.
    static let decisiveLabels: [PixelLabelKey] = [
        .noStrongSignalDetected,
        .signalsConsistentWithAIGeneration,
    ]

    var description: String {
        """
        seed \(seed), budget \(budgetRate), \(boundaryShapes.count) boundar(ies) at \
        \(boundaryPositions), \(featureCount) feature(s), \(evidenceRecordCount) \
        evidence record(s)
        """
    }

    // MARK: Derived values

    /// The generated rate, as an exact decimal at or below the 1% ceiling.
    var budgetRate: Decimal {
        Decimal(sign: .plus, exponent: -4, significand: Decimal(budgetTenThousandths))
    }

    var statistic: BudgetPassStatistic {
        BudgetPassStatistic.allCases[statisticIndex % BudgetPassStatistic.allCases.count]
    }

    var intervalMethod: ConfidenceIntervalMethod {
        ConfidenceIntervalMethod.allCases[
            intervalMethodIndex % ConfidenceIntervalMethod.allCases.count
        ]
    }

    /// The half-width of boundary `index`, at or above the fixed 0.131 minimum.
    func halfWidth(_ index: Int) -> Double {
        CategoryBoundary.minimumAbstentionHalfWidth
            + Double(boundaryShapes[index].halfWidthOffsetThousandths) / 1_000
    }

    /// The boundary positions, ascending, each separated from the previous by both
    /// half-widths plus a nonzero clearance so the closed bands stay disjoint.
    var boundaryPositions: [Double] {
        var positions: [Double] = []
        var position = Double(firstPositionThousandths) / 1_000
        for index in boundaryShapes.indices {
            if index > 0 {
                position += halfWidth(index - 1) + halfWidth(index)
                    + Double(boundaryShapes[index].gapThousandths) / 1_000
            }
            positions.append(position)
        }
        return positions
    }

    /// The decisive label `index` regions from the bottom up, alternating so adjacent
    /// boundaries agree about the region they share.
    func decisiveLabel(_ index: Int) -> PixelLabelKey {
        let base = nonPositiveBelowFirstBoundary ? 0 : 1
        return Self.decisiveLabels[(base + index) % Self.decisiveLabels.count]
    }

    /// The label a label-breaking arm targets.
    var selectedLabel: PixelLabelKey {
        PixelLabelKey.allCases[selectors.label % PixelLabelKey.allCases.count]
    }

    /// A decisive label, for the slots the requirements reserve for abstention.
    var selectedDecisiveLabel: PixelLabelKey {
        Self.decisiveLabels[selectors.label % Self.decisiveLabels.count]
    }

    /// The boundary a boundary-breaking arm targets.
    var selectedBoundary: Int { selectors.boundary % boundaryShapes.count }

    /// The held-out evidence record a citation arm targets.
    var selectedEvidence: Int { selectors.evidence % evidenceRecordCount }

    /// The required quality feature a rule arm targets.
    var selectedFeature: Int { selectors.feature % featureCount }

    /// A rate above the 1% ceiling, as an exact decimal.
    var overCeilingRate: Decimal {
        Decimal(
            sign: .plus,
            exponent: -4,
            significand: Decimal(100 + selectors.overCeilingTenThousandths)
        )
    }

    /// A confidence level other than the predeclared 95%.
    var offConfidenceLevel: Decimal {
        let hundredths = selectors.confidenceHundredths == 95 ? 94 : selectors.confidenceHundredths
        return Decimal(sign: .plus, exponent: -2, significand: Decimal(hundredths))
    }

    /// A half-width below the fixed 0.131 minimum.
    var subMinimumHalfWidth: Double {
        CategoryBoundary.minimumAbstentionHalfWidth
            - Double(selectors.subMinimumThousandths) / 1_000
    }

    // MARK: Generators

    static var generator: Generator<CalibrationPolicyShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 1...100),
            Gen.int(in: 0...(BudgetPassStatistic.allCases.count - 1)),
            Gen.int(in: 0...(ConfidenceIntervalMethod.allCases.count - 1)),
            Gen.int(in: -3_000...3_000),
            boundaryShapes,
            Gen.bool,
            qualityShape,
            Gen.int(in: 1...2),
            selectors
        )
        .map { raw in
            CalibrationPolicyShape(
                seed: raw.0,
                budgetTenThousandths: raw.1,
                statisticIndex: raw.2,
                intervalMethodIndex: raw.3,
                firstPositionThousandths: raw.4,
                boundaryShapes: raw.5,
                nonPositiveBelowFirstBoundary: raw.6,
                featureCount: raw.7.0,
                thresholdHundredths: raw.7.1,
                carriesInvalidValueRule: raw.7.2,
                evidenceRecordCount: raw.8,
                selectors: raw.9
            )
        }
        .eraseToAny()
    }

    private static var boundaryShapes: Generator<[BoundaryShape], AnySequence<Any>> {
        zip(Gen.int(in: 0...500), Gen.int(in: 1...400))
            .map { BoundaryShape(halfWidthOffsetThousandths: $0.0, gapThousandths: $0.1) }
            .array(of: 1...3)
            .eraseToAny()
    }

    /// Feature count, measured-value threshold, and whether an input-error rule is
    /// present, generated together because the rule set is built from all three.
    private static var qualityShape: Generator<(Int, Int, Bool), AnySequence<Any>> {
        zip(Gen.int(in: 1...2), Gen.int(in: 1...5_000), Gen.bool)
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }

    private static var selectors: Generator<Selectors, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 1...100),
            Gen.int(in: 1...100),
            Gen.int(in: 1...131),
            Gen.int(in: 1...200),
            Gen.int(in: 1...1_000)
        )
        .map {
            Selectors(
                label: $0.0,
                boundary: $0.1,
                evidence: $0.2,
                feature: $0.3,
                overCeilingTenThousandths: $0.4,
                confidenceHundredths: $0.5,
                subMinimumThousandths: $0.6,
                shortEdgeDelta: $0.7,
                upstreamOffsetMillionths: $0.8
            )
        }
        .eraseToAny()
    }
}

// MARK: - Scenario

/// Builds the artifacts one generated shape describes and asks validation to refuse each
/// mutation of them.
///
/// Every builder is a function of the shape plus explicit overrides, so a mutation arm
/// changes exactly one thing and the rest of the artifact stays the coherent baseline.
private struct CalibrationPolicyScenario {
    let shape: CalibrationPolicyShape

    private let decoder = BoundedArtifactDecoder(limits: .testing())

    // MARK: Seeded references

    private var seed: Int { shape.seed }

    private func artifact(_ name: String) -> ArtifactID {
        // Force-unwrapped deliberately: the composed text is canonical by construction,
        // and a `nil` here is a defect in this file rather than a property failure.
        ArtifactID("\(name)-\(seed)")!
    }

    var policyID: ArtifactID { artifact("policy.calibration") }
    var preprocessingID: ArtifactID { artifact("contract.preprocessing") }
    var verdictCopyID: ArtifactID { artifact("copy.compatibility") }
    var bundleID: ModelBundleID { ModelBundleID("bundle.calibration-\(seed)")! }

    /// An identifier no artifact in the generated release carries.
    var unindexedID: ArtifactID { artifact("evidence.not-carried") }

    private var evidenceVersion: SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: "1.\(seed % 50).\(seed % 7)")
    }

    /// Another version of the same artifact, for the wrong-version citation arm.
    private var otherEvidenceVersion: SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: "2.\(seed % 50).\(seed % 7)")
    }

    private func digest(_ salt: Int) -> SHA256Digest {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256Digest.byteCount)
        for index in 0..<SHA256Digest.byteCount {
            bytes.append(UInt8((seed &+ salt &* 31 &+ index &* 7) & 0xFF))
        }
        return SHA256Digest(bytes: bytes)!
    }

    private func evidence(_ artifactID: ArtifactID, salt: Int) -> EvidenceSource {
        EvidenceSource(artifact: artifactID, version: evidenceVersion, contentDigest: digest(salt))
    }

    /// The policy's own held-out calibration evidence (Requirement 5.6).
    func calibrationEvidence() -> [EvidenceSource] {
        (0..<shape.evidenceRecordCount).map {
            evidence(artifact("evidence.calibration.\($0)"), salt: $0)
        }
    }

    /// The evidence every abstention rule cites (Requirements 5.11 and 5.12).
    func qualityEvidence() -> EvidenceSource {
        evidence(artifact("evidence.quality"), salt: 97)
    }

    /// Every record this generated release carries.
    func evidenceRecords() -> [EvidenceSource] { calibrationEvidence() + [qualityEvidence()] }

    func evidenceIndex(records: [EvidenceSource]? = nil) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(records: records ?? evidenceRecords())
    }

    func feature(_ index: Int) -> QualityFeatureID {
        QualityFeatureID("quality.feature-\(seed).\(index)")!
    }

    var requiredFeatures: Set<QualityFeatureID> {
        Set((0..<shape.featureCount).map { feature($0) })
    }

    private var threshold: Decimal {
        Decimal(sign: .plus, exponent: -2, significand: Decimal(shape.thresholdHundredths))
    }

    // MARK: Baseline artifacts

    func budget(_ rate: Decimal? = nil) throws -> FalseAccusationBudget {
        try FalseAccusationBudget(validating: rate ?? shape.budgetRate)
    }

    func passRule(level: Decimal? = nil) throws -> FalseAccusationPassRule {
        try FalseAccusationPassRule(
            statistic: shape.statistic,
            intervalMethod: shape.intervalMethod,
            confidenceLevel: try UnitInterval(
                validating: level ?? FalseAccusationPassRule.requiredConfidenceLevel
            )
        )
    }

    /// The chained boundary set, optionally with one boundary replaced.
    func boundaries(
        halfWidthAt mutatedIndex: Int? = nil,
        halfWidth mutatedHalfWidth: Double? = nil,
        positionAt positionIndex: Int? = nil,
        position mutatedPosition: Double? = nil,
        lowerAt lowerIndex: Int? = nil,
        lower mutatedLower: PixelLabelKey? = nil,
        upperAt upperIndex: Int? = nil,
        upper mutatedUpper: PixelLabelKey? = nil
    ) throws -> [CategoryBoundary] {
        let positions = shape.boundaryPositions
        return try shape.boundaryShapes.indices.map { index in
            try CategoryBoundary(
                rawLogitBoundary: index == positionIndex
                    ? mutatedPosition! : positions[index],
                abstentionHalfWidth: index == mutatedIndex
                    ? mutatedHalfWidth! : shape.halfWidth(index),
                lowerDecision: index == lowerIndex
                    ? mutatedLower! : shape.decisiveLabel(index),
                upperDecision: index == upperIndex
                    ? mutatedUpper! : shape.decisiveLabel(index + 1)
            )
        }
    }

    func metricCategories(
        omitting omitted: PixelLabelKey? = nil,
        repeating repeated: PixelLabelKey? = nil,
        misassigning misassigned: PixelLabelKey? = nil
    ) -> [MetricCategoryAssignment] {
        var assignments = PixelLabelKey.allCases.compactMap { label -> MetricCategoryAssignment? in
            guard label != omitted else { return nil }
            guard label == misassigned else {
                return MetricCategoryAssignment(label: label, category: label.requiredMetricCategory)
            }
            let wrong = PixelMetricCategory.allCases.first { $0 != label.requiredMetricCategory }!
            return MetricCategoryAssignment(label: label, category: wrong)
        }
        if let repeated {
            assignments.append(
                MetricCategoryAssignment(
                    label: repeated,
                    category: repeated.requiredMetricCategory
                )
            )
        }
        return assignments
    }

    /// Two abstention rules per required feature, plus an optional input-error rule.
    ///
    /// The two abstention rules share an outcome, so an overlap between them is not a
    /// contradiction; the input-error rule matches an unusable value, which is a disjoint
    /// observation from both. That keeps the baseline activatable while still exercising
    /// both outcomes and three of the five condition shapes.
    func qualityRules(
        evidenceFor mutatedFeature: Int? = nil,
        evidence mutatedEvidence: [EvidenceSource]? = nil
    ) throws -> [QualityDecisionRule] {
        var rules: [QualityDecisionRule] = []
        for index in 0..<shape.featureCount {
            let cited = index == mutatedFeature ? mutatedEvidence! : [qualityEvidence()]
            rules.append(
                try QualityDecisionRule(
                    id: ArtifactID("rule.missing-\(seed).\(index)")!,
                    feature: feature(index),
                    condition: .valueMissing,
                    outcome: .insufficientSignal,
                    evidence: cited
                )
            )
            rules.append(
                try QualityDecisionRule(
                    id: ArtifactID("rule.low-\(seed).\(index)")!,
                    feature: feature(index),
                    condition: .atOrBelow(threshold),
                    outcome: .insufficientSignal,
                    evidence: cited
                )
            )
            guard shape.carriesInvalidValueRule else { continue }
            rules.append(
                try QualityDecisionRule(
                    id: ArtifactID("rule.invalid-\(seed).\(index)")!,
                    feature: feature(index),
                    condition: .valueInvalid,
                    outcome: .calibrationInputError,
                    evidence: []
                )
            )
        }
        return rules
    }

    /// The generated policy, with any single field overridden.
    func policy(
        identifier: ArtifactID? = nil,
        compatibleModel: ModelIdentity? = nil,
        compatiblePreprocessing: ArtifactID? = nil,
        compatibleVerdictCopy: ArtifactID? = nil,
        budget declaredBudget: FalseAccusationBudget? = nil,
        passRule declaredPassRule: FalseAccusationPassRule? = nil,
        outputLabels: Set<PixelLabelKey>? = nil,
        metricCategories declaredCategories: [MetricCategoryAssignment]? = nil,
        boundaries declaredBoundaries: [CategoryBoundary]? = nil,
        minimumShortEdge: Int? = nil,
        belowMinimumShortEdgeLabel: PixelLabelKey? = nil,
        requiredQualityFeatures: Set<QualityFeatureID>? = nil,
        qualityRules declaredRules: [QualityDecisionRule]? = nil,
        uncoveredQualityInputBehavior: UncoveredQualityInputBehavior? = nil,
        evidence declaredEvidence: [EvidenceSource]? = nil,
        upstreamValue: Decimal? = nil,
        upstreamRole: UpstreamBoundaryRole? = nil
    ) throws -> CalibrationPolicy {
        try CalibrationPolicy(
            id: identifier ?? policyID,
            schemaVersion: .v1,
            compatibleModel: compatibleModel ?? RequiredPixelModel.identity,
            compatiblePreprocessing: compatiblePreprocessing ?? preprocessingID,
            compatibleVerdictCopy: compatibleVerdictCopy ?? verdictCopyID,
            falseAccusationBudget: try declaredBudget ?? budget(),
            releasePassRule: try declaredPassRule ?? passRule(),
            outputLabels: outputLabels ?? Set(PixelLabelKey.allCases),
            metricCategories: declaredCategories ?? metricCategories(),
            boundaries: try declaredBoundaries ?? boundaries(),
            minimumShortEdge: minimumShortEdge ?? CalibrationPolicy.requiredMinimumShortEdge,
            belowMinimumShortEdgeLabel: belowMinimumShortEdgeLabel ?? .notEnoughSignal,
            requiredQualityFeatures: requiredQualityFeatures ?? requiredFeatures,
            qualityRules: try declaredRules ?? qualityRules(),
            uncoveredQualityInputBehavior: uncoveredQualityInputBehavior ?? .calibrationInputError,
            evidence: declaredEvidence ?? calibrationEvidence(),
            upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                rawLogitValue: upstreamValue ?? UpstreamBoundaryMetadata.requiredValue,
                role: upstreamRole ?? .modelMetadataOnly
            )
        )
    }

    /// The Model Bundle the policy is activated with.
    ///
    /// The manifest's model identity is fixed to ``RequiredPixelModel/identity`` by its
    /// own schema, so the compatibility arm moves the *policy's* model instead: that is
    /// the only representable disagreement, and it is the one Requirement 5.13 rejects.
    func manifest(
        calibrationPolicy: ArtifactID? = nil,
        preprocessingContract: ArtifactID? = nil,
        verdictCopyCompatibility: ArtifactID? = nil
    ) throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: bundleID,
            modelIdentity: RequiredPixelModel.identity,
            modelFormat: try Sample.modelFormat(),
            inputContract: try Sample.modelInput(),
            outputContract: try Sample.modelOutput(),
            componentVersions: BundleComponentVersions(
                coreMLModel: artifact("component.coreml"),
                preprocessingContract: preprocessingContract ?? preprocessingID,
                calibrationPolicy: calibrationPolicy ?? policyID,
                evidenceScope: artifact("component.scope"),
                verdictCopyCompatibility: verdictCopyCompatibility ?? verdictCopyID,
                selfTestSpecification: artifact("component.self-tests")
            ),
            artifacts: [Sample.digestRecord()],
            compatibility: try Sample.compatibilityMatrix(),
            upstreamBoundaryMetadata: try Sample.upstreamMetadata(),
            signingKey: Sample.signingKey("key.calibration-\(seed)")
        )
    }

    func activate(
        _ candidate: CalibrationPolicy? = nil,
        bundle: ModelBundleManifest? = nil,
        index: ReleaseEvidenceIndex? = nil
    ) throws -> ValidatedCalibrationPolicy {
        try ValidatedCalibrationPolicy(
            activating: candidate ?? policy(),
            for: bundle ?? manifest(),
            evidence: index ?? evidenceIndex()
        )
    }

    // MARK: - Valid arm

    /// A coherent generated policy activates, every governed value reads back as declared,
    /// and its canonical payload decodes to the identical policy.
    ///
    /// Without this arm the property would pass by refusing everything, and the payload
    /// round trip is what keeps the splice arms below non-vacuous: a refusal there is
    /// attributable to the spliced member only if the untouched bytes read back the same.
    func checkCoherentPolicyActivates() {
        let candidate: CalibrationPolicy
        let activated: ValidatedCalibrationPolicy
        do {
            candidate = try policy()
            activated = try activate(candidate)
        } catch {
            Issue.record("a coherent generated policy was refused: \(error) [\(shape)]")
            return
        }

        #expect(activated.policy == candidate)
        #expect(activated.id == policyID)
        #expect(activated.modelBundle == bundleID)

        // Requirement 5.1: one budget, at or below 1%, and it is the generated number.
        #expect(candidate.falseAccusationBudget.rate == shape.budgetRate)
        #expect(candidate.falseAccusationBudget.rate <= FalseAccusationBudget.maximumRate)
        #expect(
            candidate.releasePassRule.confidenceLevel.value
                == FalseAccusationPassRule.requiredConfidenceLevel
        )
        #expect(candidate.releasePassRule.intervalMethod == shape.intervalMethod)
        #expect(candidate.releasePassRule.statistic == shape.statistic)

        // Requirements 5.2 and 5.3: exactly the three labels, each in its fixed category.
        #expect(PixelLabelKey.allCases.count == 3, "the fixed label set changed size")
        #expect(candidate.outputLabels == Set(PixelLabelKey.allCases))
        #expect(candidate.metricCategories.count == PixelLabelKey.allCases.count)
        for assignment in candidate.metricCategories {
            #expect(assignment.category == assignment.label.requiredMetricCategory)
        }

        // Requirement 5.7: ascending, finite, at or above the minimum, and disjoint.
        let ordered = activated.orderedBoundaries
        #expect(ordered.map(\.rawLogitBoundary) == shape.boundaryPositions)
        for boundary in ordered {
            #expect(boundary.rawLogitBoundary.isFinite)
            #expect(boundary.abstentionHalfWidth.isFinite)
            #expect(
                boundary.abstentionHalfWidth >= CategoryBoundary.minimumAbstentionHalfWidth,
                "half-width \(boundary.abstentionHalfWidth) [\(shape)]"
            )
            #expect(boundary.lowerDecision != boundary.upperDecision)
            #expect(boundary.lowerDecision != .notEnoughSignal)
            #expect(boundary.upperDecision != .notEnoughSignal)
        }
        for (offset, boundary) in ordered.enumerated().dropFirst() {
            #expect(ordered[offset - 1].abstentionUpperBound < boundary.abstentionLowerBound)
            #expect(ordered[offset - 1].upperDecision == boundary.lowerDecision)
        }

        // The sub-440 rule and the upstream metadata, read back rather than assumed.
        #expect(candidate.minimumShortEdge == CalibrationPolicy.requiredMinimumShortEdge)
        #expect(candidate.belowMinimumShortEdgeLabel == .notEnoughSignal)
        #expect(candidate.uncoveredQualityInputBehavior == .calibrationInputError)
        #expect(
            candidate.upstreamBoundaryMetadata.rawLogitValue
                == UpstreamBoundaryMetadata.requiredValue
        )
        #expect(candidate.upstreamBoundaryMetadata.role == .modelMetadataOnly)

        // Requirement 5.13: the compatibility trio is the bundle's, exactly.
        #expect(candidate.compatibleModel == RequiredPixelModel.identity)
        #expect(candidate.compatiblePreprocessing == preprocessingID)
        #expect(candidate.compatibleVerdictCopy == verdictCopyID)

        // The payload positive control for every splice arm below.
        guard let payload = try? CanonicalArtifactPayload.text(candidate),
              let keys = try? CanonicalArtifactPayload.topLevelKeys(candidate)
        else {
            Issue.record("a coherent generated policy could not be encoded [\(shape)]")
            return
        }
        do {
            let decoded = try decoder.decode(CalibrationPolicy.self, from: Array(payload.utf8))
            #expect(decoded == candidate, "the untouched payload did not round trip [\(shape)]")
        } catch {
            Issue.record("the untouched payload failed to decode: \(error) [\(shape)]")
        }

        // Each member a splice arm targets has to be a top-level member, so a rename
        // fails here instead of silently skipping the arm.
        for member in Self.splicedMembers {
            #expect(keys.contains(member), "\(member) is not a top-level policy member")
            #expect(
                JSONMemberSplice.topLevelMemberRanges(in: payload)[member] != nil,
                "\(member) was not locatable in the payload text"
            )
        }
    }

    /// The members the payload arms splice. Asserted present by the valid arm.
    static let splicedMembers = [
        "falseAccusationBudget",
        "releasePassRule",
        "minimumShortEdge",
        "upstreamBoundaryMetadata",
    ]

    // MARK: - Budget arm

    /// Requirement 5.1: exactly one budget, no greater than 1%.
    ///
    /// "No greater than 1%" is four refusals — above the ceiling, at zero, negative, and
    /// the ceiling itself accepted — and "exactly one" is a fifth that only a text splice
    /// can express, because a serializer's input is a dictionary and cannot hold one key
    /// twice. The pass rule's level belongs here too: Requirement 5.21 reads the budget
    /// decision off a predeclared interval, and Requirement 5.19 fixes that level at 95%,
    /// so a policy declaring another level is not declaring this budget's pass rule.
    func checkBudgetCeilingIsEnforced() {
        expectRefused("a budget of \(shape.overCeilingRate)", .valueOutOfRange) {
            _ = try self.budget(self.shape.overCeilingRate)
        }
        for nonpositive in [Decimal.zero, -shape.budgetRate] {
            expectRefused("a budget of \(nonpositive)", .nonPositiveValue) {
                _ = try self.budget(nonpositive)
            }
        }

        // The ceiling itself is a legal decision, so the refusals above are about
        // exceeding 1% rather than about approaching it.
        do {
            let ceiling = try budget(FalseAccusationBudget.maximumRate)
            #expect(ceiling.rate == FalseAccusationBudget.maximumRate)
            _ = try activate(try policy(budget: ceiling))
        } catch {
            Issue.record("the 1% ceiling was refused as a budget: \(error) [\(shape)]")
        }

        expectRefused("a pass rule at \(shape.offConfidenceLevel)", .fixedValueMismatch) {
            _ = try self.passRule(level: self.shape.offConfidenceLevel)
        }

        guard let payload = try? CanonicalArtifactPayload.text(try policy()) else {
            Issue.record("the generated policy could not be encoded [\(shape)]")
            return
        }

        // Spliced rather than re-serialized: the budget and the level are the two exact
        // decimals a round trip moves, so a round-trip mutation is refused either way.
        expectPayloadRefused(
            "a spliced budget of \(shape.overCeilingRate)",
            replacing: "falseAccusationBudget",
            with: "\(shape.overCeilingRate)",
            in: payload,
            path: "falseAccusationBudget",
            fault: .valueOutOfRange
        )
        expectPayloadRefused(
            "a spliced budget of zero",
            replacing: "falseAccusationBudget",
            with: "0",
            in: payload,
            path: "falseAccusationBudget",
            fault: .nonPositiveValue
        )

        // A second budget in one payload. Both occurrences are legal budgets, so the
        // bytes read as a whole policy either way, which is what makes the duplicate an
        // ambiguity rather than a malformed document.
        let otherRate: Decimal =
            shape.budgetRate == FalseAccusationBudget.maximumRate
            ? Decimal(sign: .plus, exponent: -4, significand: 1)
            : FalseAccusationBudget.maximumRate
        var resolved: [Decimal] = []
        for placement in PolicyPayloadSplice.Placement.allCases {
            guard let duplicated = PolicyPayloadSplice.duplicatingTopLevelMember(
                "falseAccusationBudget",
                withValue: "\(otherRate)",
                placing: placement,
                in: payload
            ) else {
                Issue.record("the budget member could not be duplicated [\(shape)]")
                continue
            }
            // A general-purpose decoder resolves the duplicate silently and returns a
            // policy, with no indication that the bytes were ambiguous.
            if let permissive = try? JSONDecoder().decode(
                CalibrationPolicy.self,
                from: Data(duplicated.utf8)
            ) {
                resolved.append(permissive.falseAccusationBudget.rate)
            }
            expectPayloadFault(
                "a second budget placed \(placement)",
                duplicated,
                expected: .duplicateKey(path: "<root>", key: "falseAccusationBudget")
            )
        }
        // Which occurrence won decided the harm-control number, from one key set: a
        // signature over these bytes would no longer pin the budget.
        #expect(
            Set(resolved).count == resolved.count && resolved.count == 2,
            "the two placements read the same budget, so the duplicate was not ambiguous"
        )

        // The nested pass rule, spliced whole. The control re-renders the generated rule
        // at the predeclared level and must be accepted, so the refusal that follows is
        // about the level and not about hand-written JSON.
        expectPayloadAccepted(
            "a re-rendered pass rule at the predeclared level",
            replacing: "releasePassRule",
            with: passRuleText(level: FalseAccusationPassRule.requiredConfidenceLevel),
            in: payload
        )
        expectPayloadRefused(
            "a spliced pass rule at \(shape.offConfidenceLevel)",
            replacing: "releasePassRule",
            with: passRuleText(level: shape.offConfidenceLevel),
            in: payload,
            path: "releasePassRule",
            fault: .fixedValueMismatch
        )
    }

    /// The generated pass rule as payload text, at `level`.
    ///
    /// Composed from the shape's own statistic and interval method so the only difference
    /// from the encoded rule is the level.
    private func passRuleText(level: Decimal) -> String {
        """
        {"confidenceLevel":\(level),\
        "intervalMethod":"\(shape.intervalMethod.rawValue)",\
        "statistic":"\(shape.statistic.rawValue)"}
        """
    }

    // MARK: - Label arm

    /// Requirements 5.2 and 5.3: exactly the three fixed labels, each in its fixed
    /// metric category.
    ///
    /// A *fourth* label is unrepresentable — `PixelLabelKey` has exactly three cases, and
    /// the valid arm asserts that count — so the representable failures are a set that
    /// omits a label, and a category table that omits, repeats, or misassigns one. The
    /// below-minimum slot is checked here too: it names one of the same three labels, and
    /// only the insufficient outcome belongs in it.
    func checkLabelSetAndMetricCategoriesAreFixed() {
        let label = shape.selectedLabel

        expectRefused("a label set without \(label.rawValue)", .fixedValueMismatch) {
            _ = try self.policy(
                outputLabels: Set(PixelLabelKey.allCases).subtracting([label])
            )
        }
        expectRefused("an empty label set", .fixedValueMismatch) {
            _ = try self.policy(outputLabels: [])
        }
        expectRefused(
            "metric categories without \(label.rawValue)",
            .missingRequiredEntries
        ) {
            _ = try self.policy(metricCategories: self.metricCategories(omitting: label))
        }
        expectRefused(
            "metric categories repeating \(label.rawValue)",
            .duplicateEntry
        ) {
            _ = try self.policy(metricCategories: self.metricCategories(repeating: label))
        }
        expectRefused(
            "\(label.rawValue) in another metric category",
            .fixedValueMismatch
        ) {
            _ = try self.policy(metricCategories: self.metricCategories(misassigning: label))
        }
        expectRefused(
            "a below-minimum label of \(shape.selectedDecisiveLabel.rawValue)",
            .forbiddenValue
        ) {
            _ = try self.policy(belowMinimumShortEdgeLabel: self.shape.selectedDecisiveLabel)
        }
    }

    // MARK: - Boundary arm

    /// Requirement 5.7: every category-changing boundary is finite, category-changing, and
    /// carries a closed band of at least 0.131 raw-logit units, and the set of them leaves
    /// no logit with two labels or none.
    ///
    /// The per-boundary refusals are at the type, which is the strongest available form:
    /// an under-minimum, nonfinite, or non-category-changing boundary cannot be placed in
    /// a policy at all. The set-level refusals are at activation, because a single valid
    /// boundary cannot see them.
    func checkBoundariesAreFiniteAndUnambiguous() {
        let index = shape.selectedBoundary

        // The minimum itself is a legal half-width, so the refusals below are about going
        // under 0.131 rather than about reaching it.
        do {
            let atMinimum = try boundaries(
                halfWidthAt: index,
                halfWidth: CategoryBoundary.minimumAbstentionHalfWidth
            )
            #expect(
                atMinimum[index].abstentionHalfWidth
                    == CategoryBoundary.minimumAbstentionHalfWidth
            )
        } catch {
            Issue.record("the 0.131 minimum was refused as a half-width: \(error) [\(shape)]")
        }

        for narrow in [
            CategoryBoundary.minimumAbstentionHalfWidth.nextDown,
            shape.subMinimumHalfWidth,
            0,
        ] {
            expectRefused("a half-width of \(narrow)", .valueOutOfRange) {
                _ = try self.boundaries(halfWidthAt: index, halfWidth: narrow)
            }
        }
        expectRefused("a negative half-width", .valueOutOfRange) {
            _ = try self.boundaries(
                halfWidthAt: index,
                halfWidth: -self.shape.halfWidth(index)
            )
        }

        for nonfinite in [Double.infinity, -.infinity, .nan] {
            expectRefused("a boundary at \(nonfinite)", .nonFiniteValue) {
                _ = try self.boundaries(positionAt: index, position: nonfinite)
            }
            expectRefused("a half-width of \(nonfinite)", .nonFiniteValue) {
                _ = try self.boundaries(halfWidthAt: index, halfWidth: nonfinite)
            }
        }

        // A boundary whose two sides carry one label changes no category, so the
        // half-width around it protects nothing.
        expectRefused(
            "a boundary with \(shape.decisiveLabel(index).rawValue) on both sides",
            .forbiddenValue
        ) {
            _ = try self.boundaries(
                upperAt: index,
                upper: self.shape.decisiveLabel(index)
            )
        }

        expectRefused("a policy with no boundary at all", .emptyValue) {
            _ = try self.policy(boundaries: [])
        }

        // The insufficient outcome as a decisive region: Requirement 5.10 derives every
        // insufficient result from a rule, and an unconditional region is not one.
        expectRefused("the insufficient outcome below a boundary", .forbiddenValue) {
            _ = try self.activate(
                try self.policy(
                    boundaries: try self.boundaries(lowerAt: index, lower: .notEnoughSignal)
                )
            )
        }
        expectRefused("the insufficient outcome above a boundary", .forbiddenValue) {
            _ = try self.activate(
                try self.policy(
                    boundaries: try self.boundaries(upperAt: index, upper: .notEnoughSignal)
                )
            )
        }

        // Set-level: two boundaries at one position, two bands that touch, and two
        // adjacent boundaries that disagree about the region between them. Each needs a
        // second boundary, so each is built as an explicit pair rather than by mutating
        // the chain, which may be a single boundary.
        let position = shape.boundaryPositions[index]
        let halfWidth = shape.halfWidth(index)

        expectRefused("two boundaries at \(position)", .duplicateEntry) {
            _ = try self.activate(
                try self.policy(
                    boundaries: [
                        try CategoryBoundary(
                            rawLogitBoundary: position,
                            abstentionHalfWidth: halfWidth,
                            lowerDecision: self.shape.decisiveLabel(0),
                            upperDecision: self.shape.decisiveLabel(1)
                        ),
                        try CategoryBoundary(
                            rawLogitBoundary: position,
                            abstentionHalfWidth: halfWidth,
                            lowerDecision: self.shape.decisiveLabel(1),
                            upperDecision: self.shape.decisiveLabel(0)
                        ),
                    ]
                )
            )
        }

        // Bands that overlap over a whole interval: a logit inside the shared part belongs
        // to two abstention rules at once.
        expectRefused("closed bands that overlap", .valueOutOfRange) {
            _ = try self.activate(
                try self.policy(boundaries: try self.adjacentPair(gap: halfWidth))
            )
        }

        // Bands that share exactly their closed endpoints, which is the sharper case: the
        // decisive region between the two boundaries is empty, so its declared label can
        // never be produced. The second position is derived from the first band's own
        // upper edge rather than computed as `position + 2h`, because the rounding of that
        // sum can land one unit in the last place above the shared point and leave the two
        // bands genuinely disjoint — which would test nothing.
        if let pair = try? touchingPair(position: position, halfWidth: halfWidth) {
            expectRefused("closed bands that meet at one point", .valueOutOfRange) {
                _ = try self.activate(try self.policy(boundaries: pair))
            }
        } else {
            Issue.record("no touching band pair was representable [\(shape)]")
        }

        // Both boundaries put the same label above themselves, so the region between them
        // is one label by the lower boundary and the other by the upper one. Each boundary
        // is individually valid — its two sides still differ — and the clearance is a whole
        // raw-logit unit beyond both bands, so the refusal is about the disagreement.
        expectRefused("adjacent boundaries that disagree", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(
                    boundaries: try self.adjacentPair(
                        gap: halfWidth + halfWidth + 1,
                        lowerOfSecond: self.shape.decisiveLabel(0)
                    )
                )
            )
        }
    }

    /// Two boundaries separated by `gap`, chained unless `lowerOfSecond` overrides the
    /// second's lower label.
    ///
    /// Chained means the second's lower label is the first's upper label, which is what
    /// makes the region they share single-valued.
    private func adjacentPair(
        gap: Double,
        lowerOfSecond: PixelLabelKey? = nil
    ) throws -> [CategoryBoundary] {
        let position = shape.boundaryPositions[shape.selectedBoundary]
        let halfWidth = shape.halfWidth(shape.selectedBoundary)
        return [
            try CategoryBoundary(
                rawLogitBoundary: position,
                abstentionHalfWidth: halfWidth,
                lowerDecision: shape.decisiveLabel(0),
                upperDecision: shape.decisiveLabel(1)
            ),
            try CategoryBoundary(
                rawLogitBoundary: position + gap,
                abstentionHalfWidth: halfWidth,
                lowerDecision: lowerOfSecond ?? shape.decisiveLabel(1),
                upperDecision: lowerOfSecond == nil
                    ? shape.decisiveLabel(0) : shape.decisiveLabel(1)
            ),
        ]
    }

    /// Two boundaries whose closed bands share exactly one point.
    ///
    /// The second position starts one half-width above the first band's upper edge and
    /// steps down by single units in the last place until the second band's lower edge is
    /// at or below that upper edge, so the pair really does meet however the arithmetic
    /// rounds. Returns `nil` if no such position exists that is also distinct from the
    /// first, which would make the arm vacuous rather than passing.
    private func touchingPair(position: Double, halfWidth: Double) throws -> [CategoryBoundary] {
        let lower = try CategoryBoundary(
            rawLogitBoundary: position,
            abstentionHalfWidth: halfWidth,
            lowerDecision: shape.decisiveLabel(0),
            upperDecision: shape.decisiveLabel(1)
        )
        let upperEdge = lower.abstentionUpperBound
        var candidate = upperEdge + halfWidth
        for _ in 0..<8 where candidate - halfWidth > upperEdge {
            candidate = candidate.nextDown
        }
        guard candidate - halfWidth <= upperEdge, candidate > position else {
            throw CalibrationPolicyScenarioError.noTouchingPair
        }
        return [
            lower,
            try CategoryBoundary(
                rawLogitBoundary: candidate,
                abstentionHalfWidth: halfWidth,
                lowerDecision: shape.decisiveLabel(1),
                upperDecision: shape.decisiveLabel(0)
            ),
        ]
    }

    // MARK: - Evidence arm

    /// Requirements 5.11 and 5.12: every additional quality condition that can abstain
    /// cites release-validation evidence, and a policy whose citation does not resolve is
    /// rejected.
    ///
    /// Four distinct findings, not one "invalid evidence": an abstention rule with no
    /// citation at all, a citation to an artifact this release does not carry, a citation
    /// at another version, and a citation to other content at the same identifier. The
    /// last two matter because a policy bound to a mutable document at a fixed identifier
    /// is not bound to the evidence its abstention rule was measured against.
    ///
    /// A required feature no rule can reach is here too. It is the invalid required-feature
    /// behavior: the policy would demand a measurement that can only ever produce the
    /// input error and can never affect a label.
    func checkQualityRuleEvidenceMustResolve() {
        let index = shape.selectedFeature
        let cited = qualityEvidence()

        expectRefused("an abstention rule citing nothing", .emptyValue) {
            _ = try self.policy(
                qualityRules: try self.qualityRules(evidenceFor: index, evidence: [])
            )
        }
        expectRefused("an abstention rule citing absent evidence", .missingRequiredEntries) {
            _ = try self.activate(
                try self.policy(
                    qualityRules: try self.qualityRules(
                        evidenceFor: index,
                        evidence: [self.evidence(self.unindexedID, salt: 5)]
                    )
                )
            )
        }
        expectRefused("an abstention rule citing another version", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(
                    qualityRules: try self.qualityRules(
                        evidenceFor: index,
                        evidence: [
                            EvidenceSource(
                                artifact: cited.artifact,
                                version: self.otherEvidenceVersion,
                                contentDigest: cited.contentDigest
                            )
                        ]
                    )
                )
            )
        }
        expectRefused("an abstention rule citing other content", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(
                    qualityRules: try self.qualityRules(
                        evidenceFor: index,
                        evidence: [
                            EvidenceSource(
                                artifact: cited.artifact,
                                version: cited.version,
                                contentDigest: self.digest(1_009)
                            )
                        ]
                    )
                )
            )
        }

        // The policy's own held-out calibration evidence, which Requirement 5.6 makes the
        // source of every boundary, is required and has to resolve the same way.
        expectRefused("a policy citing no held-out evidence", .emptyValue) {
            _ = try self.policy(evidence: [])
        }
        expectRefused("a policy citing absent held-out evidence", .missingRequiredEntries) {
            var records = self.calibrationEvidence()
            records[self.shape.selectedEvidence] = self.evidence(self.unindexedID, salt: 11)
            _ = try self.activate(try self.policy(evidence: records))
        }

        expectRefused("a required feature no rule reaches", .missingRequiredEntries) {
            _ = try self.activate(
                try self.policy(
                    requiredQualityFeatures: self.requiredFeatures.union(
                        [self.feature(self.shape.featureCount)]
                    )
                )
            )
        }
    }

    // MARK: - Short-edge arm

    /// The sub-440 rule, and the uncovered-value behavior that guards it.
    ///
    /// `minimumShortEdge` is fixed at 440 because Requirement 5.9 makes short edges 1
    /// through 439 abstain: 439 would let a 439-pixel image produce evidence, and 441
    /// would abstain on an input the release measured. Both directions are refused. The
    /// evaluator's behavior at each short edge is a separate concern with its own tests;
    /// what is asserted here is that the policy cannot carry another number.
    func checkShortEdgeRuleIsFixed() {
        for edge in [
            CalibrationPolicy.requiredMinimumShortEdge - shape.selectors.shortEdgeDelta,
            CalibrationPolicy.requiredMinimumShortEdge + shape.selectors.shortEdgeDelta,
            0,
        ] {
            expectRefused("a minimum short edge of \(edge)", .fixedValueMismatch) {
                _ = try self.policy(minimumShortEdge: edge)
            }
        }

        // An uncovered missing or invalid required value may not abstain: abstention would
        // report weak evidence where the policy in fact has no usable input.
        expectRefused("an uncovered required value that abstains", .forbiddenValue) {
            _ = try self.policy(uncoveredQualityInputBehavior: .insufficientSignal)
        }

        guard let payload = try? CanonicalArtifactPayload.text(try policy()) else {
            Issue.record("the generated policy could not be encoded [\(shape)]")
            return
        }
        // Spliced, so the two exact decimals elsewhere in the payload stay byte-identical
        // and the refusal is attributable to this member.
        expectPayloadRefused(
            "a spliced minimum short edge of \(CalibrationPolicy.requiredMinimumShortEdge - 1)",
            replacing: "minimumShortEdge",
            with: "\(CalibrationPolicy.requiredMinimumShortEdge - 1)",
            in: payload,
            path: "<root>",
            fault: .fixedValueMismatch
        )
    }

    // MARK: - Metadata arm

    /// Requirement 5.14: `1.390625` is recorded, and it is model metadata rather than a
    /// product-verdict boundary.
    ///
    /// Two independent refusals. A different number is not the upstream checkpoint's
    /// boundary, so recording one breaks traceability to the checkpoint. The same number
    /// in the product-boundary role is worse: it would make an upstream training artifact
    /// decide a user-facing verdict, which is the substitution the requirement exists to
    /// prevent.
    ///
    /// This is the arm most exposed to the exact-decimal trap, so it carries two controls:
    /// a numerically identical value written with trailing zeros is *accepted*, and the
    /// value re-rendered from the constant is accepted, which together show the refusals
    /// are about the number rather than about the splice.
    func checkUpstreamValueStaysMetadata() {
        let required = UpstreamBoundaryMetadata.requiredValue
        let offset = Decimal(
            sign: .plus,
            exponent: -6,
            significand: Decimal(shape.selectors.upstreamOffsetMillionths)
        )

        for wrong in [required + offset, required - offset, Decimal.zero] {
            expectRefused("an upstream value of \(wrong)", .fixedValueMismatch) {
                _ = try self.policy(upstreamValue: wrong)
            }
        }
        expectRefused("the upstream value as a product boundary", .forbiddenValue) {
            _ = try self.policy(upstreamRole: .productDecisionBoundary)
        }

        // A differently written but numerically identical value is the same decision, so
        // it is accepted. This is the control that keeps the refusals above meaningful.
        do {
            let padded = Decimal(sign: .plus, exponent: -8, significand: 139_062_500)
            #expect(padded == required, "the padded rendering is not the same value")
            let accepted = try policy(upstreamValue: padded)
            #expect(accepted.upstreamBoundaryMetadata.rawLogitValue == required)
        } catch {
            Issue.record("a numerically identical upstream value was refused: \(error)")
        }

        guard let payload = try? CanonicalArtifactPayload.text(try policy()) else {
            Issue.record("the generated policy could not be encoded [\(shape)]")
            return
        }
        expectPayloadAccepted(
            "a re-rendered upstream metadata member",
            replacing: "upstreamBoundaryMetadata",
            with: upstreamMetadataText(value: "\(required)"),
            in: payload
        )
        expectPayloadAccepted(
            "a padded but identical upstream value",
            replacing: "upstreamBoundaryMetadata",
            with: upstreamMetadataText(value: "1.39062500"),
            in: payload
        )
        expectPayloadRefused(
            "a spliced upstream value of \(required + offset)",
            replacing: "upstreamBoundaryMetadata",
            with: upstreamMetadataText(value: "\(required + offset)"),
            in: payload,
            path: "upstreamBoundaryMetadata",
            fault: .fixedValueMismatch
        )
        expectPayloadRefused(
            "a spliced product-boundary role",
            replacing: "upstreamBoundaryMetadata",
            with: upstreamMetadataText(
                value: "\(required)",
                role: UpstreamBoundaryRole.productDecisionBoundary.rawValue
            ),
            in: payload,
            path: "upstreamBoundaryMetadata",
            fault: .forbiddenValue
        )
    }

    /// The upstream metadata member as payload text.
    private func upstreamMetadataText(
        value: String,
        role: String = UpstreamBoundaryRole.modelMetadataOnly.rawValue
    ) -> String {
        "{\"rawLogitValue\":\(value),\"role\":\"\(role)\"}"
    }

    // MARK: - Compatibility arm

    /// Requirement 5.13: a Model Bundle without a compatible validated Calibration Policy
    /// is rejected.
    ///
    /// Four representable disagreements, each a combination in which measured calibration
    /// evidence describes different code or different pixels than the build would run: the
    /// bundle names another policy; the policy was calibrated against another preprocessing
    /// contract, or against another Approved Verdict Copy compatibility record; or it was
    /// calibrated on another model. Each is asserted in both directions where both are
    /// representable — the bundle's reference and the policy's reference are separate
    /// fields, and either one moving is the same rejection.
    func checkCompatibilityIsExact() {
        let other = artifact("policy.other")

        expectRefused("a bundle naming another policy", .inconsistentReference) {
            _ = try self.activate(bundle: try self.manifest(calibrationPolicy: other))
        }
        expectRefused("a policy the bundle does not name", .inconsistentReference) {
            _ = try self.activate(try self.policy(identifier: other))
        }
        expectRefused("a bundle with another preprocessing contract", .inconsistentReference) {
            _ = try self.activate(
                bundle: try self.manifest(preprocessingContract: self.artifact("contract.other"))
            )
        }
        expectRefused("a policy with another preprocessing contract", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(compatiblePreprocessing: self.artifact("contract.other"))
            )
        }
        expectRefused("a bundle with another verdict-copy record", .inconsistentReference) {
            _ = try self.activate(
                bundle: try self.manifest(verdictCopyCompatibility: self.artifact("copy.other"))
            )
        }
        expectRefused("a policy with another verdict-copy record", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(compatibleVerdictCopy: self.artifact("copy.other"))
            )
        }
        expectRefused("a policy calibrated on another model", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(
                    compatibleModel: ModelIdentity(
                        checkpointIdentifier: ModelCheckpointIdentifier(
                            "Other/model-\(self.seed)"
                        )!,
                        requiredWeightDigest: self.digest(211)
                    )
                )
            )
        }
        // The same checkpoint with other weights is still another model: the digest is
        // what binds calibration evidence to the bytes that produced the logits.
        expectRefused("a policy calibrated on other weights", .inconsistentReference) {
            _ = try self.activate(
                try self.policy(
                    compatibleModel: ModelIdentity(
                        checkpointIdentifier: RequiredPixelModel.identity.checkpointIdentifier,
                        requiredWeightDigest: self.digest(307)
                    )
                )
            )
        }
    }

    // MARK: - Refusal helpers

    /// Requires `build` to refuse with a specific fault, recording an issue otherwise.
    ///
    /// Never rethrows. `propertyCheck` discards an error thrown by its body without
    /// recording an issue, so a refusal that escaped as a throw would make this property
    /// pass vacuously.
    func expectRefused(
        _ what: String,
        _ expected: CalibrationPolicyFault,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                CalibrationPolicyFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Splices `member` and requires the bounded decoder to refuse at `path` with `fault`.
    ///
    /// The splice result is checked for being both present and parseable before the
    /// refusal is asserted, so a refusal can never be about bytes this helper broke.
    func expectPayloadRefused(
        _ what: String,
        replacing member: String,
        with value: String,
        in payload: String,
        path: String,
        fault: CalibrationPolicyFault,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let mutated = splice(what, member, value, payload, sourceLocation) else { return }
        switch decodeFault(mutated) {
        case .none:
            Issue.record(
                "\(what) was accepted, so something supplied a value [\(shape)]",
                sourceLocation: sourceLocation
            )
        case let .some(.schemaViolation(reportedPath, error)):
            #expect(
                reportedPath == path,
                "\(what) was reported at \(reportedPath), not \(path) [\(shape)]",
                sourceLocation: sourceLocation
            )
            #expect(
                CalibrationPolicyFault(error) == fault,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        case let .some(other):
            Issue.record(
                "\(what) was refused as \(other) rather than a schema violation [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Splices `member` and requires the bounded decoder to accept the result.
    ///
    /// The controls that keep the exact-decimal arms honest: a re-rendered or padded value
    /// is the same decision and must decode to the same policy.
    func expectPayloadAccepted(
        _ what: String,
        replacing member: String,
        with value: String,
        in payload: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let mutated = splice(what, member, value, payload, sourceLocation),
              let expected = try? decoder.decode(
                  CalibrationPolicy.self,
                  from: Array(payload.utf8)
              )
        else {
            return
        }
        do {
            let decoded = try decoder.decode(CalibrationPolicy.self, from: Array(mutated.utf8))
            #expect(
                decoded == expected,
                "\(what) decoded to a different policy [\(shape)]",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(
                "\(what) was refused: \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Requires a already-mutated payload to be refused with exactly `expected`.
    func expectPayloadFault(
        _ what: String,
        _ payload: String,
        expected: ArtifactDecodingError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let observed = decodeFault(payload)
        let rendered = observed.map(String.init(describing:)) ?? "accepted"
        #expect(
            observed == expected,
            "\(what) was reported as \(rendered) [\(shape)]",
            sourceLocation: sourceLocation
        )
    }

    /// Replaces one member's text, checking that the result is a real, parseable mutation.
    private func splice(
        _ what: String,
        _ member: String,
        _ value: String,
        _ payload: String,
        _ sourceLocation: SourceLocation
    ) -> String? {
        guard let mutated = PolicyPayloadSplice.replacingTopLevelMember(
            member,
            with: value,
            in: payload
        ) else {
            Issue.record(
                "\(member) was not a top-level member, so \(what) mutated nothing [\(shape)]",
                sourceLocation: sourceLocation
            )
            return nil
        }
        let ranges = JSONMemberSplice.topLevelMemberRanges(in: mutated)
        #expect(
            ranges.count == JSONMemberSplice.topLevelMemberRanges(in: payload).count,
            "\(what) changed the member count [\(shape)]",
            sourceLocation: sourceLocation
        )
        #expect(
            (try? JSONSerialization.jsonObject(with: Data(mutated.utf8))) != nil,
            "\(what) left the payload unparseable [\(shape)]",
            sourceLocation: sourceLocation
        )
        return mutated
    }

    /// The fault a payload produced, or `nil` when the decoder accepted it.
    private func decodeFault(_ payload: String) -> ArtifactDecodingError? {
        do {
            _ = try decoder.decode(CalibrationPolicy.self, from: Array(payload.utf8))
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its field strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* a policy
/// was refused while leaving the audit message free to change. Asserting nothing about the
/// case would let an unrelated fault stand in for the one an arm is about, which is how a
/// mutation test passes while testing nothing.
/// A shape this file could not build the artifact an arm needs from.
///
/// Reported as a recorded issue rather than swallowed: an arm that silently skipped itself
/// would leave the property claiming coverage it did not have.
private enum CalibrationPolicyScenarioError: Error {
    case noTouchingPair
}

private enum CalibrationPolicyFault: Equatable {
    case emptyValue
    case placeholderValue
    case noncanonicalValue
    case valueOutOfRange
    case nonPositiveValue
    case nonFiniteValue
    case duplicateEntry
    case missingRequiredEntries
    case unexpectedEntries
    case fixedValueMismatch
    case forbiddenValue
    case inconsistentReference

    init(_ error: ArtifactSchemaError) {
        switch error {
        case .emptyValue: self = .emptyValue
        case .placeholderValue: self = .placeholderValue
        case .noncanonicalValue: self = .noncanonicalValue
        case .valueOutOfRange: self = .valueOutOfRange
        case .nonPositiveValue: self = .nonPositiveValue
        case .nonFiniteValue: self = .nonFiniteValue
        case .duplicateEntry: self = .duplicateEntry
        case .missingRequiredEntries: self = .missingRequiredEntries
        case .unexpectedEntries: self = .unexpectedEntries
        case .fixedValueMismatch: self = .fixedValueMismatch
        case .forbiddenValue: self = .forbiddenValue
        case .inconsistentReference: self = .inconsistentReference
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by generating
/// one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over, and a
/// `propertyCheck` body that throws before reaching its assertions passes in milliseconds
/// with every arm skipped. This collects the dimensions the arms depend on, requires each
/// to have been exercised with more than one value, and requires the case count itself, so
/// both failures are visible. The thresholds are far below what 100 uniform draws produce,
/// so this witnesses variation rather than pinning a distribution.
private final class CalibrationPolicyVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var budgetRates = Set<Decimal>()
    private var statistics = Set<BudgetPassStatistic>()
    private var intervalMethods = Set<ConfidenceIntervalMethod>()
    private var boundaryCounts = Set<Int>()
    private var halfWidths = Set<Double>()
    private var labelDirections = Set<Bool>()
    private var featureCounts = Set<Int>()
    private var evidenceCounts = Set<Int>()
    private var inputErrorRulePresence = Set<Bool>()
    private var cases = 0

    func record(_ shape: CalibrationPolicyShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        budgetRates.insert(shape.budgetRate)
        statistics.insert(shape.statistic)
        intervalMethods.insert(shape.intervalMethod)
        boundaryCounts.insert(shape.boundaryShapes.count)
        halfWidths.formUnion(shape.boundaryShapes.indices.map { shape.halfWidth($0) })
        labelDirections.insert(shape.nonPositiveBelowFirstBoundary)
        featureCounts.insert(shape.featureCount)
        evidenceCounts.insert(shape.evidenceRecordCount)
        inputErrorRulePresence.insert(shape.carriesInvalidValueRule)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases, ran \(cases)")
        // The rate is drawn from 100 admissible values, so a constant baseline shows 1. The
        // floor is an order of magnitude above that rather than a share of the range: the
        // generator concentrates draws near the low end, and this witnesses variation
        // rather than pinning a distribution.
        #expect(budgetRates.count >= 10, "generated budget rates: \(budgetRates.count)")
        #expect(
            statistics.count == BudgetPassStatistic.allCases.count,
            "generated pass statistics: \(statistics.map(\.rawValue).sorted())"
        )
        #expect(
            intervalMethods.count == ConfidenceIntervalMethod.allCases.count,
            "generated interval methods: \(intervalMethods.map(\.rawValue).sorted())"
        )
        #expect(boundaryCounts == [1, 2, 3], "generated boundary counts: \(boundaryCounts.sorted())")
        // One shape carries at most three half-widths, so a constant baseline shows 3.
        #expect(halfWidths.count >= 25, "generated half-widths: \(halfWidths.count)")
        #expect(labelDirections == [false, true], "both label directions are generated")
        #expect(featureCounts == [1, 2], "generated feature counts: \(featureCounts.sorted())")
        #expect(evidenceCounts == [1, 2], "generated evidence counts: \(evidenceCounts.sorted())")
        #expect(
            inputErrorRulePresence == [false, true],
            "both quality-rule outcome sets are generated"
        )
    }
}

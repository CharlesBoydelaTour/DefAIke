import Foundation
import Testing

@testable import DefAIkeDomain

// Evaluating one finite logit and one Input Quality Record against a validated policy.
//
// Activation validity has its own tests in `CalibrationPolicyActivationTests`; every
// policy here is already activated, so what is under test is the mapping itself: which
// label a logit reaches, which observations abstain, and which refuse to produce Pixel
// Evidence at all.
//
// No value here is an approved boundary, half-width, quality rule, or feature. Each
// expectation is written against the policy's own fields — `abstentionLowerBound`,
// `rawLogitBoundary`, `abstentionUpperBound`, `minimumShortEdge` — so a test asserts the
// rule rather than restating a number the release has not chosen yet.

extension Sample {

    /// An evaluator over an activated policy.
    static func evaluator(
        boundaries: [CategoryBoundary]? = nil,
        qualityRules: [QualityDecisionRule] = [],
        requiredQualityFeatures: Set<QualityFeatureID> = []
    ) throws -> CalibrationEvaluator {
        CalibrationEvaluator(
            activatedWith: try activate(
                try activatablePolicy(
                    boundaries: boundaries,
                    qualityRules: qualityRules,
                    requiredQualityFeatures: requiredQualityFeatures
                )
            )
        )
    }

    /// One Input Quality Record, or `nil` when the measurements are inconsistent.
    ///
    /// The dimensions default to a short edge above every Version 1 minimum, so a test
    /// about something else is never silently answered by the sub-440 rule.
    static func qualityRecord(
        width: Int? = 800,
        height: Int? = 600,
        features: [QualityFeatureID: ValidatedQualityValue] = [:]
    ) -> InputQualityRecord? {
        InputQualityRecord(
            decodedWidthBeforeOrientation: width,
            decodedHeightBeforeOrientation: height,
            validatedFeatures: features
        )
    }
}

/// The label `evaluator` assigns, through the port, for the policy it was activated with.
private func classify(
    _ evaluator: CalibrationEvaluator,
    logit: Double,
    quality: InputQualityRecord
) throws -> PixelEvidence {
    let raw = try #require(RawLogit(logit))
    return try evaluator.classify(
        raw,
        quality: quality,
        policy: evaluator.activatedPolicy.policy
    )
}

/// Asserts that classifying `logit` with `quality` fails with exactly `fault`.
private func refuses(
    _ evaluator: CalibrationEvaluator,
    logit: Double,
    quality: InputQualityRecord,
    with fault: AnalysisFault,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let raw = try #require(RawLogit(logit), sourceLocation: sourceLocation)
    #expect(throws: fault, sourceLocation: sourceLocation) {
        try evaluator.classify(
            raw,
            quality: quality,
            policy: evaluator.activatedPolicy.policy
        )
    }
}

// MARK: - Decisive regions and closed bands

@Suite("Calibration boundary evaluation")
struct CalibrationBoundaryEvaluationTests {

    @Test("A logit outside every band takes the decisive label of its region")
    func decisiveRegions() throws {
        let boundary = try Sample.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        let quality = try #require(Sample.qualityRecord())

        let below = boundary.abstentionLowerBound.nextDown
        let above = boundary.abstentionUpperBound.nextUp
        #expect(
            try classify(evaluator, logit: below, quality: quality)
                == boundary.lowerDecision.pixelEvidence
        )
        #expect(
            try classify(evaluator, logit: above, quality: quality)
                == boundary.upperDecision.pixelEvidence
        )
    }

    @Test("The abstention band is closed at both edges and at the boundary")
    func closedBandIncludesItsEdges() throws {
        // Requirements 5.7 and 5.8: the band is `[boundary - h, boundary + h]`, and all
        // three of these values are inside it. The half-width is read from the policy;
        // the release has not chosen it.
        let boundary = try Sample.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        let quality = try #require(Sample.qualityRecord())

        for logit in [
            boundary.abstentionLowerBound,
            boundary.rawLogitBoundary,
            boundary.abstentionUpperBound,
        ] {
            #expect(try classify(evaluator, logit: logit, quality: quality) == .notEnoughSignal)
        }
    }

    @Test("A chained boundary set decides every region between its bands")
    func chainedBoundaryRegions() throws {
        let lower = try Sample.boundary(
            position: 0.0,
            lower: .noStrongSignalDetected,
            upper: .signalsConsistentWithAIGeneration
        )
        let upper = try Sample.boundary(
            position: 1.0,
            lower: .signalsConsistentWithAIGeneration,
            upper: .noStrongSignalDetected
        )
        let evaluator = try Sample.evaluator(boundaries: [upper, lower])
        let quality = try #require(Sample.qualityRecord())

        let middle = (lower.abstentionUpperBound + upper.abstentionLowerBound) / 2
        let below = lower.abstentionLowerBound.nextDown
        let above = upper.abstentionUpperBound.nextUp
        #expect(
            try classify(evaluator, logit: below, quality: quality)
                == .noStrongSignalDetected
        )
        #expect(
            try classify(evaluator, logit: middle, quality: quality)
                == .signalsConsistentWithAIGeneration
        )
        #expect(
            try classify(evaluator, logit: above, quality: quality)
                == .noStrongSignalDetected
        )
        for logit in [lower.rawLogitBoundary, upper.rawLogitBoundary] {
            #expect(try classify(evaluator, logit: logit, quality: quality) == .notEnoughSignal)
        }
    }

    @Test("Every finite logit reaches exactly one label, repeatably")
    func everyFiniteLogitReachesOneLabel() throws {
        let boundary = try Sample.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        let quality = try #require(Sample.qualityRecord())

        let logits = [
            -Double.greatestFiniteMagnitude,
            -1_000, -1, 0,
            boundary.abstentionLowerBound.nextDown,
            boundary.abstentionLowerBound,
            boundary.rawLogitBoundary,
            boundary.abstentionUpperBound,
            boundary.abstentionUpperBound.nextUp,
            1_000,
            .greatestFiniteMagnitude,
            .leastNormalMagnitude,
            -.leastNonzeroMagnitude,
        ]
        for logit in logits {
            let first = try classify(evaluator, logit: logit, quality: quality)
            #expect(PixelEvidence.allCases.contains(first))
            #expect(try classify(evaluator, logit: logit, quality: quality) == first)
        }
    }

    @Test("A schedule with no boundary decides nothing")
    func emptyScheduleDecidesNothing() throws {
        // Not reachable through a validated policy, which is why the caller turns the
        // `nil` into a fail-closed fault rather than choosing a label for it.
        #expect(
            CalibrationEvaluator.label(
                forFiniteLogit: 0,
                boundaries: [],
                insufficientOutcome: .notEnoughSignal
            ) == nil
        )
        let boundary = try Sample.boundary()
        #expect(
            CalibrationEvaluator.label(
                forFiniteLogit: boundary.abstentionUpperBound.nextUp,
                boundaries: [boundary],
                insufficientOutcome: .notEnoughSignal
            ) == boundary.upperDecision.pixelEvidence
        )
    }
}

// MARK: - Nonfinite input

@Suite("Calibration refuses a nonfinite logit")
struct CalibrationNonfiniteLogitTests {

    @Test("A nonfinite value is an invalid output, never a label")
    func nonfiniteValueRefused() throws {
        // The port cannot carry one at all, so this exercises the second lock directly.
        // Without it, every comparison against NaN is false and the value would fall
        // past every band into the label above the last boundary.
        #expect(RawLogit(.nan) == nil)
        #expect(RawLogit(.infinity) == nil)

        let evaluator = try Sample.evaluator()
        let quality = try #require(Sample.qualityRecord())
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            #expect(throws: AnalysisFault.analysis(.invalidOutputError, stage: .calibration)) {
                try evaluator.label(forRawLogit: value, quality: quality)
            }
        }
    }

    @Test("A finite value of the same magnitude still produces a label")
    func finiteValueStillLabeled() throws {
        let evaluator = try Sample.evaluator()
        let quality = try #require(Sample.qualityRecord())

        #expect(
            try evaluator.label(forRawLogit: .greatestFiniteMagnitude, quality: quality)
                == .signalsConsistentWithAIGeneration
        )
    }
}

// MARK: - The short-edge rule

@Suite("Calibration short-edge rule")
struct CalibrationShortEdgeTests {

    @Test("A short edge below the policy minimum abstains, whatever the logit says")
    func belowMinimumShortEdgeAbstains() throws {
        let boundary = try Sample.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        let minimum = evaluator.activatedPolicy.policy.minimumShortEdge
        let decisive = boundary.abstentionUpperBound.nextUp

        for shortEdge in [1, minimum - 1] {
            let quality = try #require(Sample.qualityRecord(width: 900, height: shortEdge))
            #expect(quality.shortEdgeBeforeOrientation == shortEdge)
            #expect(
                try classify(evaluator, logit: decisive, quality: quality) == .notEnoughSignal
            )
        }

        let atMinimum = try #require(Sample.qualityRecord(width: 900, height: minimum))
        #expect(
            try classify(evaluator, logit: decisive, quality: atMinimum)
                == boundary.upperDecision.pixelEvidence
        )
    }

    @Test("An unmeasured short edge is an input error, not a large one")
    func absentShortEdgeIsAnInputError() throws {
        let evaluator = try Sample.evaluator()
        let unmeasured = try #require(Sample.qualityRecord(width: nil, height: nil))
        #expect(unmeasured.shortEdgeBeforeOrientation == nil)

        for quality in [unmeasured, InputQualityRecord.unmeasured] {
            try refuses(
                evaluator,
                logit: 0,
                quality: quality,
                with: .analysis(.calibrationInputError, stage: .calibration)
            )
        }
    }

    @Test("The short-edge rule is total over the recorded measurement")
    func shortEdgeRuleIsTotal() throws {
        let minimum = try Sample.activatablePolicy().minimumShortEdge

        func verdict(_ shortEdge: Int?) -> CalibrationEvaluator.QualityVerdict {
            CalibrationEvaluator.shortEdgeVerdict(shortEdge, minimumShortEdge: minimum)
        }

        #expect(verdict(nil) == .inputError)
        // Zero is not the smallest valid length. An absent measurement must not arrive
        // as 0, and a 0 that did arrive is invalid rather than "small".
        for absurd in [0, -1] {
            #expect(verdict(absurd) == .inputError)
        }
        for small in [1, minimum - 1] {
            #expect(verdict(small) == .abstain)
        }
        for large in [minimum, minimum + 1] {
            #expect(verdict(large) == .logitDecides)
        }
    }

    @Test("A nonpositive dimension never reaches the evaluator")
    func recordRefusesNonpositiveDimensions() {
        // The first lock: the record itself refuses the value, so the evaluator's own
        // refusal is a second one rather than the only one.
        #expect(Sample.qualityRecord(width: 0, height: 500) == nil)
        #expect(Sample.qualityRecord(width: 500, height: 0) == nil)
        #expect(Sample.qualityRecord(width: 500, height: nil) == nil)
    }
}

// MARK: - Additional quality rules

@Suite("Calibration quality-rule evaluation")
struct CalibrationQualityRuleEvaluationTests {

    static let feature = Sample.qualityFeature("quality.exposure")

    /// An evaluator whose policy requires ``feature`` and states `rules` for it.
    static func evaluator(rules: [QualityDecisionRule]) throws -> CalibrationEvaluator {
        try Sample.evaluator(qualityRules: rules, requiredQualityFeatures: [feature])
    }

    static func rule(
        _ identifier: String,
        _ condition: QualityCondition,
        _ outcome: QualityRuleOutcome
    ) throws -> QualityDecisionRule {
        try Sample.qualityRule(
            identifier: identifier,
            feature: feature,
            condition: condition,
            outcome: outcome,
            evidenceRecords: outcome == .insufficientSignal
                ? [Sample.evidence("evidence.quality")]
                : []
        )
    }

    @Test("A missing required value covered by an abstention rule abstains")
    func coveredMissingValueAbstains() throws {
        // Requirement 5.24.
        let evaluator = try Self.evaluator(
            rules: [try Self.rule("rule.missing", .valueMissing, .insufficientSignal)]
        )
        let quality = try #require(Sample.qualityRecord(features: [:]))

        #expect(try classify(evaluator, logit: 10, quality: quality) == .notEnoughSignal)
    }

    @Test("A missing required value no rule covers is an input error")
    func uncoveredMissingValueIsAnInputError() throws {
        // Requirement 5.25: the policy states only a measured-value rule for the
        // feature, so nothing covers its absence and no Pixel Evidence is produced.
        let evaluator = try Self.evaluator(
            rules: [try Self.rule("rule.low", .atOrBelow(10), .insufficientSignal)]
        )
        let quality = try #require(Sample.qualityRecord(features: [:]))

        try refuses(
            evaluator,
            logit: 10,
            quality: quality,
            with: .analysis(.calibrationInputError, stage: .calibration)
        )
    }

    @Test("A rule may name the input error for the condition it matches")
    func ruleMayNameTheInputError() throws {
        let evaluator = try Self.evaluator(
            rules: [try Self.rule("rule.missing", .valueMissing, .calibrationInputError)]
        )
        let quality = try #require(Sample.qualityRecord(features: [:]))

        try refuses(
            evaluator,
            logit: 10,
            quality: quality,
            with: .analysis(.calibrationInputError, stage: .calibration)
        )
    }

    @Test("A present value the stated conditions cannot read is invalid")
    func unreadableValueIsInvalid() throws {
        // The policy states a threshold for the feature and the record carries a
        // condition, so the value is present and unusable. Covered by a `value-invalid`
        // rule it abstains; uncovered it is an input error. Both legs of Requirements
        // 5.24 and 5.25 for "invalid", as distinct from "missing".
        let low = try Self.rule("rule.low", .atOrBelow(10), .insufficientSignal)
        let quality = try #require(
            Sample.qualityRecord(features: [Self.feature: .boolean(true)])
        )

        let covered = try Self.evaluator(
            rules: [low, try Self.rule("rule.invalid", .valueInvalid, .insufficientSignal)]
        )
        #expect(try classify(covered, logit: 10, quality: quality) == .notEnoughSignal)

        try refuses(
            try Self.evaluator(rules: [low]),
            logit: 10,
            quality: quality,
            with: .analysis(.calibrationInputError, stage: .calibration)
        )
    }

    @Test("A recorded condition the policy never compares is a measurement")
    func recordedConditionIsAMeasurement() throws {
        // No threshold is stated for the feature, so a recorded condition is a usable
        // measurement that matches no rule. A recorded `false` is a measured fact, not
        // an unknown, and must not become an error or an abstention.
        let evaluator = try Self.evaluator(
            rules: [try Self.rule("rule.missing", .valueMissing, .insufficientSignal)]
        )
        for recorded in [true, false] {
            let quality = try #require(
                Sample.qualityRecord(features: [Self.feature: .boolean(recorded)])
            )
            #expect(
                try classify(evaluator, logit: 10, quality: quality)
                    == .signalsConsistentWithAIGeneration
            )
        }
    }

    @Test("A measured value is matched against the stated thresholds")
    func measuredValueMatchesThresholds() throws {
        let evaluator = try Self.evaluator(
            rules: [try Self.rule("rule.low", .atOrBelow(10), .insufficientSignal)]
        )

        for measurement in [1, 10] {
            let quality = try #require(
                Sample.qualityRecord(features: [Self.feature: .integer(measurement)])
            )
            #expect(try classify(evaluator, logit: 10, quality: quality) == .notEnoughSignal)
        }

        let above = try #require(Sample.qualityRecord(features: [Self.feature: .integer(11)]))
        #expect(
            try classify(evaluator, logit: 10, quality: above)
                == .signalsConsistentWithAIGeneration
        )
    }

    @Test("Every stated condition kind is matched against one observation")
    func everyConditionKindIsMatched() throws {
        let absent = CalibrationEvaluator.Observation.absent
        let unusable = CalibrationEvaluator.Observation.unusable
        let measured = CalibrationEvaluator.Observation.usable(magnitude: 10)
        let unmeasurable = CalibrationEvaluator.Observation.usable(magnitude: nil)

        let cases: [(QualityCondition, [CalibrationEvaluator.Observation])] = [
            (.valueMissing, [absent]),
            (.valueInvalid, [unusable]),
            (.atOrBelow(10), [measured]),
            (.atOrAbove(10), [measured]),
            (.outsideClosedRange(lower: 0, upper: 5), [measured]),
        ]
        for (condition, matching) in cases {
            let rule = try Self.rule("rule.case", condition, .calibrationInputError)
            for observation in [absent, unusable, measured, unmeasurable] {
                #expect(
                    CalibrationEvaluator.rule(rule, matches: observation)
                        == matching.contains(observation),
                    "\(condition) against \(observation)"
                )
            }
        }
        // A magnitude outside the stated closed range matches; one inside does not.
        let outside = try Self.rule(
            "rule.outside",
            .outsideClosedRange(lower: 0, upper: 5),
            .calibrationInputError
        )
        #expect(CalibrationEvaluator.rule(outside, matches: .usable(magnitude: -1)))
        #expect(!CalibrationEvaluator.rule(outside, matches: .usable(magnitude: 5)))
    }
}

// MARK: - Precedence among simultaneous rules

@Suite("Calibration verdict precedence")
struct CalibrationVerdictPrecedenceTests {

    static let abstaining = Sample.qualityFeature("quality.abstaining")
    static let erroring = Sample.qualityFeature("quality.erroring")

    /// A policy requiring two features whose absences produce different verdicts.
    static func evaluator() throws -> CalibrationEvaluator {
        try Sample.evaluator(
            qualityRules: [
                try Sample.qualityRule(
                    identifier: "rule.abstain",
                    feature: abstaining,
                    condition: .valueMissing,
                    outcome: .insufficientSignal
                ),
                try Sample.qualityRule(
                    identifier: "rule.error",
                    feature: erroring,
                    condition: .valueMissing,
                    outcome: .calibrationInputError,
                    evidenceRecords: []
                ),
            ],
            requiredQualityFeatures: [abstaining, erroring]
        )
    }

    @Test("An uncovered input error dominates an abstention, in any visiting order")
    func inputErrorDominatesAbstention() throws {
        // Requirement 5.25 returns its error *without* Pixel Evidence, so it cannot be
        // satisfied by the insufficient label that Requirement 5.24 would give. The two
        // features live in a `Set`, whose iteration order is not stable across
        // processes, so the outcome comes from a precedence rather than a scan order.
        let evaluator = try Self.evaluator()
        let quality = try #require(Sample.qualityRecord(features: [:]))

        #expect(evaluator.qualityVerdict(for: quality) == .inputError)
        for _ in 0..<64 {
            try refuses(
                evaluator,
                logit: 10,
                quality: quality,
                with: .analysis(.calibrationInputError, stage: .calibration)
            )
        }
    }

    @Test("An abstention still applies when only it fires")
    func abstentionAppliesAlone() throws {
        let evaluator = try Self.evaluator()
        let quality = try #require(
            Sample.qualityRecord(features: [Self.erroring: .boolean(true)])
        )

        #expect(try classify(evaluator, logit: 10, quality: quality) == .notEnoughSignal)
    }

    @Test("A satisfied record leaves the decision to the logit")
    func satisfiedRecordLeavesTheLogitDeciding() throws {
        let evaluator = try Self.evaluator()
        let quality = try #require(
            Sample.qualityRecord(
                features: [Self.abstaining: .boolean(false), Self.erroring: .boolean(false)]
            )
        )

        #expect(evaluator.qualityVerdict(for: quality) == .logitDecides)
        #expect(
            try classify(evaluator, logit: 10, quality: quality)
                == .signalsConsistentWithAIGeneration
        )
    }

    @Test("An uncovered required value dominates the sub-440 rule too")
    func inputErrorDominatesTheShortEdgeRule() throws {
        let evaluator = try Sample.evaluator(
            qualityRules: [
                try Sample.qualityRule(
                    identifier: "rule.low",
                    feature: Self.erroring,
                    condition: .atOrBelow(10),
                    outcome: .insufficientSignal
                )
            ],
            requiredQualityFeatures: [Self.erroring]
        )
        let quality = try #require(Sample.qualityRecord(width: 900, height: 100))

        try refuses(
            evaluator,
            logit: 10,
            quality: quality,
            with: .analysis(.calibrationInputError, stage: .calibration)
        )
    }

    @Test("The verdict order is withholding order")
    func verdictOrderIsWithholdingOrder() {
        #expect(
            CalibrationEvaluator.QualityVerdict.logitDecides
                < CalibrationEvaluator.QualityVerdict.abstain
        )
        #expect(
            CalibrationEvaluator.QualityVerdict.abstain
                < CalibrationEvaluator.QualityVerdict.inputError
        )
        for outcome in QualityRuleOutcome.allCases {
            let expected: CalibrationEvaluator.QualityVerdict =
                outcome == .insufficientSignal ? .abstain : .inputError
            #expect(CalibrationEvaluator.verdict(for: outcome) == expected)
        }
        for behavior in UncoveredQualityInputBehavior.allCases {
            let expected: CalibrationEvaluator.QualityVerdict =
                behavior == .insufficientSignal ? .abstain : .inputError
            #expect(CalibrationEvaluator.verdict(for: behavior) == expected)
        }
    }
}

// MARK: - Session-bound policy

@Suite("Calibration evaluates the session-bound policy")
struct CalibrationBoundPolicyTests {

    @Test("A policy other than the activated one produces no label")
    func otherPolicyRefused() throws {
        // Requirements 5.10, 5.24, and 5.25 each name the validated policy bound to the
        // session. A different policy is a failed compatibility, which the design's
        // error table categorizes as `model-load-error` — not the calibration input
        // error, which Requirement 5.25 reserves for a required quality value.
        let evaluator = try Sample.evaluator()
        let other = try Sample.activatablePolicy(
            boundaries: [try Sample.boundary(position: 9.0)]
        )
        let quality = try #require(Sample.qualityRecord())
        let raw = try #require(RawLogit(0))

        #expect(other != evaluator.activatedPolicy.policy)
        #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .calibration)) {
            try evaluator.classify(raw, quality: quality, policy: other)
        }
    }

    @Test("The evaluator exposes the policy it was activated with")
    func evaluatorExposesItsPolicy() throws {
        let policy = try Sample.activatablePolicy()
        let evaluator = CalibrationEvaluator(activatedWith: try Sample.activate(policy))

        #expect(evaluator.activatedPolicy.policy == policy)
        #expect(evaluator.policyID == policy.id)
    }

    @Test("Every abstention path returns the one insufficient label")
    func oneInsufficientLabel() throws {
        // Requirement 5.2 fixes the label set at three, so the closed band, the sub-440
        // rule, and an evidenced quality rule share one insufficient outcome. The
        // evaluator reads it from the policy; this pins what the policy can say.
        let boundary = try Sample.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        #expect(evaluator.insufficientOutcome == .notEnoughSignal)
        #expect(
            evaluator.activatedPolicy.policy.belowMinimumShortEdgeLabel.pixelEvidence
                == .notEnoughSignal
        )

        let band = try #require(Sample.qualityRecord())
        let short = try #require(Sample.qualityRecord(width: 900, height: 100))
        let decisive = boundary.abstentionUpperBound.nextUp
        #expect(
            try classify(evaluator, logit: boundary.rawLogitBoundary, quality: band)
                == evaluator.insufficientOutcome
        )
        #expect(
            try classify(evaluator, logit: decisive, quality: short)
                == evaluator.insufficientOutcome
        )
    }
}

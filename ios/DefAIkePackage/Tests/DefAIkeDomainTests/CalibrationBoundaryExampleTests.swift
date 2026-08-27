import Foundation
import Testing

@testable import DefAIkeDomain

// The literal values calibration and release measurement turn on.
//
// Every other calibration test in this target deliberately writes its expectations
// against the policy's own fields — `abstentionLowerBound`, `rawLogitBoundary`,
// `minimumShortEdge` — so that no test restates a number the release has not chosen. That
// is the right default for a boundary position or a budget, which are release decisions.
// It is the wrong default for the handful of numbers the *requirements* fix, because a
// test written only against a constant passes after that constant is silently changed.
//
// This file is the other half. It pins each fixed number twice: once read from the type
// that owns it, and once as the literal the requirement states. Both readings have to
// agree, so editing `CategoryBoundary.minimumAbstentionHalfWidth` from 0.131 to 0.13 makes
// this file fail while every property test and every other example test keeps passing.
//
// Requirements 5.4, 5.7, 5.8, 5.9, 5.10, 5.16, 5.17, 5.18, and 5.25 are the ones a fixed
// number decides, and those are the ones pinned here.
//
// The five fixed numbers, and who owns each:
//
//   * `0.131` raw-logit units — the minimum abstention half-width (Requirement 5.7), owned
//     by ``CategoryBoundary/minimumAbstentionHalfWidth``;
//   * `440` pixels — the minimum decisive short edge, which is what makes 1 through 439
//     abstain (Requirement 5.9), owned by ``CalibrationPolicy/requiredMinimumShortEdge``;
//   * `1%` — the False Accusation Budget ceiling (Requirement 5.1), owned by
//     ``FalseAccusationBudget/maximumRate``;
//   * `95%` — the predeclared confidence level, owned by
//     ``FalseAccusationPassRule/requiredConfidenceLevel``;
//   * `1.390625` — the upstream Lowq checkpoint value, carried as model metadata, owned by
//     ``UpstreamBoundaryMetadata/requiredValue``.
//
// A budget, a boundary position, a half-width above the floor, and an interval are release
// decisions and are not fixed anywhere. Where a test needs one it states a synthetic value
// and says so, and where a test needs the harm-control limit it uses the *ceiling* rather
// than inventing the decided budget.
//
// ## The exact-decimal trap
//
// Everything here is an exact number, so a check built on a serializer round trip would
// pass whether or not the value survived it: `JSONSerialization` perturbs exact decimals.
// Nothing in this file serializes, decodes, or mutates payload text — every artifact is
// built as a typed value. Every `Decimal` is built with
// `Decimal(sign:exponent:significand:)`, never from a binary floating-point literal, and
// each one is cross-checked against the same number written as a base-10 string, so a
// significand or exponent typed wrong here fails rather than quietly agreeing with itself.
//
// ## The unit-in-the-last-place trap
//
// A band edge is never recomputed as `position ± halfWidth`: it is read back from the
// ``CategoryBoundary`` that owns it, which is the value the evaluator compares against.
// The points just outside a band are `nextDown` and `nextUp` of those stored edges, so they
// are the nearest representable neighbours rather than a step of arbitrary size, and each
// test asserts the step is reversible (`edge.nextDown.nextUp == edge`). That is what makes
// "the band is closed at exactly this value" bite: there is provably nothing between the
// decisive point and the abstaining edge.
//
// The band positions and half-widths chosen for the literal tables are exactly
// representable in binary — the four are `0 ∓ 0.131`, `0.131 ∓ 0.131`, `2.5 ∓ 0.25`, and
// `-2.5 ∓ 0.5` — so `boundary - h`, `boundary`, and `boundary + h` are all written as exact
// decimal literals rather than approximated.
//
// ## What this file does not cover
//
// It pins values; it does not re-quantify behavior. Policy validity is Property 15,
// evaluation totality and determinism is Property 16, release metric semantics is
// Property 17, and approval evidence completeness is Property 18. The general
// covered-versus-uncovered quality-rule cases behind Requirements 5.24 and 5.25 are pinned
// one example each in `CalibrationEvaluationTests`; the cases here are the ones that turn
// on a fixed number, which for those two requirements is the recorded short edge.

// MARK: - Reading the evaluator

/// The label `evaluator` assigns for `logit`, through the calibration port.
private func label(
    _ evaluator: CalibrationEvaluator,
    logit: Double,
    quality: InputQualityRecord,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> PixelEvidence {
    let raw = try #require(RawLogit(logit), sourceLocation: sourceLocation)
    return try evaluator.classify(
        raw,
        quality: quality,
        policy: evaluator.activatedPolicy.policy
    )
}

/// Asserts that classifying `logit` with `quality` fails with exactly `fault`, so no Pixel
/// Evidence is produced at all.
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

/// The exact ratio `numerator/denominator`, for stating an expected rate as two literals.
private func rate(_ numerator: Int, over denominator: Int) throws -> MeasuredRate {
    try MeasuredRate(
        numerator: Sample.nonNegative(numerator),
        denominator: Sample.count(denominator),
        field: "example.rate"
    )
}

// MARK: - The fixed constants

@Suite("Fixed calibration constants")
struct FixedCalibrationConstantTests {

    @Test("Each fixed calibration number is the literal its requirement states")
    func fixedNumbersMatchTheirLiterals() {
        // Requirement 5.7: an abstention half-width of at least 0.131 raw-logit units.
        // Asserted twice — against the literal, and against the shortest decimal that
        // round trips to the stored `Double` — so a constant edited to 0.1310000001 fails
        // here even though it still compares greater than 0.131.
        #expect(CategoryBoundary.minimumAbstentionHalfWidth == 0.131)
        #expect(CategoryBoundary.minimumAbstentionHalfWidth.description == "0.131")

        // Requirement 5.9: short edges 1 through 439 abstain, so the first decisive short
        // edge is exactly 440 and 439 is exactly one below it.
        #expect(CalibrationPolicy.requiredMinimumShortEdge == 440)
        #expect(CalibrationPolicy.requiredMinimumShortEdge - 1 == 439)

        // Requirement 5.1: one budget, no greater than 1.0%. This is the ceiling, not an
        // approved budget.
        #expect(FalseAccusationBudget.maximumRate == Decimal(string: "0.01"))
        #expect(FalseAccusationBudget.maximumRate.description == "0.01")

        // Requirement 5.19's predeclared 95% level.
        #expect(FalseAccusationPassRule.requiredConfidenceLevel == Decimal(string: "0.95"))
        #expect(FalseAccusationPassRule.requiredConfidenceLevel.description == "0.95")

        // Requirement 5.14's upstream Lowq value, recorded as model metadata.
        #expect(UpstreamBoundaryMetadata.requiredValue == Decimal(string: "1.390625"))
        #expect(UpstreamBoundaryMetadata.requiredValue.description == "1.390625")
    }

    @Test("Each fixed decimal is built exactly, not converted from a binary literal")
    func fixedDecimalsAreExactlyConstructed() {
        // The same three numbers again, written as a significand and a base-10 exponent.
        // A `Decimal` built from a `Double` literal would carry whatever that literal
        // rounded to, so an equality against it could hold for a perturbed value; these
        // are exact by construction and are checked against the string spelling too.
        let onePercent = Decimal(sign: .plus, exponent: -2, significand: 1)
        let ninetyFivePercent = Decimal(sign: .plus, exponent: -2, significand: 95)
        let upstreamValue = Decimal(sign: .plus, exponent: -6, significand: 1_390_625)

        #expect(FalseAccusationBudget.maximumRate == onePercent)
        #expect(FalseAccusationPassRule.requiredConfidenceLevel == ninetyFivePercent)
        #expect(UpstreamBoundaryMetadata.requiredValue == upstreamValue)

        #expect(onePercent == Decimal(string: "0.01"))
        #expect(ninetyFivePercent == Decimal(string: "0.95"))
        #expect(upstreamValue == Decimal(string: "1.390625"))

        // The ceiling is a rate, not a percentage: one hundredth, not one.
        #expect(onePercent * 100 == 1)
    }

    @Test("The half-width floor is at exactly 0.131, not merely below it")
    func halfWidthFloorSitsAtTheLiteral() throws {
        // Requirement 5.7 states a minimum, so the interesting values are the floor itself
        // and the nearest representable value below it. Accepting the first and refusing
        // the second places the floor at exactly 0.131: `nextDown` is the smallest step
        // that exists, and the step is reversible, so no legal half-width lies between the
        // refused value and the accepted one.
        let floor = CategoryBoundary.minimumAbstentionHalfWidth
        #expect(floor == 0.131)
        #expect(floor.nextDown < floor)
        #expect(floor.nextDown.nextUp == floor)

        let atFloor = try Sample.boundary(position: 0, halfWidth: floor)
        #expect(atFloor.abstentionHalfWidth == 0.131)

        #expect(throws: ArtifactSchemaError.self) {
            try Sample.boundary(position: 0, halfWidth: floor.nextDown)
        }
        // A width above the floor is accepted, so the refusal is about the floor rather
        // than about the field. This one is a synthetic width, not an approved one.
        #expect(try Sample.boundary(position: 0, halfWidth: 0.25).abstentionHalfWidth == 0.25)
    }
}

// MARK: - boundary - h, boundary, boundary + h

/// One band whose three literal positions are exactly representable in binary.
///
/// Stated as literals rather than derived, which is the whole point: the expected edges are
/// written out and then compared against the edges ``CategoryBoundary`` computed, so an
/// arithmetic change on either side is a failure instead of two expressions agreeing.
private struct LiteralBand {
    let position: Double
    let halfWidth: Double
    let expectedLowerEdge: Double
    let expectedUpperEdge: Double
    let what: String
}

@Suite("Exact abstention band edges")
struct ExactAbstentionBandEdgeTests {

    /// Four bands. The first two carry the fixed 0.131 floor; the other two carry synthetic
    /// widths above it, at a positive and a negative position, so the band is shown to
    /// centre on wherever the boundary sits rather than on zero.
    fileprivate static let bands: [LiteralBand] = [
        LiteralBand(
            position: 0,
            halfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
            expectedLowerEdge: -0.131,
            expectedUpperEdge: 0.131,
            what: "the 0.131 floor around zero"
        ),
        LiteralBand(
            position: 0.131,
            halfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
            expectedLowerEdge: 0,
            expectedUpperEdge: 0.262,
            what: "the 0.131 floor with its lower edge at zero"
        ),
        LiteralBand(
            position: 2.5,
            halfWidth: 0.25,
            expectedLowerEdge: 2.25,
            expectedUpperEdge: 2.75,
            what: "a synthetic width at a positive position"
        ),
        LiteralBand(
            position: -2.5,
            halfWidth: 0.5,
            expectedLowerEdge: -3,
            expectedUpperEdge: -2,
            what: "a synthetic width at a negative position"
        ),
    ]

    @Test("A band's edges are exactly boundary minus and plus the half-width")
    func edgesAreTheExactLiterals() throws {
        // Requirement 5.7's half-width and Requirement 5.8's closed interval
        // `[boundary - h, boundary + h]`, as arithmetic. Each expected edge is a literal;
        // every position and width here is exactly representable, so an edge is an exact
        // decimal rather than something a tolerance would have to hide.
        for band in Self.bands {
            let boundary = try Sample.boundary(position: band.position, halfWidth: band.halfWidth)

            #expect(boundary.rawLogitBoundary == band.position, "\(band.what)")
            #expect(boundary.abstentionHalfWidth == band.halfWidth, "\(band.what)")
            #expect(boundary.abstentionLowerBound == band.expectedLowerEdge, "\(band.what)")
            #expect(boundary.abstentionUpperBound == band.expectedUpperEdge, "\(band.what)")

            // The band is exactly two half-widths wide, and the boundary is exactly its
            // midpoint. Both hold as exact equalities for these positions.
            #expect(
                boundary.abstentionUpperBound - boundary.abstentionLowerBound
                    == band.halfWidth + band.halfWidth,
                "\(band.what)"
            )
            #expect(
                boundary.abstentionLowerBound < band.position
                    && band.position < boundary.abstentionUpperBound,
                "\(band.what)"
            )
        }
    }

    @Test("boundary minus h, boundary, and boundary plus h all abstain")
    func closedBandIncludesAllThreeExactPositions() throws {
        // Requirement 5.8: the interval is closed, so all three of these exact values
        // return the Insufficient Evidence Outcome. The three literals are asserted to be
        // the stored edges first, so the evaluation below is at the positions this test
        // claims rather than at whatever the arithmetic produced.
        //
        // Requirement 5.10 at the same positions: the outcome is compared both against the
        // literal label and against the insufficient label the policy itself carries, so the
        // abstention is shown to come from the band rule encoded in the session-bound policy
        // rather than from a label this test chose. Each position is evaluated twice, which
        // is where Requirement 5.4's "deterministic rules" bites at an exact edge — a
        // comparison sensitive to the last bit would be the place a repeat could disagree.
        for band in Self.bands {
            let boundary = try Sample.boundary(position: band.position, halfWidth: band.halfWidth)
            let evaluator = try Sample.evaluator(boundaries: [boundary])
            let quality = try #require(Sample.qualityRecord())

            let policyOutcome = evaluator.activatedPolicy.policy
                .belowMinimumShortEdgeLabel
                .pixelEvidence
            #expect(policyOutcome == .notEnoughSignal)
            #expect(evaluator.insufficientOutcome == policyOutcome)

            let insideBand: [(Double, String)] = [
                (band.expectedLowerEdge, "boundary - h"),
                (band.position, "boundary"),
                (band.expectedUpperEdge, "boundary + h"),
            ]
            for (logit, position) in insideBand {
                let first = try label(evaluator, logit: logit, quality: quality)
                #expect(
                    first == .notEnoughSignal,
                    "\(position) = \(logit) did not abstain [\(band.what)]"
                )
                #expect(
                    first == policyOutcome,
                    "\(position) = \(logit) abstained with a label the policy does not carry"
                )
                #expect(
                    try label(evaluator, logit: logit, quality: quality) == first,
                    "\(position) = \(logit) did not evaluate repeatably [\(band.what)]"
                )
            }
        }
    }

    @Test("The nearest value outside either edge is decisive")
    func nearestValuesOutsideTheBandDecide() throws {
        // The other half of "closed": one unit in the last place outside each edge takes
        // that side's decisive label. Stepping by the minimum representable amount, and
        // asserting the step is reversible, is what makes the closure exact — there is no
        // representable value between the decisive point and the abstaining edge, so the
        // band cannot be one step wider or narrower than claimed.
        for band in Self.bands {
            let boundary = try Sample.boundary(position: band.position, halfWidth: band.halfWidth)
            let evaluator = try Sample.evaluator(boundaries: [boundary])
            let quality = try #require(Sample.qualityRecord())

            let justBelow = boundary.abstentionLowerBound.nextDown
            let justAbove = boundary.abstentionUpperBound.nextUp
            #expect(justBelow.nextUp == boundary.abstentionLowerBound, "\(band.what)")
            #expect(justAbove.nextDown == boundary.abstentionUpperBound, "\(band.what)")
            #expect(justBelow == band.expectedLowerEdge.nextDown, "\(band.what)")
            #expect(justAbove == band.expectedUpperEdge.nextUp, "\(band.what)")

            #expect(
                try label(evaluator, logit: justBelow, quality: quality)
                    == boundary.lowerDecision.pixelEvidence,
                "the value just below boundary - h was not decisive [\(band.what)]"
            )
            #expect(
                try label(evaluator, logit: justAbove, quality: quality)
                    == boundary.upperDecision.pixelEvidence,
                "the value just above boundary + h was not decisive [\(band.what)]"
            )
        }
    }

    @Test("The upstream 1.390625 value is mapped by the policy, not by itself")
    func upstreamValueIsNotAProductBoundary() throws {
        // Requirement 5.14 records `1.390625` as model metadata rather than a product
        // verdict boundary, and Requirement 5.4 maps a finite logit using the policy's own
        // rules. The value is exactly representable in binary, so it can be evaluated as an
        // exact literal: two policies whose bands sit on opposite sides of it give it two
        // different decisive labels, and neither abstains. A build that had quietly adopted
        // the upstream number as a boundary would abstain on at least one of them.
        let upstreamLogit = 1.390625
        #expect(Decimal(string: "1.390625") == UpstreamBoundaryMetadata.requiredValue)

        let below = try Sample.boundary(position: 0, halfWidth: 0.25)
        let above = try Sample.boundary(position: 2.5, halfWidth: 0.25)
        #expect(below.abstentionUpperBound < upstreamLogit)
        #expect(upstreamLogit < above.abstentionLowerBound)

        let quality = try #require(Sample.qualityRecord())
        #expect(
            try label(try Sample.evaluator(boundaries: [below]), logit: upstreamLogit,
                quality: quality) == below.upperDecision.pixelEvidence
        )
        #expect(
            try label(try Sample.evaluator(boundaries: [above]), logit: upstreamLogit,
                quality: quality) == above.lowerDecision.pixelEvidence
        )
        #expect(below.upperDecision != above.lowerDecision)
    }
}

// MARK: - Short edges 0, 1, 439, 440

@Suite("Exact short-edge examples")
struct ExactShortEdgeExampleTests {

    /// A logit a whole unit above the band, so every abstention below comes from the
    /// recorded short edge rather than from the closed band.
    static let decisiveLogit = 1.0

    /// One boundary at zero with the fixed floor, whose band is exactly `[-0.131, 0.131]`.
    static func boundary() throws -> CategoryBoundary {
        try Sample.boundary(
            position: 0,
            halfWidth: CategoryBoundary.minimumAbstentionHalfWidth
        )
    }

    @Test("Short edges 1 and 439 abstain, and 440 is decisive")
    func shortEdgeLiteralsSelectTheirOutcomes() throws {
        // Requirement 5.9: a recorded short edge from 1 through 439 pixels inclusive
        // returns the Insufficient Evidence Outcome. 440 is the first length that does not,
        // so these four evaluations are the rule's two endpoints and its two neighbours.
        let boundary = try Self.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        let decisiveLabel = boundary.upperDecision.pixelEvidence
        #expect(evaluator.activatedPolicy.policy.minimumShortEdge == 440)
        #expect(decisiveLabel != .notEnoughSignal)

        let expected: [(Int, PixelEvidence, String)] = [
            (1, .notEnoughSignal, "the smallest length Requirement 5.9 abstains for"),
            (439, .notEnoughSignal, "the largest length Requirement 5.9 abstains for"),
            (440, decisiveLabel, "the first length that leaves the logit deciding"),
            (441, decisiveLabel, "one above the minimum"),
        ]
        for (shortEdge, outcome, what) in expected {
            let quality = try #require(Sample.qualityRecord(width: 900, height: shortEdge))
            #expect(quality.shortEdgeBeforeOrientation == shortEdge, "\(what)")
            #expect(
                try label(evaluator, logit: Self.decisiveLogit, quality: quality) == outcome,
                "short edge \(shortEdge): \(what)"
            )

            // The rule reads the lesser dimension, not the height field: swapping the two
            // recorded dimensions records the same short edge and reaches the same outcome.
            let swapped = try #require(Sample.qualityRecord(width: shortEdge, height: 900))
            #expect(swapped.shortEdgeBeforeOrientation == shortEdge, "\(what)")
            #expect(
                try label(evaluator, logit: Self.decisiveLogit, quality: swapped) == outcome,
                "short edge \(shortEdge) swapped: \(what)"
            )
        }
    }

    @Test("A short edge of 0 is an invalid measurement, never the smallest valid one")
    func zeroShortEdgeIsRefusedTwice() throws {
        // Requirement 5.9's range starts at 1, so 0 is not a length a decoded image has.
        // Requirement 5.25 governs it: a required quality value that is invalid and covered
        // by no approved abstention rule returns `calibration-input-error` with no Pixel
        // Evidence. Both locks are exercised, because either one alone would let 0 read as
        // "small" or as "unmeasured".
        //
        // First lock: the record refuses a nonpositive dimension, so a 0 never reaches the
        // evaluator through a constructed record at all.
        #expect(Sample.qualityRecord(width: 900, height: 0) == nil)
        #expect(Sample.qualityRecord(width: 0, height: 900) == nil)
        #expect(Sample.qualityRecord(width: 0, height: 0) == nil)

        // Second lock: the short-edge rule itself. 0 and a negative length are input
        // errors, 1 and 439 abstain, 440 leaves the logit deciding.
        let minimum = CalibrationPolicy.requiredMinimumShortEdge
        func verdict(_ shortEdge: Int?) -> CalibrationEvaluator.QualityVerdict {
            CalibrationEvaluator.shortEdgeVerdict(shortEdge, minimumShortEdge: minimum)
        }
        #expect(verdict(0) == .inputError)
        #expect(verdict(-1) == .inputError)
        #expect(verdict(1) == .abstain)
        #expect(verdict(439) == .abstain)
        #expect(verdict(440) == .logitDecides)

        // Absent is the third reading 0 must not be confused with, and it is also the
        // input error: an unmeasured short edge is not a large one.
        let unmeasured = try #require(Sample.qualityRecord(width: nil, height: nil))
        #expect(unmeasured.shortEdgeBeforeOrientation == nil)
        #expect(verdict(nil) == .inputError)
        try refuses(
            try Sample.evaluator(boundaries: [try Self.boundary()]),
            logit: Self.decisiveLogit,
            quality: unmeasured,
            with: .analysis(.calibrationInputError, stage: .calibration)
        )
    }

    @Test("A sub-440 short edge abstains even where the logit is deep inside a decision")
    func shortEdgeAbstentionOverridesEveryDecisiveLogit() throws {
        // Requirement 5.9 is unconditional in the logit, so the abstention at 439 is not an
        // artifact of the one decisive value used above. The extreme finite values are
        // included because they are the furthest a logit can be from any band.
        let boundary = try Self.boundary()
        let evaluator = try Sample.evaluator(boundaries: [boundary])
        let abstaining = try #require(Sample.qualityRecord(width: 900, height: 439))
        let deciding = try #require(Sample.qualityRecord(width: 900, height: 440))

        let logits: [Double] = [
            -.greatestFiniteMagnitude,
            boundary.abstentionLowerBound.nextDown,
            boundary.rawLogitBoundary,
            boundary.abstentionUpperBound.nextUp,
            .greatestFiniteMagnitude,
        ]
        for logit in logits {
            #expect(
                try label(evaluator, logit: logit, quality: abstaining) == .notEnoughSignal,
                "short edge 439 did not abstain at \(logit)"
            )
        }

        // The control: at 440 the same five logits are decided by the schedule, and the
        // three outside the band are not the insufficient outcome.
        for logit in [logits[0], logits[1]] {
            #expect(
                try label(evaluator, logit: logit, quality: deciding)
                    == boundary.lowerDecision.pixelEvidence
            )
        }
        #expect(
            try label(evaluator, logit: boundary.rawLogitBoundary, quality: deciding)
                == .notEnoughSignal
        )
        for logit in [logits[3], logits[4]] {
            #expect(
                try label(evaluator, logit: logit, quality: deciding)
                    == boundary.upperDecision.pixelEvidence
            )
        }
    }
}

// MARK: - Nonfinite input

@Suite("Nonfinite raw-logit rejection")
struct NonfiniteRawLogitExampleTests {

    /// Every nonfinite `Double` a model output could carry.
    static let nonfinite: [(Double, String)] = [
        (.nan, "NaN"),
        (.signalingNaN, "a signaling NaN"),
        (.infinity, "positive infinity"),
        (-.infinity, "negative infinity"),
    ]

    @Test("No nonfinite value can be carried as a raw logit at all")
    func nonfiniteValuesAreUnrepresentable() {
        // The first lock, and the reason the mapping can be stated over finite logits:
        // `RawLogit` refuses a nonfinite value, so no calibration path can receive one.
        for (value, what) in Self.nonfinite {
            #expect(RawLogit(value) == nil, "\(what) was representable as a raw logit")
        }
        // The control: the extreme finite values are representable, so the refusal is about
        // finiteness rather than about magnitude.
        for value: Double in [-.greatestFiniteMagnitude, 0, .greatestFiniteMagnitude] {
            #expect(RawLogit(value)?.value == value)
        }
    }

    @Test("A nonfinite value reaching calibration is an invalid output, never a label")
    func nonfiniteValueIsRefusedAtCalibration() throws {
        // The second lock. Requirement 4.16 forbids mapping a nonfinite output to a label,
        // and the category stays `invalid-output-error` because that is what the value is;
        // the stage is `calibration` because that is where this check caught it.
        let evaluator = try Sample.evaluator(
            boundaries: [
                try Sample.boundary(
                    position: 0,
                    halfWidth: CategoryBoundary.minimumAbstentionHalfWidth
                )
            ]
        )
        let quality = try #require(Sample.qualityRecord())

        for (value, what) in Self.nonfinite {
            #expect(
                throws: AnalysisFault.analysis(.invalidOutputError, stage: .calibration),
                "\(what) did not produce the invalid-output error"
            ) {
                try evaluator.label(forRawLogit: value, quality: quality)
            }
        }

        // The control: the extreme finite values still reach a label, one on each side.
        #expect(
            try evaluator.label(forRawLogit: -.greatestFiniteMagnitude, quality: quality)
                == .noStrongSignalDetected
        )
        #expect(
            try evaluator.label(forRawLogit: .greatestFiniteMagnitude, quality: quality)
                == .signalsConsistentWithAIGeneration
        )
    }

    @Test("Without the refusal a NaN would emerge as the label above the last band")
    func nonfiniteValueWouldOtherwiseFallThroughTheSchedule() throws {
        // Why the second lock is not redundant, pinned rather than described. Every IEEE
        // comparison against NaN is false, so a NaN passes every band check in the schedule
        // walk and leaves it carrying the label above the last boundary — a positive
        // verdict from an output that carried no value. Positive infinity does the same.
        //
        // The walk is exercised directly because that is the only way to observe what the
        // explicit refusal prevents; through the port neither value is representable.
        let boundary = try Sample.boundary(
            position: 0,
            halfWidth: CategoryBoundary.minimumAbstentionHalfWidth
        )
        let topLabel = boundary.upperDecision.pixelEvidence
        #expect(topLabel == .signalsConsistentWithAIGeneration)

        for value: Double in [.nan, .signalingNaN, .infinity] {
            #expect(
                CalibrationEvaluator.label(
                    forFiniteLogit: value,
                    boundaries: [boundary],
                    insufficientOutcome: .notEnoughSignal
                ) == topLabel,
                "the schedule walk no longer carries \(value) to the top label"
            )
        }
        // Negative infinity compares below the lower edge, so it lands on the bottom label
        // rather than the top one. It is refused for the same reason: neither label
        // describes an output that was never a number.
        #expect(
            CalibrationEvaluator.label(
                forFiniteLogit: -.infinity,
                boundaries: [boundary],
                insufficientOutcome: .notEnoughSignal
            ) == boundary.lowerDecision.pixelEvidence
        )
    }
}

// MARK: - Representative metric denominators

@Suite("Representative release-slice denominators")
struct RepresentativeMetricDenominatorTests {

    /// One synthetic slice roster, written as literals.
    ///
    /// Chosen so that the abstentions decide the budget outcome at the 1% ceiling:
    /// 2 positive labels in 200 eligible real images is exactly 1%, and the same 2 over the
    /// 100 decisive real images alone is 2%. Every count is synthetic; none of them is a
    /// measured release result.
    static func counts() throws -> SliceOutcomeCounts {
        try Sample.sliceCounts(
            realPositive: 2,
            realNonPositive: 98,
            realInsufficient: 100,
            syntheticPositive: 30,
            syntheticNonPositive: 10,
            syntheticInsufficient: 60,
            errors: 0
        )
    }

    @Test("Each denominator is the whole eligible population, abstentions included")
    func denominatorsAreTheEligiblePopulations() throws {
        // Requirements 5.16, 5.17, and 5.18 at one representative roster, with every
        // numerator and denominator written out. The three denominators are 200, 100, and
        // 300 — the eligible real, eligible synthetic, and pooled eligible populations —
        // and each one includes the images that abstained.
        let counts = try Self.counts()
        let measurement = try Sample.measurement(counts: counts)

        #expect(counts.eligibleRealImages.value == 200)
        #expect(counts.eligibleSyntheticImages.value == 100)
        #expect(counts.eligibleImageCount == 300)
        #expect(counts.decisiveLabelCount == 140)

        #expect(measurement.falsePositiveRate == (try rate(2, over: 200)))
        #expect(measurement.truePositiveRate == (try rate(30, over: 100)))
        #expect(measurement.coverage == (try rate(140, over: 300)))

        // Requirement 5.18 excludes the abstentions from coverage's numerator only, so the
        // gap between the two is exactly the two recorded insufficient counts.
        #expect(measurement.insufficientOutcomeCount == 160)
        #expect(
            counts.realInsufficientLabels.value + counts.syntheticInsufficientLabels.value == 160
        )

        // Requirement 5.19's predeclared level travels with the reported interval.
        #expect(
            measurement.falsePositiveRateInterval.confidenceLevel.value
                == FalseAccusationPassRule.requiredConfidenceLevel
        )
        #expect(measurement.falsePositiveRateInterval.confidenceLevel.value.description == "0.95")
    }

    @Test("Dropping the abstentions doubles this slice's false-positive rate")
    func abstentionsInTheDenominatorDecideTheBudgetOutcome() throws {
        // The arithmetic that makes Requirement 5.16's denominator matter. Against the 1%
        // ceiling: 2/200 is exactly 1% and satisfies it, while the same 2 positives over
        // the 100 decisive real images is 2% and does not. So this slice passes or fails on
        // whether an abstaining real image stays in the denominator.
        //
        // The budget used is the ceiling Requirement 5.1 fixes, not an approved budget.
        let ceiling = try Sample.onePercentBudget()
        #expect(ceiling.rate == FalseAccusationBudget.maximumRate)
        #expect(ceiling.rate == Decimal(string: "0.01"))

        let measurement = try Sample.measurement(counts: try Self.counts(), budget: ceiling)
        let honest = try #require(measurement.falsePositiveRate)
        #expect(honest == (try rate(2, over: 200)))
        #expect(honest.description == "2/200")
        #expect(honest.isAtMost(ceiling.rate))
        #expect(measurement.budgetOutcome == .evaluated(.passed))

        let abstentionsDropped = try rate(2, over: 100)
        #expect(abstentionsDropped != honest)
        #expect(!abstentionsDropped.isAtMost(ceiling.rate))

        // The comparison is not simply lenient: one more positive label in the same
        // eligible population is 1.5% and fails, so equality at 1% passing is the boundary
        // Requirement 5.22 draws rather than a rounding artifact.
        #expect(!(try rate(3, over: 200)).isAtMost(ceiling.rate))
        #expect((try rate(1, over: 200)).isAtMost(ceiling.rate))
    }

    @Test("Dropping the abstentions from coverage would report complete coverage")
    func abstentionsInTheCoverageDenominatorDecideWhatIsReported() throws {
        // Requirement 5.18's denominator is every eligible image. This roster has 140
        // decisive labels among 300 eligible images, so honest coverage is 140/300. Taken
        // over the decisive labels alone it would be 140/140 — a slice that abstained on
        // 160 of 300 images reported as one that decided every one of them.
        let measurement = try Sample.measurement(counts: try Self.counts())
        let honest = measurement.coverage
        #expect(honest == (try rate(140, over: 300)))
        #expect(honest.description == "140/300")
        #expect(!honest.isOne)
        #expect(!honest.isZero)

        let abstentionsDropped = try rate(140, over: 140)
        #expect(abstentionsDropped.isOne)
        #expect(abstentionsDropped != honest)
    }

    @Test("A true-positive rate is taken over the eligible synthetic population")
    func truePositiveDenominatorIsTheEligibleSyntheticPopulation() throws {
        // Requirement 5.17, at the same roster. 30 of 100 eligible synthetic images carry
        // the positive label; 60 of them abstained and stay in the denominator. Over the
        // 40 decisive synthetic images alone the same numerator reads 30/40, which would
        // report a detector that found three quarters of the synthetic images it was shown
        // instead of under a third.
        let counts = try Self.counts()
        let measurement = try Sample.measurement(counts: counts)
        let honest = try #require(measurement.truePositiveRate)

        #expect(honest == (try rate(30, over: 100)))
        #expect(honest.denominator.value == counts.eligibleSyntheticImages.value)
        #expect(honest.denominator.value == 100)

        let abstentionsDropped = try rate(30, over: 40)
        #expect(abstentionsDropped != honest)
        #expect(
            counts.syntheticPositiveLabels.value + counts.syntheticNonPositiveLabels.value == 40
        )
    }
}

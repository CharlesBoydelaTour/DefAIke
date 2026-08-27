import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 16: Calibration is total, deterministic, and quality-aware.
//
// The design states it as: for any finite raw logit and any Input Quality Record,
// repeated evaluation under one valid Calibration Policy returns the same single
// outcome; short edges from 1 through 439 and logits on or inside every closed
// abstention band return the insufficient outcome, every other insufficient result cites
// a matching policy rule, explicitly covered missing quality values abstain, and
// uncovered missing or invalid required values return only `calibration-input-error`
// with no Pixel Evidence.
//
// Quantified here as one property with seven arms over every generated shape. The three
// claims in the title map onto them as follows.
//
// **Total.** Arm 1 evaluates every generated logit site against five record shapes and
// requires each evaluation to land on exactly one of four representable outcomes — one of
// the three fixed labels, or the one `calibration-input-error` — and never on a fifth, a
// second, or nothing. It also requires that a record whose every required value is
// present and usable always reaches a *label*: no valid input falls through to a fault.
//
// **Deterministic.** Arm 2 re-evaluates each site four times and compares, then compares
// against a second evaluator built from the same policy content with its quality rules
// and required-feature set assembled in the opposite order. `requiredQualityFeatures` is
// a `Set`, whose iteration order is not stable across processes, so an evaluator that
// returned the first verdict it met rather than combining verdicts under a fixed
// precedence would disagree between the two.
//
// **Quality-aware.** Arm 3 walks each closed band: its two edges and the boundary itself
// abstain, and one unit in the last place outside either edge is decisive (Requirement
// 5.8). Arm 4 varies the recorded short edge across the policy's declared minimum
// (Requirement 5.9) and leaves it unmeasured. Arm 5 states a rule for a missing value and
// gets abstention (Requirement 5.24). Arm 6 leaves a required value uncovered and gets the
// input error with no Pixel Evidence, even when two abstention conditions fire at the same
// time (Requirement 5.25). Arm 7 is the attribution check for Requirements 5.4 and 5.10:
// the outcome for the generated logit and record equals the one derived independently
// from the policy's own fields, so every insufficient result cites a band, the short-edge
// rule, or a matched quality rule, and every decisive result cites none of them.
//
// `CalibrationEvaluationTests` pins individual mappings at one example each. This file
// quantifies the same statement over generated shapes. Task 7.9 owns the literal example
// tests — exact boundary-minus-half-width, boundary, boundary-plus-half-width, short edges
// 0, 1, 439, and 440, and nonfinite rejection — so no arm here restates one of those
// numbers: every expectation is written against the policy's own `minimumShortEdge`,
// `abstentionLowerBound`, `rawLogitBoundary`, and `abstentionUpperBound`. The neighbouring
// calibration properties belong to their own tasks: Property 15 is policy validity,
// Property 17 is release metric semantics, and Property 18 is release-approval evidence.
//
// ## Why nothing here is serialized
//
// This property turns on exact positions: a band is closed at `boundary - h` and
// `boundary + h`, the half-width floor is 0.131, and a threshold comparison is an exact
// decimal one. `JSONSerialization` perturbs exact decimals, so an assertion built on a
// serializer round trip would hold whether or not the value under test survived it. Every
// artifact here is therefore constructed as a typed value and every band edge is read back
// from the ``CategoryBoundary`` that owns it rather than recomputed as `position ± h`, so
// the number the assertion uses is the number the evaluator compares against. Where an arm
// needs a point just outside a band it steps one unit in the last place from that stored
// edge, and arm 3 asserts that adjacent bands are genuinely disjoint before relying on the
// region between them.
//
// ## Why no arm throws
//
// `propertyCheck` discards an error thrown from its body: a `throw` before the assertions
// makes the whole run pass in milliseconds with every arm skipped. Every evaluation here
// therefore goes through ``CalibrationEvaluationScenario/outcome(logit:quality:)``, which
// turns a refusal into an ``EvaluationOutcome`` value, and every helper reports through
// `Issue.record`. ``CalibrationEvaluationVariationWitness`` counts the cases and the arms
// that completed and asserts those counts *outside* the body, where an issue is not
// suppressed, so a body that stopped early is visible rather than silent.
//
// No value in this file is an approved budget, boundary, half-width, threshold, quality
// feature, evidence record, or model. Every number is generated from a synthetic range,
// every identifier carries the generated seed, and the fixed values the arms read —
// the 0.131 half-width floor and the 440 minimum short edge — are read from the schema
// constants that own them.

extension Tag {
    /// Design Property 16.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property16CalibrationTotality: Self
}

@Suite(
    "Property 16: Calibration is total, deterministic, and quality-aware",
    .tags(.property16CalibrationTotality)
)
struct CalibrationTotalityPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 5.4, 5.8, 5.9, 5.10, 5.24, 5.25**
    @Test("Evaluation is total, deterministic, and quality-aware over generated inputs")
    func calibrationIsTotalDeterministicAndQualityAware() async {
        let witness = CalibrationEvaluationVariationWitness()

        await propertyCheck(input: EvaluationShape.generator) { shape in
            witness.record(shape)
            guard let scenario = CalibrationEvaluationScenario(shape: shape, witness: witness)
            else { return }

            scenario.checkEveryInputReachesExactlyOneOutcome()
            scenario.checkRepeatedEvaluationAgrees()
            scenario.checkClosedBandsAbstainAndTheirOutsidesDecide()
            scenario.checkRecordedShortEdgeGovernsAbstention()
            scenario.checkCoveredMissingValueAbstains()
            scenario.checkUncoveredRequiredValueYieldsOnlyTheInputError()
            scenario.checkOutcomeMatchesTheRuleItCites()

            witness.recordCompletedArms()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// One generated category-changing boundary and its closed abstention band, as plain data.
///
/// The half-width is an offset above the fixed 0.131 minimum rather than an absolute
/// number, so an offset of zero generates the minimum itself. The gap is the clearance
/// beyond the two adjacent half-widths, and it is never zero: touching bands leave the
/// decisive region between two boundaries empty, which would make every assertion about
/// that region hold vacuously.
private struct BandShape: Sendable {
    /// Thousandths of a raw-logit unit above ``CategoryBoundary/minimumAbstentionHalfWidth``.
    let halfWidthOffsetThousandths: Int

    /// Thousandths of a raw-logit unit of clearance from the previous band.
    let gapThousandths: Int
}

/// What the generated Input Quality Record carries for one required feature.
///
/// Three disjoint recordings, so the observation each one produces is known from the shape
/// rather than re-derived from the evaluator's own reading of the record.
private enum FeatureRecording: Int, CaseIterable, Sendable {
    /// No entry for the feature at all.
    case absent
    /// An exact measured count.
    case measured
    /// A recorded condition, which carries no comparable magnitude.
    case condition
}

/// What the generated record carries for the pre-orientation short edge.
private enum ShortEdgeRecording: Int, CaseIterable, Sendable {
    /// No dimensions were recorded, so no short edge exists.
    case unmeasured
    /// A short edge from 1 up to one below the policy's declared minimum.
    case belowMinimum
    /// A short edge at or above the policy's declared minimum.
    case atOrAboveMinimum
}

/// One place on the finite logit line, relative to the generated schedule.
///
/// Every case is evaluated in every generated case rather than one being drawn per case:
/// a single drawn index would leave coverage of the sites to the generator's distribution,
/// and the arms that matter most are the ones at a band edge.
private enum LogitSite: Int, CaseIterable, Sendable {
    /// One unit in the last place below the selected band's stored lower edge.
    case justBelowSelectedBand
    /// The selected band's stored lower edge, which the closed band includes.
    case selectedBandLowerEdge
    /// The selected boundary itself.
    case selectedBoundary
    /// A generated point inside the selected band.
    case insideSelectedBand
    /// The selected band's stored upper edge, which the closed band includes.
    case selectedBandUpperEdge
    /// One unit in the last place above the selected band's stored upper edge.
    case justAboveSelectedBand
    /// Well below every band in the schedule.
    case belowEveryBand
    /// Well above every band in the schedule.
    case aboveEveryBand
    /// The most negative finite value a `Double` represents.
    case leastFiniteValue
    /// The largest finite value a `Double` represents.
    case greatestFiniteValue
}

/// Everything the calibration evaluator reads, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside
/// ``CalibrationEvaluationScenario``, where a construction that unexpectedly throws is
/// recorded as a failure rather than escaping.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant asserts one example a hundred times over, so
/// every dimension the arms depend on is generated:
///
///   * one to three chained boundaries, each with its own half-width at or above the 0.131
///     minimum and its own clearance from the previous band, positioned on both sides of
///     zero, and the direction of the decisive labels, so the same schedule appears both
///     ways round;
///   * which band the edge arms select, and where inside it the interior point falls;
///   * the measured-value threshold the quality rule compares against, the magnitude
///     recorded against it, and whether the policy also states an unusable-value rule;
///   * what the record carries for each of the two required features, over all three
///     recordings;
///   * whether the short edge is unmeasured, below the declared minimum, or at or above
///     it, with a generated length in each case and a generated long edge, so the rule is
///     shown to read the short edge rather than either dimension;
///   * every identifier, version, and content digest, from ``seed``.
///
/// ``CalibrationEvaluationVariationWitness`` checks after the run that this happened, and
/// additionally that all three labels and the input error were each actually produced.
private struct EvaluationShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, version, and digest, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    let seed: Int

    /// Thousandths of a raw-logit unit for the first boundary's position, signed so
    /// boundaries land on both sides of zero.
    let firstPositionThousandths: Int

    let bandShapes: [BandShape]

    /// Whether the non-positive label sits below the first boundary or above it.
    let nonPositiveBelowFirstBoundary: Bool

    /// Selects the band the edge arms walk from.
    let bandSelector: Int

    /// Hundredths of the way across the selected band, for the interior point.
    let bandFractionHundredths: Int

    /// Hundredths of the measured-value threshold an abstention rule matches at or below.
    let thresholdHundredths: Int

    /// Whether the threshold feature also carries an unusable-value rule that names the
    /// input error.
    let carriesInvalidValueRule: Bool

    let coveredRecording: FeatureRecording
    let thresholdRecording: FeatureRecording

    /// The magnitude a measured recording carries. Straddles the generated threshold, so
    /// both sides of the rule occur.
    let measuredMagnitude: Int

    let shortEdgeRecording: ShortEdgeRecording

    /// A short edge from 1 up to one below the fixed minimum.
    let belowMinimumShortEdge: Int

    /// A short edge at or above the fixed minimum.
    let atOrAboveMinimumShortEdge: Int

    /// How much longer the other recorded dimension is than the short edge.
    let longEdgeExcess: Int

    var description: String {
        """
        seed \(seed), \(bandShapes.count) band(s) at \(boundaryPositions), threshold \
        \(threshold), covered \(coveredRecording), threshold-feature \
        \(thresholdRecording), short edge \(shortEdgeRecording)
        """
    }

    // MARK: Derived values

    /// The half-width of band `index`, at or above the fixed 0.131 minimum.
    func halfWidth(_ index: Int) -> Double {
        CategoryBoundary.minimumAbstentionHalfWidth
            + Double(bandShapes[index].halfWidthOffsetThousandths) / 1_000
    }

    /// The boundary positions, ascending, each separated from the previous by both
    /// half-widths plus a nonzero clearance so the closed bands stay disjoint.
    var boundaryPositions: [Double] {
        var positions: [Double] = []
        var position = Double(firstPositionThousandths) / 1_000
        for index in bandShapes.indices {
            if index > 0 {
                position += halfWidth(index - 1) + halfWidth(index)
                    + Double(bandShapes[index].gapThousandths) / 1_000
            }
            positions.append(position)
        }
        return positions
    }

    /// The decisive label `index` regions from the bottom up, alternating so adjacent
    /// boundaries agree about the region they share.
    ///
    /// The insufficient outcome is excluded: it comes from a band, the short-edge rule, or
    /// an evidenced quality rule, never from a decisive region, and activation rejects a
    /// schedule that names it on either side of a boundary.
    func decisiveLabel(_ index: Int) -> PixelLabelKey {
        let decisive: [PixelLabelKey] = [
            .noStrongSignalDetected,
            .signalsConsistentWithAIGeneration,
        ]
        let base = nonPositiveBelowFirstBoundary ? 0 : 1
        return decisive[(base + index) % decisive.count]
    }

    /// The band the edge arms select.
    var selectedBand: Int { bandSelector % bandShapes.count }

    /// The measured-value threshold, as an exact decimal.
    var threshold: Decimal {
        Decimal(sign: .plus, exponent: -2, significand: Decimal(thresholdHundredths))
    }

    /// A magnitude strictly above ``threshold``, for a record that leaves the logit
    /// deciding.
    ///
    /// The threshold is `thresholdHundredths / 100`, and integer division truncates, so
    /// this is at least the next whole number above it for every generated threshold. It
    /// is derived rather than written as a constant so no arm depends on the generated
    /// range happening to stay below some number.
    var magnitudeAboveThreshold: Int { thresholdHundredths / 100 + 1 }

    // MARK: Generators

    static var generator: Generator<EvaluationShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: -3_000...3_000),
            bandShapes,
            Gen.bool,
            zip(Gen.int(in: 0...99), Gen.int(in: 0...100)),
            zip(Gen.int(in: 100...5_000), Gen.bool),
            featureShape,
            shortEdgeShape
        )
        .map { raw in
            EvaluationShape(
                seed: raw.0,
                firstPositionThousandths: raw.1,
                bandShapes: raw.2,
                nonPositiveBelowFirstBoundary: raw.3,
                bandSelector: raw.4.0,
                bandFractionHundredths: raw.4.1,
                thresholdHundredths: raw.5.0,
                carriesInvalidValueRule: raw.5.1,
                coveredRecording: recording(raw.6.0),
                thresholdRecording: recording(raw.6.1),
                measuredMagnitude: raw.6.2,
                shortEdgeRecording: shortEdgeRecording(raw.7.0),
                belowMinimumShortEdge: raw.7.1,
                atOrAboveMinimumShortEdge: raw.7.2,
                longEdgeExcess: raw.7.3
            )
        }
        .eraseToAny()
    }

    private static var bandShapes: Generator<[BandShape], AnySequence<Any>> {
        zip(Gen.int(in: 0...500), Gen.int(in: 1...400))
            .map { BandShape(halfWidthOffsetThousandths: $0.0, gapThousandths: $0.1) }
            .array(of: 1...3)
            .eraseToAny()
    }

    /// The two feature recordings and the magnitude, generated together because the record
    /// is built from all three.
    private static var featureShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 0...29), Gen.int(in: 0...29), Gen.int(in: 1...60))
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }

    /// The short-edge recording, a length on each side of the fixed minimum, and the long
    /// edge's excess over the short one.
    ///
    /// The two length ranges are expressed against ``CalibrationPolicy/requiredMinimumShortEdge``
    /// rather than as literals, so neither range restates a number this file must not own.
    private static var shortEdgeShape: Generator<(Int, Int, Int, Int), AnySequence<Any>> {
        let minimum = CalibrationPolicy.requiredMinimumShortEdge
        return zip(
            Gen.int(in: 0...29),
            Gen.int(in: 1...(minimum - 1)),
            Gen.int(in: minimum...(minimum * 9)),
            Gen.int(in: 0...2_000)
        )
        .map { ($0.0, $0.1, $0.2, $0.3) }
        .eraseToAny()
    }

    private static func recording(_ raw: Int) -> FeatureRecording {
        FeatureRecording.allCases[raw % FeatureRecording.allCases.count]
    }

    private static func shortEdgeRecording(_ raw: Int) -> ShortEdgeRecording {
        ShortEdgeRecording.allCases[raw % ShortEdgeRecording.allCases.count]
    }
}

// MARK: - Outcomes

/// What one evaluation produced, as a value rather than as a thrown error.
///
/// `propertyCheck` discards an error thrown from its body, so a refusal has to arrive as
/// data. The four representable outcomes of the mapping are a label, the
/// `calibration-input-error` fault, some other fault, and a value the port would not carry
/// at all; the arms distinguish all four so that a wrong-category refusal is a failure
/// rather than an unexamined "did not return a label".
private enum EvaluationOutcome: Hashable, CustomStringConvertible {
    case label(PixelEvidence)
    case fault(AnalysisFault)
    /// The port refused the value. Every logit this property generates is finite, so this
    /// is a defect in the generator rather than in the evaluator.
    case unrepresentableLogit

    /// The Pixel Evidence this outcome carries, or `nil` when it carries none.
    ///
    /// Requirement 5.25 returns its error *without* Pixel Evidence, and this is what the
    /// arms assert that absence against.
    var label: PixelEvidence? {
        guard case .label(let evidence) = self else { return nil }
        return evidence
    }

    /// Whether this outcome is exactly the `calibration-input-error` raised at calibration.
    var isCalibrationInputError: Bool {
        self == .fault(.analysis(.calibrationInputError, stage: .calibration))
    }

    var description: String {
        switch self {
        case .label(let evidence): "label \(evidence.rawValue)"
        case .fault(let fault): "fault \(fault)"
        case .unrepresentableLogit: "unrepresentable logit"
        }
    }
}

/// What the policy provides for one record, derived from the shape and the policy's own
/// fields.
///
/// Ordered by how much it withholds, so combining the short-edge verdict with each
/// feature's verdict is independent of the order they are combined in — the same
/// precedence the evaluator states, derived here from the requirements rather than from the
/// evaluator's own type.
private enum ExpectedVerdict: Comparable {
    /// Nothing withholds a decision: the logit and the schedule decide.
    case logitDecides
    /// An abstention condition fired (Requirements 5.9 and 5.24).
    case abstains
    /// A required value is missing or invalid and no rule covers it, or a rule names the
    /// error for it (Requirement 5.25).
    case inputError
}

// MARK: - Scenario

/// Builds the activated policy one generated shape describes and evaluates logits and
/// records against it.
private struct CalibrationEvaluationScenario {
    let shape: EvaluationShape
    let witness: CalibrationEvaluationVariationWitness

    /// The evaluator under test.
    let evaluator: CalibrationEvaluator

    /// A second evaluator over the same policy content, assembled with its quality rules
    /// and required-feature set in the opposite order.
    ///
    /// Its policy is a different *value* from the first one, because the rule list is
    /// ordered, so it is evaluated against its own activated policy. What the comparison
    /// catches is an evaluator whose result depends on the order it visits rules or
    /// required features in.
    let reorderedEvaluator: CalibrationEvaluator

    /// The record the shape describes, whatever it describes.
    let generatedRecord: InputQualityRecord

    /// Every required value present and usable, and the short edge at or above the
    /// declared minimum, so the logit alone decides.
    let logitDecidingRecord: InputQualityRecord

    /// The covered feature absent — a condition the policy states an abstention rule for
    /// (Requirement 5.24) — with everything else usable.
    let coveredAbsentRecord: InputQualityRecord

    /// The threshold feature absent — a required value no rule covers (Requirement 5.25) —
    /// with everything else usable.
    let uncoveredAbsentRecord: InputQualityRecord

    /// The threshold feature present but carrying no comparable magnitude, which the
    /// policy's stated threshold cannot read.
    let unreadableValueRecord: InputQualityRecord

    /// No dimensions recorded at all, so the short edge the sub-minimum rule needs was
    /// never measured, with both features usable.
    let unmeasuredShortEdgeRecord: InputQualityRecord

    /// An uncovered required value *and* two abstention conditions at the same time: the
    /// threshold feature absent, the covered feature absent, and a short edge below the
    /// declared minimum.
    let uncoveredAndAbstainingRecord: InputQualityRecord

    init?(shape: EvaluationShape, witness: CalibrationEvaluationVariationWitness) {
        self.shape = shape
        self.witness = witness

        let builder = PolicyShapeBuilder(shape: shape)
        do {
            self.evaluator = CalibrationEvaluator(
                activatedWith: try builder.activatedPolicy(reversingRuleOrder: false)
            )
            self.reorderedEvaluator = CalibrationEvaluator(
                activatedWith: try builder.activatedPolicy(reversingRuleOrder: true)
            )
        } catch {
            Issue.record("a coherent generated calibration policy was refused: \(error) [\(shape)]")
            return nil
        }

        let usable = builder.usableFeatures
        let above = shape.atOrAboveMinimumShortEdge
        guard
            let generated = builder.record(
                shortEdge: builder.generatedShortEdge,
                features: builder.generatedFeatures
            ),
            let deciding = builder.record(shortEdge: above, features: usable),
            let coveredAbsent = builder.record(
                shortEdge: above,
                features: usable.removingValue(forKey: builder.coveredFeature)
            ),
            let uncoveredAbsent = builder.record(
                shortEdge: above,
                features: usable.removingValue(forKey: builder.thresholdFeature)
            ),
            let unreadable = builder.record(
                shortEdge: above,
                features: usable.replacingValue(
                    forKey: builder.thresholdFeature,
                    with: .boolean(true)
                )
            ),
            let unmeasured = builder.record(shortEdge: nil, features: usable),
            let uncoveredAndAbstaining = builder.record(
                shortEdge: shape.belowMinimumShortEdge,
                features: [:]
            )
        else {
            Issue.record("a generated Input Quality Record was not self-consistent [\(shape)]")
            return nil
        }
        self.generatedRecord = generated
        self.logitDecidingRecord = deciding
        self.coveredAbsentRecord = coveredAbsent
        self.uncoveredAbsentRecord = uncoveredAbsent
        self.unreadableValueRecord = unreadable
        self.unmeasuredShortEdgeRecord = unmeasured
        self.uncoveredAndAbstainingRecord = uncoveredAndAbstaining
    }

    // MARK: Reading the policy

    var policy: CalibrationPolicy { evaluator.activatedPolicy.policy }

    /// The generated schedule in ascending position order, sorted here rather than read
    /// from the activated policy so the arms do not lean on the production sort.
    var ascendingBoundaries: [CategoryBoundary] {
        policy.boundaries.sorted { $0.rawLogitBoundary < $1.rawLogitBoundary }
    }

    /// The band the edge arms walk from.
    var selectedBoundary: CategoryBoundary { ascendingBoundaries[shape.selectedBand] }

    /// The one insufficient outcome every abstention path returns, read from the policy.
    var insufficientOutcome: PixelEvidence {
        policy.belowMinimumShortEdgeLabel.pixelEvidence
    }

    /// The logit at one site.
    ///
    /// Every band edge is the value stored on the ``CategoryBoundary``, and a point outside
    /// a band is one unit in the last place from that stored edge: recomputing an edge as
    /// `position ± halfWidth` could land a step clear of the value the evaluator actually
    /// compares against and make the assertion vacuous.
    func logit(at site: LogitSite) -> Double {
        let boundary = selectedBoundary
        switch site {
        case .justBelowSelectedBand:
            return boundary.abstentionLowerBound.nextDown
        case .selectedBandLowerEdge:
            return boundary.abstentionLowerBound
        case .selectedBoundary:
            return boundary.rawLogitBoundary
        case .insideSelectedBand:
            // Derived from the two stored edges and clamped back into the closed band, so
            // rounding in the interpolation cannot carry the point outside the band it is
            // meant to be inside.
            let span = boundary.abstentionUpperBound - boundary.abstentionLowerBound
            let interior = boundary.abstentionLowerBound
                + span * Double(shape.bandFractionHundredths) / 100
            return min(max(interior, boundary.abstentionLowerBound), boundary.abstentionUpperBound)
        case .selectedBandUpperEdge:
            return boundary.abstentionUpperBound
        case .justAboveSelectedBand:
            return boundary.abstentionUpperBound.nextUp
        case .belowEveryBand:
            // A whole raw-logit unit clear of the outermost band, which is well beyond the
            // largest half-width the generator produces.
            return ascendingBoundaries[0].abstentionLowerBound - 1
        case .aboveEveryBand:
            return ascendingBoundaries[ascendingBoundaries.count - 1].abstentionUpperBound + 1
        case .leastFiniteValue:
            return -.greatestFiniteMagnitude
        case .greatestFiniteValue:
            return .greatestFiniteMagnitude
        }
    }

    // MARK: Evaluating

    /// The outcome of one evaluation through the calibration port, never a thrown error.
    ///
    /// Each evaluator is asked about the policy it was activated with, because a policy
    /// other than that one is a compatibility rejection rather than a mapping
    /// (Requirement 5.13), and this property is about the mapping.
    func outcome(
        logit: Double,
        quality: InputQualityRecord,
        using selected: CalibrationEvaluator? = nil
    ) -> EvaluationOutcome {
        let active = selected ?? evaluator
        guard let raw = RawLogit(logit) else { return .unrepresentableLogit }
        let result: EvaluationOutcome
        do {
            result = .label(
                try active.classify(raw, quality: quality, policy: active.activatedPolicy.policy)
            )
        } catch {
            result = .fault(error)
        }
        witness.recordObserved(result)
        return result
    }

    /// Asserts that one evaluation produced exactly `expected`.
    ///
    /// Reports at the caller's source location, so a failure names the arm that made the
    /// claim rather than this shared helper.
    func expect(
        logit: Double,
        quality: InputQualityRecord,
        is expected: EvaluationOutcome,
        _ reason: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let produced = outcome(logit: logit, quality: quality)
        guard produced != expected else { return }
        Issue.record(
            "\(reason): expected \(expected), got \(produced) [\(shape)]",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Arm 1: totality

    /// Every generated site, against five record shapes, reaches exactly one representable
    /// outcome, and a record whose every required value is usable always reaches a label.
    ///
    /// Requirement 5.4 maps every finite logit and validated record to exactly one of the
    /// three labels; Requirement 5.25 is the one other outcome the mapping may produce.
    /// There is no fifth, and nothing falls through.
    func checkEveryInputReachesExactlyOneOutcome() {
        let records: [(String, InputQualityRecord)] = [
            ("the generated record", generatedRecord),
            ("a record that leaves the logit deciding", logitDecidingRecord),
            ("a covered missing value", coveredAbsentRecord),
            ("an uncovered missing value", uncoveredAbsentRecord),
            ("an unmeasured short edge", unmeasuredShortEdgeRecord),
        ]
        for site in LogitSite.allCases {
            let value = logit(at: site)
            guard value.isFinite else {
                Issue.record("site \(site) generated a nonfinite logit [\(shape)]")
                continue
            }
            for (label, record) in records {
                let produced = outcome(logit: value, quality: record)
                switch produced {
                case .label(let evidence):
                    // Exactly one of the three, and the same three the policy declares.
                    #expect(
                        policy.outputLabels.contains { $0.pixelEvidence == evidence },
                        """
                        \(label) at \(site) produced \(evidence.rawValue), which the \
                        policy does not declare [\(shape)]
                        """
                    )
                case .fault:
                    #expect(
                        produced.isCalibrationInputError,
                        """
                        \(label) at \(site) produced \(produced), which is neither a \
                        declared label nor the calibration input error [\(shape)]
                        """
                    )
                    #expect(produced.label == nil, "a fault carried Pixel Evidence [\(shape)]")
                case .unrepresentableLogit:
                    Issue.record("\(label) at \(site) was refused as nonfinite [\(shape)]")
                }
            }

            // No valid input falls through: with every required value present and usable
            // and the short edge at or above the declared minimum, the outcome is a label.
            let deciding = outcome(logit: value, quality: logitDecidingRecord)
            #expect(
                deciding.label != nil,
                """
                a record with every required value usable produced \(deciding) at \
                \(site) [\(shape)]
                """
            )
        }
    }

    // MARK: - Arm 2: determinism

    /// The same input produces the same outcome on every evaluation, and the order the
    /// policy's rules and required features were assembled in does not change it.
    func checkRepeatedEvaluationAgrees() {
        let records = [generatedRecord, logitDecidingRecord, uncoveredAbsentRecord]
        for site in LogitSite.allCases {
            let value = logit(at: site)
            for record in records {
                let first = outcome(logit: value, quality: record)
                for repetition in 1...3 {
                    let again = outcome(logit: value, quality: record)
                    #expect(
                        again == first,
                        """
                        evaluation \(repetition) at \(site) returned \(again) after \
                        \(first) [\(shape)]
                        """
                    )
                }
                let reordered = outcome(
                    logit: value,
                    quality: record,
                    using: reorderedEvaluator
                )
                #expect(
                    reordered == first,
                    """
                    a policy assembled in the opposite order returned \(reordered) \
                    instead of \(first) at \(site) [\(shape)]
                    """
                )
            }
        }
    }

    // MARK: - Arm 3: closed bands

    /// Requirement 5.8: every band is closed at both edges, and one unit in the last place
    /// outside either edge is decisive.
    ///
    /// The disjointness of adjacent bands is asserted first. Without it the region between
    /// two bands could be empty and the two outside-the-edge expectations would hold
    /// vacuously, since a point one unit outside one band would sit inside its neighbour.
    func checkClosedBandsAbstainAndTheirOutsidesDecide() {
        let ordered = ascendingBoundaries
        for (offset, boundary) in ordered.enumerated().dropFirst() {
            #expect(
                ordered[offset - 1].abstentionUpperBound < boundary.abstentionLowerBound,
                """
                generated bands \(offset - 1) and \(offset) are not disjoint, so the \
                decisive region between them is empty [\(shape)]
                """
            )
        }

        for boundary in ordered {
            for inside in [
                boundary.abstentionLowerBound,
                boundary.rawLogitBoundary,
                boundary.abstentionUpperBound,
            ] {
                expect(
                    logit: inside,
                    quality: logitDecidingRecord,
                    is: .label(insufficientOutcome),
                    "a logit on or inside a closed band did not abstain"
                )
            }
            expect(
                logit: boundary.abstentionLowerBound.nextDown,
                quality: logitDecidingRecord,
                is: .label(boundary.lowerDecision.pixelEvidence),
                "one unit in the last place below a band was not the lower decision"
            )
            expect(
                logit: boundary.abstentionUpperBound.nextUp,
                quality: logitDecidingRecord,
                is: .label(boundary.upperDecision.pixelEvidence),
                "one unit in the last place above a band was not the upper decision"
            )
        }

        // The interior point the shape selected, wherever inside the band it fell.
        expect(
            logit: logit(at: .insideSelectedBand),
            quality: logitDecidingRecord,
            is: .label(insufficientOutcome),
            "a generated point inside a closed band did not abstain"
        )
    }

    // MARK: - Arm 4: the short-edge rule

    /// Requirement 5.9, and Requirement 5.25 for the measurement the rule needs.
    ///
    /// A short edge below the policy's declared minimum abstains whatever the logit says; a
    /// short edge at or above it leaves the decision to the logit; a short edge that was
    /// never measured is an input error rather than a large edge. The lengths are the
    /// generated ones plus the two derived from the policy's own minimum, so no arm
    /// restates the literal minimum that task 7.9 owns as an example.
    func checkRecordedShortEdgeGovernsAbstention() {
        let minimum = policy.minimumShortEdge
        let decisive = selectedBoundary.abstentionUpperBound.nextUp
        let expectedDecision = selectedBoundary.upperDecision.pixelEvidence

        for shortEdge in [shape.belowMinimumShortEdge, minimum - 1] {
            guard let record = short(edge: shortEdge) else { continue }
            #expect(
                record.shortEdgeBeforeOrientation == shortEdge,
                "the record's short edge is not the lesser recorded dimension [\(shape)]"
            )
            expect(
                logit: decisive,
                quality: record,
                is: .label(insufficientOutcome),
                "a short edge below the declared minimum did not abstain"
            )
        }

        for shortEdge in [shape.atOrAboveMinimumShortEdge, minimum] {
            guard let record = short(edge: shortEdge) else { continue }
            expect(
                logit: decisive,
                quality: record,
                is: .label(expectedDecision),
                "a short edge at or above the declared minimum did not leave the logit deciding"
            )
        }

        expect(
            logit: decisive,
            quality: unmeasuredShortEdgeRecord,
            is: .fault(.analysis(.calibrationInputError, stage: .calibration)),
            "an unmeasured short edge was not an input error"
        )
        #expect(
            outcome(logit: decisive, quality: unmeasuredShortEdgeRecord).label == nil,
            "an unmeasured short edge produced Pixel Evidence [\(shape)]"
        )
    }

    /// A record with `edge` as its short edge and every required value usable.
    private func short(edge: Int) -> InputQualityRecord? {
        let builder = PolicyShapeBuilder(shape: shape)
        guard let record = builder.record(shortEdge: edge, features: builder.usableFeatures) else {
            Issue.record("a record with short edge \(edge) was not self-consistent [\(shape)]")
            return nil
        }
        return record
    }

    // MARK: - Arm 5: explicitly covered abstention

    /// Requirement 5.24: a required value that is missing, where the bound policy states
    /// that condition as an abstention condition, returns the insufficient outcome.
    ///
    /// The same record with the value present is the positive control: without it the
    /// abstention could be coming from the region rather than from the rule.
    func checkCoveredMissingValueAbstains() {
        let decisive = selectedBoundary.abstentionUpperBound.nextUp
        expect(
            logit: decisive,
            quality: coveredAbsentRecord,
            is: .label(insufficientOutcome),
            "a missing value the policy covers with an abstention rule did not abstain"
        )
        expect(
            logit: decisive,
            quality: logitDecidingRecord,
            is: .label(selectedBoundary.upperDecision.pixelEvidence),
            "the same record with the value present did not reach the decisive label"
        )
    }

    // MARK: - Arm 6: uncovered required values

    /// Requirement 5.25: a required value that is missing or invalid, where the bound
    /// policy does not state that condition as an abstention condition, returns
    /// `calibration-input-error` and no Pixel Evidence — including when abstention
    /// conditions fire at the same time.
    func checkUncoveredRequiredValueYieldsOnlyTheInputError() {
        let inputError = EvaluationOutcome.fault(
            .analysis(.calibrationInputError, stage: .calibration)
        )
        let sites: [Double] = [
            selectedBoundary.rawLogitBoundary,
            selectedBoundary.abstentionUpperBound.nextUp,
            ascendingBoundaries[0].abstentionLowerBound - 1,
        ]
        for value in sites {
            expect(
                logit: value,
                quality: uncoveredAbsentRecord,
                is: inputError,
                "an uncovered missing required value was not the input error"
            )
            expect(
                logit: value,
                quality: unreadableValueRecord,
                is: inputError,
                "a required value the stated conditions cannot read was not the input error"
            )
            // The abstention would be a Pixel Evidence value, so returning it would break
            // Requirement 5.25's "without Pixel Evidence"; the error dominates.
            expect(
                logit: value,
                quality: uncoveredAndAbstainingRecord,
                is: inputError,
                "an uncovered required value did not dominate simultaneous abstentions"
            )
            let withheld = [
                uncoveredAbsentRecord,
                unreadableValueRecord,
                uncoveredAndAbstainingRecord,
            ]
            for record in withheld {
                #expect(
                    outcome(logit: value, quality: record).label == nil,
                    "an uncovered required value produced Pixel Evidence [\(shape)]"
                )
            }
        }
    }

    // MARK: - Arm 7: every outcome cites a rule

    /// Requirements 5.4 and 5.10: the outcome for the generated logit and record is the one
    /// the policy's own fields provide for, so every insufficient result cites a closed
    /// band, the short-edge rule, or a matched quality rule, and every decisive result
    /// cites none of them.
    ///
    /// The expectation is derived twice over, both independently of the evaluator: the
    /// verdict from the generated recordings against the policy's declared minimum and
    /// threshold, and the decisive label by counting the bands the logit has passed rather
    /// than by walking the schedule and returning at the first region that contains it.
    func checkOutcomeMatchesTheRuleItCites() {
        for site in LogitSite.allCases {
            let value = logit(at: site)
            let expected = expectedOutcome(forLogit: value)
            let produced = outcome(logit: value, quality: generatedRecord)
            #expect(
                produced == expected,
                """
                at \(site) the policy provides for \(expected) but evaluation \
                produced \(produced) [\(shape)]
                """
            )
            let cited = citedAbstentionReasons(forLogit: value)
            if produced.label == insufficientOutcome {
                #expect(
                    !cited.isEmpty,
                    """
                    an insufficient outcome at \(site) cites no band, short-edge, or \
                    quality rule [\(shape)]
                    """
                )
            }
            if let label = produced.label, label != insufficientOutcome {
                #expect(
                    cited.isEmpty,
                    "a decisive label at \(site) coexists with \(cited) [\(shape)]"
                )
            }
        }
    }

    /// The outcome the policy provides for, derived from the generated shape.
    private func expectedOutcome(forLogit value: Double) -> EvaluationOutcome {
        switch expectedVerdict {
        case .inputError:
            return .fault(.analysis(.calibrationInputError, stage: .calibration))
        case .abstains:
            return .label(insufficientOutcome)
        case .logitDecides:
            return .label(expectedDecisiveLabel(forLogit: value))
        }
    }

    /// The combined verdict for the generated record: the short-edge rule and each required
    /// feature's rules, under the precedence the requirements imply.
    private var expectedVerdict: ExpectedVerdict {
        max(
            expectedShortEdgeVerdict,
            max(expectedCoveredVerdict, expectedThresholdFeatureVerdict)
        )
    }

    /// Requirement 5.9 over the recorded short edge, and Requirement 5.25 for its absence.
    private var expectedShortEdgeVerdict: ExpectedVerdict {
        switch shape.shortEdgeRecording {
        case .unmeasured:
            // Absence is not "at least the minimum", and no approved rule covers a short
            // edge that was never measured.
            return .inputError
        case .belowMinimum:
            return .abstains
        case .atOrAboveMinimum:
            return .logitDecides
        }
    }

    /// The covered feature carries only a missing-value abstention rule, so its absence
    /// abstains and any present value leaves the logit deciding.
    private var expectedCoveredVerdict: ExpectedVerdict {
        switch shape.coveredRecording {
        case .absent: .abstains
        case .measured, .condition: .logitDecides
        }
    }

    /// The threshold feature carries a measured-value abstention rule and no rule for its
    /// absence, so absence is uncovered. A recorded condition carries no comparable
    /// magnitude the stated threshold can read, which is the "invalid" half of
    /// Requirements 5.24 and 5.25.
    private var expectedThresholdFeatureVerdict: ExpectedVerdict {
        switch shape.thresholdRecording {
        case .absent, .condition:
            return .inputError
        case .measured:
            return Decimal(shape.measuredMagnitude) <= shape.threshold ? .abstains : .logitDecides
        }
    }

    /// The decisive label for `value`, derived by counting the bands it has passed.
    ///
    /// Deliberately not the evaluator's ordered walk: this counts the bands strictly below
    /// `value` and indexes the labels, so one traversal cannot hide a defect in the other.
    private func expectedDecisiveLabel(forLogit value: Double) -> PixelEvidence {
        let ordered = ascendingBoundaries
        if ordered.contains(where: {
            $0.abstentionLowerBound <= value && value <= $0.abstentionUpperBound
        }) {
            return insufficientOutcome
        }
        let passed = ordered.filter { $0.abstentionUpperBound < value }.count
        return passed == 0
            ? ordered[0].lowerDecision.pixelEvidence
            : ordered[passed - 1].upperDecision.pixelEvidence
    }

    /// The policy rules that provide for withholding a decision on `value` and the
    /// generated record, as audit text.
    ///
    /// Requirement 5.10 requires every insufficient outcome to come from a deterministic
    /// rule the bound policy encodes, so an insufficient outcome with an empty list here is
    /// an outcome no rule accounts for.
    private func citedAbstentionReasons(forLogit value: Double) -> [String] {
        var cited: [String] = []
        for boundary in ascendingBoundaries
        where boundary.abstentionLowerBound <= value && value <= boundary.abstentionUpperBound {
            cited.append("closed band at \(boundary.rawLogitBoundary)")
        }
        if shape.shortEdgeRecording == .belowMinimum {
            cited.append("short edge below \(policy.minimumShortEdge)")
        }
        if expectedCoveredVerdict == .abstains {
            cited.append("missing-value rule on the covered feature")
        }
        if expectedThresholdFeatureVerdict == .abstains {
            cited.append("measured-value rule at or below \(shape.threshold)")
        }
        return cited
    }
}

// MARK: - Artifact construction

/// Builds the artifacts one generated shape describes.
///
/// Every reference is derived from the shape's seed, so the whole set varies together and
/// stays coherent without a cross-reference table. No value is an approved budget,
/// boundary, threshold, quality feature, evidence record, or model.
private struct PolicyShapeBuilder {
    let shape: EvaluationShape

    private var seed: Int { shape.seed }

    // MARK: Seeded references

    /// Force-unwrapped deliberately: the composed text is canonical by construction, so a
    /// `nil` here is a defect in this file rather than a property failure.
    private func artifact(_ name: String) -> ArtifactID { ArtifactID("\(name)-\(seed)")! }

    /// The feature whose absence the policy covers with an abstention rule.
    var coveredFeature: QualityFeatureID { QualityFeatureID("quality.covered-\(seed)")! }

    /// The feature the policy states a measured-value threshold for, and states no rule for
    /// the absence of.
    var thresholdFeature: QualityFeatureID { QualityFeatureID("quality.measured-\(seed)")! }

    /// Both required features present and usable, and the threshold feature's magnitude
    /// above the stated threshold, so no rule fires.
    var usableFeatures: [QualityFeatureID: ValidatedQualityValue] {
        [
            coveredFeature: .integer(shape.measuredMagnitude),
            thresholdFeature: .integer(shape.magnitudeAboveThreshold),
        ]
    }

    /// What the shape says each feature carries.
    var generatedFeatures: [QualityFeatureID: ValidatedQualityValue] {
        var features: [QualityFeatureID: ValidatedQualityValue] = [:]
        if let covered = value(for: shape.coveredRecording) {
            features[coveredFeature] = covered
        }
        if let measured = value(for: shape.thresholdRecording) {
            features[thresholdFeature] = measured
        }
        return features
    }

    private func value(for recording: FeatureRecording) -> ValidatedQualityValue? {
        switch recording {
        case .absent: nil
        case .measured: .integer(shape.measuredMagnitude)
        case .condition: .boolean(true)
        }
    }

    /// The short edge the shape says the record carries.
    var generatedShortEdge: Int? {
        switch shape.shortEdgeRecording {
        case .unmeasured: nil
        case .belowMinimum: shape.belowMinimumShortEdge
        case .atOrAboveMinimum: shape.atOrAboveMinimumShortEdge
        }
    }

    /// One Input Quality Record, or `nil` when the measurements are not self-consistent.
    ///
    /// The long edge is the short edge plus the generated excess, so the recorded short edge
    /// is the lesser dimension whichever excess was generated.
    func record(
        shortEdge: Int?,
        features: [QualityFeatureID: ValidatedQualityValue]
    ) -> InputQualityRecord? {
        guard let shortEdge else {
            return InputQualityRecord(
                decodedWidthBeforeOrientation: nil,
                decodedHeightBeforeOrientation: nil,
                validatedFeatures: features
            )
        }
        return InputQualityRecord(
            decodedWidthBeforeOrientation: shortEdge + shape.longEdgeExcess,
            decodedHeightBeforeOrientation: shortEdge,
            validatedFeatures: features
        )
    }

    // MARK: Evidence

    private func schemaVersion() throws -> SchemaSemanticVersion {
        try SchemaSemanticVersion(validating: "1.\(seed % 50).\(seed % 7)")
    }

    private func digest(_ salt: Int) -> SHA256Digest {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256Digest.byteCount)
        for index in 0..<SHA256Digest.byteCount {
            bytes.append(UInt8((seed &+ salt &* 31 &+ index &* 7) & 0xFF))
        }
        // Force-unwrapped deliberately: exactly `byteCount` bytes were appended.
        return SHA256Digest(bytes: bytes)!
    }

    private func evidence(_ name: String, salt: Int) throws -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(name),
            version: try schemaVersion(),
            contentDigest: digest(salt)
        )
    }

    // MARK: Policy

    /// The generated boundary schedule.
    private func boundaries() throws -> [CategoryBoundary] {
        let positions = shape.boundaryPositions
        return try shape.bandShapes.indices.map { index in
            try CategoryBoundary(
                rawLogitBoundary: positions[index],
                abstentionHalfWidth: shape.halfWidth(index),
                lowerDecision: shape.decisiveLabel(index),
                upperDecision: shape.decisiveLabel(index + 1)
            )
        }
    }

    /// One abstention rule for the covered feature's absence, one measured-value abstention
    /// rule for the threshold feature, and optionally an unusable-value rule that names the
    /// input error.
    ///
    /// The threshold feature deliberately has no rule for its absence, which is what makes
    /// an absent value there the uncovered condition Requirement 5.25 governs.
    private func qualityRules(reversed: Bool) throws -> [QualityDecisionRule] {
        let cited = [try evidence("evidence.quality", salt: 97)]
        var rules = [
            try QualityDecisionRule(
                id: artifact("rule.covered-missing"),
                feature: coveredFeature,
                condition: .valueMissing,
                outcome: .insufficientSignal,
                evidence: cited
            ),
            try QualityDecisionRule(
                id: artifact("rule.measured-low"),
                feature: thresholdFeature,
                condition: .atOrBelow(shape.threshold),
                outcome: .insufficientSignal,
                evidence: cited
            ),
        ]
        if shape.carriesInvalidValueRule {
            rules.append(
                try QualityDecisionRule(
                    id: artifact("rule.measured-invalid"),
                    feature: thresholdFeature,
                    condition: .valueInvalid,
                    outcome: .calibrationInputError,
                    evidence: []
                )
            )
        }
        return reversed ? rules.reversed() : rules
    }

    private func policy(reversingRuleOrder reversed: Bool) throws -> CalibrationPolicy {
        let features = reversed
            ? [thresholdFeature, coveredFeature]
            : [coveredFeature, thresholdFeature]
        return try CalibrationPolicy(
            id: artifact("policy.calibration"),
            schemaVersion: .v1,
            compatibleModel: RequiredPixelModel.identity,
            compatiblePreprocessing: artifact("contract.preprocessing"),
            compatibleVerdictCopy: artifact("copy.compatibility"),
            falseAccusationBudget: try FalseAccusationBudget(
                validating: Decimal(sign: .plus, exponent: -4, significand: Decimal(1 + seed % 100))
            ),
            releasePassRule: try FalseAccusationPassRule(
                statistic: BudgetPassStatistic.allCases[seed % BudgetPassStatistic.allCases.count],
                intervalMethod: ConfidenceIntervalMethod.allCases[
                    seed % ConfidenceIntervalMethod.allCases.count
                ],
                confidenceLevel: try UnitInterval(
                    validating: FalseAccusationPassRule.requiredConfidenceLevel
                )
            ),
            outputLabels: Set(PixelLabelKey.allCases),
            metricCategories: PixelLabelKey.allCases.map {
                MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
            },
            boundaries: try boundaries(),
            minimumShortEdge: CalibrationPolicy.requiredMinimumShortEdge,
            belowMinimumShortEdgeLabel: .notEnoughSignal,
            requiredQualityFeatures: Set(features),
            qualityRules: try qualityRules(reversed: reversed),
            uncoveredQualityInputBehavior: .calibrationInputError,
            evidence: [try evidence("evidence.calibration", salt: 11)],
            upstreamBoundaryMetadata: try Sample.upstreamMetadata()
        )
    }

    /// The Model Bundle the policy is activated with.
    private func manifest() throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: ModelBundleID("bundle.calibration-\(seed)")!,
            modelIdentity: RequiredPixelModel.identity,
            modelFormat: try Sample.modelFormat(),
            inputContract: try Sample.modelInput(),
            outputContract: try Sample.modelOutput(),
            componentVersions: BundleComponentVersions(
                coreMLModel: artifact("component.coreml"),
                preprocessingContract: artifact("contract.preprocessing"),
                calibrationPolicy: artifact("policy.calibration"),
                evidenceScope: artifact("component.scope"),
                verdictCopyCompatibility: artifact("copy.compatibility"),
                selfTestSpecification: artifact("component.self-tests")
            ),
            artifacts: [Sample.digestRecord()],
            compatibility: try Sample.compatibilityMatrix(),
            upstreamBoundaryMetadata: try Sample.upstreamMetadata(),
            signingKey: Sample.signingKey("key.calibration-\(seed)")
        )
    }

    /// The activated policy, which is the only thing an evaluator can be built from.
    func activatedPolicy(reversingRuleOrder reversed: Bool) throws -> ValidatedCalibrationPolicy {
        try ValidatedCalibrationPolicy(
            activating: try policy(reversingRuleOrder: reversed),
            for: try manifest(),
            evidence: try ReleaseEvidenceIndex(
                records: [
                    try evidence("evidence.calibration", salt: 11),
                    try evidence("evidence.quality", salt: 97),
                ]
            )
        )
    }
}

extension Dictionary {
    /// A copy without `key`, for a record that omits one required feature.
    fileprivate func removingValue(forKey key: Key) -> Self {
        var copy = self
        copy.removeValue(forKey: key)
        return copy
    }

    /// A copy with `key` bound to `value`, for a record whose value the stated conditions
    /// cannot read.
    fileprivate func replacingValue(forKey key: Key, with value: Value) -> Self {
        var copy = self
        copy[key] = value
        return copy
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the arms observed, so the property cannot
/// pass by generating one fixed shape a hundred times or by skipping its arms.
///
/// A `propertyCheck` body that throws before reaching its assertions passes in
/// milliseconds with every arm skipped, and a property whose baseline never varies asserts
/// one example a hundred times over. This collects the dimensions the arms depend on, the
/// number of cases, the number of cases that reached the end of the body, and the set of
/// outcomes evaluation actually produced, and asserts all of it *outside* the body where an
/// issue is not suppressed.
///
/// The variation thresholds are far below what 100 draws produce, so they witness variation
/// rather than pinning a distribution. The outcome set is not a threshold at all: arm 3
/// produces all three labels and arm 6 produces the input error in every single case, so a
/// missing outcome means an arm did not run.
private final class CalibrationEvaluationVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var bandCounts = Set<Int>()
    private var halfWidths = Set<Double>()
    private var labelDirections = Set<Bool>()
    private var thresholds = Set<Decimal>()
    private var invalidRulePresence = Set<Bool>()
    private var coveredRecordings = Set<FeatureRecording>()
    private var thresholdRecordings = Set<FeatureRecording>()
    private var shortEdgeRecordings = Set<ShortEdgeRecording>()
    private var longEdges = Set<Int>()
    private var observedLabels = Set<PixelEvidence>()
    private var observedFaults = Set<AnalysisFault>()
    private var cases = 0
    private var completedArms = 0
    private var evaluations = 0

    func record(_ shape: EvaluationShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        bandCounts.insert(shape.bandShapes.count)
        halfWidths.formUnion(shape.bandShapes.indices.map { shape.halfWidth($0) })
        labelDirections.insert(shape.nonPositiveBelowFirstBoundary)
        thresholds.insert(shape.threshold)
        invalidRulePresence.insert(shape.carriesInvalidValueRule)
        coveredRecordings.insert(shape.coveredRecording)
        thresholdRecordings.insert(shape.thresholdRecording)
        shortEdgeRecordings.insert(shape.shortEdgeRecording)
        longEdges.insert(shape.longEdgeExcess)
    }

    func recordObserved(_ outcome: EvaluationOutcome) {
        lock.lock()
        defer { lock.unlock() }
        evaluations += 1
        switch outcome {
        case .label(let evidence): observedLabels.insert(evidence)
        case .fault(let fault): observedFaults.insert(fault)
        case .unrepresentableLogit: break
        }
    }

    /// Called at the end of the body, so a case that stopped early is countable.
    func recordCompletedArms() {
        lock.lock()
        defer { lock.unlock() }
        completedArms += 1
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases, ran \(cases)")
        #expect(
            completedArms == cases,
            "\(cases - completedArms) of \(cases) cases did not reach the end of the body"
        )
        // The seven arms evaluate roughly 250 logit-and-record pairs per case. The floor is
        // well below that so it does not pin an arm's internal loop, but far enough above
        // zero that a run which merely constructed policies without evaluating them fails
        // here rather than passing quickly.
        #expect(evaluations >= 20_000, "evaluations performed: \(evaluations)")
        // The seed is drawn from 10,000 values, so a constant baseline shows 1.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(bandCounts == [1, 2, 3], "generated band counts: \(bandCounts.sorted())")
        // One shape carries at most three half-widths, so a constant baseline shows 3.
        #expect(halfWidths.count >= 25, "generated half-widths: \(halfWidths.count)")
        #expect(labelDirections == [false, true], "both label directions are generated")
        // The threshold is drawn from 4,901 admissible values. The floor is an order of
        // magnitude above a constant baseline rather than a share of the range: the
        // generator concentrates its draws rather than spreading them uniformly.
        #expect(thresholds.count >= 10, "generated thresholds: \(thresholds.count)")
        #expect(
            invalidRulePresence == [false, true],
            "both quality-rule sets are generated"
        )
        #expect(
            coveredRecordings == Set(FeatureRecording.allCases),
            "generated covered-feature recordings: \(coveredRecordings.map(\.rawValue).sorted())"
        )
        #expect(
            thresholdRecordings == Set(FeatureRecording.allCases),
            """
            generated measured-feature recordings: \
            \(thresholdRecordings.map(\.rawValue).sorted())
            """
        )
        #expect(
            shortEdgeRecordings == Set(ShortEdgeRecording.allCases),
            "generated short-edge recordings: \(shortEdgeRecordings.map(\.rawValue).sorted())"
        )
        #expect(longEdges.count >= 10, "generated long-edge excesses: \(longEdges.count)")

        // Every arm of the mapping was actually exercised, not merely offered.
        #expect(
            observedLabels == Set(PixelEvidence.allCases),
            "observed labels: \(observedLabels.map(\.rawValue).sorted())"
        )
        #expect(
            observedFaults == [.analysis(.calibrationInputError, stage: .calibration)],
            "observed faults: \(observedFaults)"
        )
    }
}

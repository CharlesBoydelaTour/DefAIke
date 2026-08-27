import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 17: Release metric semantics include abstentions.
//
// The design states it as: for any nonempty eligible release slice, false-positive rate
// equals positive-labeled real images divided by all eligible real images, true-positive
// rate equals positive-labeled synthetic images divided by all eligible synthetic images,
// and coverage equals positive plus non-positive labels divided by all eligible images;
// insufficient outcomes remain in both rate denominators, and the pass decision uses the
// observed false-positive rate and its predeclared confidence interval.
//
// Quantified here as one property with six arms over every generated slice:
//
//   * rates — each of the three measured rates equals the one an independent reference
//     derives by counting individual images, and each denominator is the whole eligible
//     population that reference enumerated (Requirements 5.16, 5.17, 5.18);
//   * abstentions — the arm the property is named for. A reference that drops the
//     abstaining images from a rate denominator is computed alongside the honest one, and
//     wherever a population contains an abstention the two disagree, so agreeing with the
//     honest one is a decision rather than a coincidence. Where a population contains no
//     abstention the two agree, which is the control that keeps the arm from passing
//     merely because two numbers differ (Requirements 5.16, 5.17, 5.18);
//   * coverage numerator — abstentions leave coverage's numerator and stay in its
//     denominator, checked by reclassifying exactly one abstaining image as decisive and
//     watching the numerator move by one while the denominator holds (Requirement 5.18);
//   * pass rule — the budget decision for all three predeclared statistics equals the one
//     the reference derives from the observed rate, the predeclared interval's upper
//     bound, and the budget, and a slice with no eligible real image yields no rule result
//     rather than a pass (Requirement 5.21);
//   * predeclared interval — the supplied result is carried through unchanged, is
//     identical across two slices whose observed rates differ, and any other method or any
//     other confidence level is refused. Together: consumed as given, never selected after
//     the outcomes were seen (Requirement 5.21);
//   * errors — an Analysis Error produced no label, so changing the error count moves none
//     of the three rates (Requirements 5.16, 5.17, 5.18).
//
// `ReleaseSliceMetricTests` pins these behaviors at chosen counts with one example each,
// and task 7.9 owns the literal example tests including the representative metric
// denominator examples, so no arm here restates one of those count sets: every expectation
// is derived from the generated roster. The neighbouring calibration properties belong to
// their own tasks: Property 15 is policy validity, Property 16 is evaluation totality, and
// Property 18 is release-approval evidence completeness.
//
// ## How the reference is independent of the code under test
//
// The reference is a naive transcription of the requirement sentences over a materialized
// roster of individual images, and it reaches every number a different way than
// ``ReleaseSliceMeasurement`` does:
//
//   * Each denominator is `roster.count(where: ground truth matches)` — a count of images
//     that never looks at a label at all, so no code path in the reference can remove an
//     abstaining image from a denominator. The measurement instead reads the eligible
//     population fields of a ``SliceOutcomeCounts``. One counts images; the other reads
//     recorded totals.
//   * Each numerator is `roster.count(where: ground truth and label match)`, using a label
//     to metric category mapping written out here from Requirement 5.3 rather than read
//     from ``PixelLabelKey/requiredMetricCategory``.
//   * The budget comparison is exact integer arithmetic in whole millionths:
//     `positives × 1_000_000 ≤ budgetMillionths × population`. The measurement compares
//     `Decimal` values through `NSDecimalMultiply`. The two share no arithmetic, so a
//     defect in either is visible as a disagreement.
//
// ## Why nothing here is serialized
//
// This property turns on exact decimals: the False Accusation Budget is a rate at or below
// 1%, the interval bounds are compared against it, and the predeclared level is exactly
// 95%. `JSONSerialization` perturbs exact decimals, so an assertion built on a serializer
// round trip would hold whether or not the value under test survived it. Every artifact
// here is therefore constructed as a typed value; every budget and bound is built as an
// exact `Decimal` from a whole number of millionths, so its significand and exponent are
// the ones written rather than a rounded rendering; every rate is compared as the pair of
// integers ``MeasuredRate`` holds rather than as a quotient; and no arm mutates payload
// text, so `JSONMemberSplice` and `PolicyPayloadSplice` are not needed here.
//
// ## Why no arm throws
//
// `propertyCheck` discards an error thrown from its body: a `throw` before the assertions
// makes the whole run pass in milliseconds with every arm skipped. Every measurement here
// therefore goes through ``ReleaseSliceScenario/measure(counts:interval:statistic:)``,
// which turns a refusal into a ``MeasurementAttempt`` value, and every helper reports
// through `Issue.record`. ``ReleaseMetricVariationWitness`` counts the cases, the
// measurements, the comparisons, and the arms that completed and asserts those counts
// *outside* the body, where an issue is not suppressed, so a body that stopped early is
// visible rather than silent — a metrics property does arithmetic rather than I/O, so its
// runtime alone proves nothing about whether it ran.
//
// No value in this file is an approved budget, threshold, slice, degradation condition,
// interval method, quality rule, evidence record, or model. Every count, budget, and bound
// is generated from a synthetic range, and the one fixed number any arm reads — the 1%
// budget ceiling — is read from ``FalseAccusationBudget/maximumRate``, which owns it.

extension Tag {
    /// Design Property 17.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property17ReleaseMetricSemantics: Self
}

@Suite(
    "Property 17: Release metric semantics include abstentions",
    .tags(.property17ReleaseMetricSemantics)
)
struct ReleaseMetricSemanticsPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 5.16, 5.17, 5.18, 5.21**
    @Test("Release metrics keep abstentions and read the predeclared rule")
    func releaseMetricSemanticsIncludeAbstentions() async {
        let witness = ReleaseMetricVariationWitness()

        await propertyCheck(input: SliceShape.generator) { shape in
            witness.record(shape)
            guard let scenario = ReleaseSliceScenario(shape: shape, witness: witness) else {
                return
            }

            scenario.checkEachRateMatchesTheReference()
            scenario.checkDroppingAbstentionsWouldChangeEveryRate()
            scenario.checkCoverageCountsOnlyDecisiveLabelsInItsNumerator()
            scenario.checkPassDecisionReadsThePredeclaredRule()
            scenario.checkPredeclaredIntervalIsCarriedNotChosen()
            scenario.checkErrorCountIsInNoDenominator()

            witness.recordCompletedArms()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The metric vocabulary, transcribed

/// Which ground-truth population one eligible image belongs to.
///
/// Requirements 5.16 and 5.17 define one rate over each, so the population is a fact about
/// the image rather than something derived from what the model said about it.
private enum GroundTruth: Hashable, CaseIterable, Sendable {
    case real
    case synthetic
}

/// The metric category one assigned label contributes to.
///
/// Written out here from Requirement 5.3 — the Positive Pixel Label is positive evidence,
/// the Non Positive Pixel Label is non-positive evidence, and the Insufficient Evidence
/// Outcome is insufficient evidence — rather than read from
/// ``PixelLabelKey/requiredMetricCategory``, so the reference does not inherit the
/// production mapping it is meant to be independent of.
private enum AssignedCategory: Hashable, CaseIterable, Sendable {
    case positive
    case nonPositive
    case insufficient
}

/// One eligible image in the slice: what it is, and what the run assigned to it.
private struct EligibleImage: Hashable, Sendable {
    let groundTruth: GroundTruth
    let assigned: AssignedCategory
}

// MARK: - The reference implementation

/// The three release metrics and the budget decision, transcribed from the requirement
/// sentences over an explicit roster of eligible images.
///
/// Deliberately naive. Every quantity is a count of roster entries matching a predicate,
/// and the one comparison is integer arithmetic. Nothing here reads a
/// ``SliceOutcomeCounts``, a ``MeasuredRate``, or any other production value, so it cannot
/// agree with the measurement by sharing its reasoning.
private struct MetricReference {
    /// Every eligible image in the slice, one entry each.
    let roster: [EligibleImage]

    /// The False Accusation Budget, in whole millionths.
    let budgetMillionths: Int

    /// The predeclared interval's upper bound, in whole millionths.
    let intervalUpperMillionths: Int

    // MARK: Counting images

    /// Every eligible image of `population`, abstentions and all.
    ///
    /// This is the denominator Requirements 5.16 and 5.17 name, and it is a count of images
    /// that never consults ``EligibleImage/assigned``: there is no expression here from
    /// which an insufficient outcome could be removed.
    func eligible(_ population: GroundTruth) -> Int {
        roster.filter { $0.groundTruth == population }.count
    }

    /// Eligible images of `population` that the run assigned `category`.
    func assigned(_ category: AssignedCategory, in population: GroundTruth) -> Int {
        roster.filter { $0.groundTruth == population && $0.assigned == category }.count
    }

    /// Every eligible image in the slice, both populations pooled.
    ///
    /// Requirement 5.18 defines coverage over eligible images without splitting them by
    /// ground truth, so this is one count over the whole roster.
    var eligibleImages: Int { roster.count }

    /// Eligible images assigned the Positive or the Non Positive label.
    var decisiveImages: Int {
        roster.filter { $0.assigned == .positive || $0.assigned == .nonPositive }.count
    }

    // MARK: The three rates

    /// Requirement 5.16, transcribed: positive-labeled eligible real images over the total
    /// number of eligible real images in the slice, the insufficient ones included.
    ///
    /// `nil` when the slice holds no eligible real image: the requirement defines a ratio
    /// over that population, and there is no such ratio when the population is empty.
    var falsePositiveRate: Ratio? {
        Ratio(assigned(.positive, in: .real), over: eligible(.real))
    }

    /// Requirement 5.17, transcribed: positive-labeled eligible synthetic images over the
    /// total number of eligible synthetic images, the insufficient ones included.
    var truePositiveRate: Ratio? {
        Ratio(assigned(.positive, in: .synthetic), over: eligible(.synthetic))
    }

    /// Requirement 5.18, transcribed: images assigned the Positive or Non Positive label
    /// over the total number of eligible images.
    var coverage: Ratio? { Ratio(decisiveImages, over: eligibleImages) }

    // MARK: The same rates with the abstentions dropped

    /// What Requirement 5.16 would produce if an abstaining real image left the
    /// denominator. Never what the measurement should report.
    var falsePositiveRateDroppingAbstentions: Ratio? {
        Ratio(
            assigned(.positive, in: .real),
            over: eligible(.real) - assigned(.insufficient, in: .real)
        )
    }

    /// What Requirement 5.17 would produce if an abstaining synthetic image left the
    /// denominator.
    var truePositiveRateDroppingAbstentions: Ratio? {
        Ratio(
            assigned(.positive, in: .synthetic),
            over: eligible(.synthetic) - assigned(.insufficient, in: .synthetic)
        )
    }

    /// What Requirement 5.18 would produce if an abstaining image left the coverage
    /// denominator. Always exactly 1, which is the tell: coverage would stop measuring
    /// anything.
    var coverageDroppingAbstentions: Ratio? { Ratio(decisiveImages, over: decisiveImages) }

    // MARK: The pass rule

    /// Requirement 5.21, transcribed: the pass decision over the observed false-positive
    /// rate and the predeclared interval, for one predeclared statistic.
    ///
    /// The observed rate satisfies the budget when `positives ÷ population ≤ budget`, which
    /// is decided here by multiplying out into whole millionths so the comparison is exact
    /// integer arithmetic — no quotient is formed and no decimal is rounded. Requirement
    /// 5.22 blocks a slice that *exceeds* the budget, so equality satisfies it.
    ///
    /// `nil` when the slice holds no eligible real image: there is then no observed
    /// false-positive rate for the rule to read.
    func budgetIsSatisfied(readingStatistic statistic: BudgetPassStatistic) -> Bool? {
        let population = eligible(.real)
        guard population > 0 else { return nil }
        let observedSatisfies =
            assigned(.positive, in: .real) * 1_000_000 <= budgetMillionths * population
        let upperBoundSatisfies = intervalUpperMillionths <= budgetMillionths
        switch statistic {
        case .observedRate:
            return observedSatisfies
        case .intervalUpperBound:
            return upperBoundSatisfies
        case .observedRateAndIntervalUpperBound:
            return observedSatisfies && upperBoundSatisfies
        }
    }
}

/// Two counts, kept as a pair rather than divided.
///
/// A rate here is never a quotient: `positives ÷ population` is frequently non-terminating,
/// so comparing the reference against the measurement through a rounded number would
/// compare the roundings. Equality of the two pairs is the comparison, and it is exact.
private struct Ratio: Hashable, CustomStringConvertible {
    let numerator: Int
    let denominator: Int

    /// `nil` when the population is empty, because a ratio over no image is not a ratio of
    /// zero.
    init?(_ numerator: Int, over denominator: Int) {
        guard denominator > 0 else { return nil }
        self.numerator = numerator
        self.denominator = denominator
    }

    var description: String { "\(numerator)/\(denominator)" }
}

extension MeasuredRate {
    /// The measured rate as the plain pair of integers it holds, for comparison against the
    /// reference without either side forming a quotient.
    fileprivate var asRatio: Ratio? { Ratio(numerator.value, over: denominator.value) }
}

// MARK: - Generated shape

/// Which ground-truth populations the generated slice contains.
///
/// A slice with only real images is the shape Requirement 5.20 makes mandatory, and a slice
/// with only synthetic images is the one Requirement 5.1 leaves outside the budget's reach,
/// so both are generated beside the ordinary two-population slice. Every case is nonempty:
/// the design states this property over a nonempty eligible slice.
private enum PopulationMix: Int, CaseIterable, Sendable {
    case bothPopulations
    case realImagesOnly
    case syntheticImagesOnly

    var containsRealImages: Bool { self != .syntheticImagesOnly }
    var containsSyntheticImages: Bool { self != .realImagesOnly }
}

/// How many eligible real images the run assigned the Positive Pixel Label.
///
/// Generated as a density rather than a bare count so that both directions of the budget
/// comparison occur: a budget is at most 1%, so a slice with a percent-scale false-positive
/// rate could never satisfy one and the pass-rule arm would only ever see failures.
/// ``ReleaseMetricVariationWitness`` asserts that both outcomes were observed.
private enum PositiveDensity: Int, CaseIterable, Sendable {
    /// No real image was assigned the Positive label, so the observed rate is a measured
    /// zero and satisfies every budget.
    case noFalsePositives
    /// A handful, on the order of a tenth of a percent of the real population.
    case sparse
    /// Percent-scale, well above any admissible budget.
    case dense
}

/// Where the predeclared interval's upper bound sits relative to the budget.
///
/// Generated rather than derived from the counts, which is the point: the interval is
/// predeclared, so its bound has no relationship to the observation, and the two statistics
/// that read it have to disagree with the one that does not.
private enum UpperBoundPlacement: Int, CaseIterable, Sendable {
    case withinBudget
    case aboveBudget
}

/// Everything one generated slice measurement is built from, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside
/// ``ReleaseSliceScenario``, where a construction that unexpectedly throws is recorded as a
/// failure rather than escaping.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant asserts one example a hundred times over, so
/// every dimension the arms depend on is generated:
///
///   * which ground-truth populations the slice contains, over all three mixes;
///   * the size of each population, and how the images inside it were labeled — the share
///     assigned the Positive label and the share that abstained, both over their full
///     ranges, so slices with no abstention, with some, and with nothing but abstentions
///     all occur;
///   * the Analysis Error count, which no rate may read;
///   * the False Accusation Budget, anywhere in the admissible range up to the 1% ceiling;
///   * which of the three predeclared statistics the pass rule reads, and which of the five
///     predeclared interval methods the slice and the policy agree on;
///   * where the interval's bounds sit relative to that budget, on both sides;
///   * whether the slice is the mandatory contemporary phone-camera one;
///   * the slice identifier, from ``seed``.
private struct SliceShape: Sendable, CustomStringConvertible {
    /// Drives the synthetic slice identifier, so slices are distinguishable in a failure
    /// message.
    let seed: Int

    let mix: PopulationMix

    /// Eligible real images, when the mix contains them.
    let realPopulation: Int

    let positiveDensity: PositiveDensity

    /// Percent-scale count of positive labels, for ``PositiveDensity/dense``.
    let densePositiveCount: Int

    /// Thousandths of the remaining real images that abstained.
    let realAbstentionPermille: Int

    /// Eligible synthetic images, when the mix contains them.
    let syntheticPopulation: Int

    /// Thousandths of the synthetic images assigned the Positive label.
    let syntheticPositivePermille: Int

    /// Thousandths of the remaining synthetic images that abstained.
    let syntheticAbstentionPermille: Int

    /// Analysis Errors encountered while evaluating the slice.
    let errorCount: Int

    /// The False Accusation Budget, in whole millionths. At most the 1% ceiling.
    let budgetMillionths: Int

    let statisticSelector: Int
    let methodSelector: Int

    let upperBoundPlacement: UpperBoundPlacement

    /// Millionths between the budget and the interval's upper bound. Never zero, so the
    /// placement is unambiguous.
    let upperBoundOffsetMillionths: Int

    /// Millionths below the upper bound the lower bound sits, beyond the one millionth that
    /// keeps the interval from collapsing to a point.
    let lowerBoundOffsetMillionths: Int

    let isContemporaryPhoneCameraSlice: Bool

    var description: String {
        """
        seed \(seed), \(mix), real \(realPositives)+\(realNonPositives)+\(realAbstentions), \
        synthetic \(syntheticPositives)+\(syntheticNonPositives)+\(syntheticAbstentions), \
        errors \(errorCount), budget \(budgetMillionths)/1e6, \(statistic.rawValue), \
        interval \(lowerBoundMillionths)...\(upperBoundMillionths)/1e6
        """
    }

    // MARK: Derived label counts

    /// Eligible real images in the slice.
    var realTotal: Int { mix.containsRealImages ? realPopulation : 0 }

    /// Eligible synthetic images in the slice.
    var syntheticTotal: Int { mix.containsSyntheticImages ? syntheticPopulation : 0 }

    /// Real images assigned the Positive Pixel Label, never more than the population.
    ///
    /// The sparse count stays a handful whatever the population is, so a large population
    /// puts the resulting rate on the scale a budget can reach; the dense count grows with
    /// the generated percent-scale figure, so it does not.
    var realPositives: Int {
        let requested =
            switch positiveDensity {
            case .noFalsePositives: 0
            case .sparse: 1 + (seed % 3)
            case .dense: densePositiveCount
            }
        return min(requested, realTotal)
    }

    /// Real images assigned the Insufficient Evidence Outcome.
    var realAbstentions: Int {
        (realTotal - realPositives) * realAbstentionPermille / 1_000
    }

    /// Real images assigned the Non Positive Pixel Label.
    var realNonPositives: Int { realTotal - realPositives - realAbstentions }

    var syntheticPositives: Int {
        syntheticTotal * syntheticPositivePermille / 1_000
    }

    var syntheticAbstentions: Int {
        (syntheticTotal - syntheticPositives) * syntheticAbstentionPermille / 1_000
    }

    var syntheticNonPositives: Int {
        syntheticTotal - syntheticPositives - syntheticAbstentions
    }

    // MARK: Derived predeclarations

    var statistic: BudgetPassStatistic {
        BudgetPassStatistic.allCases[statisticSelector % BudgetPassStatistic.allCases.count]
    }

    var intervalMethod: ConfidenceIntervalMethod {
        ConfidenceIntervalMethod.allCases[
            methodSelector % ConfidenceIntervalMethod.allCases.count
        ]
    }

    /// The interval's upper bound, in whole millionths.
    ///
    /// The within-budget offset is reduced modulo the budget so the bound spreads across the
    /// whole admissible range instead of collapsing onto its floor, and so the case in which
    /// the bound sits exactly on the budget is reachable — Requirement 5.22 blocks a slice
    /// that *exceeds* the budget, so that case has to be a pass.
    ///
    /// Both branches are at least 1, which is what lets the lower bound sit strictly below:
    /// a collapsed interval is refused, and this property is not the one stating that.
    var upperBoundMillionths: Int {
        switch upperBoundPlacement {
        case .withinBudget:
            return budgetMillionths - (upperBoundOffsetMillionths % budgetMillionths)
        case .aboveBudget:
            return budgetMillionths + upperBoundOffsetMillionths
        }
    }

    /// The interval's lower bound, in whole millionths, always strictly below the upper one.
    var lowerBoundMillionths: Int {
        max(0, upperBoundMillionths - 1 - lowerBoundOffsetMillionths)
    }

    // MARK: Generator

    static var generator: Generator<SliceShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...(PopulationMix.allCases.count * 97)),
            populationShape,
            abstentionShape,
            Gen.int(in: 0...400),
            budgetShape,
            intervalShape,
            Gen.bool
        )
        .map { raw in
            SliceShape(
                seed: raw.0,
                mix: PopulationMix.allCases[raw.1 % PopulationMix.allCases.count],
                realPopulation: raw.2.0,
                positiveDensity: PositiveDensity.allCases[
                    raw.2.1 % PositiveDensity.allCases.count
                ],
                densePositiveCount: raw.2.2,
                realAbstentionPermille: raw.3.0,
                syntheticPopulation: raw.3.1,
                syntheticPositivePermille: raw.3.2,
                syntheticAbstentionPermille: raw.3.3,
                errorCount: raw.4,
                budgetMillionths: raw.5.0,
                statisticSelector: raw.5.1,
                methodSelector: raw.5.2,
                upperBoundPlacement: UpperBoundPlacement.allCases[
                    raw.6.0 % UpperBoundPlacement.allCases.count
                ],
                upperBoundOffsetMillionths: raw.6.1,
                lowerBoundOffsetMillionths: raw.6.2,
                isContemporaryPhoneCameraSlice: raw.7
            )
        }
        .eraseToAny()
    }

    /// The real population, the positive density selector, and the percent-scale count.
    private static var populationShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 1...1_200), Gen.int(in: 0...29), Gen.int(in: 1...40))
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }

    /// The real abstention share, the synthetic population, and the two synthetic shares.
    ///
    /// Each share spans the full thousandth range, so a population with no abstention, one
    /// with a few, and one that abstained on everything all occur.
    private static var abstentionShape: Generator<(Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...1_000),
            Gen.int(in: 1...900),
            Gen.int(in: 0...1_000),
            Gen.int(in: 0...1_000)
        )
        .map { ($0.0, $0.1, $0.2, $0.3) }
        .eraseToAny()
    }

    /// The budget in millionths, and the two predeclaration selectors.
    ///
    /// The ceiling is read from ``FalseAccusationBudget/maximumRate`` rather than written
    /// out, so this range does not restate a number the schema owns. Zero is excluded
    /// because a budget of zero is not a measured decision.
    private static var budgetShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 1...MetricScale.millionths(FalseAccusationBudget.maximumRate)),
            Gen.int(in: 0...(BudgetPassStatistic.allCases.count * 97)),
            Gen.int(in: 0...(ConfidenceIntervalMethod.allCases.count * 97))
        )
        .map { ($0.0, $0.1, $0.2) }
        .eraseToAny()
    }

    /// The upper-bound placement and the two bound offsets.
    private static var intervalShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 0...29), Gen.int(in: 1...20_000), Gen.int(in: 0...5_000))
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }
}

// MARK: - Exact decimals from whole millionths

/// Converting between whole millionths and exact `Decimal` values.
///
/// Every budget and bound in this file starts as an `Int` count of millionths and becomes a
/// `Decimal` with exponent `-6`, so its significand and exponent are the ones written. That
/// is what keeps the arms out of the perturbation a serializer round trip would introduce,
/// and it is why the reference can compare in integers while the measurement compares in
/// decimals without either side rounding.
private enum MetricScale {
    /// `count ÷ 1_000_000`, exactly.
    static func decimal(millionths count: Int) -> Decimal {
        Decimal(sign: .plus, exponent: -6, significand: Decimal(count))
    }

    /// `value × 1_000_000`, for a value the caller knows is a whole number of millionths.
    ///
    /// Used only to derive a generator range from the fixed 1% ceiling and the fixed 95%
    /// level, so it is not on the reference's comparison path: the reference decides the
    /// budget rule in `Int` arithmetic and never multiplies a `Decimal`. Rounding is stated
    /// as `.plain` on values that need none, so the conversion is total rather than trapping.
    static func millionths(_ value: Decimal) -> Int {
        var scaled = Decimal()
        var value = value
        var scale = Decimal(1_000_000)
        _ = NSDecimalMultiply(&scaled, &value, &scale, .plain)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

// MARK: - Attempted measurements

/// What one attempt to measure a slice produced, as a value rather than as a thrown error.
///
/// `propertyCheck` discards an error thrown from its body, so a refusal has to arrive as
/// data. The three cases are the measurement, a schema refusal naming a field, and anything
/// else — the arms distinguish all three so that a refusal for the wrong reason is a failure
/// rather than an unexamined "did not measure".
private enum MeasurementAttempt {
    case measured(ReleaseSliceMeasurement)
    case refused(ArtifactSchemaError)
    case failedOtherwise(String)

    var measurement: ReleaseSliceMeasurement? {
        guard case .measured(let measurement) = self else { return nil }
        return measurement
    }

    /// The refusal's audit text, or `nil` when the attempt was not a schema refusal.
    var refusalText: String? {
        guard case .refused(let error) = self else { return nil }
        return error.description
    }

    var description: String {
        switch self {
        case .measured: "measured"
        case .refused(let error): "refused: \(error.description)"
        case .failedOtherwise(let text): "failed: \(text)"
        }
    }
}

// MARK: - Scenario

/// Builds the artifacts one generated shape describes and measures the slice against them.
private struct ReleaseSliceScenario {
    let shape: SliceShape
    let witness: ReleaseMetricVariationWitness

    /// The predeclared slice specification, carrying the interval method both sides agree
    /// on and the required 95% level the type fixes.
    let specification: ReleaseGatingSliceSpecification

    /// The validated policy the slice is measured against, carrying the generated budget and
    /// the generated pass rule.
    let policy: ValidatedCalibrationPolicy

    /// The label counts the generated roster tallies to.
    let counts: SliceOutcomeCounts

    /// The predeclared confidence-interval result, supplied rather than computed.
    let interval: ConfidenceIntervalResult

    /// The measurement under test.
    let measurement: ReleaseSliceMeasurement

    /// The independent transcription of the requirement sentences.
    let reference: MetricReference

    init?(shape: SliceShape, witness: ReleaseMetricVariationWitness) {
        self.shape = shape
        self.witness = witness

        do {
            self.specification = try Sample.gatingSlice(
                identifier: "slice.generated-\(shape.seed)",
                intervalMethod: shape.intervalMethod,
                isContemporaryPhoneCameraSlice: shape.isContemporaryPhoneCameraSlice
            )
            self.policy = try Sample.activate(
                try Sample.activatablePolicy(
                    budget: try FalseAccusationBudget(
                        validating: MetricScale.decimal(millionths: shape.budgetMillionths)
                    ),
                    passRule: try Sample.passRule(
                        statistic: shape.statistic,
                        intervalMethod: shape.intervalMethod
                    )
                )
            )
            self.counts = try Self.tally(Self.roster(for: shape), errors: shape.errorCount)
            self.interval = try Self.interval(
                method: shape.intervalMethod,
                lowerMillionths: shape.lowerBoundMillionths,
                upperMillionths: shape.upperBoundMillionths
            )
            self.measurement = try ReleaseSliceMeasurement(
                slice: specification,
                counts: counts,
                falsePositiveRateInterval: interval,
                measuredAgainst: policy
            )
        } catch {
            Issue.record("a coherent generated release slice was refused: \(error) [\(shape)]")
            return nil
        }
        self.reference = MetricReference(
            roster: Self.roster(for: shape),
            budgetMillionths: shape.budgetMillionths,
            intervalUpperMillionths: shape.upperBoundMillionths
        )
    }

    // MARK: Building the roster and its tally

    /// One entry per eligible image the shape describes.
    ///
    /// Materialized so the reference can count images rather than read totals. Building it
    /// from the shape's six label counts is deliberate: the counts describe a slice the way
    /// a dataset composition record does, and expanding them is the only step that could
    /// lose an image, which the tally below then makes impossible to hide.
    static func roster(for shape: SliceShape) -> [EligibleImage] {
        var roster: [EligibleImage] = []
        roster.reserveCapacity(shape.realTotal + shape.syntheticTotal)
        let composition: [(GroundTruth, AssignedCategory, Int)] = [
            (.real, .positive, shape.realPositives),
            (.real, .nonPositive, shape.realNonPositives),
            (.real, .insufficient, shape.realAbstentions),
            (.synthetic, .positive, shape.syntheticPositives),
            (.synthetic, .nonPositive, shape.syntheticNonPositives),
            (.synthetic, .insufficient, shape.syntheticAbstentions),
        ]
        for (groundTruth, assigned, count) in composition {
            roster.append(
                contentsOf: repeatElement(
                    EligibleImage(groundTruth: groundTruth, assigned: assigned),
                    count: max(0, count)
                )
            )
        }
        return roster
    }

    /// The label counts `roster` tallies to, in one pass.
    ///
    /// Each eligible population is the sum of the three label counters, which is how a
    /// release evaluator would record what it observed. ``SliceOutcomeCounts`` requires that
    /// sum to hold, so a tally that dropped an abstention could not be built at all — and
    /// the reference, which counts images without reading a label, would disagree with it
    /// even if it could.
    static func tally(_ roster: [EligibleImage], errors: Int) throws -> SliceOutcomeCounts {
        func labelled(_ population: GroundTruth, _ category: AssignedCategory) -> Int {
            roster.filter { $0.groundTruth == population && $0.assigned == category }.count
        }
        let realPositive = labelled(.real, .positive)
        let realNonPositive = labelled(.real, .nonPositive)
        let realInsufficient = labelled(.real, .insufficient)
        let syntheticPositive = labelled(.synthetic, .positive)
        let syntheticNonPositive = labelled(.synthetic, .nonPositive)
        let syntheticInsufficient = labelled(.synthetic, .insufficient)
        return try SliceOutcomeCounts(
            eligibleRealImages: try NonNegativeCount(
                validating: realPositive + realNonPositive + realInsufficient
            ),
            eligibleSyntheticImages: try NonNegativeCount(
                validating: syntheticPositive + syntheticNonPositive + syntheticInsufficient
            ),
            realPositiveLabels: try NonNegativeCount(validating: realPositive),
            realNonPositiveLabels: try NonNegativeCount(validating: realNonPositive),
            realInsufficientLabels: try NonNegativeCount(validating: realInsufficient),
            syntheticPositiveLabels: try NonNegativeCount(validating: syntheticPositive),
            syntheticNonPositiveLabels: try NonNegativeCount(validating: syntheticNonPositive),
            syntheticInsufficientLabels: try NonNegativeCount(
                validating: syntheticInsufficient
            ),
            errorCount: try NonNegativeCount(validating: errors)
        )
    }

    /// A predeclared interval result from whole millionths, exact in every bound.
    static func interval(
        method: ConfidenceIntervalMethod,
        lowerMillionths: Int,
        upperMillionths: Int
    ) throws -> ConfidenceIntervalResult {
        try ConfidenceIntervalResult(
            method: method,
            confidenceLevel: try UnitInterval(
                validating: FalseAccusationPassRule.requiredConfidenceLevel
            ),
            lowerBound: try UnitInterval(
                validating: MetricScale.decimal(millionths: lowerMillionths)
            ),
            upperBound: try UnitInterval(
                validating: MetricScale.decimal(millionths: upperMillionths)
            )
        )
    }

    // MARK: Measuring

    /// One measurement attempt, never a thrown error.
    ///
    /// Each argument defaults to the generated baseline, so an arm states only what it
    /// varies. A policy is rebuilt whenever the statistic changes, because the statistic is
    /// a field of the validated policy rather than an argument to the measurement.
    func measure(
        counts replacementCounts: SliceOutcomeCounts? = nil,
        interval replacementInterval: ConfidenceIntervalResult? = nil,
        statistic: BudgetPassStatistic? = nil
    ) -> MeasurementAttempt {
        let attempt: MeasurementAttempt
        do {
            let activated =
                if let statistic {
                    try Sample.activate(
                        try Sample.activatablePolicy(
                            budget: policy.policy.falseAccusationBudget,
                            passRule: try Sample.passRule(
                                statistic: statistic,
                                intervalMethod: shape.intervalMethod
                            )
                        )
                    )
                } else {
                    policy
                }
            attempt = .measured(
                try ReleaseSliceMeasurement(
                    slice: specification,
                    counts: replacementCounts ?? counts,
                    falsePositiveRateInterval: replacementInterval ?? interval,
                    measuredAgainst: activated
                )
            )
        } catch let error as ArtifactSchemaError {
            attempt = .refused(error)
        } catch {
            attempt = .failedOtherwise("\(error)")
        }
        witness.recordMeasurement(attempt)
        return attempt
    }

    /// The measurement, or `nil` after recording the refusal as a failure.
    ///
    /// Used by arms whose claim is about a measured number: a refusal there is a defect
    /// rather than the answer, and reporting it here keeps the arm's own assertions from
    /// running against a value that does not exist.
    func requireMeasured(
        _ attempt: MeasurementAttempt,
        _ reason: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ReleaseSliceMeasurement? {
        guard let measurement = attempt.measurement else {
            Issue.record(
                "\(reason) was not measured: \(attempt.description) [\(shape)]",
                sourceLocation: sourceLocation
            )
            return nil
        }
        return measurement
    }

    // MARK: Arm 1 — each rate is the reference's rate

    /// Requirements 5.16, 5.17, and 5.18: every rate and every denominator is the one the
    /// reference counted.
    ///
    /// Compared as pairs of integers, so neither side forms a quotient and no rounding
    /// convention enters the comparison — an equal quotient over a different population
    /// is a different pair and fails here.
    ///
    /// Each denominator is then asserted again against the count of images the reference
    /// enumerated, because that is where the requirement's "total number of eligible images"
    /// lives and because it is the claim with a case the ratio comparison cannot state: an
    /// empty population has no rate at all rather than a rate over nothing.
    func checkEachRateMatchesTheReference() {
        witness.recordComparison()
        #expect(
            measurement.falsePositiveRate?.asRatio == reference.falsePositiveRate,
            """
            false-positive rate \(measurement.falsePositiveRate?.description ?? "absent") \
            against reference \(reference.falsePositiveRate?.description ?? "absent") \
            [\(shape)]
            """
        )
        #expect(
            measurement.truePositiveRate?.asRatio == reference.truePositiveRate,
            """
            true-positive rate \(measurement.truePositiveRate?.description ?? "absent") \
            against reference \(reference.truePositiveRate?.description ?? "absent") \
            [\(shape)]
            """
        )
        #expect(
            measurement.coverage.asRatio == reference.coverage,
            """
            coverage \(measurement.coverage.description) against reference \
            \(reference.coverage?.description ?? "absent") [\(shape)]
            """
        )

        // The denominators, stated separately from the ratios.
        expectDenominator(
            of: measurement.falsePositiveRate,
            isEveryEligibleImageOf: reference.eligible(.real),
            named: "false-positive rate",
            population: "eligible real image"
        )
        expectDenominator(
            of: measurement.truePositiveRate,
            isEveryEligibleImageOf: reference.eligible(.synthetic),
            named: "true-positive rate",
            population: "eligible synthetic image"
        )
        // Requirement 5.18 pools both populations, so coverage's denominator is the whole
        // roster rather than either population. It is never absent: a slice with no eligible
        // image at all is refused, so the property is stated over a nonempty slice.
        #expect(
            measurement.coverage.denominator.value == reference.eligibleImages,
            """
            coverage was taken over \(measurement.coverage.denominator.value) images, the \
            slice holds \(reference.eligibleImages) [\(shape)]
            """
        )
    }

    /// Asserts that `rate` is taken over exactly the `eligible` images the reference counted.
    ///
    /// An empty population is the one case in which the requirement defines no ratio, so the
    /// rate has to be absent rather than a rate over nothing: reporting zero there would
    /// claim a population was examined that held no image.
    private func expectDenominator(
        of rate: MeasuredRate?,
        isEveryEligibleImageOf eligible: Int,
        named name: String,
        population: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordComparison()
        guard eligible > 0 else {
            #expect(
                rate == nil,
                """
                the slice holds no \(population), yet the \(name) is \
                \(rate?.description ?? "absent") [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(
            rate?.denominator.value == eligible,
            """
            the \(name) denominator is \(rate?.denominator.description ?? "absent"), the \
            slice holds \(eligible) \(population)s [\(shape)]
            """,
            sourceLocation: sourceLocation
        )
    }

    // MARK: Arm 2 — the abstentions are what the property is named for

    /// Requirements 5.16, 5.17, and 5.18: an insufficient outcome never leaves a denominator.
    ///
    /// The reference computes each rate twice — once as the requirement states it, and once
    /// with the abstaining images removed from the denominator, which is the defect this
    /// property exists to catch. Wherever a population holds an abstention the two differ,
    /// and the measurement has to equal the first; wherever it holds none they coincide,
    /// which is the control that stops the arm from passing on any two unequal numbers.
    func checkDroppingAbstentionsWouldChangeEveryRate() {
        compareAgainstDroppedVariant(
            measured: measurement.falsePositiveRate,
            honest: reference.falsePositiveRate,
            dropped: reference.falsePositiveRateDroppingAbstentions,
            abstentions: reference.assigned(.insufficient, in: .real),
            named: "false-positive rate"
        )
        compareAgainstDroppedVariant(
            measured: measurement.truePositiveRate,
            honest: reference.truePositiveRate,
            dropped: reference.truePositiveRateDroppingAbstentions,
            abstentions: reference.assigned(.insufficient, in: .synthetic),
            named: "true-positive rate"
        )
        compareAgainstDroppedVariant(
            measured: measurement.coverage,
            honest: reference.coverage,
            dropped: reference.coverageDroppingAbstentions,
            abstentions: reference.eligibleImages - reference.decisiveImages,
            named: "coverage"
        )

        // The pooled abstention count the measurement reports is the roster's, so the
        // reported number cannot disagree with the one inside the denominators.
        witness.recordComparison()
        #expect(
            measurement.insufficientOutcomeCount
                == reference.eligibleImages - reference.decisiveImages,
            """
            \(measurement.insufficientOutcomeCount) abstentions reported, the roster holds \
            \(reference.eligibleImages - reference.decisiveImages) [\(shape)]
            """
        )
    }

    /// Asserts that `measured` is `honest` and that `dropped` is the number a denominator
    /// without the abstentions would have produced.
    private func compareAgainstDroppedVariant(
        measured: MeasuredRate?,
        honest: Ratio?,
        dropped: Ratio?,
        abstentions: Int,
        named name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordComparison()
        #expect(
            measured?.asRatio == honest,
            "\(name) is not the requirement's ratio [\(shape)]",
            sourceLocation: sourceLocation
        )
        guard abstentions > 0 else {
            // No abstention in this population, so the two readings coincide. Asserting it
            // keeps the arm honest: a disagreement here would mean the "dropped" variant
            // differs for some reason other than the abstentions.
            #expect(
                dropped == honest,
                """
                \(name) without abstentions is \(dropped?.description ?? "absent") but the \
                population has none to drop [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        witness.recordAbstainingPopulation()
        #expect(
            dropped != honest,
            """
            dropping \(abstentions) abstention(s) from the \(name) denominator changed \
            nothing, so this arm cannot see the defect it exists for [\(shape)]
            """,
            sourceLocation: sourceLocation
        )
        #expect(
            measured?.asRatio != dropped,
            """
            \(name) is \(measured?.description ?? "absent"), which is the value a \
            denominator without its \(abstentions) abstention(s) produces [\(shape)]
            """,
            sourceLocation: sourceLocation
        )
        // The direction, not merely the difference: removing images from a denominator can
        // only shrink it, which is exactly why an abstention that leaves inflates a rate.
        if let dropped, let honest {
            #expect(
                dropped.denominator < honest.denominator,
                """
                the \(name) denominator without abstentions is \(dropped.denominator), not \
                below the \(honest.denominator) the requirement names [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: Arm 3 — coverage's numerator

    /// Requirement 5.18: the insufficient outcomes are excluded from coverage's numerator
    /// and stay in its denominator.
    ///
    /// Reclassifying exactly one abstaining image as decisive is the smallest change that
    /// separates the two roles: the numerator has to move by one and the denominator has to
    /// hold, because the image was always eligible. A measurement that kept abstentions out
    /// of the denominator would move both.
    func checkCoverageCountsOnlyDecisiveLabelsInItsNumerator() {
        witness.recordComparison()
        #expect(
            measurement.coverage.numerator.value == reference.decisiveImages,
            """
            coverage counts \(measurement.coverage.numerator.value) decisive labels, the \
            roster holds \(reference.decisiveImages) [\(shape)]
            """
        )

        var reclassified = Self.roster(for: shape)
        guard
            let abstaining = reclassified.firstIndex(where: { $0.assigned == .insufficient })
        else {
            // No abstention to reclassify. Coverage then counts every eligible image, which
            // is the one case in which the two readings of Requirement 5.18 agree.
            #expect(
                measurement.coverage.isOne,
                "no image abstained, yet coverage is \(measurement.coverage) [\(shape)]"
            )
            return
        }
        let population = reclassified[abstaining].groundTruth
        reclassified[abstaining] = EligibleImage(groundTruth: population, assigned: .nonPositive)

        guard
            let decisiveCounts = try? Self.tally(reclassified, errors: shape.errorCount),
            let decisive = requireMeasured(
                measure(counts: decisiveCounts),
                "the slice with one abstention reclassified as decisive"
            )
        else { return }

        #expect(
            decisive.coverage.denominator == measurement.coverage.denominator,
            """
            reclassifying one abstention moved the coverage denominator from \
            \(measurement.coverage.denominator) to \(decisive.coverage.denominator) [\(shape)]
            """
        )
        #expect(
            decisive.coverage.numerator.value == measurement.coverage.numerator.value + 1,
            """
            reclassifying one abstention moved the coverage numerator from \
            \(measurement.coverage.numerator) to \(decisive.coverage.numerator) [\(shape)]
            """
        )
        // The rate over the population the image belongs to keeps its denominator too: the
        // image was eligible before and after, and only its label changed.
        let denominatorBefore =
            population == .real
            ? measurement.falsePositiveRate?.denominator
            : measurement.truePositiveRate?.denominator
        let denominatorAfter =
            population == .real
            ? decisive.falsePositiveRate?.denominator
            : decisive.truePositiveRate?.denominator
        #expect(
            denominatorBefore == denominatorAfter,
            """
            reclassifying one \(population) abstention moved that population's rate \
            denominator from \(denominatorBefore?.description ?? "absent") to \
            \(denominatorAfter?.description ?? "absent") [\(shape)]
            """
        )
    }

    // MARK: Arm 4 — the pass rule

    /// Requirement 5.21: the pass decision reads the observed false-positive rate and the
    /// predeclared interval, and nothing else.
    ///
    /// Every statistic is exercised in every case rather than only the generated one: the
    /// three read different inputs, and a single drawn statistic would leave which of them
    /// gets checked to the generator's distribution. The reference decides each one by
    /// integer arithmetic over the roster, so agreement is agreement between two separate
    /// derivations rather than between two readings of the same code.
    func checkPassDecisionReadsThePredeclaredRule() {
        for statistic in BudgetPassStatistic.allCases {
            guard
                let measured = requireMeasured(
                    measure(statistic: statistic),
                    "the slice measured under \(statistic.rawValue)"
                )
            else { continue }

            witness.recordComparison()
            let expected: BudgetRuleOutcome =
                switch reference.budgetIsSatisfied(readingStatistic: statistic) {
                case .none: .noObservedFalsePositiveRate
                case .some(true): .evaluated(.passed)
                case .some(false): .evaluated(.failed)
                }
            #expect(
                measured.budgetOutcome == expected,
                """
                \(statistic.rawValue) decided \(measured.budgetOutcome) against reference \
                \(expected) [\(shape)]
                """
            )
            witness.recordBudgetOutcome(measured.budgetOutcome)

            // A slice with no eligible real image never passes, whichever statistic is read:
            // Requirement 5.1 scopes the budget to slices that contain held-out real images,
            // so there is no observed rate for the rule to test.
            if reference.eligible(.real) == 0 {
                #expect(
                    !measured.budgetOutcome.isPassing,
                    """
                    a slice with no eligible real image passed the budget under \
                    \(statistic.rawValue) [\(shape)]
                    """
                )
            }

            // The rule's declared inputs are all readable from the measurement, and both
            // declared ones are the policy's rather than anything this arm supplied.
            #expect(measured.releasePassRule.statistic == statistic)
            #expect(
                measured.falseAccusationBudget.rate
                    == MetricScale.decimal(millionths: shape.budgetMillionths)
            )
            #expect(measured.falseAccusationBudget.rate <= FalseAccusationBudget.maximumRate)
        }
    }

    // MARK: Arm 5 — the interval is consumed, not chosen

    /// Requirement 5.21: the predeclared interval result is consumed as supplied.
    ///
    /// Three claims, because "predeclared" fails in three different ways:
    ///
    ///   * the reported interval is field-for-field the supplied one, compared as typed
    ///     `Decimal` bounds rather than through any rendering of them;
    ///   * a slice whose observed rate is different reports the *identical* interval, so no
    ///     bound can have been derived from the counts. This is the arm that would catch an
    ///     interval computed after the outcomes were seen, which is what Requirement 5.15
    ///     forbids and what Requirement 5.21's rule would then read;
    ///   * any other method, and any other confidence level, is refused rather than adopted.
    func checkPredeclaredIntervalIsCarriedNotChosen() {
        witness.recordComparison()
        #expect(
            measurement.falsePositiveRateInterval == interval,
            "the reported interval is not the supplied one [\(shape)]"
        )
        #expect(measurement.falsePositiveRateInterval.method == shape.intervalMethod)
        #expect(
            measurement.falsePositiveRateInterval.lowerBound.value
                == MetricScale.decimal(millionths: shape.lowerBoundMillionths)
        )
        #expect(
            measurement.falsePositiveRateInterval.upperBound.value
                == MetricScale.decimal(millionths: shape.upperBoundMillionths)
        )
        #expect(
            measurement.falsePositiveRateInterval.confidenceLevel == specification.confidenceLevel
        )

        checkIntervalIsIndependentOfTheObservation()
        checkAnotherMethodIsRefused()
        checkAnotherConfidenceLevelIsRefused()
    }

    /// The same predeclared interval, against a slice whose observed rate differs.
    ///
    /// The alternative roster reassigns every real image to the Positive label, which moves
    /// the observed false-positive rate as far as it can go. If any bound were computed from
    /// the counts it would move with it.
    private func checkIntervalIsIndependentOfTheObservation() {
        let reassigned = Self.roster(for: shape).map { image in
            image.groundTruth == .real
                ? EligibleImage(groundTruth: .real, assigned: .positive)
                : image
        }
        guard
            let alternativeCounts = try? Self.tally(reassigned, errors: shape.errorCount),
            let alternative = requireMeasured(
                measure(counts: alternativeCounts),
                "the slice with every real image assigned the positive label"
            )
        else { return }

        witness.recordComparison()
        #expect(
            alternative.falsePositiveRateInterval == interval,
            """
            the reported interval changed with the observation, from \
            \(interval.lowerBound)...\(interval.upperBound) to \
            \(alternative.falsePositiveRateInterval.lowerBound)...\
            \(alternative.falsePositiveRateInterval.upperBound) [\(shape)]
            """
        )
        // The positive control for this arm: the observation really did move, so the
        // unchanged interval is a fact about the interval rather than about two identical
        // slices. Only a slice whose real images were not already all positive can move.
        if reference.eligible(.real) > reference.assigned(.positive, in: .real) {
            #expect(
                alternative.falsePositiveRate != measurement.falsePositiveRate,
                """
                reassigning every real image left the observed rate at \
                \(measurement.falsePositiveRate?.description ?? "absent") [\(shape)]
                """
            )
        }
    }

    /// Requirement 5.15: an interval computed with a method nobody predeclared is refused.
    private func checkAnotherMethodIsRefused() {
        for method in ConfidenceIntervalMethod.allCases where method != shape.intervalMethod {
            guard
                let other = try? Self.interval(
                    method: method,
                    lowerMillionths: shape.lowerBoundMillionths,
                    upperMillionths: shape.upperBoundMillionths
                )
            else {
                Issue.record("a \(method.rawValue) interval could not be built [\(shape)]")
                continue
            }
            witness.recordComparison()
            expectRefusal(
                measure(interval: other),
                naming: "falsePositiveRateInterval.method",
                "an interval computed with \(method.rawValue) rather than the predeclared "
                    + shape.intervalMethod.rawValue
            )
        }
    }

    /// Requirement 5.19's 95% level, read from the predeclared specification: a result at
    /// any other level is refused.
    ///
    /// The off-level values are derived by stepping away from the predeclared level rather
    /// than written out, so this arm does not restate the number the schema owns.
    private func checkAnotherConfidenceLevelIsRefused() {
        let predeclared = MetricScale.millionths(FalseAccusationPassRule.requiredConfidenceLevel)
        for offset in [-50_000, 1] {
            let level = MetricScale.decimal(millionths: predeclared + offset)
            guard
                let other = try? ConfidenceIntervalResult(
                    method: shape.intervalMethod,
                    confidenceLevel: try UnitInterval(validating: level),
                    lowerBound: try UnitInterval(
                        validating: MetricScale.decimal(millionths: shape.lowerBoundMillionths)
                    ),
                    upperBound: try UnitInterval(
                        validating: MetricScale.decimal(millionths: shape.upperBoundMillionths)
                    )
                )
            else {
                Issue.record("an interval at level \(level) could not be built [\(shape)]")
                continue
            }
            witness.recordComparison()
            expectRefusal(
                measure(interval: other),
                naming: "falsePositiveRateInterval.confidenceLevel",
                "an interval reported at level \(level)"
            )
        }
    }

    /// Asserts that `attempt` was refused with a schema error naming `field`.
    private func expectRefusal(
        _ attempt: MeasurementAttempt,
        naming field: String,
        _ reason: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordRefusedField(field)
        guard let text = attempt.refusalText else {
            Issue.record(
                "\(reason) was not refused: \(attempt.description) [\(shape)]",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(
            text.contains(field),
            "\(reason) was refused without naming \(field): \(text) [\(shape)]",
            sourceLocation: sourceLocation
        )
    }

    // MARK: Arm 6 — an Analysis Error is in no denominator

    /// Requirements 5.16 through 5.18: an image that produced an Analysis Error received no
    /// label, so it is neither a numerator nor a denominator member.
    ///
    /// Changing the error count alone therefore has to move nothing. The two counts differ
    /// by construction, so the arm is not comparing a slice with itself.
    func checkErrorCountIsInNoDenominator() {
        let otherErrorCount = shape.errorCount == 0 ? 1 : 0
        guard
            let otherCounts = try? Self.tally(
                Self.roster(for: shape),
                errors: otherErrorCount
            ),
            let other = requireMeasured(
                measure(counts: otherCounts),
                "the slice with \(otherErrorCount) Analysis Error(s)"
            )
        else { return }

        witness.recordComparison()
        #expect(other.errorCount.value == otherErrorCount)
        #expect(measurement.errorCount.value == shape.errorCount)
        #expect(
            other.falsePositiveRate == measurement.falsePositiveRate,
            "the error count moved the false-positive rate [\(shape)]"
        )
        #expect(
            other.truePositiveRate == measurement.truePositiveRate,
            "the error count moved the true-positive rate [\(shape)]"
        )
        #expect(
            other.coverage == measurement.coverage,
            "the error count moved coverage [\(shape)]"
        )
        #expect(
            other.budgetOutcome == measurement.budgetOutcome,
            "the error count moved the budget decision [\(shape)]"
        )
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the arms observed, so the property cannot
/// pass by generating one fixed slice a hundred times or by skipping its arms.
///
/// A `propertyCheck` body that throws before reaching its assertions passes in milliseconds
/// with every arm skipped, and this property does arithmetic rather than I/O, so a fast run
/// is not evidence either way. This collects the dimensions the arms depend on, the number
/// of cases, the number of cases that reached the end of the body, how many measurements and
/// comparisons were actually performed, and which budget outcomes were reached, and asserts
/// all of it *outside* the body where an issue is not suppressed.
///
/// The variation thresholds are far below what 100 draws produce, so they witness variation
/// rather than pinning a distribution. Two of the assertions are not thresholds at all: both
/// budget outcomes have to occur, or the pass-rule arm only ever saw one answer; and a
/// population carrying an abstention has to occur, or the arm the property is named for
/// never had anything to drop.
private final class ReleaseMetricVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var mixes = Set<PopulationMix>()
    private var densities = Set<PositiveDensity>()
    private var placements = Set<UpperBoundPlacement>()
    private var methods = Set<ConfidenceIntervalMethod>()
    private var statistics = Set<BudgetPassStatistic>()
    private var budgets = Set<Int>()
    private var realPopulations = Set<Int>()
    private var syntheticPopulations = Set<Int>()
    private var abstentionCounts = Set<Int>()
    private var errorCounts = Set<Int>()
    private var observedBudgetOutcomes = Set<BudgetRuleOutcome>()
    private var refusalFields = Set<String>()
    private var cases = 0
    private var completedArms = 0
    private var measurements = 0
    private var refusals = 0
    private var comparisons = 0
    private var abstainingPopulations = 0

    func record(_ shape: SliceShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        mixes.insert(shape.mix)
        densities.insert(shape.positiveDensity)
        placements.insert(shape.upperBoundPlacement)
        methods.insert(shape.intervalMethod)
        statistics.insert(shape.statistic)
        budgets.insert(shape.budgetMillionths)
        realPopulations.insert(shape.realTotal)
        syntheticPopulations.insert(shape.syntheticTotal)
        abstentionCounts.insert(shape.realAbstentions + shape.syntheticAbstentions)
        errorCounts.insert(shape.errorCount)
    }

    func recordMeasurement(_ attempt: MeasurementAttempt) {
        lock.lock()
        defer { lock.unlock() }
        measurements += 1
        if case .refused = attempt { refusals += 1 }
    }

    /// The field an arm asserted a refusal against, so the run can be shown to have
    /// exercised every refusal the interval arms state rather than one of them repeatedly.
    func recordRefusedField(_ field: String) {
        lock.lock()
        refusalFields.insert(field)
        lock.unlock()
    }

    func recordComparison() {
        lock.lock()
        comparisons += 1
        lock.unlock()
    }

    /// Called whenever an arm found a population with something to drop.
    func recordAbstainingPopulation() {
        lock.lock()
        abstainingPopulations += 1
        lock.unlock()
    }

    func recordBudgetOutcome(_ outcome: BudgetRuleOutcome) {
        lock.lock()
        observedBudgetOutcomes.insert(outcome)
        lock.unlock()
    }

    /// Called at the end of the body, so a case that stopped early is countable.
    func recordCompletedArms() {
        lock.lock()
        completedArms += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases, ran \(cases)")
        #expect(
            completedArms == cases,
            "\(cases - completedArms) of \(cases) cases did not reach the end of the body"
        )
        // The six arms build about a dozen measurements and score about twenty comparisons
        // per case. Both floors are well below that so they do not pin an arm's internal
        // loop, but far enough above zero that a run which constructed policies without
        // measuring or comparing anything fails here rather than passing quickly.
        #expect(measurements >= 700, "measurements attempted: \(measurements)")
        #expect(comparisons >= 700, "comparisons performed: \(comparisons)")
        // Six intervals per case are deliberately unpredeclared, so a run in which nothing
        // was refused means the refusal arms did not execute.
        #expect(refusals >= 500, "refusals observed: \(refusals)")
        // Not a threshold: both refusals the interval arms state have to have been asserted,
        // so neither the method arm nor the level arm can have been skipped.
        #expect(
            refusalFields == [
                "falsePositiveRateInterval.confidenceLevel",
                "falsePositiveRateInterval.method",
            ],
            "refusals were asserted against \(refusalFields.sorted())"
        )

        // The seed is drawn from 10,000 values, so a constant baseline shows 1.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(mixes == Set(PopulationMix.allCases), "generated population mixes: \(mixes)")
        #expect(
            densities == Set(PositiveDensity.allCases),
            "generated positive densities: \(densities)"
        )
        #expect(
            placements == Set(UpperBoundPlacement.allCases),
            "generated interval placements: \(placements)"
        )
        #expect(
            methods == Set(ConfidenceIntervalMethod.allCases),
            "predeclared interval methods: \(methods.map(\.rawValue).sorted())"
        )
        #expect(
            statistics == Set(BudgetPassStatistic.allCases),
            "predeclared statistics: \(statistics.map(\.rawValue).sorted())"
        )
        // The budget is drawn from 10,000 admissible values. The floor is an order of
        // magnitude above a constant baseline rather than a share of the range: the
        // generator concentrates its draws rather than spreading them uniformly.
        #expect(budgets.count >= 25, "generated budgets: \(budgets.count)")
        #expect(realPopulations.count >= 25, "generated real populations: \(realPopulations)")
        #expect(
            syntheticPopulations.count >= 25,
            "generated synthetic populations: \(syntheticPopulations.count)"
        )
        #expect(abstentionCounts.count >= 25, "generated abstention totals: \(abstentionCounts)")
        #expect(errorCounts.count >= 10, "generated error counts: \(errorCounts.count)")

        // The arm the property is named for had something to drop, many times over.
        #expect(
            abstainingPopulations >= 100,
            "populations carrying an abstention: \(abstainingPopulations)"
        )
        // Both budget answers and the no-observed-rate case were reached, so the pass-rule
        // arm compared a decision rather than one constant.
        #expect(
            observedBudgetOutcomes.isSuperset(of: [.evaluated(.passed), .evaluated(.failed)]),
            "observed budget outcomes: \(observedBudgetOutcomes)"
        )
        #expect(
            observedBudgetOutcomes.contains(.noObservedFalsePositiveRate),
            "no synthetic-only slice reached the budget rule: \(observedBudgetOutcomes)"
        )
    }
}

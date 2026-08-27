import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 18: Calibration release approval requires complete independent evidence.
//
// The design states it as: for any Model Bundle, Calibration Policy, dataset-lineage
// record, and mandatory slice result set, the bundle-policy combination is release-eligible
// only when calibration/evaluation populations are properly separated, every required
// report field and interval is present, and every mandatory slice passes the budget and
// confidence rule; one missing, incompatible, contaminated, or failing element blocks
// approval.
//
// Quantified here as one property with four arms over every generated release:
//
//   * complete evidence approves — the generated release is coherent in every respect, and
//     the approval reads back the budget, pass rule, mandatory slice set, lineage, and the
//     two separate populations that were generated rather than any value written here. This
//     is the control every refusal below is attributable against;
//   * every mandatory slice is completely reported — for each slice the approval carries the
//     false-positive rate, true-positive rate, coverage, error count, dataset composition,
//     degradation condition, and an interval predeclared at exactly 95%; each reported rate
//     is shown to be the measured ratio by an exact integer identity rather than by comparing
//     two quotients; and a slice specification predeclaring any other confidence level cannot
//     be constructed at all (Requirement 5.19);
//   * every element is individually necessary — the arm the property is named for. A complete
//     release has exactly one separation, report, interval, compatibility, or pass element
//     removed or invalidated, and approval has to be blocked with a *specific* refusal naming
//     that element's position and the gate's own reason. Every case knocks out every element in
//     ``EvidenceElement`` on its own, and ``CalibrationEvidenceVariationWitness`` requires each
//     of those refusals to have actually been produced. The two exceptions prove the rule: the
//     observed rate and the interval's upper bound each block only when the predeclared
//     statistic reads them, and the witness requires all four branches
//     (Requirements 5.5, 5.6, 5.19, 5.22, 5.23);
//   * any incomplete combination is blocked — a freely generated subset of the same elements
//     is removed at once. A subset that removes nothing the predeclared rule reads still
//     approves; any effective subset is blocked, and the refusal has to name a position one of
//     the active elements broke.
//
// The pairing of the last two arms is deliberate. A randomly sampled combination space can
// leave an element that never mattered looking necessary, because some other element in the
// same draw did all the work. The one-at-a-time knockout is what makes each element's
// necessity a fact about that element; the freely generated combination is what keeps the
// property from being a list of independent examples.
//
// `CalibrationReleaseApprovalTests` pins these behaviors at chosen counts with one example
// each. The neighbouring calibration properties belong to their own tasks: Property 15 is
// policy validity, Property 16 is evaluation totality, and Property 17 is release metric
// semantics. Task 7.9 owns the literal boundary and metric-denominator example tests, so no
// arm here restates one of those.
//
// ## Why nothing here is serialized
//
// This property turns on exact decimals: the False Accusation Budget is a rate at or below
// 1%, the predeclared interval's bounds are compared against it, and Requirement 5.19 fixes
// the confidence level at exactly 95%. `JSONSerialization` perturbs exact decimals, so an
// assertion built on a serializer round trip would hold whether or not the value under test
// survived it. Every artifact here is therefore a typed value; every budget, bound, rate, and
// level starts as an `Int` count of whole millionths and becomes a `Decimal` with exponent
// `-6`, so its significand and exponent are the ones written; and the generated populations
// come from a table in which every eligible population and every pooled total divides one
// million, so each reported rate is an exact whole number of millionths rather than a
// rounding this file would have to pick a convention for. No arm mutates payload text, so no
// splice helper is needed here.
//
// ## Why no arm throws
//
// `propertyCheck` discards an error thrown from its body: a `throw` before the assertions
// makes the whole run pass in milliseconds with every arm skipped, and a record-validation
// property does comparisons rather than I/O, so a fast run is no evidence either way. Every
// approval here goes through ``ApprovalInputs/approve()``, which turns a refusal into an
// ``ApprovalAttempt`` value, and every helper reports through `Issue.record`.
// ``CalibrationEvidenceVariationWitness`` counts the cases, the arms that completed, the
// approvals, the knockouts, the comparisons, and *which* refusals were produced, and asserts
// all of it outside the body where an issue is not suppressed.
//
// No value in this file is an approved budget, boundary, slice, dataset, separation result,
// interval, interval method, pass rule, or model. Every identifier carries the generated
// seed, every count and bound comes from a synthetic range, and the two fixed numbers any arm
// reads — the 1% budget ceiling and the 95% confidence level — are read from
// ``FalseAccusationBudget/maximumRate`` and
// ``FalseAccusationPassRule/requiredConfidenceLevel``, which own them.

extension Tag {
    /// Design Property 18.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property gets
    /// one dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property18CalibrationReleaseEvidence: Self
}

@Suite(
    "Property 18: Calibration release approval requires complete independent evidence",
    .tags(.property18CalibrationReleaseEvidence)
)
struct CalibrationReleaseEvidencePropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the minimum
    /// the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 5.5, 5.6, 5.19, 5.22, 5.23**
    @Test("Release approval requires complete independent calibration evidence")
    func calibrationReleaseApprovalRequiresCompleteIndependentEvidence() async {
        let witness = CalibrationEvidenceVariationWitness()

        await propertyCheck(input: EvidenceShape.generator) { shape in
            witness.record(shape)
            guard let scenario = EvidenceScenario(shape: shape, witness: witness) else {
                return
            }
            guard let approved = scenario.checkCompleteEvidenceApproves() else { return }

            scenario.checkEveryMandatorySliceIsCompletelyReported(approved)
            scenario.checkEveryElementIsIndividuallyNecessary()
            scenario.checkAnyIncompleteCombinationIsBlocked()

            witness.recordCompletedArms()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The elements a release's calibration evidence is made of

/// One removable or invalidatable element of a complete calibration evidence set.
///
/// Every case is a single edit to one position of an otherwise coherent release, and every
/// case has to block approval on its own. Grouped by the five kinds of element Requirements
/// 5.22 and 5.23 reach: the recorded population separation, the recorded slice reports, the
/// predeclared interval, exact compatibility between what was measured and what ships, and
/// the predeclared budget pass rule.
///
/// `CaseIterable` so the knockout arm sweeps the set rather than a hand-written list: a case
/// added here without an expectation is a compile error in
/// ``EvidenceScenario/expectation(for:)``, and a case whose refusal stops firing is a witness
/// failure at the end of the run rather than an arm that quietly stops asserting.
private enum EvidenceElement: String, CaseIterable, Sendable {

    // MARK: Separation and the two independent populations (Requirements 5.5, 5.6, 5.23)

    /// One of the three unordered population pairs carries no recorded result at all.
    case separationPairOmitted

    /// One pair is recorded twice, the second time with its two populations swapped, so a
    /// contradictory verification could sit beside a passing one.
    case separationPairRecordedTwice

    /// One pair's sample-level verification did not pass.
    case sampleLevelSeparationNotPassing

    /// One pair's content-level verification did not pass. Checked separately from the sample
    /// level, because identical identifiers and identical content are different kinds of
    /// contamination and a release that checked only identifiers has not established the
    /// second.
    case contentLevelSeparationNotPassing

    /// The artifact a recorded separation pass cites is not evidence this release carries.
    case separationEvidenceOutsideThisRelease

    /// The corrected-identifier record behind the content-level claim is unfindable.
    case identifierCorrectionOutsideThisRelease

    /// The duplicate-content-hash disposition behind the content-level claim is unfindable.
    case duplicateHashDispositionOutsideThisRelease

    /// The held-out calibration evidence the boundaries were derived from is not evidence this
    /// release carries, even though the policy activated legitimately against another index.
    case heldOutCalibrationEvidenceOutsideThisRelease

    /// One artifact is both the held-out calibration evidence and a mandatory slice's
    /// evaluation dataset composition, so one record describes both populations
    /// (Requirement 5.6).
    case calibrationEvidenceReusedAsEvaluationPopulation

    // MARK: Reports (Requirement 5.19)

    /// A mandatory slice that can be reported truthfully carries no recorded report.
    case sliceReportOmitted

    /// A recorded report's Analysis Error count is not the measured one.
    case reportedErrorCountDisagrees

    /// A recorded report states a budget outcome the measurement did not produce.
    case reportedBudgetOutcomeDisagrees

    /// The specification artifact a recorded report cites is unfindable.
    case reportSpecificationOutsideThisRelease

    /// One of a slice's five predeclared references is unfindable.
    case predeclaredSliceReferenceOutsideThisRelease

    /// No slice is designated the contamination-controlled contemporary phone-camera
    /// real-image subset, so the mandatory set is not the one this release owes reports for.
    case contemporaryPhoneCameraSliceNotDesignated

    /// A predeclared mandatory slice was never measured, so it has no report at all.
    case predeclaredSliceUnmeasured

    // MARK: The predeclared interval (Requirement 5.19)

    /// A recorded report states an interval other than the predeclared one measured against.
    case reportedIntervalDisagrees

    /// The predeclared interval's upper bound sits above the budget. Blocks exactly when the
    /// predeclared statistic reads that bound, which is what shows the pass rule is read
    /// rather than assumed.
    case intervalUpperBoundAboveTheBudget

    // MARK: Compatibility

    /// Every slice was measured against another Calibration Policy.
    case measuredAgainstAnotherPolicy

    /// Every slice was measured against another Model Bundle.
    case measuredAgainstAnotherBundle

    /// The measured policy carries the shipping policy's identifier and different content, so
    /// the budget the slices were measured against is not the budget this release ships.
    case measuredPolicyCarriesOtherContent

    /// A recorded report names another Calibration Policy.
    case reportNamesAnotherPolicy

    /// A recorded report names another Model Bundle.
    case reportNamesAnotherBundle

    /// A recorded separation pass cites its evidence at a version this release does not carry,
    /// so the citation names other content.
    case separationEvidenceCitedAtAnotherVersion

    /// A slice was measured against a specification edited after evaluation began, under the
    /// identifier of the one that was predeclared.
    case predeclarationEditedAfterEvaluation

    // MARK: The budget pass rule (Requirement 5.22)

    /// One mandatory slice's observed false-positive rate exceeds the budget. Blocks exactly
    /// when the predeclared statistic reads the observed rate, which is the mirror image of
    /// ``intervalUpperBoundAboveTheBudget``.
    case sliceExceedsTheBudget

    /// One mandatory slice holds no eligible held-out real image, while its record still states
    /// a budget outcome the predeclared rule never produced.
    case sliceRealPopulationRemoved

    /// One mandatory slice holds no eligible held-out real image and honestly carries no
    /// record, so the predeclared rule could not be applied to a mandatory slice at all.
    case budgetRuleCouldNotBeApplied

    /// The two elements whose effect depends on which statistic the pass rule predeclared.
    ///
    /// Requirement 5.22 blocks a mandatory slice that exceeds the budget *or* fails the
    /// predeclared confidence-interval rule, and ``BudgetPassStatistic`` decides which of the
    /// two a given policy reads: a policy predeclaring the interval's upper bound alone does
    /// not read the observed rate, and one predeclaring the observed rate alone does not read
    /// the bound. Each of these two elements therefore has a blocking branch and an inert
    /// branch, and the witness requires all four to have occurred — which is what shows the
    /// gate reads the predeclared statistic rather than assuming one.
    ///
    /// Stated as a set rather than derived, so an element that becomes statistic-dependent, or
    /// stops being, fails the witness's coverage assertion instead of quietly changing what
    /// the property claims.
    static let readThroughThePredeclaredStatistic: Set<EvidenceElement> = [
        .sliceExceedsTheBudget, .intervalUpperBoundAboveTheBudget,
    ]

    /// Whether removing this element blocks approval for the release `shape` describes.
    ///
    /// A new element defaults to blocking, which is the safe direction here: it is
    /// ``EvidenceScenario/expectation(for:)`` that is exhaustive, so a new element still has to
    /// have its fault and position stated before this file compiles.
    func blocks(in shape: EvidenceShape) -> Bool {
        switch self {
        case .sliceExceedsTheBudget:
            shape.statisticReadsTheObservedRate
        case .intervalUpperBoundAboveTheBudget:
            shape.statisticReadsTheIntervalUpperBound
        default:
            true
        }
    }
}

/// Which of a slice's five predeclared references one knockout makes unfindable.
///
/// Generated rather than swept, so the shrinker can reduce a failing case to one reference and
/// so 100 cases spread across the five instead of every case paying for all of them. The
/// witness requires all five to have been exercised. The raw values are the field names the
/// gate reports, so an arm can require the refusal to name the reference that was removed.
private enum SliceReferenceSite: String, CaseIterable, Sendable {
    case eligibilityRule
    case outcomeMapping
    case metricDefinition
    case datasetComposition
    case degradationCondition
}

// MARK: - Synthetic identifiers

/// Every identifier one generated release uses, carrying the generated seed.
///
/// Seeded so two cases never describe the same release and so a failure message names the
/// exact synthetic artifact that was broken. Nothing here is an approved identifier. The
/// preprocessing contract and verdict-copy compatibility identifiers are deliberately absent:
/// they are supplied by the shared bundle-manifest sample, and the policy has to match them
/// exactly for activation to succeed, so this file does not get to choose them.
private struct EvidenceNames: Sendable {
    let seed: Int

    private var suffix: String { "-\(seed)" }

    var calibrationEvidence: String { "evidence.calibration" + suffix }
    var eligibilityRule: String { "evidence.eligibility" + suffix }
    var outcomeMapping: String { "evidence.outcome-mapping" + suffix }
    var metricDefinition: String { "evidence.metric" + suffix }
    var datasetComposition: String { "evidence.composition" + suffix }
    var degradationCondition: String { "evidence.degradation" + suffix }
    var revisedDegradationCondition: String { "evidence.degradation-revised" + suffix }
    var separation: String { "evidence.separation" + suffix }
    var identifierCorrection: String { "evidence.identifier-correction" + suffix }
    var duplicateHashDisposition: String { "evidence.duplicate-hashes" + suffix }
    var sliceSpecification: String { "evidence.slice-specification" + suffix }

    var lineage: String { "record.dataset-lineage" + suffix }
    var policy: String { "policy.calibration" + suffix }
    var otherPolicy: String { "policy.elsewhere" + suffix }
    var bundle: String { "bundle.sample" + suffix }
    var otherBundle: String { "bundle.elsewhere" + suffix }

    /// Slice identifiers sort in index order for the counts this file generates, so the slice
    /// the approval gate reports first is slice 0.
    func slice(_ index: Int) -> String { "slice.gating-\(index)" + suffix }

    /// Every artifact this release carries, which is exactly what its evidence index holds.
    ///
    /// The revised degradation condition is in the index and cited by nothing, so the knockout
    /// that edits a predeclaration after evaluation edits it to something that *resolves* —
    /// otherwise that knockout would be an unresolvable reference wearing another name.
    var citedEvidence: [String] {
        [
            calibrationEvidence, eligibilityRule, outcomeMapping, metricDefinition,
            datasetComposition, degradationCondition, revisedDegradationCondition,
            separation, identifierCorrection, duplicateHashDisposition, sliceSpecification,
        ]
    }

    func identifier(of site: SliceReferenceSite) -> String {
        switch site {
        case .eligibilityRule: eligibilityRule
        case .outcomeMapping: outcomeMapping
        case .metricDefinition: metricDefinition
        case .datasetComposition: datasetComposition
        case .degradationCondition: degradationCondition
        }
    }
}

// MARK: - Exact decimals from whole millionths

/// Converting between whole millionths and exact `Decimal` values.
///
/// Every budget, bound, rate, and confidence level in this file starts as an `Int` count of
/// millionths and becomes a `Decimal` with exponent `-6`, so its significand and exponent are
/// the ones written rather than a rounded rendering. That is what keeps the arms out of the
/// perturbation a serializer round trip would introduce.
private enum MillionthScale {
    /// `count ÷ 1_000_000`, exactly.
    static func decimal(millionths count: Int) -> Decimal {
        Decimal(sign: .plus, exponent: -6, significand: Decimal(count))
    }

    /// `value × 1_000_000`, for a value the caller knows is a whole number of millionths.
    ///
    /// Used only to turn the fixed 1% ceiling and the fixed 95% level into generator ranges,
    /// so it is on no comparison path: every comparison below is between two `Int` counts or
    /// between two exact `Decimal` values. Rounding is stated as `.plain` on values that need
    /// none, so the conversion is total rather than trapping.
    static func millionths(_ value: Decimal) -> Int {
        var scaled = Decimal()
        var value = value
        var scale = Decimal(1_000_000)
        _ = NSDecimalMultiply(&scaled, &value, &scale, .plain)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// The exact millionths of a measured rate, or `nil` when its population does not divide
    /// one million.
    ///
    /// `nil` is a fault in the generated population table rather than in the code under test,
    /// and every caller reports it as an issue: a rate that is not a whole number of millionths
    /// cannot be reported exactly, and every reported rate here is exact.
    static func millionths(of rate: MeasuredRate) -> Int? {
        let population = rate.denominator.value
        guard population > 0, 1_000_000 % population == 0 else { return nil }
        return rate.numerator.value * (1_000_000 / population)
    }
}

// MARK: - Generated shape

/// Everything one generated release is built from, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside ``EvidenceScenario``,
/// where a construction that unexpectedly throws is recorded as a failure rather than
/// escaping.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant asserts one example a hundred times over, so
/// every dimension the arms depend on is generated:
///
///   * every identifier, through ``seed``;
///   * how many mandatory slices the release predeclares, and which slice, pair, and report
///     each knockout breaks, through ``rotation``;
///   * the False Accusation Budget, anywhere in the admissible range up to the 1% ceiling;
///   * which of the three predeclared statistics the pass rule reads, and which of the five
///     predeclared interval methods the slices and the policy agree on;
///   * the two eligible populations, from a table in which every population and every pooled
///     total divides one million;
///   * how the images in each population were labeled, over the full range, so slices with no
///     abstention, with some, and with nothing but abstentions all occur;
///   * the Analysis Error count no rate may read;
///   * where the predeclared interval's bounds sit inside the budget, and how far above it a
///     knocked-out bound sits;
///   * which non-passing outcome a broken separation verification recorded;
///   * which of a slice's five predeclared references one knockout unresolves;
///   * the version a miscited separation record names, and a confidence level other than the
///     fixed 95%;
///   * how many elements the combination arm removes at once, and which ones.
private struct EvidenceShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so the whole reference set varies together and stays
    /// coherent without a cross-reference table.
    let seed: Int

    /// Selects the number of mandatory slices.
    let sliceCountSelector: Int

    /// Rotates which pair, which slice, and which report each knockout breaks.
    let rotation: Int

    /// The False Accusation Budget, in whole millionths. At most the 1% ceiling.
    let budgetMillionths: Int

    let statisticSelector: Int
    let methodSelector: Int

    /// Index into ``EvidenceShape/populationTable``.
    let populationSelector: Int

    /// Real images the run assigned the Positive Pixel Label, before the budget clamp.
    let requestedRealPositives: Int

    /// Analysis Errors encountered while evaluating the slice.
    let errorCount: Int

    /// Thousandths of the remaining real images that abstained.
    let realAbstentionPermille: Int

    /// Thousandths of the synthetic images assigned the Positive Pixel Label.
    let syntheticPositivePermille: Int

    /// Thousandths of the remaining synthetic images that abstained.
    let syntheticAbstentionPermille: Int

    /// Millionths below the budget the predeclared interval's upper bound sits.
    let upperBoundOffsetMillionths: Int

    /// Millionths below the upper bound the lower bound sits.
    let lowerBoundOffsetMillionths: Int

    /// Millionths above the budget a knocked-out upper bound sits.
    let excessBoundMillionths: Int

    let nonPassingOutcomeSelector: Int
    let referenceSiteSelector: Int

    /// Components of a version this release does not carry. The major component is derived
    /// with a positive floor, so the trio is never the rejected `0.0.0` placeholder and never
    /// the `1.0.0` the evidence index holds.
    let otherVersionMinor: Int
    let otherVersionPatch: Int

    /// A confidence level other than the fixed 95%, in whole millionths.
    let otherConfidenceLevelMillionths: Int

    /// How many elements the combination arm removes at once, and which.
    let combinationSize: Int
    let combinationSelectors: [Int]

    var description: String {
        """
        seed \(seed), \(sliceCount) slices, rotation \(rotation), \
        budget \(budgetMillionths)/1e6, \(statistic.rawValue), \(intervalMethod.rawValue), \
        real \(realPopulation), synthetic \(syntheticPopulation), \
        interval \(lowerBoundMillionths)...\(upperBoundMillionths)/1e6, \
        combination \(generatedCombination.map(\.rawValue).sorted())
        """
    }

    // MARK: Slices

    /// Mandatory slices in the release.
    ///
    /// At least three, so the two knockouts that empty a slice's eligible real population
    /// always have a general slice each and never have to target the contemporary phone-camera
    /// slice, whose real population is required to be nonempty in its own right.
    var sliceCount: Int { 3 + (sliceCountSelector % 2) }

    // MARK: Populations

    /// Eligible population pairs in which each population and their pooled total divides one
    /// million.
    ///
    /// That is what makes every reported rate an exact whole number of millionths rather than
    /// a rounding, which in turn is what lets a recorded report state the measured ratio
    /// exactly instead of a value this file would have to pick a rounding convention for.
    /// ``EvidenceScenario`` re-checks the divisibility at run time, so an edit here that breaks
    /// it fails rather than silently reintroducing rounding.
    ///
    /// One million is `2^6 × 5^6`, so a population divides it only when it is `2^a × 5^b` with
    /// both exponents at most six — `400_000` and `800_000` look like round numbers and are
    /// not divisors. Every entry here is therefore drawn from the two families that stay
    /// closed under addition inside that set: equal populations, whose total is twice one of
    /// them, and a four-to-one split, whose total is five times the smaller one.
    static let populationTable: [(real: Int, synthetic: Int)] = [
        (500_000, 500_000),
        (250_000, 250_000),
        (200_000, 50_000),
        (125_000, 125_000),
        (100_000, 100_000),
        (100_000, 25_000),
        (62_500, 62_500),
        (50_000, 50_000),
        (50_000, 12_500),
        (40_000, 10_000),
        (31_250, 31_250),
        (25_000, 25_000),
        (25_000, 100_000),
        (20_000, 5_000),
        (12_500, 12_500),
        (10_000, 2_500),
    ]

    private var population: (real: Int, synthetic: Int) {
        Self.populationTable[populationSelector % Self.populationTable.count]
    }

    var realPopulation: Int { population.real }
    var syntheticPopulation: Int { population.synthetic }

    /// Millionths one eligible real image contributes to the false-positive rate.
    var realImageMillionths: Int { 1_000_000 / realPopulation }

    /// The most positive labels an eligible real population can carry and still satisfy the
    /// budget.
    ///
    /// Requirement 5.22 blocks a slice that *exceeds* the budget, so a rate exactly on the
    /// budget satisfies it, which is why this is a floor rather than a floor minus one.
    var positivesWithinBudget: Int { budgetMillionths / realImageMillionths }

    /// One more positive label than the budget admits, so the observed rate exceeds it.
    var positivesAboveBudget: Int { min(realPopulation, positivesWithinBudget + 1) }

    // MARK: Predeclarations

    var statistic: BudgetPassStatistic {
        BudgetPassStatistic.allCases[statisticSelector % BudgetPassStatistic.allCases.count]
    }

    var intervalMethod: ConfidenceIntervalMethod {
        ConfidenceIntervalMethod.allCases[
            methodSelector % ConfidenceIntervalMethod.allCases.count
        ]
    }

    /// Whether the predeclared pass rule reads the observed false-positive rate.
    ///
    /// Exhaustive with no `default`, so a new statistic is a compile error here rather than one
    /// this property silently assumes reads nothing.
    var statisticReadsTheObservedRate: Bool {
        switch statistic {
        case .observedRate, .observedRateAndIntervalUpperBound: true
        case .intervalUpperBound: false
        }
    }

    /// Whether the predeclared pass rule reads the predeclared interval's upper bound.
    var statisticReadsTheIntervalUpperBound: Bool {
        switch statistic {
        case .intervalUpperBound, .observedRateAndIntervalUpperBound: true
        case .observedRate: false
        }
    }

    /// The predeclared interval's upper bound, in whole millionths, never above the budget.
    ///
    /// Reduced modulo the budget so the bound spreads across the admissible range instead of
    /// collapsing onto its floor, and so the case in which it sits exactly on the budget is
    /// reachable. At least 2, which is what lets the lower bound sit strictly below.
    var upperBoundMillionths: Int {
        2 + (upperBoundOffsetMillionths % (budgetMillionths - 1))
    }

    /// The predeclared interval's lower bound, in whole millionths, at least 1 so a knockout
    /// can shift it down and stay inside the unit interval.
    var lowerBoundMillionths: Int {
        1 + (lowerBoundOffsetMillionths % (upperBoundMillionths - 1))
    }

    /// An upper bound above the budget, so a pass rule that reads it fails.
    var excessUpperBoundMillionths: Int { budgetMillionths + excessBoundMillionths }

    var nonPassingOutcome: GateOutcome {
        let blocking = GateOutcome.allCases.filter { !$0.isPassing }
        return blocking[nonPassingOutcomeSelector % blocking.count]
    }

    var referenceSite: SliceReferenceSite {
        SliceReferenceSite.allCases[referenceSiteSelector % SliceReferenceSite.allCases.count]
    }

    /// A version this release does not carry. The major component is at least 2, so it is
    /// never the sample index's `1.0.0` and never the rejected `0.0.0` placeholder.
    var otherVersion: String {
        "\(2 + rotation % 7).\(otherVersionMinor).\(otherVersionPatch)"
    }

    // MARK: Which position each knockout breaks

    /// Which of the three unordered population pairs one separation knockout breaks.
    ///
    /// Offsets rather than one index, so the omission, the failed verification, and the
    /// duplication target different pairs. That matters for the combination arm: omitting and
    /// duplicating the *same* pair would cancel into a coherent record, and a nonempty
    /// combination that approves is not a knockout.
    func pairIndex(_ offset: Int) -> Int { (rotation + offset) % 3 }

    /// Which slice one general-slice knockout breaks. Never slice 0, which is the mandatory
    /// contemporary phone-camera slice.
    func generalSliceIndex(_ offset: Int) -> Int {
        1 + ((rotation + offset) % (sliceCount - 1))
    }

    /// Which recorded report the report knockouts break.
    var reportedSliceIndex: Int { rotation % sliceCount }

    /// Which slice reuses the held-out calibration evidence as its evaluation population.
    var contaminatedSliceIndex: Int { (rotation + 1) % sliceCount }

    /// The freely generated subset the combination arm removes at once.
    var generatedCombination: Set<EvidenceElement> {
        let all = EvidenceElement.allCases
        return Set(combinationSelectors.prefix(combinationSize).map { all[$0 % all.count] })
    }

    // MARK: Generator

    static var generator: Generator<EvidenceShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...29),
            Gen.int(in: 0...29),
            budgetShape,
            populationShape,
            labelShape,
            intervalShape,
            citationShape,
            combinationShape
        )
        .map { raw in
            EvidenceShape(
                seed: raw.0,
                sliceCountSelector: raw.1,
                rotation: raw.2,
                budgetMillionths: raw.3.0,
                statisticSelector: raw.3.1,
                methodSelector: raw.3.2,
                populationSelector: raw.4.0,
                requestedRealPositives: raw.4.1,
                errorCount: raw.4.2,
                realAbstentionPermille: raw.5.0,
                syntheticPositivePermille: raw.5.1,
                syntheticAbstentionPermille: raw.5.2,
                upperBoundOffsetMillionths: raw.6.0,
                lowerBoundOffsetMillionths: raw.6.1,
                excessBoundMillionths: raw.6.2,
                nonPassingOutcomeSelector: raw.7.0,
                referenceSiteSelector: raw.7.1,
                otherVersionMinor: raw.7.2,
                otherVersionPatch: raw.7.3,
                otherConfidenceLevelMillionths: raw.7.4,
                combinationSize: raw.8.0,
                combinationSelectors: [raw.8.1, raw.8.2, raw.8.3, raw.8.4]
            )
        }
        .eraseToAny()
    }

    /// The budget in millionths and the two predeclaration selectors.
    ///
    /// The ceiling is read from ``FalseAccusationBudget/maximumRate`` rather than written out,
    /// so this range does not restate a number the schema owns. The floor is a hundred
    /// millionths so the predeclared interval always has room for two distinct bounds inside
    /// the budget; where a bound sits relative to the budget is this property's concern, and a
    /// budget too small to hold an interval is not.
    private static var budgetShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 100...MillionthScale.millionths(FalseAccusationBudget.maximumRate)),
            Gen.int(in: 0...(BudgetPassStatistic.allCases.count * 97)),
            Gen.int(in: 0...(ConfidenceIntervalMethod.allCases.count * 97))
        )
        .map { ($0.0, $0.1, $0.2) }
        .eraseToAny()
    }

    /// The population selector, the requested positive-label count, and the error count.
    private static var populationShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...(populationTable.count * 7)),
            Gen.int(in: 0...60),
            Gen.int(in: 0...400)
        )
        .map { ($0.0, $0.1, $0.2) }
        .eraseToAny()
    }

    /// The three label shares.
    ///
    /// Each spans the full thousandth range, so a population with no abstention, one with a
    /// few, and one that abstained on everything all occur.
    private static var labelShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 0...1_000), Gen.int(in: 0...1_000), Gen.int(in: 0...1_000))
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }

    /// The two bound offsets and the excess above the budget.
    private static var intervalShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 0...20_000), Gen.int(in: 0...20_000), Gen.int(in: 1...5_000))
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }

    /// The outcome selector, the reference-site selector, the two version components, and a
    /// confidence level other than the fixed 95%.
    ///
    /// The level is shifted past the fixed value rather than drawn around it, so no draw can
    /// accidentally be the required level; the required level itself is read from
    /// ``FalseAccusationPassRule/requiredConfidenceLevel`` rather than written out.
    private static var citationShape: Generator<(Int, Int, Int, Int, Int), AnySequence<Any>> {
        let required = MillionthScale.millionths(
            FalseAccusationPassRule.requiredConfidenceLevel
        )
        return zip(
            Gen.int(in: 0...29),
            Gen.int(in: 0...(SliceReferenceSite.allCases.count * 97)),
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...9_999),
            Gen.int(in: 1...(1_000_000 - 1))
        )
        .map { raw in
            let level = raw.4 >= required ? raw.4 + 1 : raw.4
            return (raw.0, raw.1, raw.2, raw.3, min(level, 1_000_000))
        }
        .eraseToAny()
    }

    /// The combination size and its four element selectors.
    ///
    /// Size zero occurs about a fifth of the time, so the arm's positive control — a release
    /// with nothing removed still approves — is itself generated rather than written as a
    /// separate example.
    private static var combinationShape: Generator<(Int, Int, Int, Int, Int), AnySequence<Any>> {
        let span = EvidenceElement.allCases.count * 13
        return zip(
            Gen.int(in: 0...4),
            Gen.int(in: 0...span),
            Gen.int(in: 0...span),
            Gen.int(in: 0...span),
            Gen.int(in: 0...span)
        )
        .map { ($0.0, $0.1, $0.2, $0.3, $0.4) }
        .eraseToAny()
    }
}

// MARK: - Attempted approvals

/// What one attempt to approve a release produced, as a value rather than a thrown error.
///
/// `propertyCheck` discards an error thrown from its body, so a refusal has to arrive as data.
/// The three cases are the approval, a schema refusal naming a field, and anything else; every
/// arm distinguishes all three, so a refusal for the wrong reason is a failure rather than an
/// unexamined "did not approve".
private enum ApprovalAttempt {
    case approved(ApprovedCalibrationRelease)
    case refused(ArtifactSchemaError)
    case failedOtherwise(String)

    var release: ApprovedCalibrationRelease? {
        guard case .approved(let release) = self else { return nil }
        return release
    }

    /// The refusal's audit text, or `nil` when the attempt was not a schema refusal.
    var refusalText: String? {
        guard case .refused(let error) = self else { return nil }
        return error.description
    }

    var description: String {
        switch self {
        case .approved: "approved"
        case .refused(let error): "refused: \(error.description)"
        case .failedOtherwise(let text): "failed: \(text)"
        }
    }
}

/// The schema fault vocabulary, flattened so an arm can name the fault it expects without
/// restating the offending field twice.
private enum ApprovalFault: Equatable {
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

/// What removing one element has to do, and how the refusal has to read.
private enum ElementExpectation {
    /// Approval is blocked with this fault, and the audit text names every one of these
    /// fragments. Fragments rather than one string so an arm can require the position *and*
    /// the gate's reason, which is what keeps an assertion from passing because an unrelated
    /// check refused the same field.
    case blocked(ApprovalFault, naming: [String])

    /// Approval still succeeds, because the element removed is not one the predeclared rule
    /// reads.
    case stillApproved
}

// MARK: - Approval inputs

/// The six arguments a calibration release approval takes, held together so both knockout
/// arms build them the same way.
private struct ApprovalInputs {
    let policy: ValidatedCalibrationPolicy
    let predeclared: [ReleaseGatingSliceSpecification]
    let measurements: [ReleaseSliceMeasurement]
    let reports: [CalibrationSliceResult]
    let lineage: DatasetLineageRecord
    let index: ReleaseEvidenceIndex

    /// Approves, or returns the refusal as a value. Never throws.
    func approve() -> ApprovalAttempt {
        do {
            return .approved(
                try ApprovedCalibrationRelease(
                    approving: policy,
                    predeclaredMandatorySlices: predeclared,
                    measurements: measurements,
                    recordedReports: reports,
                    lineage: lineage,
                    evidence: index
                )
            )
        } catch let error as ArtifactSchemaError {
            return .refused(error)
        } catch {
            return .failedOtherwise("\(error)")
        }
    }
}

/// Raised when a generated release cannot be built at all, which is a fault in this file
/// rather than in the code under test.
private struct UnbuildableEvidence: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

// MARK: - Scenario

/// Builds the release one generated shape describes, and rebuilds it with any subset of its
/// calibration evidence removed or invalidated.
private struct EvidenceScenario {
    let shape: EvidenceShape
    let witness: CalibrationEvidenceVariationWitness
    let names: EvidenceNames

    /// Every artifact the coherent release carries. Policy activation always uses this index,
    /// so a knockout that removes an artifact from the *approval's* index leaves a policy that
    /// activated legitimately — which is the only way to show that requiring the citation
    /// again at approval is not a repeat of activation.
    let completeIndex: ReleaseEvidenceIndex

    /// The validated policy under approval, carrying the generated budget and pass rule.
    let policy: ValidatedCalibrationPolicy

    /// A policy under another identifier, for the compatibility knockouts.
    let otherPolicy: ValidatedCalibrationPolicy

    /// The same policy activated with another Model Bundle.
    let otherBundlePolicy: ValidatedCalibrationPolicy

    /// This release's policy identifier carrying a different budget, which is the worst of the
    /// three compatibility faults: a reader sees a coherent release while the budget the
    /// slices were measured against is not the budget it ships.
    let otherContentPolicy: ValidatedCalibrationPolicy

    init?(shape: EvidenceShape, witness: CalibrationEvidenceVariationWitness) {
        self.shape = shape
        self.witness = witness
        let names = EvidenceNames(seed: shape.seed)
        self.names = names

        do {
            let pooled = shape.realPopulation + shape.syntheticPopulation
            guard 1_000_000 % shape.realPopulation == 0,
                1_000_000 % shape.syntheticPopulation == 0,
                1_000_000 % pooled == 0
            else {
                throw UnbuildableEvidence(
                    reason: """
                        the generated population table no longer divides one million, so a \
                        reported rate cannot be exact
                        """
                )
            }
            let index = try ReleaseEvidenceIndex(
                records: names.citedEvidence.map { Sample.evidence($0) }
            )
            self.completeIndex = index
            self.policy = try Self.activated(
                identifier: names.policy,
                bundle: names.bundle,
                budgetMillionths: shape.budgetMillionths,
                shape: shape,
                names: names,
                index: index
            )
            self.otherPolicy = try Self.activated(
                identifier: names.otherPolicy,
                bundle: names.bundle,
                budgetMillionths: shape.budgetMillionths,
                shape: shape,
                names: names,
                index: index
            )
            self.otherBundlePolicy = try Self.activated(
                identifier: names.policy,
                bundle: names.otherBundle,
                budgetMillionths: shape.budgetMillionths,
                shape: shape,
                names: names,
                index: index
            )
            self.otherContentPolicy = try Self.activated(
                identifier: names.policy,
                bundle: names.bundle,
                budgetMillionths: shape.budgetMillionths - 1,
                shape: shape,
                names: names,
                index: index
            )
        } catch {
            Issue.record("a coherent generated release could not be built: \(error) [\(shape)]")
            return nil
        }
    }

    // MARK: Building the artifacts

    /// One validated policy, activated against the complete index and a manifest that names it.
    private static func activated(
        identifier: String,
        bundle: String,
        budgetMillionths: Int,
        shape: EvidenceShape,
        names: EvidenceNames,
        index: ReleaseEvidenceIndex
    ) throws -> ValidatedCalibrationPolicy {
        try Sample.activate(
            try Sample.activatablePolicy(
                identifier: identifier,
                budget: try FalseAccusationBudget(
                    validating: MillionthScale.decimal(millionths: budgetMillionths)
                ),
                passRule: try Sample.passRule(
                    statistic: shape.statistic,
                    intervalMethod: shape.intervalMethod
                ),
                evidenceRecords: [Sample.evidence(names.calibrationEvidence)]
            ),
            bundle: try PreflightSample.bundleManifest(
                bundleID: bundle,
                componentVersions: PreflightSample.componentVersions(
                    calibrationPolicy: identifier
                )
            ),
            index: index
        )
    }

    /// One predeclared mandatory slice. Slice 0 is the contemporary phone-camera real slice
    /// Requirement 5.20 makes mandatory; every other index is a general slice.
    private func slice(
        _ index: Int,
        designatedPhoneCamera: Bool? = nil,
        datasetComposition: String? = nil,
        degradationCondition: String? = nil,
        confidenceLevelMillionths: Int? = nil
    ) throws -> ReleaseGatingSliceSpecification {
        var level = FalseAccusationPassRule.requiredConfidenceLevel
        if let confidenceLevelMillionths {
            level = MillionthScale.decimal(millionths: confidenceLevelMillionths)
        }
        return try ReleaseGatingSliceSpecification(
            id: Sample.slice(names.slice(index)),
            schemaVersion: .v1,
            eligibilityRule: Sample.evidence(names.eligibilityRule),
            outcomeMapping: Sample.evidence(names.outcomeMapping),
            metricDefinition: Sample.evidence(names.metricDefinition),
            datasetComposition: Sample.evidence(datasetComposition ?? names.datasetComposition),
            degradationCondition: Sample.evidence(
                degradationCondition ?? names.degradationCondition
            ),
            intervalMethod: shape.intervalMethod,
            confidenceLevel: try UnitInterval(validating: level),
            isContemporaryPhoneCameraSlice: designatedPhoneCamera ?? (index == 0)
        )
    }

    /// The label counts for one slice.
    ///
    /// The shares are rotated by the slice index so no two slices in a release carry the same
    /// counts, and the positive count is clamped to what the budget admits, so a coherent
    /// release passes the pass rule for a reason its counts state rather than by luck.
    private func counts(
        for index: Int,
        realPositives requestedPositives: Int? = nil,
        removingRealPopulation: Bool = false
    ) throws -> SliceOutcomeCounts {
        let realTotal = removingRealPopulation ? 0 : shape.realPopulation
        let requested =
            requestedPositives
            ?? min(shape.requestedRealPositives + index, shape.positivesWithinBudget)
        let positives = min(realTotal, requested)
        let realAbstentions =
            (realTotal - positives)
            * ((shape.realAbstentionPermille + index * 37) % 1_001) / 1_000
        let syntheticPositives =
            shape.syntheticPopulation
            * ((shape.syntheticPositivePermille + index * 53) % 1_001) / 1_000
        let syntheticAbstentions =
            (shape.syntheticPopulation - syntheticPositives)
            * ((shape.syntheticAbstentionPermille + index * 71) % 1_001) / 1_000
        return try Sample.sliceCounts(
            realPositive: positives,
            realNonPositive: realTotal - positives - realAbstentions,
            realInsufficient: realAbstentions,
            syntheticPositive: syntheticPositives,
            syntheticNonPositive: shape.syntheticPopulation - syntheticPositives
                - syntheticAbstentions,
            syntheticInsufficient: syntheticAbstentions,
            errors: shape.errorCount + index
        )
    }

    /// The predeclared confidence-interval result, from whole millionths, exact in every bound.
    private func interval(upperMillionths: Int? = nil) throws -> ConfidenceIntervalResult {
        try ConfidenceIntervalResult(
            method: shape.intervalMethod,
            confidenceLevel: try UnitInterval(
                validating: FalseAccusationPassRule.requiredConfidenceLevel
            ),
            lowerBound: try UnitInterval(
                validating: MillionthScale.decimal(millionths: shape.lowerBoundMillionths)
            ),
            upperBound: try UnitInterval(
                validating: MillionthScale.decimal(
                    millionths: upperMillionths ?? shape.upperBoundMillionths
                )
            )
        )
    }

    /// One recorded report of `measurement`, stating the exact measured ratios.
    ///
    /// Every rate is the measured pair of counts scaled to whole millionths, so the record
    /// states the measurement rather than a rounding and no comparison in the gate can pass or
    /// fail because of a convention this file picked. An absent measured rate has no such
    /// value, and the record's field is a required `UnitInterval`, so the report puts a zero
    /// there — which is exactly the fabrication
    /// ``EvidenceElement/sliceRealPopulationRemoved`` exists to have refused.
    private func report(
        of measurement: ReleaseSliceMeasurement,
        modelBundle: ModelBundleID? = nil,
        calibrationPolicy: ArtifactID? = nil,
        extraErrors: Int = 0,
        budgetOutcome overriddenOutcome: GateOutcome? = nil,
        loweringIntervalFloorBy floorShift: Int = 0
    ) throws -> CalibrationSliceResult {
        let derived: GateOutcome =
            switch measurement.budgetOutcome {
            case let .evaluated(outcome): outcome
            case .noObservedFalsePositiveRate: .notExecuted
            }

        var counts = measurement.counts
        if extraErrors != 0 {
            counts = try SliceOutcomeCounts(
                eligibleRealImages: counts.eligibleRealImages,
                eligibleSyntheticImages: counts.eligibleSyntheticImages,
                realPositiveLabels: counts.realPositiveLabels,
                realNonPositiveLabels: counts.realNonPositiveLabels,
                realInsufficientLabels: counts.realInsufficientLabels,
                syntheticPositiveLabels: counts.syntheticPositiveLabels,
                syntheticNonPositiveLabels: counts.syntheticNonPositiveLabels,
                syntheticInsufficientLabels: counts.syntheticInsufficientLabels,
                errorCount: try NonNegativeCount(
                    validating: counts.errorCount.value + extraErrors
                )
            )
        }

        var reportedInterval = measurement.falsePositiveRateInterval
        if floorShift != 0 {
            reportedInterval = try ConfidenceIntervalResult(
                method: reportedInterval.method,
                confidenceLevel: reportedInterval.confidenceLevel,
                lowerBound: try UnitInterval(
                    validating: MillionthScale.decimal(
                        millionths: max(0, shape.lowerBoundMillionths - floorShift)
                    )
                ),
                upperBound: reportedInterval.upperBound
            )
        }

        return CalibrationSliceResult(
            slice: measurement.slice,
            specification: Sample.evidence(names.sliceSpecification),
            modelBundle: modelBundle ?? measurement.modelBundle,
            calibrationPolicy: calibrationPolicy ?? measurement.calibrationPolicy,
            counts: counts,
            falsePositiveRate: try exactly(measurement.falsePositiveRate),
            truePositiveRate: try exactly(measurement.truePositiveRate),
            coverage: try exactly(measurement.coverage),
            falsePositiveRateInterval: reportedInterval,
            budgetOutcome: overriddenOutcome ?? derived
        )
    }

    /// One measured rate as the exact `UnitInterval` its two counts pin, or zero when the
    /// population was empty and no rate was measured.
    private func exactly(_ rate: MeasuredRate?) throws -> UnitInterval {
        guard let rate else { return .zero }
        guard let millionths = MillionthScale.millionths(of: rate) else {
            throw UnbuildableEvidence(
                reason: "the measured rate \(rate.description) is not a whole millionth"
            )
        }
        return try UnitInterval(validating: MillionthScale.decimal(millionths: millionths))
    }

    /// The three unordered population pairs, in the order the approval gate reports them.
    private static var orderedPairs: [[String]] {
        CalibrationPopulation.requiredSeparationPairs
            .map { $0.map(\.rawValue).sorted() }
            .sorted { $0.joined(separator: "|") < $1.joined(separator: "|") }
    }

    /// The separation results one lineage record carries.
    private func separationResults(
        applying elements: Set<EvidenceElement>
    ) throws -> [PopulationSeparationResult] {
        let omitted = shape.pairIndex(0)
        let faulted = shape.pairIndex(1)
        let duplicated = shape.pairIndex(2)

        var results: [PopulationSeparationResult] = []
        for (index, pair) in Self.orderedPairs.enumerated() {
            if elements.contains(.separationPairOmitted), index == omitted { continue }
            let sampleFailed =
                elements.contains(.sampleLevelSeparationNotPassing) && index == faulted
            let contentFailed =
                elements.contains(.contentLevelSeparationNotPassing) && index == faulted
            var version: String?
            if elements.contains(.separationEvidenceCitedAtAnotherVersion),
                index == duplicated
            {
                version = shape.otherVersion
            }
            results.append(
                try Self.separation(
                    pair,
                    sampleLevel: sampleFailed ? shape.nonPassingOutcome : .passed,
                    contentLevel: contentFailed ? shape.nonPassingOutcome : .passed,
                    evidence: names.separation,
                    atVersion: version
                )
            )
            if elements.contains(.separationPairRecordedTwice), index == duplicated {
                // The same two populations the other way round: an unordered pair is one pair
                // whichever order a record lists it in.
                results.append(
                    try Self.separation(
                        pair.reversed(),
                        sampleLevel: .passed,
                        contentLevel: .passed,
                        evidence: names.separation,
                        atVersion: nil
                    )
                )
            }
        }
        return results
    }

    private static func separation(
        _ pair: [String],
        sampleLevel: GateOutcome,
        contentLevel: GateOutcome,
        evidence: String,
        atVersion version: String?
    ) throws -> PopulationSeparationResult {
        guard pair.count == 2,
            let first = CalibrationPopulation(rawValue: pair[0]),
            let second = CalibrationPopulation(rawValue: pair[1])
        else {
            throw UnbuildableEvidence(reason: "\(pair) is not a population pair")
        }
        var source = Sample.evidence(evidence)
        if let version {
            source = EvidenceSource(
                artifact: Sample.artifact(evidence),
                version: try SchemaSemanticVersion(validating: version),
                contentDigest: Sample.digest()
            )
        }
        return try PopulationSeparationResult(
            firstPopulation: first,
            secondPopulation: second,
            sampleLevelOutcome: sampleLevel,
            contentLevelOutcome: contentLevel,
            evidence: source
        )
    }

    // MARK: Assembling one release

    /// The complete approval inputs, with every active element removed or invalidated.
    ///
    /// One function for both knockout arms, so the single-element arm and the combination arm
    /// cannot disagree about what removing an element means. Where two elements would write the
    /// same position the earlier check in the gate wins, which is why the combination arm
    /// asserts only that the refusal names *some* active element's position: that is what keeps
    /// an overlap from turning into an unattributable pass.
    private func inputs(applying elements: Set<EvidenceElement>) throws -> ApprovalInputs {
        var omitted: Set<String> = []
        if elements.contains(.separationEvidenceOutsideThisRelease) {
            omitted.insert(names.separation)
        }
        if elements.contains(.identifierCorrectionOutsideThisRelease) {
            omitted.insert(names.identifierCorrection)
        }
        if elements.contains(.duplicateHashDispositionOutsideThisRelease) {
            omitted.insert(names.duplicateHashDisposition)
        }
        if elements.contains(.heldOutCalibrationEvidenceOutsideThisRelease) {
            omitted.insert(names.calibrationEvidence)
        }
        if elements.contains(.reportSpecificationOutsideThisRelease) {
            omitted.insert(names.sliceSpecification)
        }
        if elements.contains(.predeclaredSliceReferenceOutsideThisRelease) {
            omitted.insert(names.identifier(of: shape.referenceSite))
        }
        let evidenceIndex = try ReleaseEvidenceIndex(
            records: names.citedEvidence.filter { !omitted.contains($0) }
                .map { Sample.evidence($0) }
        )

        let lineage = try DatasetLineageRecord(
            id: Sample.artifact(names.lineage),
            schemaVersion: .v1,
            separationResults: try separationResults(applying: elements),
            identifierCorrection: Sample.evidence(names.identifierCorrection),
            duplicateHashDisposition: Sample.evidence(names.duplicateHashDisposition)
        )

        let measuringPolicy: ValidatedCalibrationPolicy =
            if elements.contains(.measuredAgainstAnotherPolicy) {
                otherPolicy
            } else if elements.contains(.measuredAgainstAnotherBundle) {
                otherBundlePolicy
            } else if elements.contains(.measuredPolicyCarriesOtherContent) {
                otherContentPolicy
            } else {
                policy
            }

        let undesignated = elements.contains(.contemporaryPhoneCameraSliceNotDesignated)
        let contaminated = shape.contaminatedSliceIndex
        let editedSlice = shape.generalSliceIndex(0)
        let emptiedSlice = shape.generalSliceIndex(0)
        let unrunRuleSlice = shape.generalSliceIndex(1)
        let unmeasuredSlice = shape.generalSliceIndex(1)
        let reportedSlice = shape.reportedSliceIndex

        var predeclared: [ReleaseGatingSliceSpecification] = []
        var measurements: [ReleaseSliceMeasurement] = []
        var reports: [CalibrationSliceResult] = []
        for index in 0..<shape.sliceCount {
            var composition: String?
            if elements.contains(.calibrationEvidenceReusedAsEvaluationPopulation),
                index == contaminated
            {
                composition = names.calibrationEvidence
            }
            let declared = try slice(
                index,
                designatedPhoneCamera: undesignated ? false : nil,
                datasetComposition: composition
            )
            predeclared.append(declared)

            if elements.contains(.predeclaredSliceUnmeasured), index == unmeasuredSlice {
                continue
            }

            var measured = declared
            if elements.contains(.predeclarationEditedAfterEvaluation), index == editedSlice {
                measured = try slice(
                    index,
                    designatedPhoneCamera: undesignated ? false : nil,
                    datasetComposition: composition,
                    degradationCondition: names.revisedDegradationCondition
                )
            }

            var requestedPositives: Int?
            if elements.contains(.sliceExceedsTheBudget), index == 0 {
                requestedPositives = shape.positivesAboveBudget
            }
            let emptyRealPopulation =
                (elements.contains(.sliceRealPopulationRemoved) && index == emptiedSlice)
                || (elements.contains(.budgetRuleCouldNotBeApplied) && index == unrunRuleSlice)
            var upperBound: Int?
            if elements.contains(.intervalUpperBoundAboveTheBudget), index == 0 {
                upperBound = shape.excessUpperBoundMillionths
            }

            let measurement = try ReleaseSliceMeasurement(
                slice: measured,
                counts: try counts(
                    for: index,
                    realPositives: requestedPositives,
                    removingRealPopulation: emptyRealPopulation
                ),
                falsePositiveRateInterval: try interval(upperMillionths: upperBound),
                measuredAgainst: measuringPolicy
            )
            measurements.append(measurement)
            witness.recordBudgetOutcome(measurement.budgetOutcome)

            if elements.contains(.sliceReportOmitted), index == reportedSlice { continue }
            if elements.contains(.budgetRuleCouldNotBeApplied), index == unrunRuleSlice {
                continue
            }

            let targeted = index == reportedSlice
            var reportBundle: ModelBundleID?
            if elements.contains(.reportNamesAnotherBundle), targeted {
                reportBundle = Sample.bundle(names.otherBundle)
            }
            var reportPolicy: ArtifactID?
            if elements.contains(.reportNamesAnotherPolicy), targeted {
                reportPolicy = Sample.artifact(names.otherPolicy)
            }
            var statedOutcome: GateOutcome?
            if elements.contains(.reportedBudgetOutcomeDisagrees), targeted {
                statedOutcome = shape.nonPassingOutcome
            }
            reports.append(
                try report(
                    of: measurement,
                    modelBundle: reportBundle,
                    calibrationPolicy: reportPolicy,
                    extraErrors: elements.contains(.reportedErrorCountDisagrees) && targeted
                        ? 1 : 0,
                    budgetOutcome: statedOutcome,
                    loweringIntervalFloorBy: elements.contains(.reportedIntervalDisagrees)
                        && targeted ? 1 : 0
                )
            )
        }

        return ApprovalInputs(
            policy: policy,
            predeclared: predeclared,
            measurements: measurements,
            reports: reports,
            lineage: lineage,
            index: evidenceIndex
        )
    }

    /// One approval attempt with `elements` removed or invalidated. Never throws.
    ///
    /// A release this file cannot build at all is reported separately from a release the gate
    /// refused, so a fixture defect can never read as a refusal.
    private func approve(applying elements: Set<EvidenceElement>) -> ApprovalAttempt {
        let inputs: ApprovalInputs
        do {
            inputs = try self.inputs(applying: elements)
        } catch {
            Issue.record(
                """
                a release missing \(elements.map(\.rawValue).sorted()) could not be built: \
                \(error) [\(shape)]
                """
            )
            return .failedOtherwise("unbuildable")
        }
        return inputs.approve()
    }

    // MARK: - Arm: complete evidence approves

    /// Requirements 5.5, 5.6, 5.19, 5.22, and 5.23 in the direction that keeps every refusal
    /// below attributable: a release whose calibration evidence is complete, uncontaminated,
    /// and passing is approved, and the approval reads back what was generated.
    ///
    /// Every expectation is derived from the generated shape, so the arm cannot pass by
    /// agreeing with a constant written in this file.
    func checkCompleteEvidenceApproves() -> ApprovedCalibrationRelease? {
        let attempt = approve(applying: [])
        guard let release = attempt.release else {
            Issue.record(
                """
                complete, uncontaminated, passing calibration evidence was not approved: \
                \(attempt.description) [\(shape)]
                """
            )
            return nil
        }
        witness.recordApproval()

        #expect(release.policy == policy, "[\(shape)]")
        #expect(release.calibrationPolicy == Sample.artifact(names.policy), "[\(shape)]")
        #expect(release.modelBundle == Sample.bundle(names.bundle), "[\(shape)]")
        #expect(release.datasetLineage == Sample.artifact(names.lineage), "[\(shape)]")

        // Requirement 5.21's inputs are read from the policy, never written here.
        #expect(
            release.falseAccusationBudget.rate
                == MillionthScale.decimal(millionths: shape.budgetMillionths),
            "[\(shape)]"
        )
        #expect(release.releasePassRule.statistic == shape.statistic, "[\(shape)]")
        #expect(release.releasePassRule.intervalMethod == shape.intervalMethod, "[\(shape)]")

        // The mandatory set is exactly the generated one, in a reproducible order, with the
        // contemporary phone-camera real slice present.
        #expect(
            release.mandatorySlices.map(\.rawValue)
                == (0..<shape.sliceCount).map { names.slice($0) },
            "[\(shape)]"
        )
        #expect(
            release.contemporaryPhoneCameraSlices.map(\.slice.rawValue) == [names.slice(0)],
            "[\(shape)]"
        )

        // Requirement 5.6 in artifact terms: the held-out calibration population and every
        // product-threshold evaluation population are named by different records, and the
        // approval exposes both so an audit can see that for itself.
        #expect(
            release.heldOutCalibrationEvidence == [Sample.evidence(names.calibrationEvidence)],
            "[\(shape)]"
        )
        #expect(
            release.evaluationDatasetCompositions == [Sample.evidence(names.datasetComposition)],
            "[\(shape)]"
        )
        #expect(
            release.evaluationDatasetCompositions
                .isDisjoint(with: Set(release.heldOutCalibrationEvidence)),
            "[\(shape)]"
        )

        // Requirements 5.5 and 5.23: all three pairs carry a passing verification at both
        // levels, and the same pair resolves whichever order it is asked for.
        for pair in CalibrationPopulation.requiredSeparationPairs {
            let populations = Array(pair)
            guard
                let separation = release.separation(
                    between: populations[0],
                    and: populations[1]
                )
            else {
                Issue.record("no separation recorded for \(pair) [\(shape)]")
                continue
            }
            #expect(separation.isSeparated, "[\(shape)]")
            #expect(separation.sampleLevelOutcome == .passed, "[\(shape)]")
            #expect(separation.contentLevelOutcome == .passed, "[\(shape)]")
            #expect(
                release.separation(between: populations[1], and: populations[0]) == separation,
                "[\(shape)]"
            )
            witness.recordComparison()
        }
        return release
    }

    // MARK: - Arm: every mandatory slice is completely reported

    /// Requirement 5.19: every mandatory slice reports a false-positive rate, a true-positive
    /// rate, coverage, an error count, its dataset composition, its degradation condition, and
    /// a predeclared 95% confidence interval.
    ///
    /// Each rate is checked two ways at once, against the record the *approval returned*
    /// rather than the one this file handed it. The reported `Decimal` has to be the exact
    /// millionths value the arm derives from the measurement's two counts, and that value has
    /// to satisfy `numerator × 1_000_000 == millionths × denominator` in `Int` arithmetic — an
    /// identity that says the reported decimal is the measured ratio without either side
    /// forming a quotient. Together they also say the gate returned the record unchanged:
    /// validation never repairs, normalizes, or fills a field.
    ///
    /// The 95% level is asserted from both sides. Every predeclared slice and every recorded
    /// interval in the approved release carries exactly
    /// ``FalseAccusationPassRule/requiredConfidenceLevel``, and a slice specification
    /// predeclaring the generated other level cannot be constructed at all, so the level is
    /// fixed by the schema rather than by a check some caller could skip.
    func checkEveryMandatorySliceIsCompletelyReported(_ release: ApprovedCalibrationRelease) {
        let required = FalseAccusationPassRule.requiredConfidenceLevel
        for slice in release.mandatorySlices {
            guard let measurement = release.measurement(for: slice) else {
                Issue.record("mandatory slice \(slice.rawValue) has no measurement [\(shape)]")
                continue
            }
            guard let recorded = release.report(for: slice) else {
                Issue.record("mandatory slice \(slice.rawValue) has no report [\(shape)]")
                continue
            }

            let rates: [(String, MeasuredRate?, UnitInterval)] = [
                ("falsePositiveRate", measurement.falsePositiveRate, recorded.falsePositiveRate),
                ("truePositiveRate", measurement.truePositiveRate, recorded.truePositiveRate),
                ("coverage", measurement.coverage, recorded.coverage),
            ]
            for (name, measured, reported) in rates {
                guard let measured, let millionths = MillionthScale.millionths(of: measured)
                else {
                    Issue.record(
                        """
                        \(slice.rawValue).\(name) was not measured as a whole millionth \
                        [\(shape)]
                        """
                    )
                    continue
                }
                #expect(
                    measured.numerator.value * 1_000_000
                        == millionths * measured.denominator.value,
                    """
                    \(slice.rawValue).\(name) \(measured.description) is not \
                    \(millionths)/1e6 [\(shape)]
                    """
                )
                #expect(
                    reported.value == MillionthScale.decimal(millionths: millionths),
                    """
                    \(slice.rawValue).\(name) reported \(reported.description) rather than the \
                    measured \(measured.description) [\(shape)]
                    """
                )
                witness.recordExactRateIdentity()
            }

            // Requirement 5.19's remaining reported fields.
            #expect(
                recorded.counts.errorCount == measurement.errorCount,
                "\(slice.rawValue) reported error count [\(shape)]"
            )
            #expect(
                measurement.datasetComposition == Sample.evidence(names.datasetComposition),
                "\(slice.rawValue) dataset composition [\(shape)]"
            )
            #expect(
                measurement.degradationCondition
                    == Sample.evidence(names.degradationCondition),
                "\(slice.rawValue) degradation condition [\(shape)]"
            )

            // The predeclared interval, at the fixed level and the predeclared method.
            #expect(
                measurement.specification.confidenceLevel.value == required,
                "\(slice.rawValue) predeclared confidence level [\(shape)]"
            )
            #expect(
                recorded.falsePositiveRateInterval == measurement.falsePositiveRateInterval,
                "\(slice.rawValue) reported interval [\(shape)]"
            )
            #expect(
                recorded.falsePositiveRateInterval.confidenceLevel.value == required,
                "\(slice.rawValue) reported confidence level [\(shape)]"
            )
            #expect(
                recorded.falsePositiveRateInterval.method == shape.intervalMethod,
                "\(slice.rawValue) reported interval method [\(shape)]"
            )
            witness.recordComparison()
        }

        // A slice cannot predeclare any other level, so Requirement 5.19's 95% is a fact about
        // the schema rather than something the approval gate has to re-derive.
        do {
            _ = try slice(0, confidenceLevelMillionths: shape.otherConfidenceLevelMillionths)
            Issue.record(
                """
                a slice predeclaring \(shape.otherConfidenceLevelMillionths)/1e6 as its \
                confidence level was accepted [\(shape)]
                """
            )
        } catch let error as ArtifactSchemaError {
            #expect(
                ApprovalFault(error) == .fixedValueMismatch
                    && error.description.contains("slice.confidenceLevel"),
                "another confidence level was refused as \(error) [\(shape)]"
            )
            witness.recordComparison()
        } catch {
            Issue.record("another confidence level failed as \(error) [\(shape)]")
        }
    }

    // MARK: - Arm: every element is individually necessary

    /// The arm the property is named for. Each element of a complete evidence set is removed or
    /// invalidated on its own, and approval has to be blocked with the specific refusal that
    /// element earns.
    ///
    /// Every element is knocked out in every case rather than a generated selection of them, so
    /// "each element is individually necessary" is a fact about this run rather than about the
    /// draws it happened to make. The witness requires each refusal to have been produced at
    /// the fault and position stated here, so an element whose knockout stopped biting fails
    /// the run even if every individual case still passed.
    func checkEveryElementIsIndividuallyNecessary() {
        for element in EvidenceElement.allCases {
            let attempt = approve(applying: [element])
            witness.recordKnockout()
            switch expectation(for: element) {
            case let .blocked(fault, fragments):
                expect(attempt, refuses: element, as: fault, naming: fragments)
            case .stillApproved:
                guard attempt.release != nil else {
                    Issue.record(
                        """
                        removing \(element.rawValue) blocked a release whose predeclared \
                        \(shape.statistic.rawValue) rule does not read it: \
                        \(attempt.description) [\(shape)]
                        """
                    )
                    continue
                }
                witness.recordInertKnockout(of: element)
            }
        }
    }

    /// What removing one element has to produce, as a fault and the fragments the audit text
    /// has to name.
    ///
    /// Exhaustive with no `default`, so a new element is a compile error here rather than an
    /// element nothing asserts. Every fragment is either a generated identifier or the gate's
    /// own wording, so an assertion cannot pass because an unrelated check refused the same
    /// field. Where a knockout breaks the same artifact for every slice or every pair, the
    /// fragments deliberately omit the position: the gate sweeps in sorted order and reports
    /// the first one, and pinning that would assert the sweep order rather than the refusal.
    private func expectation(for element: EvidenceElement) -> ElementExpectation {
        let separationField = "approval.datasetLineage.separationResults"
        let pairKeys = Self.orderedPairs.map { $0.joined(separator: "|") }
        let reported = names.slice(shape.reportedSliceIndex)
        let reportField = "approval.sliceReports[\(reported)]"
        let firstSlice = "approval.slice[\(names.slice(0))]"
        let budgetBlocks = "blocks distribution of the affected Model Bundle and application"

        switch element {
        case .separationPairOmitted:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "\(separationField) is missing required entries",
                    pairKeys[shape.pairIndex(0)],
                ]
            )
        case .separationPairRecordedTwice:
            return .blocked(
                .duplicateEntry,
                naming: [
                    "\(separationField) declares",
                    pairKeys[shape.pairIndex(2)],
                    "more than once",
                ]
            )
        case .sampleLevelSeparationNotPassing:
            return .blocked(
                .forbiddenValue,
                naming: [
                    "\(separationField)[\(pairKeys[shape.pairIndex(1)])].sampleLevelOutcome",
                    "missing or failed sample-level or content-level separation",
                ]
            )
        case .contentLevelSeparationNotPassing:
            return .blocked(
                .forbiddenValue,
                naming: [
                    "\(separationField)[\(pairKeys[shape.pairIndex(1)])].contentLevelOutcome",
                    "missing or failed sample-level or content-level separation",
                ]
            )
        case .separationEvidenceOutsideThisRelease:
            return .blocked(
                .missingRequiredEntries,
                naming: [".evidence is missing required entries", names.separation]
            )
        case .identifierCorrectionOutsideThisRelease:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "approval.datasetLineage.identifierCorrection is missing required entries",
                    names.identifierCorrection,
                ]
            )
        case .duplicateHashDispositionOutsideThisRelease:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "approval.datasetLineage.duplicateHashDisposition is missing required "
                        + "entries",
                    names.duplicateHashDisposition,
                ]
            )
        case .heldOutCalibrationEvidenceOutsideThisRelease:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "approval.calibrationPolicy.evidence[0] is missing required entries",
                    names.calibrationEvidence,
                ]
            )
        case .calibrationEvidenceReusedAsEvaluationPopulation:
            return .blocked(
                .forbiddenValue,
                naming: [
                    "approval.slice[\(names.slice(shape.contaminatedSliceIndex))]"
                        + ".datasetComposition",
                    "it is also held-out calibration evidence",
                    names.calibrationEvidence,
                ]
            )
        case .sliceReportOmitted:
            return .blocked(
                .missingRequiredEntries,
                naming: ["approval.sliceReports is missing required entries", reported]
            )
        case .reportedErrorCountDisagrees:
            return .blocked(
                .inconsistentReference,
                naming: ["\(reportField).counts.errorCount must reference"]
            )
        case .reportedBudgetOutcomeDisagrees:
            return .blocked(
                .inconsistentReference,
                naming: ["\(reportField).budgetOutcome must reference"]
            )
        case .reportSpecificationOutsideThisRelease:
            return .blocked(
                .missingRequiredEntries,
                naming: [".specification is missing required entries", names.sliceSpecification]
            )
        case .predeclaredSliceReferenceOutsideThisRelease:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    ".\(shape.referenceSite.rawValue) is missing required entries",
                    names.identifier(of: shape.referenceSite),
                ]
            )
        case .contemporaryPhoneCameraSliceNotDesignated:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "approval.mandatorySlices is missing required entries",
                    "contemporary phone-camera real-image slice",
                ]
            )
        case .predeclaredSliceUnmeasured:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "approval.sliceMeasurements is missing required entries",
                    names.slice(shape.generalSliceIndex(1)),
                ]
            )
        case .reportedIntervalDisagrees:
            return .blocked(
                .inconsistentReference,
                naming: ["\(reportField).falsePositiveRateInterval must reference"]
            )
        case .intervalUpperBoundAboveTheBudget:
            guard shape.statisticReadsTheIntervalUpperBound else { return .stillApproved }
            return .blocked(
                .forbiddenValue,
                naming: ["\(firstSlice).budgetOutcome", budgetBlocks]
            )
        case .measuredAgainstAnotherPolicy:
            return .blocked(
                .inconsistentReference,
                naming: [
                    "\(firstSlice).calibrationPolicy must reference", names.otherPolicy,
                ]
            )
        case .measuredAgainstAnotherBundle:
            return .blocked(
                .inconsistentReference,
                naming: ["\(firstSlice).modelBundle must reference", names.otherBundle]
            )
        case .measuredPolicyCarriesOtherContent:
            return .blocked(
                .inconsistentReference,
                naming: [
                    "\(firstSlice).policy must reference the validated policy under approval",
                    names.policy,
                ]
            )
        case .reportNamesAnotherPolicy:
            return .blocked(
                .inconsistentReference,
                naming: ["\(reportField).calibrationPolicy must reference", names.otherPolicy]
            )
        case .reportNamesAnotherBundle:
            return .blocked(
                .inconsistentReference,
                naming: ["\(reportField).modelBundle must reference", names.otherBundle]
            )
        case .separationEvidenceCitedAtAnotherVersion:
            return .blocked(
                .inconsistentReference,
                naming: [
                    "\(separationField)[\(pairKeys[shape.pairIndex(2)])].evidence.version "
                        + "must reference",
                    shape.otherVersion,
                ]
            )
        case .predeclarationEditedAfterEvaluation:
            return .blocked(
                .inconsistentReference,
                naming: [
                    "approval.slice[\(names.slice(shape.generalSliceIndex(0)))].specification "
                        + "must reference the specification predeclared for this slice"
                ]
            )
        case .sliceExceedsTheBudget:
            guard shape.statisticReadsTheObservedRate else { return .stillApproved }
            return .blocked(
                .forbiddenValue,
                naming: ["\(firstSlice).budgetOutcome", budgetBlocks]
            )
        case .sliceRealPopulationRemoved:
            return .blocked(
                .forbiddenValue,
                naming: [
                    "approval.sliceReports[\(names.slice(shape.generalSliceIndex(0)))]"
                        + ".budgetOutcome",
                    "the slice holds no eligible held-out real image",
                ]
            )
        case .budgetRuleCouldNotBeApplied:
            return .blocked(
                .missingRequiredEntries,
                naming: [
                    "approval.slice[\(names.slice(shape.generalSliceIndex(1)))].budgetOutcome",
                    "an observed false-positive rate for the predeclared pass rule to read",
                ]
            )
        }
    }

    // MARK: - Arm: any incomplete combination is blocked

    /// A freely generated subset of the same elements, removed at once.
    ///
    /// Two directions. A subset that removes nothing the predeclared rule reads still approves,
    /// which is the generated positive control. Any effective subset is blocked, and the
    /// refusal has to name a position one of the active elements broke — otherwise a
    /// combination could pass because something unrelated happened to refuse, which is how a
    /// combination-only property quietly stops testing anything.
    func checkAnyIncompleteCombinationIsBlocked() {
        let requested = shape.generatedCombination
        let effective = requested.filter { $0.blocks(in: shape) }
        let attempt = approve(applying: requested)
        witness.recordCombination(size: requested.count)

        guard !effective.isEmpty else {
            guard attempt.release != nil else {
                Issue.record(
                    """
                    a release missing only elements the predeclared rule does not read, \
                    \(requested.map(\.rawValue).sorted()), was not approved: \
                    \(attempt.description) [\(shape)]
                    """
                )
                return
            }
            witness.recordApprovedCombination()
            return
        }
        guard let text = attempt.refusalText else {
            Issue.record(
                """
                a release missing \(effective.map(\.rawValue).sorted()) was not blocked: \
                \(attempt.description) [\(shape)]
                """
            )
            return
        }
        let positions = effective.flatMap(attributablePositions(of:))
        #expect(
            positions.contains { text.contains($0) },
            """
            a release missing \(effective.map(\.rawValue).sorted()) was refused as \
            "\(text)", which names none of \(positions.sorted()) [\(shape)]
            """
        )
        witness.recordBlockedCombination()
    }

    /// The positions one element breaks, for attributing a combination's refusal.
    ///
    /// Broader than ``expectation(for:)``'s fragments on purpose. Two elements may target the
    /// same slice, pair, or report, and the gate then reports whichever check it reaches
    /// first; what has to hold is that the refusal names something an active element broke,
    /// not that it names the one an arm would have predicted in isolation.
    private func attributablePositions(of element: EvidenceElement) -> [String] {
        let pairKeys = Self.orderedPairs.map { $0.joined(separator: "|") }
        switch element {
        case .separationPairOmitted:
            return [pairKeys[shape.pairIndex(0)]]
        case .separationPairRecordedTwice, .separationEvidenceCitedAtAnotherVersion:
            return [pairKeys[shape.pairIndex(2)]]
        case .sampleLevelSeparationNotPassing, .contentLevelSeparationNotPassing:
            return [pairKeys[shape.pairIndex(1)]]
        case .separationEvidenceOutsideThisRelease:
            return [names.separation]
        case .identifierCorrectionOutsideThisRelease:
            return [names.identifierCorrection]
        case .duplicateHashDispositionOutsideThisRelease:
            return [names.duplicateHashDisposition]
        case .heldOutCalibrationEvidenceOutsideThisRelease,
            .calibrationEvidenceReusedAsEvaluationPopulation:
            return [names.calibrationEvidence]
        case .reportSpecificationOutsideThisRelease:
            return [names.sliceSpecification]
        case .predeclaredSliceReferenceOutsideThisRelease:
            return [names.identifier(of: shape.referenceSite)]
        case .contemporaryPhoneCameraSliceNotDesignated:
            return ["contemporary phone-camera real-image slice"]
        case .sliceReportOmitted, .reportedErrorCountDisagrees, .reportedBudgetOutcomeDisagrees,
            .reportedIntervalDisagrees:
            return [names.slice(shape.reportedSliceIndex)]
        case .reportNamesAnotherPolicy, .measuredAgainstAnotherPolicy:
            return [names.otherPolicy]
        case .reportNamesAnotherBundle, .measuredAgainstAnotherBundle:
            return [names.otherBundle]
        case .measuredPolicyCarriesOtherContent:
            return ["must reference the validated policy under approval"]
        case .predeclarationEditedAfterEvaluation, .sliceRealPopulationRemoved:
            return [names.slice(shape.generalSliceIndex(0))]
        case .predeclaredSliceUnmeasured, .budgetRuleCouldNotBeApplied:
            return [names.slice(shape.generalSliceIndex(1))]
        case .intervalUpperBoundAboveTheBudget, .sliceExceedsTheBudget:
            return [names.slice(0)]
        }
    }

    // MARK: - Refusal helper

    /// Requires `attempt` to be a refusal with `fault` whose audit text names every fragment.
    ///
    /// Never rethrows: `propertyCheck` discards an error thrown from its body, so a refusal
    /// that escaped as a throw would make this property pass vacuously. A refusal is recorded
    /// with the witness only when the fault *and* every fragment matched, so the witness's
    /// end-of-run coverage assertion means each refusal was produced as stated rather than
    /// merely that something was refused.
    private func expect(
        _ attempt: ApprovalAttempt,
        refuses element: EvidenceElement,
        as fault: ApprovalFault,
        naming fragments: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .refused(let error) = attempt else {
            Issue.record(
                """
                removing \(element.rawValue) did not block approval: \(attempt.description) \
                [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        let text = error.description
        guard ApprovalFault(error) == fault else {
            Issue.record(
                """
                removing \(element.rawValue) was refused as \(ApprovalFault(error)) rather \
                than \(fault): "\(text)" [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        let unnamed = fragments.filter { !text.contains($0) }
        guard unnamed.isEmpty else {
            Issue.record(
                """
                removing \(element.rawValue) was refused as "\(text)", which does not name \
                \(unnamed) [\(shape)]
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        witness.recordRefusal(of: element)
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the arms observed, so the property cannot pass
/// by generating one fixed release a hundred times or by skipping its arms.
///
/// A `propertyCheck` body that throws before reaching its assertions passes in milliseconds
/// with every arm skipped, and a record-validation property does comparisons rather than I/O,
/// so runtime is no evidence either way. `completedArms == cases` alone is not enough: it holds
/// vacuously as `0 == 0` when the body stops on the first case. So the case count itself is
/// required to reach the design's minimum, and the approvals, knockouts, comparisons, and
/// exact-rate identities are required at floors derived from the arms rather than from a clock.
///
/// The variation thresholds are far below what 100 draws produce, so they witness variation
/// rather than pinning a distribution. Three assertions are not thresholds at all: every
/// element's refusal has to have been produced; both elements the predeclared statistic may or
/// may not read have to have been observed inert as well as blocking; and the combination arm
/// has to have reached both of its directions.
private final class CalibrationEvidenceVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var sliceCounts = Set<Int>()
    private var pairRotations = Set<Int>()
    private var budgets = Set<Int>()
    private var statistics = Set<BudgetPassStatistic>()
    private var methods = Set<ConfidenceIntervalMethod>()
    private var realPopulations = Set<Int>()
    private var syntheticPopulations = Set<Int>()
    private var abstentionShares = Set<Int>()
    private var errorCounts = Set<Int>()
    private var upperBounds = Set<Int>()
    private var nonPassingOutcomes = Set<GateOutcome>()
    private var referenceSites = Set<SliceReferenceSite>()
    private var otherVersions = Set<String>()
    private var otherLevels = Set<Int>()
    private var combinationSizes = Set<Int>()
    private var observedBudgetOutcomes = Set<BudgetRuleOutcome>()
    private var refusalsProduced = Set<EvidenceElement>()
    private var inertKnockoutsObserved = Set<EvidenceElement>()
    private var cases = 0
    private var completedArms = 0
    private var approvals = 0
    private var knockouts = 0
    private var inertKnockouts = 0
    private var blockedCombinations = 0
    private var approvedCombinations = 0
    private var comparisons = 0
    private var exactRateIdentities = 0

    func record(_ shape: EvidenceShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        sliceCounts.insert(shape.sliceCount)
        pairRotations.insert(shape.rotation % 3)
        budgets.insert(shape.budgetMillionths)
        statistics.insert(shape.statistic)
        methods.insert(shape.intervalMethod)
        realPopulations.insert(shape.realPopulation)
        syntheticPopulations.insert(shape.syntheticPopulation)
        abstentionShares.insert(shape.realAbstentionPermille)
        errorCounts.insert(shape.errorCount)
        upperBounds.insert(shape.upperBoundMillionths)
        nonPassingOutcomes.insert(shape.nonPassingOutcome)
        referenceSites.insert(shape.referenceSite)
        otherVersions.insert(shape.otherVersion)
        otherLevels.insert(shape.otherConfidenceLevelMillionths)
    }

    func recordApproval() {
        lock.lock()
        approvals += 1
        lock.unlock()
    }

    func recordKnockout() {
        lock.lock()
        knockouts += 1
        lock.unlock()
    }

    /// Called when a knockout the predeclared rule does not read left the release approvable.
    func recordInertKnockout(of element: EvidenceElement) {
        lock.lock()
        inertKnockouts += 1
        inertKnockoutsObserved.insert(element)
        lock.unlock()
    }

    /// Called only when a knockout's refusal matched the expected fault and every named
    /// position, so the coverage assertion below means each refusal was produced as stated.
    func recordRefusal(of element: EvidenceElement) {
        lock.lock()
        refusalsProduced.insert(element)
        lock.unlock()
    }

    func recordBudgetOutcome(_ outcome: BudgetRuleOutcome) {
        lock.lock()
        observedBudgetOutcomes.insert(outcome)
        lock.unlock()
    }

    func recordCombination(size: Int) {
        lock.lock()
        combinationSizes.insert(size)
        lock.unlock()
    }

    func recordBlockedCombination() {
        lock.lock()
        blockedCombinations += 1
        lock.unlock()
    }

    func recordApprovedCombination() {
        lock.lock()
        approvedCombinations += 1
        lock.unlock()
    }

    func recordComparison() {
        lock.lock()
        comparisons += 1
        lock.unlock()
    }

    func recordExactRateIdentity() {
        lock.lock()
        exactRateIdentities += 1
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

        let elementCount = EvidenceElement.allCases.count
        #expect(cases >= 100, "the design requires at least 100 generated cases, ran \(cases)")
        #expect(
            completedArms == cases,
            "\(cases - completedArms) of \(cases) cases did not reach the end of the body"
        )
        // Counted rather than timed. Each of these comes from a specific arm, so a body that
        // stopped before that arm shows a shortfall here even when every case that ran passed.
        #expect(approvals == cases, "coherent releases approved: \(approvals) of \(cases)")
        #expect(
            knockouts == cases * elementCount,
            "knockouts attempted: \(knockouts), expected \(cases * elementCount)"
        )
        #expect(comparisons >= cases * 3, "comparisons performed: \(comparisons)")
        #expect(
            exactRateIdentities >= cases * 3,
            "exact rate identities checked: \(exactRateIdentities)"
        )

        // The property's central claim: every element of a complete evidence set produced its
        // own refusal, at the fault and the position stated for it.
        let never = Set(EvidenceElement.allCases).subtracting(refusalsProduced)
        #expect(
            refusalsProduced == Set(EvidenceElement.allCases),
            "refusals never produced: \(never.map(\.rawValue).sorted())"
        )

        // The inert branch of each element the predeclared statistic may or may not read.
        // Combined with the coverage assertion above, which required each of the same two
        // elements to have blocked, this is all four branches: the gate reads the predeclared
        // statistic in both directions rather than assuming one.
        #expect(
            inertKnockoutsObserved == EvidenceElement.readThroughThePredeclaredStatistic,
            """
            elements observed inert: \(inertKnockoutsObserved.map(\.rawValue).sorted()), \
            expected \
            \(EvidenceElement.readThroughThePredeclaredStatistic.map(\.rawValue).sorted())
            """
        )
        #expect(inertKnockouts >= 20, "inert knockouts observed: \(inertKnockouts)")

        // The combination arm reached both of its directions.
        #expect(blockedCombinations >= 40, "combinations blocked: \(blockedCombinations)")
        #expect(approvedCombinations >= 3, "combinations approved: \(approvedCombinations)")
        #expect(
            combinationSizes.contains(0),
            "generated combination sizes: \(combinationSizes.sorted())"
        )
        #expect(
            combinationSizes.count >= 4,
            "generated combination sizes: \(combinationSizes.sorted())"
        )

        // The seed is drawn from 10,000 values, so a constant baseline shows 1.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            sliceCounts == [3, 4],
            "generated mandatory slice counts: \(sliceCounts.sorted())"
        )
        #expect(pairRotations == [0, 1, 2], "generated pair rotations: \(pairRotations.sorted())")
        // The budget is drawn from about 10,000 admissible values. The floor is an order of
        // magnitude above a constant baseline rather than a share of the range: the generator
        // concentrates its draws rather than spreading them uniformly.
        #expect(budgets.count >= 25, "generated budgets: \(budgets.count)")
        #expect(
            statistics == Set(BudgetPassStatistic.allCases),
            "predeclared statistics: \(statistics.map(\.rawValue).sorted())"
        )
        #expect(
            methods == Set(ConfidenceIntervalMethod.allCases),
            "predeclared interval methods: \(methods.map(\.rawValue).sorted())"
        )
        #expect(realPopulations.count >= 6, "generated real populations: \(realPopulations.count)")
        #expect(
            syntheticPopulations.count >= 5,
            "generated synthetic populations: \(syntheticPopulations.count)"
        )
        #expect(
            abstentionShares.count >= 25,
            "generated abstention shares: \(abstentionShares.count)"
        )
        #expect(errorCounts.count >= 10, "generated error counts: \(errorCounts.count)")
        #expect(upperBounds.count >= 25, "generated interval upper bounds: \(upperBounds.count)")
        #expect(
            nonPassingOutcomes == Set(GateOutcome.allCases.filter { !$0.isPassing }),
            "generated non-passing outcomes: \(nonPassingOutcomes.map(\.rawValue).sorted())"
        )
        #expect(
            referenceSites == Set(SliceReferenceSite.allCases),
            "unresolved predeclared references: \(referenceSites.map(\.rawValue).sorted())"
        )
        #expect(otherVersions.count >= 25, "generated other versions: \(otherVersions.count)")
        #expect(otherLevels.count >= 25, "generated other confidence levels: \(otherLevels.count)")

        // Every answer the pass rule can produce was reached while the releases were built, so
        // the pass arms compared a decision rather than one constant.
        #expect(
            observedBudgetOutcomes.isSuperset(of: [.evaluated(.passed), .evaluated(.failed)]),
            "observed budget outcomes: \(observedBudgetOutcomes)"
        )
        #expect(
            observedBudgetOutcomes.contains(.noObservedFalsePositiveRate),
            "no slice with an empty eligible real population reached the pass rule"
        )
    }
}

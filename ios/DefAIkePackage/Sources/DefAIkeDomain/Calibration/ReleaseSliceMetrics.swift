import Foundation

// Release-slice metrics, and the predeclared confidence result they are read with.
//
// This layer sits above ``CalibrationEvaluator``. The evaluator turns one logit and one
// quality record into one label; this file counts labels that were already assigned and
// reports the three rates Requirements 5.16 through 5.18 define, next to everything else
// Requirement 5.19 makes reportable for a mandatory Release Gating Slice.
//
// Two constraints shape every decision here, and both are structural rather than a
// comment asking for good behavior:
//
//   * **An insufficient outcome never leaves a denominator.** ``SliceOutcomeCounts``
//     already requires the three real label counts to sum to the eligible real
//     population and the three synthetic counts to sum to the eligible synthetic
//     population, so a denominator that excluded the abstentions would not be a
//     different rate — it would be an unconstructible count set. Nothing here recomputes
//     a population from the decisive labels, and nothing subtracts an abstention.
//     Requirements 5.16 and 5.17 name the eligible population as the denominator, and
//     Requirement 5.18 excludes abstentions from the coverage *numerator* only.
//   * **The confidence-interval result and its method are consumed, never chosen.** The
//     interval arrives whole, as an initializer argument, and is checked against the
//     method and level the slice predeclared (Requirement 5.15). There is no method
//     parameter, no per-method branch, and no arithmetic that could produce a bound: this
//     file contains no reference to any ``ConfidenceIntervalMethod`` case, so it cannot
//     select or compute one even by accident. An interval that disagrees with the
//     predeclared method or level is refused rather than adopted.
//
// # Why the rates are exact ratios rather than decimals
//
// A rate here is two counts, not a rounded number. `positive ÷ eligible` is frequently
// non-terminating and has no exact `Decimal` form, so producing a single `Decimal` would
// force this code to invent a rounding convention — and a rounding convention applied to
// a false-positive rate is a release decision about harm control. Keeping the ratio exact
// means the budget comparison Requirement 5.21 depends on is decided exactly, and the
// convention for a *published* number stays with the party that publishes it.
// ``ValidatedBenchmarkClaim`` reaches the same conclusion from the other direction: it
// checks a reported coverage only at the two endpoints the counts pin exactly.
//
// # What this file deliberately does not do
//
// It does not choose or derive a budget, a threshold, an interval, an interval method, a
// confidence level, or an eligibility rule: each one arrives from the validated
// Calibration Policy or the predeclared slice specification. It does not decide whether a
// release is approved — whether the mandatory slice set is complete, whether the
// contemporary phone-camera slice of Requirement 5.20 is present, and whether the
// populations were separated are the calibration approval gate's questions
// (Requirements 5.5, 5.20, 5.22, and 5.23), and one slice cannot answer them.
//
// It also does not write a ``CalibrationSliceResult``. That record states each rate as a
// `UnitInterval`, which is a rounded reported number and cannot represent a rate that was
// never measured, so filling one in from here would mean both inventing a rounding
// convention and writing 0 where a population is empty. The approval gate is where a
// recorded report is compared against measurements, with the whole slice set in view.

// MARK: - Measured rate

/// One measured rate, held as the exact ratio of two counts.
///
/// The denominator is a ``PositiveCount``, so a rate over an empty population is
/// unrepresentable rather than silently zero: `0/0` is not a rate of zero, it is a
/// measurement that was not taken. Callers that may have an empty population get an
/// `Optional` rate instead of a fabricated one.
public struct MeasuredRate: Hashable, Sendable, CustomStringConvertible {
    /// Images in the measured category, for example real images assigned the positive
    /// label.
    public let numerator: NonNegativeCount

    /// The full eligible population the rate is taken over, abstentions included.
    public let denominator: PositiveCount

    /// Builds a rate, refusing a numerator larger than the population it came from.
    ///
    /// `field` names the position for an audit message, so a rejection points at one rate
    /// rather than reporting "invalid metrics".
    public init(numerator: NonNegativeCount, denominator: PositiveCount, field: String) throws {
        guard numerator.value <= denominator.value else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: field,
                value: "\(numerator.value)/\(denominator.value)",
                allowed: "a numerator no greater than the eligible population"
            )
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The rate over `population`, or `nil` when that population is empty.
    ///
    /// The `nil` is the whole point: Requirements 5.16 and 5.17 define each rate over a
    /// specific ground-truth population, and a slice that contains none of one population
    /// has no such rate. Returning zero would report a measured absence of false
    /// positives that no image was ever examined for.
    static func rate(
        of numerator: NonNegativeCount,
        over population: NonNegativeCount,
        field: String
    ) throws -> MeasuredRate? {
        guard population.value > 0 else { return nil }
        return try MeasuredRate(
            numerator: numerator,
            denominator: try PositiveCount(validating: population.value),
            field: field
        )
    }

    /// Whether the rate is exactly zero.
    public var isZero: Bool { numerator.value == 0 }

    /// Whether every eligible image in the population fell in the measured category.
    public var isOne: Bool { numerator.value == denominator.value }

    /// Whether this rate is at most `limit`, decided exactly and failing closed.
    ///
    /// Compared as `numerator <= limit × denominator` rather than by dividing, because the
    /// quotient is frequently non-terminating and any decimal form of it is already a
    /// rounded value — the comparison would then be against the rounding, not against the
    /// rate. The multiplication is checked instead of trusted: if the product cannot be
    /// represented exactly the answer is `false`, so an unrepresentable comparison blocks
    /// rather than certifies. Both operands here are a release budget and an image count,
    /// so an inexact product means the inputs are far outside any measurable slice.
    public func isAtMost(_ limit: Decimal) -> Bool {
        guard let scaled = Self.exactProduct(limit, Decimal(denominator.value)) else {
            return false
        }
        return Decimal(numerator.value) <= scaled
    }

    /// `left × right`, or `nil` when the product is not exact.
    ///
    /// `Decimal`'s `*` operator discards the calculation error, so overflow or a silently
    /// rounded product would be indistinguishable from an exact one. This keeps the error.
    private static func exactProduct(_ left: Decimal, _ right: Decimal) -> Decimal? {
        var product = Decimal()
        var left = left
        var right = right
        let error = NSDecimalMultiply(&product, &left, &right, .plain)
        guard error == .noError else { return nil }
        return product
    }

    /// The exact ratio, for an audit message. Never a rounded quotient.
    public var description: String { "\(numerator.value)/\(denominator.value)" }
}

// MARK: - Budget rule outcome

/// The result of applying the predeclared False Accusation Budget pass rule to one slice.
///
/// Two cases rather than a bare ``GateOutcome``, because "the rule failed" and "the rule
/// had nothing to read" are different audit findings and only one of them is a
/// measurement. Requirement 5.1 scopes the budget to every mandatory slice *containing
/// held-out real images*, so a slice with none of them has no observed false-positive rate
/// for the rule to test. That case is never a pass, and it is not reported as a failure
/// either: what to do about a mandatory slice the budget cannot reach is the approval
/// gate's decision, and it needs to be able to tell the two apart.
public enum BudgetRuleOutcome: Hashable, Sendable {
    /// The predeclared rule was applied to the observed rate and the predeclared interval.
    case evaluated(GateOutcome)

    /// The slice contains no eligible held-out real image, so there is no observed
    /// false-positive rate and no rule result. Never a pass.
    case noObservedFalsePositiveRate

    /// Whether this outcome satisfies the budget. False whenever the rule did not run.
    public var isPassing: Bool {
        switch self {
        case let .evaluated(outcome): outcome.isPassing
        case .noObservedFalsePositiveRate: false
        }
    }
}

// MARK: - Measured slice

/// The complete measurement of one predeclared mandatory Release Gating Slice.
///
/// Holding this value means everything Requirement 5.19 requires reported for the slice is
/// present and is a measurement: the dataset composition and degradation condition the
/// slice predeclared, the label counts with their insufficient outcomes intact, the error
/// count, the false-positive and true-positive rates over their full eligible populations,
/// coverage, and a confidence-interval result carrying the predeclared method at the
/// predeclared level. Requirement 5.21's pass rule has been applied to the observed rate
/// and that interval, so ``budgetOutcome`` is derived from the counts rather than declared
/// by whoever wrote the report.
///
/// Each rate is `Optional` exactly where its ground-truth population can be empty.
/// Requirement 5.20 makes a contemporary phone-camera *real-image* subset a mandatory
/// slice, and a real-only slice has no synthetic population, so its true-positive rate is
/// absent rather than zero. That is the one reading of Requirements 5.19 and 5.20 that
/// does not fabricate a number: a rate of 0 would say every synthetic image in the slice
/// escaped detection, when there was no synthetic image at all.
public struct ReleaseSliceMeasurement: Hashable, Sendable {
    /// The slice as predeclared before evaluation began (Requirement 5.15).
    public let specification: ReleaseGatingSliceSpecification

    /// The validated policy whose budget and pass rule this slice was measured against.
    public let policy: ValidatedCalibrationPolicy

    /// The observed label counts, with the three insufficient counts intact.
    public let counts: SliceOutcomeCounts

    /// Requirement 5.16: real images assigned the positive label over every eligible real
    /// image in the slice, abstentions included. Absent when the slice holds no eligible
    /// real image.
    public let falsePositiveRate: MeasuredRate?

    /// Requirement 5.17: synthetic images assigned the positive label over every eligible
    /// synthetic image in the slice, abstentions included. Absent when the slice holds no
    /// eligible synthetic image.
    public let truePositiveRate: MeasuredRate?

    /// Requirement 5.18: eligible images assigned a decisive label over every eligible
    /// image in the slice. Always present, because a slice with no eligible image at all
    /// is refused.
    public let coverage: MeasuredRate

    /// The predeclared confidence-interval result on the observed false-positive rate.
    ///
    /// Supplied, and carried unchanged. Nothing here computes a bound, and the value is
    /// accepted only when its method and level are the ones the slice predeclared.
    public let falsePositiveRateInterval: ConfidenceIntervalResult

    /// Requirement 5.21's pass rule, applied to the observed rate and that interval.
    public let budgetOutcome: BudgetRuleOutcome

    /// Measures one slice from its predeclared specification and its observed counts.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending field. A failure
    /// is never an ``AnalysisError``: an unmeasurable slice leaves the release
    /// unevaluated rather than producing anything a user could see.
    ///
    /// `interval` is a required argument because Requirement 5.19 requires a predeclared
    /// 95% interval reported for every mandatory slice, and because an interval that
    /// arrives as an input cannot have been picked to suit the observation. Requirement
    /// 5.15 predeclares the method and level on the slice, and ``FalseAccusationPassRule``
    /// predeclares them again on the policy; both have to agree with each other and with
    /// the supplied result, so an interval computed with a method nobody predeclared is
    /// refused instead of reported.
    public init(
        slice specification: ReleaseGatingSliceSpecification,
        counts: SliceOutcomeCounts,
        falsePositiveRateInterval interval: ConfidenceIntervalResult,
        measuredAgainst policy: ValidatedCalibrationPolicy
    ) throws {
        let field = "slice[\(specification.id.rawValue)]"
        try ArtifactSchemaValidation.requireDecidedReference(
            specification.id,
            field: "\(field).id"
        )
        try Self.validatePredeclaredInterval(
            interval,
            slice: specification,
            policy: policy,
            field: field
        )

        let falsePositiveRate = try MeasuredRate.rate(
            of: counts.realPositiveLabels,
            over: counts.eligibleRealImages,
            field: "\(field).falsePositiveRate"
        )
        let truePositiveRate = try MeasuredRate.rate(
            of: counts.syntheticPositiveLabels,
            over: counts.eligibleSyntheticImages,
            field: "\(field).truePositiveRate"
        )
        guard counts.eligibleImageCount > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(
                field: "\(field).counts.eligibleImages",
                value: "\(counts.eligibleImageCount)"
            )
        }
        let coverage = try MeasuredRate(
            numerator: try NonNegativeCount(validating: counts.decisiveLabelCount),
            denominator: try PositiveCount(validating: counts.eligibleImageCount),
            field: "\(field).coverage"
        )

        self.specification = specification
        self.policy = policy
        self.counts = counts
        self.falsePositiveRate = falsePositiveRate
        self.truePositiveRate = truePositiveRate
        self.coverage = coverage
        self.falsePositiveRateInterval = interval
        self.budgetOutcome = Self.budgetOutcome(
            observedFalsePositiveRate: falsePositiveRate,
            interval: interval,
            rule: policy.policy.releasePassRule,
            budget: policy.policy.falseAccusationBudget
        )
    }

    // MARK: The predeclared interval

    /// Requirements 5.15 and 5.19: the reported interval is the predeclared one.
    ///
    /// Three separate refusals, because each one is a different way an interval stops
    /// pinning anything:
    ///
    ///   * The slice and the policy disagree about the method or the level. Then there is
    ///     no single predeclared choice to compare against, and picking either one would
    ///     be this code deciding which prediction counts. The level half of that check is
    ///     unreachable through valid artifacts today, because both types pin
    ///     ``FalseAccusationPassRule/requiredConfidenceLevel`` themselves. It stays written
    ///     out so the agreement is stated rather than inferred from two constants
    ///     happening to match.
    ///   * The supplied result was computed with another method, or at another level. A
    ///     method chosen after seeing the counts is the exact practice Requirement 5.15
    ///     exists to forbid, and the level is where Requirement 5.19's 95% is enforced —
    ///     read from the predeclared specification rather than written here.
    ///   * The bounds coincide. A lower bound equal to the upper bound expresses no
    ///     uncertainty, so it is a point estimate wearing an interval's name, and
    ///     Requirement 5.21's rule would then read the observed rate twice.
    ///
    /// Deliberately not checked: whether the interval contains the observed rate. Whether
    /// it must is a property of the method, and this code may not model a method it is
    /// forbidden to select — a containment rule written here would reject intervals that
    /// an approved method legitimately produces.
    private static func validatePredeclaredInterval(
        _ interval: ConfidenceIntervalResult,
        slice: ReleaseGatingSliceSpecification,
        policy: ValidatedCalibrationPolicy,
        field: String
    ) throws {
        let rule = policy.policy.releasePassRule
        guard slice.intervalMethod == rule.intervalMethod else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).intervalMethod",
                expected: rule.intervalMethod.rawValue,
                found: slice.intervalMethod.rawValue
            )
        }
        guard slice.confidenceLevel == rule.confidenceLevel else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).confidenceLevel",
                expected: rule.confidenceLevel.description,
                found: slice.confidenceLevel.description
            )
        }
        guard interval.method == slice.intervalMethod else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "\(field).falsePositiveRateInterval.method",
                expected: slice.intervalMethod.rawValue,
                found: interval.method.rawValue
            )
        }
        guard interval.confidenceLevel == slice.confidenceLevel else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "\(field).falsePositiveRateInterval.confidenceLevel",
                expected: slice.confidenceLevel.description,
                found: interval.confidenceLevel.description
            )
        }
        guard interval.lowerBound < interval.upperBound else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "\(field).falsePositiveRateInterval",
                value: "\(interval.lowerBound.description)...\(interval.upperBound.description)",
                allowed: "a lower bound below the upper bound, so the interval expresses "
                    + "uncertainty"
            )
        }
    }

    // MARK: The budget pass rule

    /// Requirement 5.21, applied rather than authored.
    ///
    /// The budget and the statistic come from the validated policy, and the interval was
    /// predeclared, so all this does is read them. `exceeds` in Requirement 5.22 is the
    /// failing direction, so a rate or bound exactly equal to the budget passes; treating
    /// equality as a failure would be a stricter rule than the one approved.
    ///
    /// The switch is exhaustive with no `default`, so adding a statistic to
    /// ``BudgetPassStatistic`` is a compile error here rather than a statistic that
    /// silently reads nothing.
    static func budgetOutcome(
        observedFalsePositiveRate rate: MeasuredRate?,
        interval: ConfidenceIntervalResult,
        rule: FalseAccusationPassRule,
        budget: FalseAccusationBudget
    ) -> BudgetRuleOutcome {
        guard let rate else { return .noObservedFalsePositiveRate }
        let observedRateSatisfies = rate.isAtMost(budget.rate)
        let upperBoundSatisfies = interval.upperBound.value <= budget.rate
        let satisfied =
            switch rule.statistic {
            case .observedRate: observedRateSatisfies
            case .intervalUpperBound: upperBoundSatisfies
            case .observedRateAndIntervalUpperBound: observedRateSatisfies && upperBoundSatisfies
            }
        return .evaluated(satisfied ? .passed : .failed)
    }
}

// MARK: - The reported fields

extension ReleaseSliceMeasurement {
    /// The slice this measurement answers for.
    public var slice: ReleaseSliceID { specification.id }

    /// The Model Bundle the measured policy was activated with.
    public var modelBundle: ModelBundleID { policy.modelBundle }

    /// The Calibration Policy this slice was measured against.
    public var calibrationPolicy: ArtifactID { policy.id }

    /// Requirement 5.19's dataset composition record for the slice.
    public var datasetComposition: EvidenceSource { specification.datasetComposition }

    /// Requirement 5.19's degradation condition for the slice.
    public var degradationCondition: EvidenceSource { specification.degradationCondition }

    /// The False Accusation Budget this slice was measured against.
    ///
    /// Surfaced beside ``budgetOutcome`` so the pass decision's inputs are all readable
    /// from the measurement: the observed rate, the predeclared interval, this budget, and
    /// ``releasePassRule``'s statistic. Read from the validated policy, never chosen here.
    public var falseAccusationBudget: FalseAccusationBudget {
        policy.policy.falseAccusationBudget
    }

    /// The predeclared pass rule that was applied (Requirement 5.21).
    public var releasePassRule: FalseAccusationPassRule { policy.policy.releasePassRule }

    /// Requirement 5.19's Analysis Error count for the slice.
    ///
    /// Reported beside the rates and deliberately not folded into one. An Analysis Error
    /// produced no label, and ``SliceOutcomeCounts`` pins each eligible population to the
    /// labels it received, so an error is neither a numerator member nor a denominator
    /// member. Hiding it inside a rate would make an evaluation run that mostly failed
    /// read like one that mostly abstained.
    public var errorCount: NonNegativeCount { counts.errorCount }

    /// Eligible images assigned an insufficient outcome, both populations pooled.
    ///
    /// Derived from the counts for reporting only; every one of these images is already
    /// inside the coverage denominator and inside whichever rate denominator its
    /// ground-truth population feeds.
    public var insufficientOutcomeCount: Int {
        counts.eligibleImageCount - counts.decisiveLabelCount
    }

    /// Whether this is the mandatory contemporary phone-camera real slice
    /// (Requirement 5.20).
    ///
    /// Read from the predeclared specification. Whether such a slice is present in a
    /// release's slice set is the approval gate's question, not one slice's.
    public var isContemporaryPhoneCameraSlice: Bool {
        specification.isContemporaryPhoneCameraSlice
    }
}

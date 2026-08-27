import Foundation

// The deterministic, quality-aware calibration evaluator.
//
// Calibration is the only path from a raw logit to Pixel Evidence, and this file is
// the whole of it: one pure, total, synchronous function over one finite logit and one
// Input Quality Record, evaluated against the validated Calibration Policy an Analysis
// Session is bound to.
//
// Three properties are the point, and each one is structural rather than asserted:
//
//   * Total. Every finite logit paired with a valid quality record reaches exactly one
//     of the three fixed labels, or the `calibration-input-error` path Requirement 5.25
//     defines. There is no fourth outcome and no unhandled combination: the validated
//     boundary schedule partitions the finite logit line, and every observation of a
//     required quality feature is absent, unusable, or usable.
//   * Deterministic. Nothing here reads a clock, a random source, or an iteration
//     order. `requiredQualityFeatures` is a `Set`, and Swift `Set` iteration order is
//     not stable across processes, so the quality gate combines per-feature verdicts
//     under a fixed precedence instead of returning the first verdict it meets.
//   * Quality-aware and fail closed. A missing or invalid required value never becomes
//     a default, a zero, or an assumption that the measurement was good enough. An
//     absent short edge is not a large short edge, and a recorded 0 is not a small one.
//
// Every number comes from the validated policy: the minimum short edge, each boundary
// position, each abstention half-width, and the policy's own spelling of the
// insufficient label. No threshold, budget, or half-width is written here.
//
// # Precedence, when two rules fire at once
//
// One record can satisfy several rules: a short edge of 300 abstains under Requirement
// 5.9 while a different required feature is missing and uncovered under Requirement
// 5.25. Requirement 5.24's abstention *is* a Pixel Evidence value; Requirement 5.25's
// outcome is an Analysis Error returned **without** Pixel Evidence. Returning the
// insufficient label would therefore break 5.25, while returning the error breaks
// nothing 5.24 says, because 5.24 describes what to return when the observed condition
// is covered and this one is not. So the input error dominates, abstention dominates a
// decisive logit, and the three verdicts form a total order rather than a scan order.
//
// # What this evaluator does not do
//
// It does not validate a policy: ``ValidatedCalibrationPolicy`` is the only way to
// construct one, and holding that type is what lets this code treat the boundary
// schedule as a partition instead of re-deriving that fact per call. It does not
// compute a release metric, approve a policy, or read a probability: a logit reaches
// exactly one label and stops.

/// Maps one finite raw logit and one Input Quality Record to exactly one of the three
/// fixed pixel labels, or fails closed.
///
/// Constructed from a ``ValidatedCalibrationPolicy``, so the schedule it evaluates has
/// already been proven finite, nonambiguous, and gapless: no two closed abstention
/// bands touch, adjacent boundaries agree about the region they share, and no decisive
/// region is the insufficient outcome. Those are exactly the facts that make the single
/// pass over the schedule below total.
public struct CalibrationEvaluator: PixelCalibrating, Hashable, Sendable {

    /// The policy this evaluator was activated with, unchanged.
    public let activatedPolicy: ValidatedCalibrationPolicy

    public init(activatedWith policy: ValidatedCalibrationPolicy) {
        self.activatedPolicy = policy
    }

    /// The policy's artifact identifier, matching an ``AnalysisSessionBinding``.
    public var policyID: ArtifactID { activatedPolicy.id }

    /// The single Insufficient Evidence Outcome every abstention path returns.
    ///
    /// Read from the artifact rather than written here. `belowMinimumShortEdgeLabel` is
    /// the policy's own spelling of that outcome, and ``CalibrationPolicy`` cannot be
    /// constructed with any other label in that position, so the field *is* the
    /// insufficient label. Requirement 5.2 fixes the label set at three, so the closed
    /// band, the sub-440 rule, and an evidenced quality rule share one insufficient
    /// label rather than each naming its own.
    var insufficientOutcome: PixelEvidence {
        activatedPolicy.policy.belowMinimumShortEdgeLabel.pixelEvidence
    }

    // MARK: - The calibration port

    /// Requirements 5.4, 5.8, 5.9, 5.10, 5.24, and 5.25.
    ///
    /// `policy` is the Calibration Policy the Analysis Session is bound to. It has to be
    /// the policy this evaluator was activated with: Requirements 5.10, 5.24, and 5.25
    /// each name *the validated policy bound to the session*, so evaluating a session's
    /// logit against some other policy — a bundle activated or rolled back after the
    /// session started, or a policy that never passed activation — would produce a label
    /// no measured calibration evidence covers.
    ///
    /// A disagreement is the Requirement 5.13 compatibility rejection, and the design's
    /// error table gives a failed compatibility the `model-load-error` category. It is
    /// deliberately not `calibration-input-error`, which Requirement 5.25 reserves for a
    /// required quality value, and deliberately not a label.
    public func classify(
        _ logit: RawLogit,
        quality: InputQualityRecord,
        policy: CalibrationPolicy
    ) throws(AnalysisFault) -> PixelEvidence {
        guard policy == activatedPolicy.policy else {
            throw AnalysisFault.analysis(.modelLoadError, stage: .calibration)
        }
        return try label(forRawLogit: logit.value, quality: quality)
    }

    // MARK: - Evaluation

    /// The label for one raw value, or one fault.
    ///
    /// Takes a `Double` rather than a ``RawLogit`` so the nonfinite refusal is reachable
    /// and testable. `RawLogit` already makes NaN and infinity unconstructible, so this
    /// is the second lock, not the only one — but it has to exist, because IEEE
    /// comparison semantics would not fail closed on their own: every comparison against
    /// NaN is false, so a NaN would fall past every band and every decisive region check
    /// below and emerge as the label above the last boundary. Requirement 4.16 forbids
    /// mapping a nonfinite output to a label at all, so the value is refused explicitly.
    ///
    /// The category stays `invalid-output-error` because that is what the value is; the
    /// stage is `calibration` because that is where it was caught. Output validation
    /// owns the first check, and a snapshot that names calibration is the honest record
    /// that the first check let one through.
    func label(
        forRawLogit value: Double,
        quality: InputQualityRecord
    ) throws(AnalysisFault) -> PixelEvidence {
        guard value.isFinite else {
            throw AnalysisFault.analysis(.invalidOutputError, stage: .calibration)
        }

        switch qualityVerdict(for: quality) {
        case .inputError:
            // Requirement 5.25: no Pixel Evidence at all, so this is a throw rather
            // than a label. Nothing downstream can turn it back into evidence.
            throw AnalysisFault.analysis(.calibrationInputError, stage: .calibration)
        case .abstain:
            return insufficientOutcome
        case .logitDecides:
            guard
                let label = Self.label(
                    forFiniteLogit: value,
                    boundaries: activatedPolicy.orderedBoundaries,
                    insufficientOutcome: insufficientOutcome
                )
            else {
                // A schedule with no boundary decides nothing, so there is no label to
                // return and none may be invented. A validated policy always carries at
                // least one boundary, which is why this is the same unusable-policy
                // outcome as a policy that is not the activated one.
                throw AnalysisFault.analysis(.modelLoadError, stage: .calibration)
            }
            return label
        }
    }

    /// One pass over the ascending boundary schedule (Requirements 5.4 and 5.8).
    ///
    /// For a validated schedule the finite line is: the region below the first band, one
    /// closed band per boundary, one decisive region between each adjacent pair of bands,
    /// and the region above the last band. This walks that partition in order and stops
    /// at the first region containing `value`, so exactly one label is produced:
    ///
    ///   * `value` below this band's lower edge — it is in the decisive region this
    ///     boundary's lower label names, and every earlier band has been passed.
    ///   * `value` inside `[boundary - h, boundary + h]` — the band is closed on both
    ///     edges, which is why the two comparisons are `<` then `<=`: the lower edge,
    ///     the boundary, and the upper edge are all inside.
    ///   * otherwise `value` is above this band, so the boundary's upper label becomes
    ///     the standing decisive label and the walk continues.
    ///
    /// Static, and taking the schedule as a parameter, so the empty-schedule case is
    /// reachable in a test. `nil` means the schedule decided nothing; it is never a
    /// label and never a silent default.
    static func label(
        forFiniteLogit value: Double,
        boundaries: [CategoryBoundary],
        insufficientOutcome: PixelEvidence
    ) -> PixelEvidence? {
        var labelAbovePassedBands: PixelLabelKey?
        for boundary in boundaries {
            if value < boundary.abstentionLowerBound {
                return boundary.lowerDecision.pixelEvidence
            }
            if value <= boundary.abstentionUpperBound {
                return insufficientOutcome
            }
            labelAbovePassedBands = boundary.upperDecision
        }
        return labelAbovePassedBands?.pixelEvidence
    }

    // MARK: - The quality gate

    /// What the quality gate concluded about one Input Quality Record.
    ///
    /// The three cases are ordered by how much they withhold, and the order is the
    /// precedence: an input error withholds Pixel Evidence entirely, abstention
    /// withholds a decision, and `logitDecides` withholds nothing. `Comparable` is
    /// synthesized from that declaration order, so combining verdicts with `max` is
    /// independent of the order the features were visited in.
    enum QualityVerdict: Comparable, Hashable, Sendable {
        /// No quality rule fired. The logit and the boundary schedule decide.
        case logitDecides
        /// An abstention rule fired: the sub-440 rule, or an evidenced quality rule
        /// (Requirements 5.9 and 5.24).
        case abstain
        /// A required value is missing or invalid and no approved rule covers the
        /// observed condition (Requirement 5.25).
        case inputError
    }

    /// The verdict for one record: the short-edge rule combined with every required
    /// feature's rule under the precedence above.
    func qualityVerdict(for quality: InputQualityRecord) -> QualityVerdict {
        var verdict = Self.shortEdgeVerdict(
            quality.shortEdgeBeforeOrientation,
            minimumShortEdge: activatedPolicy.policy.minimumShortEdge
        )
        for feature in activatedPolicy.policy.requiredQualityFeatures {
            verdict = max(verdict, self.verdict(forRequired: feature, in: quality))
        }
        return verdict
    }

    /// Requirement 5.9, and Requirement 5.25 for the measurement it needs.
    ///
    /// The recorded short edge is a required quality value for every Version 1 policy,
    /// because the sub-440 rule is unconditional and cannot be evaluated without it:
    ///
    ///   * Absent is an input error. It is not "at least the minimum", and no approved
    ///     abstention rule covers a short edge that was never measured. Reading absence
    ///     as large enough would let an unmeasured image be labeled.
    ///   * A nonpositive length is an input error, not a small edge. Requirement 5.9
    ///     abstains for 1 through the minimum less one; 0 is not a length a decoded
    ///     image has, so it is an invalid value rather than the smallest valid one.
    ///     ``InputQualityRecord`` already refuses a nonpositive dimension, so this is
    ///     the second lock — and the one that keeps zero from being read as unknown.
    ///   * Otherwise the edge is compared against the policy's declared minimum. The
    ///     number is never written here.
    ///
    /// The measurement is the record's own `shortEdgeBeforeOrientation`, not an entry in
    /// `validatedFeatures`: no approved quality-feature identifier for the short edge
    /// exists, and minting one here would be a placeholder for a deliberately unresolved
    /// release input. A policy that separately declares a short-edge feature still has
    /// that feature evaluated as a required feature in its own right.
    static func shortEdgeVerdict(_ shortEdge: Int?, minimumShortEdge: Int) -> QualityVerdict {
        guard let shortEdge else { return .inputError }
        guard shortEdge >= 1 else { return .inputError }
        return shortEdge < minimumShortEdge ? .abstain : .logitDecides
    }

    /// The verdict for one required feature.
    ///
    /// Every rule matching the observation is collected and the strongest verdict wins.
    /// Activation already refuses two rules on one feature that can match the same
    /// observation with different outcomes, so for a validated policy at most one
    /// verdict is ever present; taking the maximum rather than the first keeps that
    /// independent of rule order too.
    ///
    /// When no rule matched, an absent or unusable value falls to the policy's declared
    /// behavior for a condition it does not cover (Requirement 5.25), and a usable value
    /// leaves the decision to the logit.
    func verdict(
        forRequired feature: QualityFeatureID,
        in quality: InputQualityRecord
    ) -> QualityVerdict {
        let observed = observation(of: feature, in: quality)
        let fired = activatedPolicy.policy.qualityRules
            .filter { $0.feature == feature && Self.rule($0, matches: observed) }
            .map { Self.verdict(for: $0.outcome) }
        if let strongest = fired.max() { return strongest }

        switch observed {
        case .absent, .unusable:
            return Self.verdict(for: activatedPolicy.policy.uncoveredQualityInputBehavior)
        case .usable:
            return .logitDecides
        }
    }

    /// One observation of one required feature, before any rule is consulted.
    ///
    /// Three disjoint observations, matching the three things ``QualityCondition`` can
    /// describe. `magnitude` is deliberately `nil` for both non-usable cases, so no
    /// threshold condition can match an absent or unusable value by accident.
    enum Observation: Hashable, Sendable {
        /// The record carries no entry for the feature.
        case absent
        /// Present, but not a value the policy's stated conditions can read.
        case unusable
        /// Present and usable, carrying a comparable measurement when it has one.
        case usable(magnitude: Decimal?)

        /// The comparable measurement, or `nil` when there is none to compare.
        var magnitude: Decimal? {
            switch self {
            case .absent, .unusable: nil
            case .usable(let magnitude): magnitude
            }
        }
    }

    /// Observes one required feature in one record.
    ///
    /// An exact measured count is a magnitude. A recorded boolean condition is where
    /// "present but invalid" comes from: ``QualityCondition`` states thresholds as
    /// decimals and has no boolean test, so a policy that states a threshold for this
    /// feature is asking for a magnitude the record does not carry — a present value the
    /// rules cannot read, which is the "invalid" half of Requirements 5.24 and 5.25.
    /// Where the policy states no threshold for the feature, the same recorded condition
    /// is a real measurement that simply matches no rule; calling it invalid would turn
    /// a successful measurement into an error, and a recorded `false` into a defect.
    func observation(
        of feature: QualityFeatureID,
        in quality: InputQualityRecord
    ) -> Observation {
        guard let value = quality.validatedFeatures[feature] else { return .absent }
        switch value {
        case .integer(let measurement):
            return .usable(magnitude: Decimal(measurement))
        case .boolean:
            return statesMeasuredCondition(for: feature)
                ? .unusable
                : .usable(magnitude: nil)
        }
    }

    /// Whether the policy states a measured-value condition for `feature`.
    private func statesMeasuredCondition(for feature: QualityFeatureID) -> Bool {
        activatedPolicy.policy.qualityRules.contains {
            $0.feature == feature && !$0.condition.matchesUnusableValue
        }
    }

    /// Whether one rule matches one observation.
    ///
    /// Exhaustive over the condition vocabulary with no `default`, so adding a condition
    /// is a compile error here rather than a silently unmatched rule. A closed range is
    /// matched from outside, which is the condition the policy states.
    static func rule(_ rule: QualityDecisionRule, matches observation: Observation) -> Bool {
        switch rule.condition {
        case .valueMissing:
            observation == .absent
        case .valueInvalid:
            observation == .unusable
        case .atOrBelow(let threshold):
            observation.magnitude.map { $0 <= threshold } ?? false
        case .atOrAbove(let threshold):
            observation.magnitude.map { $0 >= threshold } ?? false
        case .outsideClosedRange(let lower, let upper):
            observation.magnitude.map { $0 < lower || $0 > upper } ?? false
        }
    }

    /// The verdict a matched rule produces (Requirements 5.24 and 5.25).
    static func verdict(for outcome: QualityRuleOutcome) -> QualityVerdict {
        switch outcome {
        case .insufficientSignal: .abstain
        case .calibrationInputError: .inputError
        }
    }

    /// The verdict for an observed condition no rule covers.
    ///
    /// ``CalibrationPolicy`` cannot be constructed with anything but
    /// `calibrationInputError` here, so the other arm is unreachable through a validated
    /// policy. It stays written out so the mapping is total and so a future approved
    /// behavior cannot arrive as a silent fallthrough.
    static func verdict(for behavior: UncoveredQualityInputBehavior) -> QualityVerdict {
        switch behavior {
        case .insufficientSignal: .abstain
        case .calibrationInputError: .inputError
        }
    }
}

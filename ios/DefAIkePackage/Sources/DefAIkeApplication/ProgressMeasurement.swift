import DefAIkeDomain

// The values honest progress derivation works from.
//
// An adapter reports what it actually counted while doing work: bytes streamed, rows
// transformed. Those raw reports are the only admissible input to a completion
// fraction (Requirement 15.2), so they are modelled here as measurements that can be
// absent, can be unreliable, and can disagree with each other — because in practice
// they are all three. The derivation in `ProgressDerivation.swift` refuses a fraction
// in every one of those cases rather than repairing the report.
//
// Completed and total are two independently united measurements rather than two
// numbers sharing one declared unit. That is deliberate: a framework can report a
// byte total alongside a row count, and pooling those into one fraction produces a
// number that looks measured and is not. The units have to be comparable for the
// mismatch to be detectable at all.
//
// Deliberately absent from this file, and the absence is the requirement:
//
//   * No clock, `Date`, `Duration`, deadline, elapsed-time, countdown, or
//     estimated-completion member. Progress carries no time, so nothing downstream
//     can read a duration out of it and no terminal decision can be derived from one
//     (Requirement 15.10 and the design's "no unmeasured analysis timeout").
//   * No stage weighting, stage count, or percent-per-stage table. A weighted stage
//     percentage is an estimate presented as a measurement, which is what the design
//     forbids outright.
//   * No default reliability, and no default unit. A caller that does not know
//     whether its own count is trustworthy cannot silently claim it is.
//   * No initializer anywhere in this file that takes a bare fraction, percentage,
//     probability, confidence, logit, or calibration label. The only way to obtain an
//     ``AnalysisWorkPercentage`` is from a determinate measured state.
//
// None of these types is `Codable`. Progress describes work in flight for the active
// session and is then discarded; there is no progress history, export, or replay, so
// giving it a serialized form would only create a way to leak one.

/// Whether the operation doing the work vouches for an amount it reported.
///
/// There is no third case and no "probably". An amount an adapter cannot stand
/// behind is `unreliable`, and an unreliable amount can never contribute to a
/// completion fraction (Requirements 15.2 and 15.3).
public enum WorkMeasurementReliability: String, Sendable, CaseIterable {
    /// Counted directly by the operation performing the work.
    case reliable

    /// Estimated, extrapolated, sampled, stale, or otherwise not vouched for.
    case unreliable
}

/// One amount an operation reports about its own analysis work.
public struct WorkAmount: Hashable, Sendable {
    /// How much work this amount describes, counted in ``unit``.
    public let amount: UInt64

    /// What is being counted.
    public let unit: ProgressUnit

    /// Whether the reporting operation vouches for ``amount``.
    public let reliability: WorkMeasurementReliability

    public init(
        amount: UInt64,
        unit: ProgressUnit,
        reliability: WorkMeasurementReliability
    ) {
        self.amount = amount
        self.unit = unit
        self.reliability = reliability
    }

    /// Creates an amount from a framework's signed count, or `nil` when the count is
    /// negative.
    ///
    /// Progress-reporting APIs use a negative count as an "unknown" sentinel. Widening
    /// such a value into an unsigned amount would turn "I do not know the total" into
    /// the largest total expressible, and every subsequent fraction would be honest
    /// arithmetic over a fabricated denominator. `nil` here becomes a missing
    /// measurement, which becomes indeterminate progress.
    public init?(
        reportedCount: Int64,
        unit: ProgressUnit,
        reliability: WorkMeasurementReliability
    ) {
        guard reportedCount >= 0 else { return nil }
        self.init(
            amount: UInt64(reportedCount),
            unit: unit,
            reliability: reliability
        )
    }

    /// Whether this amount may contribute to a completion fraction.
    var isReliable: Bool { reliability == .reliable }
}

/// What one operation reports about the work it is performing.
///
/// Both amounts are optional because both are genuinely optional at runtime: a stream
/// of unknown length reports completed bytes with no total, and a stage that counts
/// nothing reports neither. Absence is carried rather than replaced, so the reason a
/// fraction was refused survives into ``UnmeasuredProgressCause``.
///
/// The two amounts must come from one operation's report of its own work, which is
/// the "same measured work" half of the design's rule. Unit disagreement and
/// unreliability are checked; a caller that pairs one operation's completed count
/// with a different operation's total has misreported its work, and no arithmetic
/// here can detect that.
public struct ReportedWork: Hashable, Sendable {
    /// Work finished so far, when the operation counts it.
    public let completed: WorkAmount?

    /// Work the operation expects in total, when it knows it.
    public let total: WorkAmount?

    public init(completed: WorkAmount?, total: WorkAmount?) {
        self.completed = completed
        self.total = total
    }
}

/// Why no completion fraction was derivable from a report.
///
/// Every case yields the same outcome — explicitly indeterminate progress — so the
/// cause exists for auditing and diagnostics rather than to select behavior. Keeping
/// it separate from the progress state is the same split the Resource Controller uses
/// for a breach cause: an audit can name which fail-closed path fired without the
/// user-facing vocabulary growing a case the requirements do not define.
public enum UnmeasuredProgressCause: Hashable, Sendable {
    /// The stage reported no measurement at all.
    case nothingReported

    /// A total was reported with no completed count to compare against it.
    case completedAmountMissing

    /// Completed work was counted, but the operation does not know the total.
    case totalAmountMissing

    /// The two amounts count different things, so their ratio is not a fraction of
    /// anything. Never resolved by preferring one unit.
    case unitMismatch(completed: ProgressUnit, total: ProgressUnit)

    /// The completed count is not vouched for by the operation that reported it.
    case unreliableCompletedAmount

    /// The total is not vouched for by the operation that reported it.
    case unreliableTotalAmount

    /// The total is zero, so there is nothing to divide by. An unsigned amount cannot
    /// be negative, so zero is the only way the design's `total > 0` can fail.
    case totalIsNotPositive

    /// Completed work exceeds the total, so the two do not describe one consistent
    /// measurement. Never resolved by clamping to the total.
    case completedExceedsTotal
}

/// What a numeric progress quantity means.
///
/// One case by construction, so "probability", "confidence", "certainty", and
/// "likelihood" are not representable. Requirement 15.11 requires a displayed
/// percentage to be identified as analysis work progress rather than as a result
/// probability or confidence; making the alternative unrepresentable is how that
/// identification survives a later refactor.
public enum ProgressQuantitySemantics: String, Sendable, CaseIterable {
    /// The fraction of measured analysis work completed so far.
    case analysisWorkProgress
}

/// A percentage of measured analysis work.
///
/// Derived only from a determinate ``AnalysisProgressState``, which is itself derived
/// only from reliable, comparable, in-range measurements. There is no initializer
/// from a `Double`, a percentage, a raw logit, a calibration label, a probability, or
/// a confidence value, so the only percentage this module can produce is a measured
/// work fraction (Requirements 15.2 and 15.11).
///
/// It carries no display text. Which English sentence labels it is Approved Verdict
/// Copy resolved in the presentation layer; this type fixes the meaning, and
/// ``semantics`` is the whole of that meaning.
public struct AnalysisWorkPercentage: Hashable, Sendable {
    /// What this quantity is. Always analysis work progress.
    public static let semantics: ProgressQuantitySemantics = .analysisWorkProgress

    /// The measured percentage of analysis work completed, in `0...100`.
    public let percent: Double

    /// The unit the underlying measurements were counted in.
    public let unit: ProgressUnit

    /// The stage whose work this percentage describes.
    public let stage: AnalysisStage

    /// Creates a percentage from a determinate measured state, or `nil` for any state
    /// with no usable fraction.
    ///
    /// `nil` covers indeterminate progress and a determinate state whose measurements
    /// cannot produce a fraction. A percentage is therefore absent exactly when the
    /// measurement is unusable, rather than being shown as zero.
    public init?(_ state: AnalysisProgressState) {
        guard case .determinate(_, _, let unit, let stage) = state,
              let fraction = state.fractionOfWorkCompleted
        else { return nil }
        self.percent = fraction * 100
        self.unit = unit
        self.stage = stage
    }
}

/// What an indeterminate progress state asserts about the session.
///
/// One case by construction. Indeterminate progress means the work is continuing:
/// "stalled", "completed", and "failed" are not representable here, so an unmeasured
/// stage cannot be projected as a stopped or finished one (Requirements 15.1 and
/// 15.4). Completion, cancellation, and failure are separate terminal outcomes owned
/// by the session coordinator, and none of them is a progress state.
public enum IndeterminateProgressAssertion: String, Sendable, CaseIterable {
    /// Analysis work is still running.
    case analysisIsContinuing
}

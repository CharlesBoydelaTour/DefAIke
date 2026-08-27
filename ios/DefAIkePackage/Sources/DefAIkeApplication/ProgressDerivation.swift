import DefAIkeDomain

// Honest progress derivation.
//
// The design fixes one rule and permits no other:
//
//     if unit is defined AND total > 0 AND 0 <= completed <= total
//        AND completed and total describe the same reliable measured work:
//            determinate(completed, total, unit)
//     else:
//            indeterminate(stage, "Analysis is continuing")
//
// This file is that rule and nothing else. It is a pure value derivation: no clock, no
// stored history, no adapter, no actor, and no mutable state. Two consequences are the
// point rather than side effects:
//
//   * Elapsed time cannot reach any terminal decision through progress, because
//     progress holds no time to read (Requirement 15.10). The derivation cannot end a
//     session, cannot fail, and cannot report a deadline; it produces one displayable
//     state.
//   * The derivation is total. Every report, including no report at all, yields a
//     state, so active work always has something honest to display and there is no
//     window where a running stage shows nothing (Requirement 15.1).
//
// Being stateless also means the derivation makes no monotonicity claim. A stage that
// revises its total mid-flight is reporting a new measurement, not breaking a promise
// the last fraction made, and inventing a stored maximum to keep a bar from moving
// backwards would be exactly the kind of cosmetic smoothing that turns a measurement
// into an estimate.

/// The progress state derived from one operation's reported work.
///
/// Carries the state a presenter displays and, when no fraction was derivable, the
/// single reason why. A determinate state here is guaranteed usable: it never carries
/// a zero total or an out-of-range completed count, so
/// ``AnalysisProgressState/fractionOfWorkCompleted`` is non-`nil` whenever
/// ``isDeterminate`` is true.
public struct DerivedAnalysisProgress: Hashable, Sendable {
    /// The state to display for this stage.
    public let state: AnalysisProgressState

    /// Why no fraction was derived. `nil` exactly when ``state`` is determinate.
    public let unmeasuredCause: UnmeasuredProgressCause?

    /// Derives progress for `stage` from one operation's report of its own work.
    ///
    /// The prerequisites are checked in the design's order — both amounts present,
    /// comparable units, both reliable, positive total, completed in range — and the
    /// first one that fails is the reported cause. Any single failure is enough:
    /// nothing is repaired, clamped, substituted, or preferred, because every repair
    /// would produce a fraction the work never measured.
    ///
    /// `nil` for a stage whose work reports no measurement at all, which is not an
    /// error and not a stall.
    public init(reported: ReportedWork?, at stage: AnalysisStage) {
        switch Self.measuredWork(in: reported) {
        case .measured(let completed, let total, let unit):
            self.state = .determinate(
                completed: completed,
                total: total,
                unit: unit,
                stage: stage
            )
            self.unmeasuredCause = nil
        case .refused(let cause):
            self.state = .indeterminate(stage: stage)
            self.unmeasuredCause = cause
        }
    }

    /// Derives progress for a stage whose work reports no measurement.
    ///
    /// Model load and calibration count nothing a user could see a fraction of. That
    /// is a fact about the work, so it produces explicitly indeterminate progress
    /// rather than a synthesized step count.
    public init(at stage: AnalysisStage) {
        self.init(reported: nil, at: stage)
    }

    /// The stage this progress describes.
    public var stage: AnalysisStage { state.stage }

    /// Whether a completion fraction is available.
    public var isDeterminate: Bool { state.isDeterminate }

    /// The measured fraction of analysis work completed, in `0...1`, or `nil`.
    public var fractionOfWorkCompleted: Double? { state.fractionOfWorkCompleted }

    /// The measured percentage of analysis work completed, or `nil` when no fraction
    /// was derivable.
    ///
    /// Labeled analysis work progress by its type and never a result probability or
    /// confidence (Requirement 15.11). Absent rather than zero when the measurement is
    /// unusable, so an indeterminate stage cannot be rendered as "0% done".
    public var percentage: AnalysisWorkPercentage? { AnalysisWorkPercentage(state) }

    /// What an indeterminate state asserts, or `nil` when progress is determinate.
    ///
    /// Non-`nil` exactly when there is no fraction to show, which is the case
    /// Requirement 15.4 governs: the session is continuing, not stalled, completed, or
    /// failed.
    public var indeterminateAssertion: IndeterminateProgressAssertion? {
        state.isDeterminate ? nil : .analysisIsContinuing
    }

    // MARK: - The rule

    /// The outcome of checking one report against the design's prerequisites.
    private enum Prerequisites {
        case measured(completed: UInt64, total: UInt64, unit: ProgressUnit)
        case refused(UnmeasuredProgressCause)
    }

    private static func measuredWork(in reported: ReportedWork?) -> Prerequisites {
        guard let reported else { return .refused(.nothingReported) }
        guard let completed = reported.completed else {
            return .refused(.completedAmountMissing)
        }
        guard let total = reported.total else {
            return .refused(.totalAmountMissing)
        }
        // A unit is defined for each amount by construction, so "unit is defined"
        // becomes "the two units are the same one". Counting bytes against a row total
        // is not a fraction of the work; it is a ratio of two unrelated quantities.
        guard completed.unit == total.unit else {
            return .refused(
                .unitMismatch(completed: completed.unit, total: total.unit)
            )
        }
        guard completed.isReliable else {
            return .refused(.unreliableCompletedAmount)
        }
        guard total.isReliable else {
            return .refused(.unreliableTotalAmount)
        }
        guard total.amount > 0 else {
            return .refused(.totalIsNotPositive)
        }
        guard completed.amount <= total.amount else {
            return .refused(.completedExceedsTotal)
        }
        return .measured(
            completed: completed.amount,
            total: total.amount,
            unit: completed.unit
        )
    }
}

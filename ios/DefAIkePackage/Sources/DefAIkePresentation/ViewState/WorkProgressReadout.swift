import DefAIkeDomain

// What a progress surface may say, and the shapes that keep it from saying anything else.
//
// Requirement 15.11 asks for two things about a displayed percentage: that it come from
// the reliable completed-work and total-work measurements, and that it be identified as
// analysis *work* progress rather than a result probability or confidence. Requirement
// 15.4 asks that an unmeasured active state say the analysis is continuing rather than
// stalled, completed, or failed. Requirement 15.5 asks that cancellation stay visible and
// enabled for the whole of active work.
//
// All three are settled by shape here rather than by wording downstream, because wording
// is an unresolved release decision and shape is not:
//
//   * **A percentage cannot be read as a likelihood.** ``WorkProgressReadout`` holds two
//     unsigned measured amounts and their unit. It exposes no `Double`, no `Float`, no
//     `Decimal`, no fraction in `0...1`, and no `Comparable` or arithmetic conformance, so
//     there is no value to threshold, no value to multiply into a score, and nothing that
//     reads as a chance of anything. Its only initializer takes a determinate
//     ``AnalysisProgressState``; there is no initializer from a number, a logit, a
//     calibration label, or a piece of evidence.
//   * **The quantity names itself.** ``WorkProgressQuantity`` has exactly one case, so
//     "probability", "confidence", "certainty", and "likelihood" are not expressible as
//     the meaning of the number.
//   * **An unmeasured state asserts continuation and nothing else.**
//     ``ContinuingWorkAssertion`` has exactly one case, so "stalled", "completed", and
//     "failed" cannot be asserted by a progress value. Those three are terminal outcomes
//     owned by the session, and none of them is progress.
//   * **Cancellation has one availability.** ``CancellationAvailability`` has exactly one
//     case, so a hidden, disabled, or deferred cancel control is unrepresentable wherever
//     the field appears - and it appears on the active screen only.
//
// This module derives no progress. Whether a fraction exists at all was decided by the
// coordinator's honest derivation from what an operation reported about its own work, and
// arrives here already settled as an ``AnalysisProgressState``. Nothing here consults a
// clock, weights a stage, smooths a value, remembers a previous maximum, or substitutes a
// value for a missing measurement. The arithmetic below is exact integer arithmetic over
// the amounts the measurement carried.

/// What a numeric progress quantity means in the presentation layer.
///
/// One case by construction. Requirement 15.11 requires a displayed percentage to be
/// identified as analysis work progress; making every alternative meaning unrepresentable
/// is how that identification survives a refactor that nobody re-reads the requirement
/// for.
public enum WorkProgressQuantity: String, Hashable, Sendable, CaseIterable {
    /// The measured fraction of analysis work completed so far.
    case analysisWorkProgress
}

/// What an unmeasured active progress state asserts.
///
/// One case by construction (Requirement 15.4). An active session with no usable
/// completion fraction is continuing. It is not stalled, not finished, and not failed, and
/// no value here can say otherwise.
public enum ContinuingWorkAssertion: String, Hashable, Sendable, CaseIterable {
    /// Analysis work is still running.
    case analysisIsContinuing
}

/// The cancellation control's availability while analysis work is active.
///
/// One case by construction (Requirement 15.5). A control that is hidden, disabled, or
/// "available once the current stage finishes" is not representable, so cancellation
/// cannot be withdrawn part-way through a minute-scale analysis by an ordinary code
/// change.
///
/// Whether the control is *reachable through the Accessibility Layer* is a separate
/// guarantee that needs accessibility semantics and manual assistive-technology testing.
/// This value states availability only, and claims nothing about accessibility
/// conformance.
public enum CancellationAvailability: String, Hashable, Sendable, CaseIterable {
    /// Visible and enabled, for the whole of active work.
    case visibleAndEnabled
}

/// A readout of measured analysis work, ready to render.
///
/// Constructed only from a determinate ``AnalysisProgressState`` whose measurements are
/// usable. A determinate state carrying a zero total or a completed amount above its total
/// yields `nil` rather than a repaired value, matching the domain's own refusal to project
/// a fraction it cannot divide.
public struct WorkProgressReadout: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// What the numbers in this readout mean. Always analysis work progress.
    public static let quantity: WorkProgressQuantity = .analysisWorkProgress

    /// Measured work finished so far, counted in ``workUnit``.
    public let completedWorkAmount: UInt64

    /// Measured work expected in total, counted in ``workUnit``.
    public let totalWorkAmount: UInt64

    /// What the two amounts count. Never "percent", "step", or "stage": those are not
    /// units the application measures.
    public let workUnit: ProgressUnit

    /// The stage whose work these amounts describe.
    public let stage: AnalysisStage

    /// Reads one determinate progress state, or `nil` for anything without a usable
    /// fraction.
    ///
    /// `nil` covers an indeterminate state and a determinate state whose measurements
    /// cannot produce a fraction. A readout is therefore absent exactly when the
    /// measurement is unusable, rather than present and showing zero.
    public init?(_ state: AnalysisProgressState) {
        guard case let .determinate(completed, total, unit, stage) = state else { return nil }
        // The same two conditions the domain applies before projecting a fraction. Checked
        // again rather than trusted, so an unusable determinate state degrades to
        // "continuing" instead of dividing by zero or exceeding one.
        guard total > 0, completed <= total else { return nil }
        self.completedWorkAmount = completed
        self.totalWorkAmount = total
        self.workUnit = unit
        self.stage = stage
    }

    /// Measured analysis work completed, counted out of one hundred: `0...100`.
    ///
    /// This is the percentage Requirement 15.11 governs, and it is derived from nothing but
    /// the two measured amounts. Three properties are deliberate:
    ///
    ///   * **Exact integer arithmetic.** No `Double` is formed at any point, so no rounding
    ///     model, decimal perturbation, or floating-point comparison enters a user-facing
    ///     number.
    ///   * **Truncated toward zero.** 99.9% of the work reads as `99`, so the readout
    ///     cannot reach one hundred before the measured work actually has.
    ///   * **Not a likelihood.** The value is a `UInt8` count out of one hundred whose
    ///     meaning is fixed by ``quantity``. It is not a fraction, not comparable to a
    ///     decision boundary, and not convertible to one by any member of this type.
    public var completedWorkOutOfOneHundred: UInt8 {
        // `completedWorkAmount * 100` can exceed `UInt64.max`, so the multiply is done at
        // full width and the divide consumes both words. A completed amount no greater than
        // the total, and a positive total, are initializer invariants, so the quotient is
        // in `0...100` and the division cannot trap.
        let scaled = completedWorkAmount.multipliedFullWidth(by: 100)
        let (quotient, _) = totalWorkAmount.dividingFullWidth(scaled)
        // The `min` is unreachable under the invariants above. It is here so that a future
        // change to those invariants becomes a wrong number a test can catch rather than a
        // trap in a release build.
        return UInt8(min(quotient, 100))
    }

    /// Whether the measured work has finished.
    ///
    /// Equality of the two measured amounts, not a rounded readout of one hundred. Finished
    /// measured work is still not a terminal outcome: completion, cancellation, and failure
    /// are committed by the session, and a progress value never announces one.
    public var isMeasuredWorkFinished: Bool { completedWorkAmount == totalWorkAmount }
}

/// The progress an active Analysis Session displays.
///
/// Total over every ``AnalysisProgressState``: an active session always has something
/// honest to show, so there is no window where running work displays nothing
/// (Requirement 15.1). The two cases are disjoint, so a surface cannot show a measured
/// readout and an "analysis is continuing" assertion at the same time, or neither.
public enum ProjectedWorkProgress: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Reliable measurements exist, and this is what they say.
    case measured(WorkProgressReadout)

    /// No usable completion fraction exists, so the surface states that work continues
    /// (Requirements 15.3 and 15.4).
    case unmeasured(stage: AnalysisStage, assertion: ContinuingWorkAssertion)

    /// Projects one already-derived progress state.
    ///
    /// The determinate-or-not decision is not made here. It was made by the coordinator's
    /// honest derivation from reported work and arrives settled in `state`; this only
    /// chooses which of the two display shapes carries it.
    public init(_ state: AnalysisProgressState) {
        if let readout = WorkProgressReadout(state) {
            self = .measured(readout)
        } else {
            self = .unmeasured(stage: state.stage, assertion: .analysisIsContinuing)
        }
    }

    /// The stage this progress describes.
    public var stage: AnalysisStage {
        switch self {
        case let .measured(readout): readout.stage
        case let .unmeasured(stage, _): stage
        }
    }

    /// The measured readout, or `nil` when no usable fraction exists.
    public var readout: WorkProgressReadout? {
        guard case let .measured(readout) = self else { return nil }
        return readout
    }

    /// What an unmeasured state asserts, or `nil` when the progress is measured.
    ///
    /// Non-`nil` exactly when there is no fraction to show, which is the case
    /// Requirement 15.4 governs.
    public var continuingAssertion: ContinuingWorkAssertion? {
        guard case let .unmeasured(_, assertion) = self else { return nil }
        return assertion
    }
}

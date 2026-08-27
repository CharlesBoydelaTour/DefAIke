import DefAIkeDomain

// Which of two faults a session reports, decided by causal stage order rather than by
// arrival order.
//
// The design fixes the order stages commit errors in: handoff verification, media and
// static classification, decode and resource validation, preprocessing and resource
// validation, model load, inference, output validation, calibration. Within a stage the
// adapter returns one normalized error, and the coordinator's terminal commit accepts
// only the first *causally* applicable result — so wall-clock race order cannot produce
// different user-visible categories for the same causal failure.
//
// That sentence is the whole reason this file is separate from the coordinator. If the
// ordering lived inside a `catch` in the coordinator's branch join, it would be a
// property of whichever branch happened to return first, which is exactly the
// nondeterminism the design excludes. Here it is a pure, total, synchronous function
// over a fault list, so:
//
//   * the ranking is written out once, in one place, and a test can read it directly
//     rather than inferring it from a scheduling outcome;
//   * arbitration is order-independent by construction — ``earliest(of:)`` returns the
//     same fault for any permutation of the same list, which is the testable form of
//     "wall-clock race order cannot change the category"; and
//   * the coordinator gathers faults and then decides, instead of deciding as they
//     arrive. A branch cannot commit a terminal on its own, so there is no path by
//     which the slower causal failure wins because it was the faster call.
//
// Nothing here decides *whether* a session failed, cancels anything, or invents a
// category. It picks one of the faults it was given, or reports that it was given none.

/// Picks the fault a session reports when more than one arrives.
///
/// A namespace rather than a value: it holds no state, reads no clock, and has nothing to
/// configure. Every member is deterministic in its arguments alone.
public enum CausalFaultArbitration: Sendable {

    /// The stages that can commit an ``AnalysisError``, in the design's causal order.
    ///
    /// The eight the design enumerates come first and in its order. ``AnalysisStage`` is
    /// `CaseIterable` and this list is checked against it below, so a stage added to the
    /// vocabulary without a rank here is a test failure rather than a silent tie.
    ///
    /// The two remaining stages are not in the design's enumerated order, and their
    /// placement is derived rather than chosen:
    ///
    ///   * ``AnalysisStage/provenanceValidation`` runs beside the whole pixel branch
    ///     rather than inside its ordered prerequisite chain, so there is no causal
    ///     relation to read off the design. It is ranked after the pixel stages because
    ///     pixel analysis is the required Version 1 evidence capability and its stages
    ///     *are* the session's ordered chain: a failure there is the report a user needs,
    ///     and preferring it is a fixed rule rather than a scheduling accident. The
    ///     provenance port cannot return an ``AnalysisError`` at all — every validator
    ///     condition maps to one of the five enabled states — so this rank governs only a
    ///     runtime resource breach detected while that lane was resolving.
    ///   * ``AnalysisStage/evidenceJoining`` is last because nothing can be joined before
    ///     both lanes resolve, so every other stage precedes it by construction.
    public static let causalStageOrder: [AnalysisStage] = [
        .handoffVerification,
        .mediaClassification,
        .inputValidation,
        .preprocessing,
        .modelLoad,
        .inference,
        .outputValidation,
        .calibration,
        .provenanceValidation,
        .evidenceJoining,
    ]

    /// Position of `stage` in ``causalStageOrder``: lower is causally earlier.
    ///
    /// Total over the closed vocabulary. The lookup is exhaustive rather than a `default`
    /// that would give an unranked stage a rank by accident.
    public static func causalRank(of stage: AnalysisStage) -> Int {
        switch stage {
        case .handoffVerification: 0
        case .mediaClassification: 1
        case .inputValidation: 2
        case .preprocessing: 3
        case .modelLoad: 4
        case .inference: 5
        case .outputValidation: 6
        case .calibration: 7
        case .provenanceValidation: 8
        case .evidenceJoining: 9
        }
    }

    /// Whether `stage` is causally earlier than `other`.
    public static func stage(_ stage: AnalysisStage, precedes other: AnalysisStage) -> Bool {
        causalRank(of: stage) < causalRank(of: other)
    }

    /// The fault a session reports, given every fault it observed.
    ///
    /// `nil` for an empty list, which is not a failure: a session whose branches all
    /// resolved has nothing to arbitrate and goes on to its completed terminal.
    ///
    /// Two rules, in this order:
    ///
    /// 1. **Cancellation wins.** Requirement 11.17 makes the cancelled terminal distinct
    ///    from every error category, and a user who withdrew the input is not told the
    ///    input failed. A port that reports cancellation observed the user's request, so
    ///    reporting an error alongside it would attribute a failure to work the user
    ///    stopped. Cancellation carries no stage for the same reason: recording one would
    ///    imply the cancelled session failed somewhere.
    /// 2. **Otherwise the causally earliest stage wins**, by ``causalRank(of:)``.
    ///
    /// Ties keep the earlier element, which matters only for two faults at the same
    /// stage — a case the design excludes, since an adapter returns one normalized error
    /// per stage. Keeping the first is still deterministic for a caller that offers a
    /// deterministically ordered list.
    ///
    /// The result is invariant under permutation of `faults` whenever the faults occupy
    /// distinct stages, which is the property that makes the commit independent of which
    /// branch returned first.
    public static func earliest(of faults: [AnalysisFault]) -> AnalysisFault? {
        var earliest: AnalysisFault?
        for fault in faults {
            guard let incumbent = earliest else {
                earliest = fault
                continue
            }
            earliest = earlier(incumbent, than: fault)
        }
        return earliest
    }

    /// The causally earlier of two faults, under the rules in ``earliest(of:)``.
    ///
    /// Returns `lhs` on a tie, so folding a list left keeps the first of equal-ranked
    /// faults.
    public static func earlier(
        _ lhs: AnalysisFault,
        than rhs: AnalysisFault
    ) -> AnalysisFault {
        switch (lhs, rhs) {
        case (.cancelled, _): return lhs
        case (_, .cancelled): return rhs
        case let (.analysis(_, leftStage), .analysis(_, rightStage)):
            return causalRank(of: rightStage) < causalRank(of: leftStage) ? rhs : lhs
        }
    }
}

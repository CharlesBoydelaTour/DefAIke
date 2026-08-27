// The closed fault vocabulary every analysis port throws.
//
// Spec task 1.4 owns every type in `Sources/DefAIkeDomain/Ports/`. Ports live in
// the domain so an adapter depends on the domain rather than on the orchestrator,
// which is what keeps `DefAIkeSharedTransfer` shippable inside the Share Extension
// without reaching inference code.
//
// A session has exactly three terminal outcomes: one Evidence Report, cancellation,
// or one Analysis Error (``SessionTerminalOutcome``). A port that does not return a
// value therefore has exactly two things it can report, and ``AnalysisFault`` is
// exactly those two. Nothing else is representable: there is no "unknown error",
// no wrapped underlying framework error reaching a user-facing surface, and no
// timeout.

/// Why an analysis port did not produce its value.
///
/// Typed `throws(AnalysisFault)` on every analysis port makes the closed
/// `AnalysisError` vocabulary a compile-time guarantee rather than a convention: an
/// adapter cannot leak a framework error, a `CancellationError`, or an invented
/// category out of a port.
///
/// Each fault carries the ``AnalysisStage`` it was detected in, because an
/// ``AnalysisFailureSnapshot`` records the stage and the coordinator must not have
/// to guess it. Arbitrating two concurrent faults against the design's causal stage
/// order is the coordinator's responsibility (task 10.x); this type only reports.
public enum AnalysisFault: Error, Hashable, Sendable {
    /// The user cancelled. No evidence, no error, no partial result
    /// (Requirements 11.14 and 15.7).
    case cancelled

    /// Exactly one Analysis Error, and where it was detected.
    case analysis(AnalysisError, stage: AnalysisStage)

    /// The single error category, or `nil` for cancellation.
    ///
    /// Cancellation is not an Analysis Error: it is a separate terminal outcome and
    /// must never be presented as a failure category (Requirement 11.17).
    public var analysisError: AnalysisError? {
        guard case .analysis(let error, _) = self else { return nil }
        return error
    }

    /// The stage the fault was detected in, or `nil` for cancellation.
    ///
    /// Cancellation can arrive at any stage, and recording one would imply the
    /// cancelled session failed somewhere.
    public var stage: AnalysisStage? {
        guard case .analysis(_, let stage) = self else { return nil }
        return stage
    }

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

extension SessionEndReason {
    /// The Data Lifecycle Policy deadline this end reason selects.
    ///
    /// The two vocabularies are deliberately separate: ``SessionEndReason`` is a
    /// domain session fact, and ``SessionCleanupReason`` is the encoded key a signed
    /// policy is written against. The mapping is total and one-to-one in this single
    /// place, so a policy deadline can never be selected by a spelling coincidence.
    public var cleanupReason: SessionCleanupReason {
        switch self {
        case .completed: .completed
        case .cancelled: .cancelled
        case .error: .errorTerminated
        case .interrupted: .interrupted
        case .abandoned: .abandoned
        }
    }
}

extension SessionCleanupReason {
    /// The session end reason this policy key describes. Inverse of
    /// ``SessionEndReason/cleanupReason``.
    public var endReason: SessionEndReason {
        switch self {
        case .completed: .completed
        case .cancelled: .cancelled
        case .errorTerminated: .error
        case .interrupted: .interrupted
        case .abandoned: .abandoned
        }
    }
}

import DefAIkeDomain

// The values the Resource Controller enforces with.
//
// Every reason a measurement did not pass is in one closed enumeration, and every one
// of them raises the same `resource-limit` Analysis Error. That is deliberate: a
// missing limit, a limit in the wrong unit, and a measurement that cannot be compared
// to any limit are all "this work cannot be shown to fit the approved budget", which
// is the same fail-closed conclusion as exceeding it (Requirements 3.4, 11.6, 11.8).
// None of them is a decoding problem, none may become a downgraded warning, and none
// may pass silently.
//
// The cause is kept separate from the error so an audit can name which fail-closed
// path fired without the user-facing vocabulary growing a category the requirements
// do not define.

/// Why measured or requested work did not fit the bound Resource Budget.
public struct ResourceBreach: Hashable, Sendable {
    /// The fail-closed condition that fired.
    public enum Cause: Hashable, Sendable {
        /// The metric was measured and continuing would exceed its hard limit.
        case wouldExceedHardLimit

        /// The governor refused to grant headroom for the requested amount.
        case reservationRefused

        /// The bound budget defines no limit for this metric, so no comparison
        /// exists. Never treated as "unlimited".
        case limitNotDefined

        /// The bound budget's limit for this metric is numeric but in a different
        /// unit than the request, so the two cannot be compared.
        case limitUnitMismatch(requested: ResourceLimitUnit, defined: ResourceLimitUnit)

        /// The metric is categorical: it can be observed but not reserved, so a
        /// reservation against it is not a check that can be performed.
        case notReservable

        /// The metric cannot be measured in this environment, so it cannot be
        /// compared to its limit. Not a pass.
        case measurementUnavailable

        /// The governor returned headroom bound to a different target or budget
        /// than the one that was asked for. A substitution, not a breach of a
        /// number, and rejected for the same reason (Requirement 11.1).
        case substitutedBudget
    }

    /// The metric whose check did not pass.
    public let metric: ResourceMetric

    public let cause: Cause

    /// The stage that was running, so a failure snapshot records where the
    /// controller stopped rather than having to guess.
    public let stage: AnalysisStage

    /// The target whose budget was being enforced.
    public let target: ExecutionTarget

    public init(
        metric: ResourceMetric,
        cause: Cause,
        stage: AnalysisStage,
        target: ExecutionTarget
    ) {
        self.metric = metric
        self.cause = cause
        self.stage = stage
        self.target = target
    }

    /// The fault this breach raises.
    ///
    /// Always exactly one `resource-limit` at the stage the breach was detected in.
    /// The controller has no other Analysis Error to emit, so no cause can widen the
    /// closed vocabulary.
    public var fault: AnalysisFault { .analysis(.resourceLimit, stage: stage) }
}

/// A commit a resource breach must prevent.
///
/// The two cases are not interchangeable and are not both available to a controller:
/// only the main application can commit an Evidence Report, and only the Share
/// Extension can publish a ready transfer ticket. Asking a controller whether it
/// permits the other target's commit always answers `false`, so an extension
/// controller can never authorize evidence and a main-application controller can
/// never authorize a ready ticket (Requirements 11.6, 11.8, and 11.11).
public enum ResourceGatedCommit: Hashable, Sendable, CaseIterable {
    /// One Evidence Report for the session.
    case evidenceReport

    /// Atomic publication of one ready Share transfer ticket, which is the sole
    /// Share-route session-creation commit.
    case readyTransferTicket

    /// The only target that may perform this commit.
    public var governingTarget: ExecutionTarget {
        switch self {
        case .evidenceReport: .mainApplication
        case .readyTransferTicket: .shareExtension
        }
    }
}

/// Names one branch of concurrent work the controller may cancel on a breach.
///
/// Opaque and process-local: it carries no image-derived value, no path, and no
/// session-correlatable value, and its description omits the raw discriminator so it
/// cannot become a correlatable log identifier (Requirement 9.11).
public struct SiblingWorkToken: Hashable, Sendable, CustomStringConvertible {
    let number: UInt64

    public var description: String { "SiblingWorkToken(opaque)" }
}

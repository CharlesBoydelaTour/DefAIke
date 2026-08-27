import Foundation

// The resource port.
//
// The Resource Controller reads the signed budget for its own target, reserves work
// before a large allocation, samples the approved metrics, and stops before a hard limit
// where that is measurable. Two things are deliberately absent from this port:
//
//   * a timeout, deadline, or maximum-duration member, because Requirement 15.5 forbids
//     an unmeasured requirement-level time limit and the design "does not invent a time
//     limit" (Property 36); and
//   * any way to raise, waive, or override a limit, because the numbers come from an
//     approved Resource Budget and nothing at runtime may edit them.

/// A request to reserve headroom before an allocation.
///
/// The unit is explicit because a limit without a unit cannot be compared to a
/// measurement, and because Requirement 15.2 only permits determinate progress when
/// completed and total describe the same measured unit.
public struct ResourceReservationRequest: Hashable, Sendable {
    public let metric: ResourceMetric
    public let amount: PositiveDecimal
    public let unit: ResourceLimitUnit

    /// The stage the reservation is for, so a breach reports the right stage.
    public let stage: AnalysisStage

    /// Creates a request, or `nil` for a categorical metric.
    ///
    /// Thermal state is a condition, not a quantity: it can be observed but not
    /// reserved, so asking to reserve it is not representable.
    public init?(
        metric: ResourceMetric,
        amount: PositiveDecimal,
        unit: ResourceLimitUnit,
        stage: AnalysisStage
    ) {
        guard !metric.isCategorical else { return nil }
        self.metric = metric
        self.amount = amount
        self.unit = unit
        self.stage = stage
    }
}

/// Headroom granted for one allocation.
///
/// Held for the duration of the work and returned through
/// ``ResourceGoverning/release(_:)``. It records which budget granted it, so a
/// reservation taken against the extension budget cannot be released against the main
/// application's.
public struct ResourceReservation: Hashable, Sendable {
    public let token: ResourceReservationToken
    public let request: ResourceReservationRequest
    public let budgetID: ArtifactID
    public let target: ExecutionTarget

    public init(
        token: ResourceReservationToken,
        request: ResourceReservationRequest,
        budgetID: ArtifactID,
        target: ExecutionTarget
    ) {
        self.token = token
        self.request = request
        self.budgetID = budgetID
        self.target = target
    }
}

/// What a sample of one metric found relative to its hard limit.
///
/// ``notMeasurable`` exists because the design only claims to stop before a hard limit
/// "where measurable". An unmeasurable metric is reported honestly rather than being
/// treated as within limit, and the caller decides what an unmeasurable mandatory metric
/// means for its stage.
public enum ResourceObservation: Hashable, Sendable {
    /// Measured and inside the hard limit.
    case withinHardLimit(ResourceMetric)
    /// Measured and continuing would exceed the hard limit.
    case wouldBreachHardLimit(ResourceMetric)
    /// This metric cannot be measured in this environment.
    case notMeasurable(ResourceMetric)

    public var metric: ResourceMetric {
        switch self {
        case .withinHardLimit(let metric),
             .wouldBreachHardLimit(let metric),
             .notMeasurable(let metric):
            metric
        }
    }

    /// Whether continuing would breach the hard limit.
    ///
    /// An unmeasurable metric is not a breach and not a pass: it answers `false` here
    /// and must be handled explicitly through ``isMeasured``.
    public var breachesHardLimit: Bool {
        if case .wouldBreachHardLimit = self { return true }
        return false
    }

    public var isMeasured: Bool {
        if case .notMeasurable = self { return false }
        return true
    }
}

/// Keeps measured resource use inside one target's signed budget.
///
/// A hard-limit breach is `.analysis(.resourceLimit, stage:)` with no evidence: the
/// affected work stops, sibling work is cancelled, and cleanup starts. In the extension
/// the same breach additionally means no session and no inference ever began
/// (Requirements 11.5 through 11.8 and Property 29).
public protocol ResourceGoverning: Sendable {
    /// The target this controller governs. A controller never reads the other target's
    /// budget (Requirement 11.1).
    var target: ExecutionTarget { get }

    /// Reserves headroom, or fails with `resource-limit` at the request's stage.
    ///
    /// Called before a large allocation rather than after, which is what lets validation
    /// reject an oversized decode before it is attempted (Requirement 3.3).
    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ResourceReservation

    /// Returns previously granted headroom. Idempotent and non-failing: releasing an
    /// already-released reservation is not an error, so cleanup paths can be
    /// unconditional.
    func release(_ reservation: ResourceReservation) async

    /// Samples one metric against its hard limit.
    ///
    /// Non-throwing: observing is not the same as breaching. A caller that finds
    /// ``ResourceObservation/wouldBreachHardLimit(_:)`` decides at which stage to commit
    /// the `resource-limit` outcome.
    func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) async -> ResourceObservation
}

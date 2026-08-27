import DefAIkeDomain
import Foundation

/// A deterministic ``ResourceGoverning`` with programmable measurements.
///
/// Nothing is measured for real: a test declares what each metric currently reads, and the
/// governor compares that against the *signed budget it was handed*. Comparing against the
/// artifact rather than against a constant is the point — a governor that carried its own
/// numbers would be the source-code default the requirements forbid.
///
/// The governor holds no timeout and no way to raise a limit, matching the port. It refuses
/// a budget for the other target, so a reservation taken against the extension budget can
/// never be checked against the main application's (Requirement 11.1).
public actor FakeResourceGovernor: ResourceGoverning {
    public let target: ExecutionTarget

    private let recorder: PortCallRecorder?
    private var readings: [ResourceMetric: Decimal] = [:]
    private var thermalReading: ThermalState?
    private var unmeasurable: Set<ResourceMetric> = []
    private var outstanding: [ResourceReservationToken: ResourceReservation] = [:]
    private var nextReservationNumber: UInt64 = 1

    public init(target: ExecutionTarget, recorder: PortCallRecorder? = nil) {
        self.target = target
        self.recorder = recorder
    }

    // MARK: - Programming

    /// Declares the current reading for a numeric metric.
    public func setReading(_ value: Decimal, for metric: ResourceMetric) {
        readings[metric] = value
    }

    /// Declares the current thermal state.
    public func setThermalState(_ state: ThermalState) {
        thermalReading = state
    }

    /// Declares that a metric cannot be measured in this environment.
    ///
    /// Reported honestly as ``ResourceObservation/notMeasurable(_:)`` rather than as
    /// "within limit", because the design only claims to stop before a hard limit where
    /// measurement is possible.
    public func setNotMeasurable(_ metric: ResourceMetric) {
        unmeasurable.insert(metric)
    }

    // MARK: - Inspection

    /// Reservations granted and not yet released.
    ///
    /// A cleanup path that forgot to release leaves this nonempty, which is how a leak
    /// shows up as a failed assertion rather than as a slow test.
    public func outstandingReservations() -> [ResourceReservation] {
        Array(outstanding.values)
    }

    // MARK: - ResourceGoverning

    public func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) throws(AnalysisFault) -> ResourceReservation {
        recorder?.record(.reserveResource(request.metric))
        guard budget.target == target else {
            // Reading the other target's budget is a wiring fault, not a resource breach.
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard case .numeric(let limit, let unit) = budget.limit(for: request.metric) else {
            // The metric is not in this target's required set, or is categorical.
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard unit == request.unit else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        let alreadyReserved = outstanding.values
            .filter { $0.request.metric == request.metric }
            .reduce(Decimal(0)) { $0 + $1.request.amount.value }
        let currentReading = readings[request.metric] ?? 0
        guard currentReading + alreadyReserved + request.amount.value <= limit.value else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        let reservation = ResourceReservation(
            token: ResourceReservationToken(rawValue: nextReservationNumber),
            request: request,
            budgetID: budget.id,
            target: target
        )
        nextReservationNumber += 1
        outstanding[reservation.token] = reservation
        return reservation
    }

    public func release(_ reservation: ResourceReservation) {
        recorder?.record(.releaseResource(reservation.request.metric))
        // Idempotent: releasing twice is not an error, so cleanup can be unconditional.
        outstanding.removeValue(forKey: reservation.token)
    }

    public func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) -> ResourceObservation {
        recorder?.record(.observeResource(metric))
        guard budget.target == target, !unmeasurable.contains(metric) else {
            return .notMeasurable(metric)
        }
        switch budget.limit(for: metric) {
        case .numeric(let limit, _):
            let reading = readings[metric] ?? 0
            return reading > limit.value
                ? .wouldBreachHardLimit(metric)
                : .withinHardLimit(metric)
        case .thermal(let maximumState):
            guard let reading = thermalReading else { return .notMeasurable(metric) }
            return reading > maximumState
                ? .wouldBreachHardLimit(metric)
                : .withinHardLimit(metric)
        case nil:
            // The metric is not part of this target's budget at all.
            return .notMeasurable(metric)
        }
    }
}

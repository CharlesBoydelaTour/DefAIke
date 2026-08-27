import DefAIkeDomain
import Foundation

// Arguments the Resource Controller needs in order to be called at all.
//
// **No number, unit pairing, or limit in this file is an approved release value.** Every
// resource limit is an unresolved external decision measured by the Device Validation
// Plan (design decision D6). These fixtures exist so a controller that takes a signed
// budget can be exercised, and no test asserts that a value here is correct. Nothing
// here may be copied into a shipping artifact.
//
// The governor double below compares programmed readings against *the budget it is
// handed* rather than against constants of its own. That is what makes the tests bite:
// if the controller passed the wrong target's budget, or invented a number, the
// comparison would move and the assertions would fail.

// MARK: - Identifiers

enum Fixture {
    static func artifactID(_ raw: String) -> ArtifactID {
        guard let id = ArtifactID(raw) else {
            preconditionFailure("fixture artifact identifier is not canonical: \(raw)")
        }
        return id
    }

    /// A deterministic 32-byte digest derived from a seed, with no cryptographic claim.
    static func digest(_ seed: String) -> DefAIkeDomain.SHA256Digest {
        var bytes = [UInt8](repeating: 0, count: DefAIkeDomain.SHA256Digest.byteCount)
        for (index, byte) in Array(seed.utf8).enumerated() {
            bytes[index % bytes.count] ^= byte &+ UInt8(truncatingIfNeeded: index)
        }
        guard let digest = DefAIkeDomain.SHA256Digest(bytes: bytes) else {
            preconditionFailure("fixture digest is the wrong length")
        }
        return digest
    }

    static func evidence(_ artifact: String) -> EvidenceSource {
        do {
            return EvidenceSource(
                artifact: artifactID(artifact),
                version: try SchemaSemanticVersion(validating: "0.1.0"),
                contentDigest: digest(artifact)
            )
        } catch {
            preconditionFailure("fixture evidence source must be schema-valid: \(error)")
        }
    }

    static func positive(_ value: Decimal) -> PositiveDecimal {
        do {
            return try PositiveDecimal(validating: value)
        } catch {
            preconditionFailure("\(value) is not a positive decimal: \(error)")
        }
    }
}

// MARK: - Resource budgets

enum ResourceFixture {
    /// The synthetic limit every numeric metric gets unless a test overrides it.
    static let defaultLimitValue: Decimal = 1000

    /// A schema-valid budget for one target.
    ///
    /// `overrides` replaces individual limits so a test can drive one metric to a breach,
    /// or give a metric a limit in a unit a request will not match, without disturbing
    /// the others.
    static func budget(
        for target: ExecutionTarget,
        id: String? = nil,
        defaultValue: Decimal = defaultLimitValue,
        overrides: [ResourceMetric: ValidatedLimit] = [:]
    ) -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: Fixture.artifactID(id ?? "budget-\(target.rawValue)"),
                schemaVersion: .v1,
                target: target,
                hardLimits: try ResourceMetric.requiredMetrics(for: target)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        try ResourceLimitEntry(
                            metric: metric,
                            limit: overrides[metric] ?? defaultLimit(metric, value: defaultValue),
                            measurementConditions: Fixture.evidence(
                                "measurement-\(metric.rawValue)"
                            )
                        )
                    },
                validationPlan: Fixture.artifactID("validation-plan-0001")
            )
        } catch {
            preconditionFailure("the resource budget fixture must be schema-valid: \(error)")
        }
    }

    /// Both target budgets, which is the only form the controller accepts.
    static func budgetSet(
        mainApplicationOverrides: [ResourceMetric: ValidatedLimit] = [:],
        shareExtensionOverrides: [ResourceMetric: ValidatedLimit] = [:]
    ) -> ResourceBudgetSet {
        do {
            return try ResourceBudgetSet(
                mainApplication: budget(
                    for: .mainApplication,
                    overrides: mainApplicationOverrides
                ),
                shareExtension: budget(
                    for: .shareExtension,
                    overrides: shareExtensionOverrides
                )
            )
        } catch {
            preconditionFailure("the budget set fixture must be schema-valid: \(error)")
        }
    }

    static func numeric(_ value: Decimal, _ unit: ResourceLimitUnit) -> ValidatedLimit {
        .numeric(value: Fixture.positive(value), unit: unit)
    }

    private static func defaultLimit(
        _ metric: ResourceMetric,
        value: Decimal
    ) -> ValidatedLimit {
        metric.isCategorical
            ? .thermal(maximumState: .fair)
            : numeric(value, unit(for: metric))
    }

    /// A unit that matches each metric's dimension. Only the pairing is meaningful in a
    /// fixture; the number is a measured release decision.
    static func unit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .milliseconds
        }
    }
}

// MARK: - Synchronous recorder

/// A minimal mutable box with mutual exclusion.
///
/// Sibling cancellation hooks are synchronous `@Sendable` closures, so they cannot await
/// an actor. `NSLock` is enough: every critical section is one append with no
/// reentrancy and no suspension point inside it.
final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] { lock.withLock { storage } }

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }
}

// MARK: - Resource governor double

/// A deterministic ``ResourceGoverning`` with programmable readings and outcomes.
///
/// Nothing is measured for real. A test declares what each metric currently reads and
/// the governor compares that against the budget it was handed, so the number in force
/// is always the artifact's.
///
/// It records the budget identifier of every call, which is how a test proves the
/// controller never hands over the other target's budget.
actor RecordingResourceGovernor: ResourceGoverning {
    enum Call: Hashable, Sendable {
        case reserve(ResourceMetric, ArtifactID)
        case release(ResourceMetric, ArtifactID)
        case observe(ResourceMetric, ArtifactID)
    }

    /// How the governor answers the next reservation.
    enum ReserveOutcome: Sendable {
        /// Compare the reading plus outstanding headroom against the budget's limit.
        case measured
        /// Refuse with `resource-limit`, as an over-budget adapter would.
        case refuse
        /// Report cancellation, which is not an Analysis Error.
        case cancelled
        /// Grant headroom stamped with a different budget identifier.
        case substituteBudgetID(ArtifactID)
        /// Grant headroom stamped with the other target.
        case substituteTarget(ExecutionTarget)
        /// Grant headroom for a different amount than was requested.
        case substituteAmount(Decimal)
    }

    let target: ExecutionTarget

    private var recorded: [Call] = []
    private var numericReadings: [ResourceMetric: Decimal] = [:]
    private var thermalReading: ThermalState?
    private var unmeasurable: Set<ResourceMetric> = []
    private var reserveOutcome: ReserveOutcome = .measured
    private var granted: [ResourceReservationToken: ResourceReservation] = [:]
    private var nextToken: UInt64 = 1
    private var gatedCall: GatedCall?
    private var gateIsOpen = false
    private var gateWasEntered = false

    init(target: ExecutionTarget) {
        self.target = target
        self.thermalReading = .nominal
    }

    // MARK: Programming

    func setReading(_ value: Decimal, for metric: ResourceMetric) {
        numericReadings[metric] = value
    }

    func setThermalState(_ state: ThermalState) {
        thermalReading = state
    }

    func setNotMeasurable(_ metric: ResourceMetric) {
        unmeasurable.insert(metric)
    }

    func setReserveOutcome(_ outcome: ReserveOutcome) {
        reserveOutcome = outcome
    }

    /// Which port call the gate applies to.
    enum GatedCall: Hashable, Sendable {
        case observe(ResourceMetric)
        case reserve(ResourceMetric)
    }

    /// Makes one port call for `metric` suspend until ``openGate()``.
    ///
    /// This is how a test creates the actor-reentrancy window: the controller is
    /// suspended inside the port, so another branch can reach the same controller while
    /// this call is outstanding.
    func gate(_ call: GatedCall) {
        gatedCall = call
        gateIsOpen = false
        gateWasEntered = false
    }

    func gateWasReached() -> Bool { gateWasEntered }

    func openGate() {
        gateIsOpen = true
    }

    // MARK: Inspection

    func calls() -> [Call] { recorded }

    func heldReservations() -> [ResourceReservation] { Array(granted.values) }

    // MARK: Gate

    /// Suspends inside the port when `call` is the gated one.
    ///
    /// Each yield releases this actor, so the test can open the gate and reach the
    /// controller while this call is outstanding. Bounded so a wiring mistake fails the
    /// assertions instead of hanging the suite.
    private func waitAtGate(_ call: GatedCall) async {
        guard gatedCall == call else { return }
        gateWasEntered = true
        var spins = 0
        while !gateIsOpen, spins < 100_000 {
            spins += 1
            await Task.yield()
        }
    }

    // MARK: ResourceGoverning

    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ResourceReservation {
        recorded.append(.reserve(request.metric, budget.id))
        await waitAtGate(.reserve(request.metric))
        switch reserveOutcome {
        case .refuse:
            throw .analysis(.resourceLimit, stage: request.stage)
        case .cancelled:
            throw .cancelled
        case .measured, .substituteBudgetID, .substituteTarget, .substituteAmount:
            break
        }
        guard budget.target == target else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard case .numeric(let limit, let unit) = budget.limit(for: request.metric),
              unit == request.unit
        else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        let alreadyHeld = granted.values
            .filter { $0.request.metric == request.metric }
            .reduce(Decimal(0)) { $0 + $1.request.amount.value }
        let reading = numericReadings[request.metric] ?? 0
        guard reading + alreadyHeld + request.amount.value <= limit.value else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }

        var grantedRequest = request
        var grantedBudgetID = budget.id
        var grantedTarget = target
        switch reserveOutcome {
        case .substituteBudgetID(let id):
            grantedBudgetID = id
        case .substituteTarget(let other):
            grantedTarget = other
        case .substituteAmount(let amount):
            guard let mutated = ResourceReservationRequest(
                metric: request.metric,
                amount: Fixture.positive(amount),
                unit: request.unit,
                stage: request.stage
            ) else {
                preconditionFailure("a numeric metric must accept a reservation request")
            }
            grantedRequest = mutated
        case .measured, .refuse, .cancelled:
            break
        }

        let reservation = ResourceReservation(
            token: ResourceReservationToken(rawValue: nextToken),
            request: grantedRequest,
            budgetID: grantedBudgetID,
            target: grantedTarget
        )
        nextToken += 1
        granted[reservation.token] = reservation
        return reservation
    }

    func release(_ reservation: ResourceReservation) {
        recorded.append(.release(reservation.request.metric, reservation.budgetID))
        granted.removeValue(forKey: reservation.token)
    }

    func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) async -> ResourceObservation {
        recorded.append(.observe(metric, budget.id))
        await waitAtGate(.observe(metric))
        guard budget.target == target, !unmeasurable.contains(metric) else {
            return .notMeasurable(metric)
        }
        switch budget.limit(for: metric) {
        case .numeric(let limit, _):
            let reading = numericReadings[metric] ?? 0
            return reading > limit.value
                ? .wouldBreachHardLimit(metric)
                : .withinHardLimit(metric)
        case .thermal(let maximumState):
            guard let thermalReading else { return .notMeasurable(metric) }
            return thermalReading > maximumState
                ? .wouldBreachHardLimit(metric)
                : .withinHardLimit(metric)
        case nil:
            return .notMeasurable(metric)
        }
    }
}

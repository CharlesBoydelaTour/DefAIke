import DefAIkeDomain

// The Resource Controller.
//
// One controller governs exactly one ``ExecutionTarget``. It is constructed from the
// signed ``ResourceBudgetSet`` and selects its own target's budget, so the
// main-application budget and the Share Extension budget cannot be substituted for one
// another by a caller passing the wrong one: the caller does not choose a budget at all
// (Requirement 11.1). A governor for the other target is rejected at construction, so a
// mismatched pair is unrepresentable rather than a runtime check that could be skipped.
//
// Every number comes from the injected budget. There is no default, no fallback, and no
// clamp, and there is no way to raise or waive a limit. A metric the bound budget does
// not define is a check that cannot be performed, and a check that cannot be performed
// fails closed with `resource-limit` rather than passing silently — the same posture as
// the image pipeline's validation checks.
//
// Deliberately absent, and the absence is the requirement:
//
//   * No clock, deadline, `Duration`, or elapsed-time member of any kind. The controller
//     cannot derive a timeout because it has nothing to derive one from: while every
//     checked metric reads inside its limit, work continues indefinitely (Requirement
//     15.10 and Property 36). The millisecond metrics in a budget are measurements the
//     Device Validation Suite takes and the governor reports; the controller never times
//     anything itself.
//   * No "check everything" convenience. The caller names the metrics that bound the
//     work it is about to do, because which metrics gate a stage at runtime is a bound
//     plan decision, not one this file may make.
//   * No cancellation decision. Cancellation is a separate terminal outcome owned by the
//     coordinator; the only Analysis Error this type can produce is `resource-limit`. The
//     controller *honors* a cancellation it is handed — the reservation path passes a
//     cancelled port fault through unchanged, and the sampling loop stops at a metric
//     boundary — but it never originates one and never latches a breach for one.

/// Keeps one target's measured resource use inside its signed budget.
///
/// An actor because the pixel and provenance branches may run concurrently under an
/// approved execution policy, and the breach latch, the sibling registry, and the
/// outstanding reservations are shared mutable state those branches both touch.
///
/// The first breach latches. Every later call reports that same first breach, so a
/// subsequent within-limit reading cannot revive a session the controller already
/// stopped, and the fault's stage stays the causally first one rather than wherever the
/// next call happened to be.
public actor ResourceController {
    /// The target this controller governs.
    public let target: ExecutionTarget

    /// The bound budget for ``target``, selected from the signed set.
    public let budget: ResourceBudget

    private let governor: any ResourceGoverning

    /// The first breach, once one has fired. Monotonic: never cleared.
    private var latchedBreach: ResourceBreach?

    /// Headroom this controller granted and has not released, in grant order.
    private var outstanding: [ResourceReservation] = []

    /// Registered concurrent work, in registration order so cancellation is
    /// deterministic rather than dictionary-ordered.
    private var siblings: [(token: SiblingWorkToken, cancel: @Sendable () -> Void)] = []

    private var nextSiblingNumber: UInt64 = 1

    /// Binds a controller to one target's budget, or fails when the governor governs a
    /// different target.
    ///
    /// `nil` rather than a fallback: a controller that would read one target's budget
    /// through the other target's governor has no correct behavior available to it, and
    /// silently preferring either side is the substitution Requirement 11.1 forbids.
    public init?(
        target: ExecutionTarget,
        budgets: ResourceBudgetSet,
        governor: any ResourceGoverning
    ) {
        guard governor.target == target else { return nil }
        self.target = target
        // `ResourceBudgetSet` already guarantees each side carries its own target, so
        // this selection cannot return the other target's artifact.
        self.budget = budgets.budget(for: target)
        self.governor = governor
    }

    // MARK: - Enforcement state

    /// The first breach, or `nil` while every performed check has passed.
    public func currentBreach() -> ResourceBreach? { latchedBreach }

    /// Whether `commit` is still permitted.
    ///
    /// False after any breach, and false for the commit this target does not own even
    /// before one. A breach therefore leaves the main application unable to commit
    /// evidence and the extension unable to publish a ready ticket, which is the
    /// "no evidence or ready ticket as applicable" half of Requirements 11.6 and 11.8.
    public func permits(_ commit: ResourceGatedCommit) -> Bool {
        latchedBreach == nil && commit.governingTarget == target
    }

    /// Headroom granted and not yet released.
    ///
    /// Empty after a breach, because stopping the affected work returns its headroom.
    /// A path that forgot to release leaves this nonempty.
    public func outstandingReservations() -> [ResourceReservation] { outstanding }

    // MARK: - Reserving

    /// Reserves headroom before an allocation, or fails closed with `resource-limit`.
    ///
    /// Called before the allocation rather than after, which is what lets an oversized
    /// decode be rejected before it is attempted (Requirement 3.4).
    ///
    /// The bound budget is consulted here as well as inside the governor. That is not
    /// redundancy for its own sake: an adapter is injected, and a governor that answered
    /// "within limit" for a metric the bound budget never defined would otherwise decide
    /// policy. The controller establishes that a comparison exists before it trusts one.
    public func reserve(
        _ metric: ResourceMetric,
        amount: PositiveDecimal,
        unit: ResourceLimitUnit,
        at stage: AnalysisStage
    ) async throws(AnalysisFault) -> ResourceReservation {
        if let latchedBreach { throw latchedBreach.fault }

        guard let limit = budget.limit(for: metric) else {
            throw await latch(.limitNotDefined, metric: metric, at: stage)
        }
        guard case .numeric(_, let definedUnit) = limit else {
            // A thermal state is a condition, not a quantity: observable, not
            // reservable. Comparing an amount to it is not a check that can be made.
            throw await latch(.notReservable, metric: metric, at: stage)
        }
        guard definedUnit == unit else {
            // A limit measured in bytes cannot bound a request stated in milliseconds.
            // Fail closed rather than compare magnitudes across units.
            throw await latch(
                .limitUnitMismatch(requested: unit, defined: definedUnit),
                metric: metric,
                at: stage
            )
        }
        guard let request = ResourceReservationRequest(
            metric: metric,
            amount: amount,
            unit: unit,
            stage: stage
        ) else {
            // Unreachable while the numeric guard above holds, because a numeric limit
            // implies a noncategorical metric. Kept as a fail-closed branch rather than
            // a force-unwrap.
            throw await latch(.notReservable, metric: metric, at: stage)
        }

        let reservation: ResourceReservation
        do {
            reservation = try await governor.reserve(request, budget: budget)
        } catch {
            // Cancellation is not an Analysis Error and must never be presented as one,
            // so it passes through unchanged and does not latch a breach. Every other
            // fault from the port means the requested headroom was not granted, which is
            // `resource-limit` at this stage whatever category the adapter named.
            if error.isCancelled { throw error }
            throw await latch(.reservationRefused, metric: metric, at: stage)
        }

        guard reservation.target == target,
              reservation.budgetID == budget.id,
              reservation.request == request
        else {
            // Headroom minted against a different target, a different budget, or a
            // different request is not the reservation that was asked for. Hand it back
            // so it does not leak, then fail closed.
            await governor.release(reservation)
            throw await latch(.substitutedBudget, metric: metric, at: stage)
        }

        // The actor suspended while the governor answered, so a concurrent branch may
        // have latched a breach in the meantime and already returned every reservation
        // it knew about. Keeping this one would hand out headroom the budget has since
        // refused, so it goes back and the first breach is what this call reports.
        if let latchedBreach {
            await governor.release(reservation)
            throw latchedBreach.fault
        }

        outstanding.append(reservation)
        return reservation
    }

    /// Returns granted headroom. Idempotent and non-failing, so cleanup paths can be
    /// unconditional.
    ///
    /// A reservation from another target or another budget is not this controller's to
    /// return and is ignored rather than forwarded.
    public func release(_ reservation: ResourceReservation) async {
        guard reservation.target == target, reservation.budgetID == budget.id else { return }
        outstanding.removeAll { $0.token == reservation.token }
        await governor.release(reservation)
    }

    // MARK: - Measuring

    /// Samples the named metrics in order and stops before a measurable hard-limit
    /// breach.
    ///
    /// Returns normally only when every named metric has a limit in the bound budget and
    /// reads inside it. That is what permits work to continue: no elapsed time is
    /// consulted, so a session whose measurements stay in budget is never stopped here
    /// (Requirement 15.10).
    ///
    /// At least one metric is required by the signature rather than by a runtime check.
    /// A checkpoint that named nothing would return "in budget" without performing a
    /// single comparison, which is the silent pass this whole file exists to prevent; the
    /// split first/rest parameters make that call unrepresentable.
    ///
    /// The metrics are checked in the given order and the first failing one is reported,
    /// so which breach a caller sees is determined by its own argument order rather than
    /// by sampling races. A caller holding a computed list can loop over it and get the
    /// same result, because the latch below keeps the first breach's metric and stage.
    /// Cancellation is checked at every metric boundary of the loop, for the same reason a
    /// streaming copy checks it at every chunk: a cancelled session must stop sampling
    /// within one metric rather than after the whole list. It is not a breach and latches
    /// nothing — cancellation is a separate terminal outcome with no Analysis Error
    /// category, and a later within-limit reading must not be able to revive a session,
    /// which only a latched *breach* could wrongly do (Requirements 11.14 and 15.7).
    public func checkpoint(
        _ first: ResourceMetric,
        _ rest: ResourceMetric...,
        at stage: AnalysisStage
    ) async throws(AnalysisFault) {
        if let latchedBreach { throw latchedBreach.fault }

        for metric in [first] + rest {
            if Task.isCancelled { throw AnalysisFault.cancelled }
            guard budget.limit(for: metric) != nil else {
                throw await latch(.limitNotDefined, metric: metric, at: stage)
            }
            let observation = await governor.observe(metric, budget: budget)
            // Sampling suspended the actor, so a concurrent branch may have latched a
            // breach while this metric was being read. Reporting "in budget" now would
            // let the session step over a breach it has already committed to.
            if let latchedBreach { throw latchedBreach.fault }
            switch observation {
            case .withinHardLimit:
                continue
            case .wouldBreachHardLimit:
                throw await latch(.wouldExceedHardLimit, metric: metric, at: stage)
            case .notMeasurable:
                // Reported honestly by the port and treated as a failure here: a metric
                // that cannot be measured cannot be shown to fit its limit, and calling
                // that a pass would make the limit advisory.
                throw await latch(.measurementUnavailable, metric: metric, at: stage)
            }
        }
    }

    // MARK: - Sibling work

    /// Registers concurrent work to cancel if a breach fires.
    ///
    /// Registering after a breach cancels immediately and stores nothing, so a branch
    /// that starts in the window after the latch cannot run on unbudgeted resources.
    public func registerSiblingWork(
        _ cancel: @escaping @Sendable () -> Void
    ) -> SiblingWorkToken {
        let token = SiblingWorkToken(number: nextSiblingNumber)
        nextSiblingNumber += 1
        guard latchedBreach == nil else {
            cancel()
            return token
        }
        siblings.append((token: token, cancel: cancel))
        return token
    }

    /// Withdraws work that finished on its own, so a completed branch is not cancelled
    /// later. Idempotent.
    public func withdrawSiblingWork(_ token: SiblingWorkToken) {
        siblings.removeAll { $0.token == token }
    }

    // MARK: - The breach path

    /// Latches the first breach, stops the affected work, and returns its fault.
    ///
    /// The three effects are one step on purpose. A breach that cancelled siblings but
    /// did not latch could be overtaken by a later within-limit reading; a breach that
    /// latched but did not cancel would leave concurrent work running on resources the
    /// budget has already refused. Committing the terminal outcome and deleting session
    /// material are the coordinator's and the Privacy Controller's work; this returns
    /// the single fault they act on.
    private func latch(
        _ cause: ResourceBreach.Cause,
        metric: ResourceMetric,
        at stage: AnalysisStage
    ) async -> AnalysisFault {
        if let latchedBreach { return latchedBreach.fault }

        let breach = ResourceBreach(metric: metric, cause: cause, stage: stage, target: target)
        latchedBreach = breach

        let cancellations = siblings
        siblings.removeAll()
        for sibling in cancellations {
            sibling.cancel()
        }

        let held = outstanding
        outstanding.removeAll()
        for reservation in held {
            await governor.release(reservation)
        }

        return breach.fault
    }
}

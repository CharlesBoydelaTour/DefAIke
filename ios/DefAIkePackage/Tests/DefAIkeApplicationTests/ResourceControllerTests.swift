import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeApplication

// Unit tests for target-specific Resource Controller enforcement (spec task 10.2).
//
// Three things are being tested, and they are separable:
//
//   1. The budget in force is the bound target's signed budget, and the other target's
//      can never stand in for it (Requirement 11.1).
//   2. Every check that cannot be performed fails closed with `resource-limit` — a
//      missing limit, a limit in the wrong unit, a categorical metric, an unmeasurable
//      metric, and a substituted grant all land there (Requirements 3.4, 11.6, 11.8).
//   3. Work inside the budget continues, and nothing in the controller can end it from
//      elapsed time (Requirement 15.10).
//
// Property 29 (hard resource limits fail without evidence) is spec task 10.8 and is not
// written here.

@Suite("Resource Controller binding")
struct ResourceControllerBindingTests {
    @Test(
        "A controller binds only a governor for its own target",
        arguments: ExecutionTarget.allCases
    )
    func rejectsMismatchedGovernor(target: ExecutionTarget) async {
        let other: ExecutionTarget = target == .mainApplication ? .shareExtension : .mainApplication
        let budgets = ResourceFixture.budgetSet()

        #expect(
            ResourceController(
                target: target,
                budgets: budgets,
                governor: RecordingResourceGovernor(target: other)
            ) == nil
        )
        #expect(
            ResourceController(
                target: target,
                budgets: budgets,
                governor: RecordingResourceGovernor(target: target)
            ) != nil
        )
    }

    @Test(
        "The bound budget is the target's own, never the other target's",
        arguments: ExecutionTarget.allCases
    )
    func bindsOwnBudget(target: ExecutionTarget) async throws {
        let budgets = ResourceFixture.budgetSet()
        let controller = try #require(
            ResourceController(
                target: target,
                budgets: budgets,
                governor: RecordingResourceGovernor(target: target)
            )
        )

        #expect(await controller.budget.id == budgets.budget(for: target).id)
        #expect(await controller.budget.target == target)
        let otherTarget: ExecutionTarget =
            target == .mainApplication ? .shareExtension : .mainApplication
        #expect(await controller.budget.id != budgets.budget(for: otherTarget).id)
    }

    @Test("Every governor call carries the bound target's budget")
    func everyCallUsesTheBoundBudget() async throws {
        let budgets = ResourceFixture.budgetSet()
        let governor = RecordingResourceGovernor(target: .shareExtension)
        let controller = try #require(
            ResourceController(target: .shareExtension, budgets: budgets, governor: governor)
        )

        let reservation = try await controller.reserve(
            .encodedInputSize,
            amount: Fixture.positive(10),
            unit: .bytes,
            at: .handoffVerification
        )
        await controller.release(reservation)
        try await controller.checkpoint(.temporaryStorage, at: .handoffVerification)

        let expected = budgets.shareExtension.id
        let unexpected = budgets.mainApplication.id
        for call in await governor.calls() {
            switch call {
            case .reserve(_, let id), .release(_, let id), .observe(_, let id):
                #expect(id == expected)
                #expect(id != unexpected)
            }
        }
    }
}

@Suite("Resource Controller work inside budget")
struct ResourceControllerWithinBudgetTests
{
    @Test("A reading at the limit is inside the limit and does not stop work")
    func readingAtLimitPasses() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue, for: .peakResidentMemory)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        try await controller.checkpoint(.peakResidentMemory, at: .inputValidation)
        #expect(await controller.currentBreach() == nil)
    }

    @Test("Repeated checkpoints inside budget never stop the work")
    func repeatedCheckpointsPermitContinuation() async throws {
        // The controller holds no clock, so no number of checkpoints and no amount of
        // elapsed time can produce a terminal outcome while the readings stay in budget
        // (Requirement 15.10). Repeating the checkpoint is the observable form of that:
        // an implementation that accumulated anything per call would fail here.
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue - 1, for: .peakResidentMemory)
        await governor.setReading(ResourceFixture.defaultLimitValue - 1, for: .temporaryStorage)
        await governor.setThermalState(.nominal)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        for _ in 0..<200 {
            try await controller.checkpoint(
                .peakResidentMemory,
                .temporaryStorage,
                .thermalState,
                at: .inference
            )
        }
        #expect(await controller.currentBreach() == nil)
        #expect(await controller.permits(.evidenceReport))
    }

    @Test("Reserved headroom is tracked and released")
    func reservationLifecycle() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        let reservation = try await controller.reserve(
            .peakResidentMemory,
            amount: Fixture.positive(100),
            unit: .bytes,
            at: .inputValidation
        )
        #expect(await controller.outstandingReservations().map(\.token) == [reservation.token])
        #expect(await governor.heldReservations().count == 1)

        await controller.release(reservation)
        #expect(await controller.outstandingReservations().isEmpty)
        #expect(await governor.heldReservations().isEmpty)

        // Idempotent: a cleanup path may release unconditionally.
        await controller.release(reservation)
        #expect(await controller.outstandingReservations().isEmpty)
    }

    @Test("A reservation from another target is not this controller's to release")
    func foreignReservationIsNotForwarded() async throws {
        let budgets = ResourceFixture.budgetSet()
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(target: .mainApplication, budgets: budgets, governor: governor)
        )
        let foreign = ResourceReservation(
            token: ResourceReservationToken(rawValue: 99),
            request: try #require(
                ResourceReservationRequest(
                    metric: .encodedInputSize,
                    amount: Fixture.positive(1),
                    unit: .bytes,
                    stage: .handoffVerification
                )
            ),
            budgetID: budgets.shareExtension.id,
            target: .shareExtension
        )

        await controller.release(foreign)
        #expect(await governor.calls().isEmpty)
    }
}

@Suite("Resource Controller gated commits")
struct ResourceControllerGatedCommitTests {
    @Test("A target permits only its own commit")
    func onlyOwnCommitIsPermitted() async throws {
        let budgets = ResourceFixture.budgetSet()
        let app = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: budgets,
                governor: RecordingResourceGovernor(target: .mainApplication)
            )
        )
        let ext = try #require(
            ResourceController(
                target: .shareExtension,
                budgets: budgets,
                governor: RecordingResourceGovernor(target: .shareExtension)
            )
        )

        #expect(await app.permits(.evidenceReport))
        #expect(await app.permits(.readyTransferTicket) == false)
        #expect(await ext.permits(.readyTransferTicket))
        #expect(await ext.permits(.evidenceReport) == false)
    }

    @Test("A main-application breach forbids every evidence commit")
    func appBreachForbidsEvidence() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.decodedPixelCount, at: .inputValidation)
        }
        for commit in ResourceGatedCommit.allCases {
            #expect(await controller.permits(commit) == false)
        }
    }

    @Test("A Share Extension breach forbids publishing a ready ticket")
    func extensionBreachForbidsReadyTicket() async throws {
        let governor = RecordingResourceGovernor(target: .shareExtension)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .encodedInputSize)
        let controller = try #require(
            ResourceController(
                target: .shareExtension,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        await #expect(
            throws: AnalysisFault.analysis(.resourceLimit, stage: .handoffVerification)
        ) {
            try await controller.checkpoint(.encodedInputSize, at: .handoffVerification)
        }
        #expect(await controller.permits(.readyTransferTicket) == false)
    }
}

@Suite("Resource Controller fail-closed checks")
struct ResourceControllerFailClosedTests {
    /// Builds a main-application controller with a governor a test can program.
    private func makeController(
        overrides: [ResourceMetric: ValidatedLimit] = [:]
    ) throws -> (ResourceController, RecordingResourceGovernor) {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(mainApplicationOverrides: overrides),
                governor: governor
            )
        )
        return (controller, governor)
    }

    @Test("A measured breach reports resource-limit at the running stage")
    func measuredBreach() async throws {
        let (controller, governor) = try makeController()
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .temporaryStorage)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await controller.checkpoint(.temporaryStorage, at: .preprocessing)
        }
        let breach = try #require(await controller.currentBreach())
        #expect(breach.metric == .temporaryStorage)
        #expect(breach.cause == .wouldExceedHardLimit)
        #expect(breach.stage == .preprocessing)
        #expect(breach.target == .mainApplication)
    }

    @Test("A thermal state above the approved maximum is a breach")
    func thermalBreach() async throws {
        let (controller, governor) = try makeController()
        await governor.setThermalState(.critical)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inference)) {
            try await controller.checkpoint(.thermalState, at: .inference)
        }
        #expect(await controller.currentBreach()?.cause == .wouldExceedHardLimit)
    }

    @Test("A metric the bound budget does not define fails without asking the governor")
    func undefinedMetricFailsClosed() async throws {
        // `encodedInputSize` belongs to the Share Extension budget, so a main-application
        // budget correctly has none. Absence is not "unlimited": there is no comparison to
        // make, and the governor is never consulted about a limit that does not exist.
        let (controller, governor) = try makeController()

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.encodedInputSize, at: .inputValidation)
        }
        #expect(await controller.currentBreach()?.cause == .limitNotDefined)
        #expect(await governor.calls().isEmpty)
    }

    @Test("An unmeasurable metric is not a pass")
    func unmeasurableMetricFailsClosed() async throws {
        let (controller, governor) = try makeController()
        await governor.setNotMeasurable(.energyImpact)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inference)) {
            try await controller.checkpoint(.energyImpact, at: .inference)
        }
        #expect(await controller.currentBreach()?.cause == .measurementUnavailable)
    }

    @Test("The first named metric that fails is the one reported")
    func firstFailingMetricIsReported() async throws {
        let (controller, governor) = try makeController()
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .peakResidentMemory)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .temporaryStorage)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await controller.checkpoint(
                .decodedPixelCount,
                .temporaryStorage,
                .peakResidentMemory,
                at: .preprocessing
            )
        }
        #expect(await controller.currentBreach()?.metric == .temporaryStorage)
    }

    @Test("A request in a unit the budget's limit does not use fails closed")
    func unitMismatchFailsClosed() async throws {
        let (controller, governor) = try makeController()

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            // The budget bounds peak resident memory in bytes. A request stated in
            // milliseconds cannot be compared to it, so the magnitudes are never
            // compared across units.
            try await controller.reserve(
                .peakResidentMemory,
                amount: Fixture.positive(1),
                unit: .milliseconds,
                at: .inputValidation
            )
        }
        #expect(
            await controller.currentBreach()?.cause
                == .limitUnitMismatch(requested: .milliseconds, defined: .bytes)
        )
        #expect(await governor.calls().isEmpty)
    }

    @Test("A categorical metric cannot be reserved")
    func categoricalMetricIsNotReservable() async throws {
        let (controller, governor) = try makeController()

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .modelLoad)) {
            try await controller.reserve(
                .thermalState,
                amount: Fixture.positive(1),
                unit: .milliseconds,
                at: .modelLoad
            )
        }
        #expect(await controller.currentBreach()?.cause == .notReservable)
        #expect(await governor.calls().isEmpty)
    }

    @Test("A refused reservation stops the work before the allocation")
    func refusedReservationFailsClosed() async throws {
        let (controller, governor) = try makeController()
        await governor.setReserveOutcome(.refuse)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.reserve(
                .decodedPixelCount,
                amount: Fixture.positive(1),
                unit: .pixels,
                at: .inputValidation
            )
        }
        #expect(await controller.currentBreach()?.cause == .reservationRefused)
        #expect(await controller.outstandingReservations().isEmpty)
    }

    @Test("A request larger than the remaining headroom is refused")
    func overBudgetReservationFailsClosed() async throws {
        let (controller, _) = try makeController()

        _ = try await controller.reserve(
            .peakResidentMemory,
            amount: Fixture.positive(ResourceFixture.defaultLimitValue),
            unit: .bytes,
            at: .inputValidation
        )
        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await controller.reserve(
                .peakResidentMemory,
                amount: Fixture.positive(1),
                unit: .bytes,
                at: .preprocessing
            )
        }
        #expect(await controller.currentBreach()?.cause == .reservationRefused)
    }

    @Test(
        "Headroom granted against a different budget, target, or amount is rejected",
        arguments: [
            RecordingResourceGovernor.ReserveOutcome.substituteTarget(.shareExtension),
            .substituteAmount(2),
        ]
    )
    func substitutedGrantFailsClosed(
        outcome: RecordingResourceGovernor.ReserveOutcome
    ) async throws {
        let (controller, governor) = try makeController()
        await governor.setReserveOutcome(outcome)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.reserve(
                .decodedPixelCount,
                amount: Fixture.positive(1),
                unit: .pixels,
                at: .inputValidation
            )
        }
        #expect(await controller.currentBreach()?.cause == .substitutedBudget)
        // The rejected grant was handed back rather than leaked.
        #expect(await governor.heldReservations().isEmpty)
        #expect(await controller.outstandingReservations().isEmpty)
    }

    @Test("Headroom stamped with another budget identifier is rejected")
    func substitutedBudgetIdentifierFailsClosed() async throws {
        let budgets = ResourceFixture.budgetSet()
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(target: .mainApplication, budgets: budgets, governor: governor)
        )
        await governor.setReserveOutcome(.substituteBudgetID(budgets.shareExtension.id))

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.reserve(
                .decodedPixelCount,
                amount: Fixture.positive(1),
                unit: .pixels,
                at: .inputValidation
            )
        }
        #expect(await controller.currentBreach()?.cause == .substitutedBudget)
        #expect(await governor.heldReservations().isEmpty)
    }

    @Test("Cancellation from the port stays cancellation and latches no breach")
    func cancellationIsNotAResourceFailure() async throws {
        // Cancellation is a separate terminal outcome and must never be presented as an
        // Analysis Error, so it passes through unchanged rather than being folded into
        // `resource-limit`.
        let (controller, governor) = try makeController()
        await governor.setReserveOutcome(.cancelled)

        await #expect(throws: AnalysisFault.cancelled) {
            try await controller.reserve(
                .decodedPixelCount,
                amount: Fixture.positive(1),
                unit: .pixels,
                at: .inputValidation
            )
        }
        #expect(await controller.currentBreach() == nil)
        #expect(await controller.permits(.evidenceReport))
    }
}

@Suite("Resource Controller breach effects")
struct ResourceControllerBreachEffectTests {
    @Test("The first breach latches and later in-budget readings cannot revive the work")
    func breachIsMonotonic() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .temporaryStorage)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.temporaryStorage, at: .inputValidation)
        }
        // The reading recovers, and a later stage checks a metric that is comfortably
        // inside its limit. The session stays stopped, and the reported stage is still
        // the causally first one.
        await governor.setReading(0, for: .temporaryStorage)
        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.peakResidentMemory, at: .calibration)
        }
        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.reserve(
                .peakResidentMemory,
                amount: Fixture.positive(1),
                unit: .bytes,
                at: .calibration
            )
        }
        #expect(await controller.currentBreach()?.stage == .inputValidation)
    }

    @Test("A breach cancels registered sibling work in registration order, once each")
    func breachCancelsSiblings() async throws {
        let cancelled = LockedList<String>()
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        _ = await controller.registerSiblingWork { cancelled.append("pixel") }
        _ = await controller.registerSiblingWork { cancelled.append("provenance") }

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.decodedPixelCount, at: .inputValidation)
        }
        #expect(cancelled.values == ["pixel", "provenance"])

        // A second failing call must not cancel a second time.
        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.decodedPixelCount, at: .preprocessing)
        }
        #expect(cancelled.values == ["pixel", "provenance"])
    }

    @Test("Withdrawn sibling work is not cancelled")
    func withdrawnSiblingIsNotCancelled() async throws {
        let cancelled = LockedList<String>()
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        let finished = await controller.registerSiblingWork { cancelled.append("finished") }
        _ = await controller.registerSiblingWork { cancelled.append("running") }
        await controller.withdrawSiblingWork(finished)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.decodedPixelCount, at: .inputValidation)
        }
        #expect(cancelled.values == ["running"])
    }

    @Test("Work registered after a breach is cancelled immediately")
    func lateSiblingIsCancelledImmediately() async throws {
        let cancelled = LockedList<String>()
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)) {
            try await controller.checkpoint(.decodedPixelCount, at: .inputValidation)
        }
        _ = await controller.registerSiblingWork { cancelled.append("late") }
        #expect(cancelled.values == ["late"])
    }

    @Test("A breach returns every outstanding reservation")
    func breachReleasesOutstandingHeadroom() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        _ = try await controller.reserve(
            .peakResidentMemory,
            amount: Fixture.positive(10),
            unit: .bytes,
            at: .inputValidation
        )
        _ = try await controller.reserve(
            .temporaryStorage,
            amount: Fixture.positive(10),
            unit: .bytes,
            at: .inputValidation
        )
        #expect(await controller.outstandingReservations().count == 2)

        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await controller.checkpoint(.decodedPixelCount, at: .preprocessing)
        }

        #expect(await controller.outstandingReservations().isEmpty)
        #expect(await governor.heldReservations().isEmpty)
    }

    @Test("A sample outstanding when a sibling breaches cannot report in-budget")
    func concurrentBreachIsNotSteppedOver() async throws {
        // The controller suspends while the governor samples, which frees its actor. A
        // concurrent branch can breach inside that window, and an in-budget reading that
        // arrives afterwards must not let the session continue past a breach it has
        // already committed to.
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(0, for: .peakResidentMemory)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        await governor.gate(.observe(.peakResidentMemory))
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        let sampling = Task { try await controller.checkpoint(.peakResidentMemory, at: .inference) }
        try await waitForGate(governor)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await controller.checkpoint(.decodedPixelCount, at: .preprocessing)
        }
        await governor.openGate()

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await sampling.value
        }
    }

    @Test("Headroom granted while a sibling breaches is handed straight back")
    func concurrentBreachReturnsLateGrant() async throws {
        // The mirror of the case above, on the reserving path: the grant arrives after
        // the latch, so it can no longer be held. It goes back to the governor rather
        // than becoming headroom the budget has already refused.
        let governor = RecordingResourceGovernor(target: .mainApplication)
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .decodedPixelCount)
        await governor.gate(.reserve(.temporaryStorage))
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )

        let reserving = Task {
            try await controller.reserve(
                .temporaryStorage,
                amount: Fixture.positive(1),
                unit: .bytes,
                at: .inputValidation
            )
        }
        try await waitForGate(governor)

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            try await controller.checkpoint(.decodedPixelCount, at: .preprocessing)
        }
        await governor.openGate()

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            _ = try await reserving.value
        }
        #expect(await controller.outstandingReservations().isEmpty)
        #expect(await governor.heldReservations().isEmpty)
    }

    /// Waits until the governor's gated call has actually been entered.
    ///
    /// Bounded, so a wiring mistake fails this requirement instead of hanging the suite.
    private func waitForGate(_ governor: RecordingResourceGovernor) async throws {
        var spins = 0
        while await governor.gateWasReached() == false, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        try #require(await governor.gateWasReached())
    }

    @Test("Every breach cause raises exactly resource-limit and nothing else")
    func everyCauseIsResourceLimit() async throws {
        let causes: [ResourceBreach.Cause] = [
            .wouldExceedHardLimit,
            .reservationRefused,
            .limitNotDefined,
            .limitUnitMismatch(requested: .bytes, defined: .pixels),
            .notReservable,
            .measurementUnavailable,
            .substitutedBudget,
        ]
        for cause in causes {
            for stage in AnalysisStage.allCases {
                let breach = ResourceBreach(
                    metric: .peakResidentMemory,
                    cause: cause,
                    stage: stage,
                    target: .mainApplication
                )
                #expect(breach.fault == .analysis(.resourceLimit, stage: stage))
                #expect(breach.fault.analysisError == .resourceLimit)
                #expect(breach.fault.isCancelled == false)
            }
        }
    }
}

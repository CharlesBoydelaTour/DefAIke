import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeTestSupport

/// Checks the remaining doubles: the clock, the stubs, the cleanup fake, the resource
/// governor, and the artifact store.
///
/// Each test states one behavior a later property depends on. Together they also prove
/// every port in `DefAIkeDomain` has at least one conforming implementation that
/// compiles, which is the compile-time half of task 1.4.
@Suite("Port double behavior")
struct DoubleBehaviorTests {

    // MARK: - Clock

    @Test("The virtual clock only moves when a test moves it")
    func clockIsDeterministic() {
        let clock = VirtualSessionClock()
        let start = clock.wallClockNow

        #expect(clock.wallClockNow == start)
        clock.advance(by: .seconds(5))
        #expect(clock.wallClockNow == start.addingTimeInterval(5))
        #expect(clock.elapsed(since: clock.monotonicNow) == .zero)
    }

    @Test("A deadline is due exactly at its boundary, not before")
    func deadlineEvaluationIsInclusive() {
        let clock = VirtualSessionClock()
        let created = clock.wallClockNow
        let deadline = LifecycleFixture.duration(30_000)

        #expect(!clock.isDue(createdAt: created, deadline: deadline))
        clock.advance(by: .milliseconds(29_999))
        #expect(!clock.isDue(createdAt: created, deadline: deadline))
        clock.advance(by: .milliseconds(1))
        #expect(clock.isDue(createdAt: created, deadline: deadline))
    }

    @Test("A wall clock that moved backwards retains rather than deletes")
    func backwardWallClockFailsClosedTowardRetention() {
        let clock = VirtualSessionClock()
        let created = clock.wallClockNow.addingTimeInterval(3600)

        #expect(!clock.isDue(createdAt: created, deadline: LifecycleFixture.duration(1)))
    }

    // MARK: - Stub outcomes

    @Test("A stub sequence walks its steps and then repeats the last one")
    func stubSequenceRepeatsFinalStep() throws {
        let outcome = StubOutcome<PixelEvidence>([
            .fault(.analysis(.calibrationInputError, stage: .calibration)),
            .success(.notEnoughSignal),
        ])

        #expect(throws: AnalysisFault.analysis(.calibrationInputError, stage: .calibration)) {
            _ = try outcome.resolve()
        }
        #expect(try outcome.resolve() == .notEnoughSignal)
        #expect(try outcome.resolve() == .notEnoughSignal)
    }

    @Test("A stub records its call even when it is programmed to fail")
    func failingStubStillRecordsItsCall() async {
        let recorder = PortCallRecorder()
        let validator = StubInputValidator(
            outcome: StubOutcome(
                alwaysFailing: .analysis(.unsupportedMedia, stage: .mediaClassification)
            ),
            recorder: recorder
        )
        let asset = PortValue.asset()

        await #expect(
            throws: AnalysisFault.analysis(.unsupportedMedia, stage: .mediaClassification)
        ) {
            _ = try await validator.validate(
                asset,
                contract: PreprocessingFixture.contract(),
                budget: ResourceFixture.budget(for: .mainApplication)
            )
        }

        #expect(recorder.didCall(.validate(asset.sessionID)))
        #expect(recorder.callKinds == [.validate])
    }

    @Test("The validator stub reports the artifact versions it was called with")
    func validatorStubReportsBoundVersions() async throws {
        let contract = PreprocessingFixture.contract(id: "preprocessing-0007")
        let budget = ResourceFixture.budget(for: .mainApplication, id: "budget-app-0007")
        let validator = StubInputValidator(
            outcome: StubOutcome(always: PortValue.validatedImage())
        )

        _ = try await validator.validate(PortValue.asset(), contract: contract, budget: budget)

        let received = try #require(validator.receivedArtifactVersions.first)
        #expect(received.contract == contract.id)
        #expect(received.budget == budget.id)
    }

    @Test("A non-finite model output cannot be programmed as a successful logit")
    func nonFiniteOutputIsNotALogit() {
        #expect(RawLogit(.nan) == nil)
        #expect(RawLogit(.infinity) == nil)
        #expect(RawLogit(-.infinity) == nil)
        #expect(RawLogit(0) != nil)
    }

    @Test("The provenance stub records which bytes it inspected")
    func provenanceStubRecordsInspectedBytes() async {
        let recorder = PortCallRecorder()
        let analyzer = StubProvenanceAnalyzer(always: .absent, recorder: recorder)
        let asset = PortValue.asset()

        let evidence = await analyzer.analyze(asset, policy: ProvenanceFixture.policy())

        #expect(evidence == .absent)
        #expect(analyzer.inspectedDigests == [asset.sha256])
        #expect(recorder.didCall(.provenanceAnalyze(asset.sessionID)))
    }

    // MARK: - Resource governor

    @Test("A reservation inside the budget is granted and released")
    func reservationWithinBudgetIsGranted() async throws {
        let governor = FakeResourceGovernor(target: .mainApplication)
        let budget = ResourceFixture.budget(for: .mainApplication)
        let request = try #require(
            ResourceReservationRequest(
                metric: .peakResidentMemory,
                amount: ResourceFixture.positive(1000),
                unit: .bytes,
                stage: .inputValidation
            )
        )

        let reservation = try await governor.reserve(request, budget: budget)
        #expect(await governor.outstandingReservations().count == 1)

        await governor.release(reservation)
        #expect(await governor.outstandingReservations().isEmpty)

        // Idempotent: a cleanup path may release unconditionally.
        await governor.release(reservation)
        #expect(await governor.outstandingReservations().isEmpty)
    }

    @Test("A reservation beyond the budget's hard limit is resource-limit at its stage")
    func reservationBeyondBudgetFails() async throws {
        let governor = FakeResourceGovernor(target: .mainApplication)
        let budget = ResourceFixture.budget(for: .mainApplication, limitValue: 500)
        let request = try #require(
            ResourceReservationRequest(
                metric: .peakResidentMemory,
                amount: ResourceFixture.positive(900),
                unit: .bytes,
                stage: .preprocessing
            )
        )

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)) {
            _ = try await governor.reserve(request, budget: budget)
        }
        #expect(await governor.outstandingReservations().isEmpty)
    }

    @Test("A controller refuses the other target's budget")
    func governorRefusesForeignBudget() async throws {
        let governor = FakeResourceGovernor(target: .shareExtension)
        let applicationBudget = ResourceFixture.budget(for: .mainApplication)
        let request = try #require(
            ResourceReservationRequest(
                metric: .peakResidentMemory,
                amount: ResourceFixture.positive(1),
                unit: .bytes,
                stage: .handoffVerification
            )
        )

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .handoffVerification)) {
            _ = try await governor.reserve(request, budget: applicationBudget)
        }
    }

    @Test("A categorical metric cannot be reserved")
    func thermalStateCannotBeReserved() {
        #expect(
            ResourceReservationRequest(
                metric: .thermalState,
                amount: ResourceFixture.positive(1),
                unit: .bytes,
                stage: .inference
            ) == nil
        )
    }

    @Test("An unmeasurable metric is reported honestly, not as within limit")
    func unmeasurableMetricIsReportedAsSuch() async {
        let governor = FakeResourceGovernor(target: .mainApplication)
        let budget = ResourceFixture.budget(for: .mainApplication)
        await governor.setNotMeasurable(.energyImpact)

        let observation = await governor.observe(.energyImpact, budget: budget)

        #expect(observation == .notMeasurable(.energyImpact))
        #expect(!observation.breachesHardLimit)
        #expect(!observation.isMeasured)
    }

    @Test("A reading above the hard limit is observed as a breach")
    func readingAboveLimitIsABreach() async {
        let governor = FakeResourceGovernor(target: .mainApplication)
        let budget = ResourceFixture.budget(for: .mainApplication, limitValue: 100)
        await governor.setReading(150, for: .temporaryStorage)

        #expect(
            await governor.observe(.temporaryStorage, budget: budget)
                == .wouldBreachHardLimit(.temporaryStorage)
        )
    }

    // MARK: - Cleanup

    @Test("Deleting a session empties its scope and repeats with nothing to remove")
    func sessionDeletionIsCompleteAndIdempotent() async throws {
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let sessionID = PortValue.sessionID()
        _ = try await store.writeComplete(PortValue.bytes(count: 64), in: .session(sessionID))
        let policy = LifecycleFixture.policy()

        let first = try await deleter.deleteSession(sessionID, reason: .completed, policy: policy)
        #expect(first.removedObjectCount == 1)
        #expect(first.reason == .completed)
        #expect(first.lifecyclePolicyID == policy.id)
        #expect(await store.keys(in: .session(sessionID)).isEmpty)

        let second = try await deleter.deleteSession(sessionID, reason: .completed, policy: policy)
        #expect(second.removedObjectCount == 0)
    }

    @Test(
        "Every end reason selects its own deadline",
        arguments: SessionEndReason.allCases
    )
    func endReasonSelectsItsDeadline(reason: SessionEndReason) async throws {
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let policy = LifecycleFixture.policy()

        let receipt = try await deleter.deleteSession(
            PortValue.sessionID(),
            reason: reason,
            policy: policy
        )

        #expect(receipt.reason == reason.cleanupReason)
        #expect(receipt.reason.endReason == reason)
        #expect(receipt.deadline == policy.deadline(for: reason.cleanupReason))
    }

    @Test("Abandoned cleanup sweeps orphaned material and spares a live session")
    func abandonedCleanupSparesLiveSessions() async throws {
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let live = PortValue.sessionID("session-live")
        let orphan = PortValue.sessionID("session-orphan")
        let transferID = PortValue.transferID()

        _ = try await store.writeComplete(PortValue.bytes(count: 16), in: .session(live))
        _ = try await store.writeComplete(PortValue.bytes(count: 16), in: .session(orphan))
        _ = try await store.writeComplete(
            PortValue.bytes(count: 16),
            in: .transfer(transferID, .staging)
        )
        await deleter.registerLiveSession(live)

        let receipts = try await deleter.deleteAbandonedData(policy: LifecycleFixture.policy())

        #expect(receipts.map(\.sessionID) == [orphan])
        #expect(receipts.allSatisfy { $0.reason == .abandoned })
        #expect(await store.keys(in: .session(live)).count == 1)
        #expect(await store.keys(in: .session(orphan)).isEmpty)
        #expect(await store.keys(in: .transfer(transferID, .staging)).isEmpty)
    }

    // MARK: - Artifact store

    @Test("An unregistered artifact is not found rather than invented")
    func unregisteredArtifactFailsClosed() async throws {
        let recorder = PortCallRecorder()
        let artifacts = InMemoryArtifactStore(recorder: recorder)
        let missing = PortValue.artifactID("lifecycle-missing")

        await #expect(throws: ReleaseArtifactError.notFound(missing)) {
            _ = try await artifacts.lifecyclePolicy(missing)
        }
        #expect(recorder.didCall(.readPolicyArtifact(missing)))
    }

    @Test("A registered artifact is returned for its exact identifier only")
    func registeredArtifactIsReturnedByExactIdentifier() async throws {
        let artifacts = InMemoryArtifactStore()
        let policy = LifecycleFixture.policy(id: "lifecycle-0042")
        await artifacts.register(policy)

        #expect(try await artifacts.lifecyclePolicy(policy.id) == policy)

        let other = PortValue.artifactID("lifecycle-0043")
        await #expect(throws: ReleaseArtifactError.notFound(other)) {
            _ = try await artifacts.lifecyclePolicy(other)
        }
    }

    @Test("Forgetting an artifact makes a previously readable policy unreadable")
    func forgettingAnArtifactFailsClosed() async throws {
        let artifacts = InMemoryArtifactStore()
        let policy = LifecycleFixture.policy()
        await artifacts.register(policy)
        _ = try await artifacts.lifecyclePolicy(policy.id)

        await artifacts.forgetPolicyArtifact(policy.id)

        await #expect(throws: ReleaseArtifactError.notFound(policy.id)) {
            _ = try await artifacts.lifecyclePolicy(policy.id)
        }
    }

    @Test("Both target budgets are read as one pair")
    func resourceBudgetsAreReadAsAPair() async throws {
        let artifacts = InMemoryArtifactStore()
        let application = ResourceFixture.budget(for: .mainApplication, id: "budget-app")
        let extensionBudget = ResourceFixture.budget(
            for: .shareExtension,
            id: "budget-extension"
        )
        await artifacts.register(application)
        await artifacts.register(extensionBudget)

        let pair = try await artifacts.resourceBudgets(
            mainApplication: application.id,
            shareExtension: extensionBudget.id
        )

        #expect(pair.budget(for: .mainApplication).id == application.id)
        #expect(pair.budget(for: .shareExtension).id == extensionBudget.id)

        await artifacts.forgetPolicyArtifact(extensionBudget.id)
        await #expect(throws: ReleaseArtifactError.notFound(extensionBudget.id)) {
            _ = try await artifacts.resourceBudgets(
                mainApplication: application.id,
                shareExtension: extensionBudget.id
            )
        }
    }

    // MARK: - Module boundary

    @Test("The test-support module is marked nonshipping")
    func moduleIsNonshipping() {
        #expect(DefAIkeTestSupportModule.name == "DefAIkeTestSupport")
        #expect(!DefAIkeTestSupportModule.isShippingModule)
    }
}

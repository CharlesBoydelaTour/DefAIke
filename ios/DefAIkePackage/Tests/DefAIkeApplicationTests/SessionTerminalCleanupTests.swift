import DefAIkeDomain
import Testing

@testable import DefAIkeApplication

/// The binding from a terminal outcome to the deadline its removal is audited against.
///
/// Requirement 9.8 removes a session's material on completion, cancellation, or an Analysis
/// Error, and each of those is a *different* approved number. So the assertions here are all
/// about which policy entry was read, never about how long anything waited: deletion is
/// immediate in every case, and the fixture gives each reason a distinct deadline so reading
/// the wrong entry is visible rather than indistinguishable.
@Suite("Session terminal cleanup")
struct SessionTerminalCleanupTests {

    private func makeCleanup(
        deleter: RecordingSessionDataDeleter,
        policy: DataLifecyclePolicy = Fixture.lifecyclePolicy()
    ) -> SessionTerminalCleanup {
        SessionTerminalCleanup(deleter: deleter, policy: policy)
    }

    /// The three terminal outcomes, with the reason and deadline each one selects.
    private static let terminalCases: [(SessionTerminalOutcome, SessionEndReason, UInt64)] = [
        (Fixture.completedOutcome(), .completed, 1_000),
        (.cancelled, .cancelled, 2_000),
        (Fixture.failedOutcome(), .error, 3_000),
    ]

    // MARK: - Reason and deadline selection

    @Test(
        "Each terminal outcome removes the session under its own deadline",
        arguments: SessionTerminalCleanupTests.terminalCases
    )
    func terminalOutcomeSelectsItsOwnDeadline(
        outcome: SessionTerminalOutcome,
        endReason: SessionEndReason,
        milliseconds: UInt64
    ) async throws {
        let deleter = RecordingSessionDataDeleter()
        let policy = Fixture.lifecyclePolicy()
        let cleanup = makeCleanup(deleter: deleter, policy: policy)
        let session = Fixture.sessionID("session-terminal-0001")

        let result = await cleanup.removeMaterial(for: session, after: outcome)

        let receipt = try #require(result.receipt)
        #expect(receipt.sessionID == session)
        #expect(receipt.reason == endReason.cleanupReason)
        #expect(receipt.deadline.milliseconds == milliseconds)
        #expect(receipt.deadline == policy.deadline(for: endReason.cleanupReason))
        #expect(receipt.lifecyclePolicyID == policy.id)
        // The reason the port was asked for is the outcome's, not one this type chose.
        #expect(
            await deleter.terminalCalls == [
                RecordingSessionDataDeleter.TerminalCall(
                    sessionID: session,
                    reason: endReason,
                    policyID: policy.id
                )
            ]
        )
    }

    @Test(
        "The deadline can be read before the deletion, and it is the same one",
        arguments: SessionTerminalCleanupTests.terminalCases
    )
    func announcedDeadlineMatchesTheReceipt(
        outcome: SessionTerminalOutcome,
        endReason: SessionEndReason,
        milliseconds: UInt64
    ) async throws {
        let deleter = RecordingSessionDataDeleter()
        let cleanup = makeCleanup(deleter: deleter)

        let announced = cleanup.deadline(for: outcome)
        let result = await cleanup.removeMaterial(
            for: Fixture.sessionID(),
            after: outcome
        )

        #expect(announced.milliseconds == milliseconds)
        #expect(try #require(result.receipt).deadline == announced)
        // Reading a deadline is not a deletion: only the removal call reached the port.
        #expect(await deleter.terminalCalls.count == 1)
    }

    @Test("The three terminal reasons select three different deadlines")
    func terminalDeadlinesAreDistinct() {
        let cleanup = makeCleanup(deleter: RecordingSessionDataDeleter())
        let deadlines = Self.terminalCases.map { cleanup.deadline(for: $0.0).milliseconds }

        // A single deadline for every reason would make every assertion above pass for the
        // wrong reason, so the fixture's distinctness is checked rather than assumed.
        #expect(Set(deadlines).count == Self.terminalCases.count)
    }

    @Test("A cancelled session is cleaned up under the cancellation deadline")
    func cancellationUsesTheCancellationDeadline() async throws {
        let deleter = RecordingSessionDataDeleter()
        let policy = Fixture.lifecyclePolicy()
        let cleanup = makeCleanup(deleter: deleter, policy: policy)

        let result = await cleanup.removeMaterial(for: Fixture.sessionID(), after: .cancelled)

        // Requirement 11.15 names this deadline specifically, and cancellation is not an
        // error: the receipt must not carry the error-terminated reason.
        let receipt = try #require(result.receipt)
        #expect(receipt.reason == .cancelled)
        #expect(receipt.reason != .errorTerminated)
        #expect(receipt.deadline == policy.deadline(for: .cancelled))
    }

    // MARK: - Idempotence

    @Test("Repeating a terminal cleanup succeeds and reports nothing removed")
    func repeatedCleanupIsIdempotent() async throws {
        let deleter = RecordingSessionDataDeleter()
        let cleanup = makeCleanup(deleter: deleter)
        let session = Fixture.sessionID()

        let first = await cleanup.removeMaterial(for: session, after: .cancelled)
        await deleter.setRemovedObjectCount(0)
        let second = await cleanup.removeMaterial(for: session, after: .cancelled)
        let third = await cleanup.removeMaterial(for: session, after: .cancelled)

        #expect(try #require(first.receipt).removedObjectCount == 1)
        #expect(try #require(second.receipt).removedObjectCount == 0)
        #expect(try #require(third.receipt).removedObjectCount == 0)
        // A repeat is still a real deletion request, not a cached answer.
        #expect(await deleter.terminalCalls.count == 3)
        #expect(await deleter.terminalCalls.allSatisfy { $0.reason == .cancelled })
    }

    // MARK: - Failure is not an analysis outcome

    @Test("A store failure is reported as a cleanup fault, never as an analysis error")
    func storeFailureIsNotAnAnalysisOutcome() async throws {
        let deleter = RecordingSessionDataDeleter()
        await deleter.failNextDeletion(with: .storeUnavailable)
        let cleanup = makeCleanup(deleter: deleter)

        let result = await cleanup.removeMaterial(
            for: Fixture.sessionID(),
            after: Fixture.completedOutcome()
        )

        // The session already committed its terminal state. A file system that refused a
        // deletion must not turn a completed analysis into a failed one, and there is no
        // `AnalysisError` anywhere in this result to present.
        #expect(result.storeFault == .storeUnavailable)
        #expect(result.receipt == nil)
        #expect(!result.isRemoved)
    }

    @Test("A failed cleanup does not stop a later attempt from succeeding")
    func failedCleanupIsRetryable() async throws {
        let deleter = RecordingSessionDataDeleter()
        await deleter.failNextDeletion(with: .storeUnavailable)
        let cleanup = makeCleanup(deleter: deleter)
        let session = Fixture.sessionID()

        let failed = await cleanup.removeMaterial(for: session, after: .cancelled)
        let retried = await cleanup.removeMaterial(for: session, after: .cancelled)

        // Material that could not be removed is material with no terminal deletion receipt,
        // which is exactly what the next start removes as abandoned.
        #expect(failed.storeFault == .storeUnavailable)
        #expect(try #require(retried.receipt).reason == .cancelled)
    }

    // MARK: - Startup cleanup is not duplicated here

    @Test("Terminal cleanup never runs the startup sweep")
    func terminalCleanupDoesNotSweepAbandonedData() async throws {
        let deleter = RecordingSessionDataDeleter()
        let cleanup = makeCleanup(deleter: deleter)

        for (outcome, _, _) in Self.terminalCases {
            _ = await cleanup.removeMaterial(for: Fixture.sessionID(), after: outcome)
        }

        // The startup sweep and its fail-closed ingest gate belong to `StartupPreflight`
        // step 5. A second caller here would be a second cleanup path with its own idea of
        // when ingest is allowed.
        #expect(await deleter.abandonedCallCount == 0)
        #expect(await deleter.terminalCalls.count == Self.terminalCases.count)
    }
}

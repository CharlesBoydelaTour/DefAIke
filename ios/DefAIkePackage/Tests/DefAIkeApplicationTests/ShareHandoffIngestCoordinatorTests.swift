import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeApplication

/// Resuming a pending Share handoff, and the ordering that makes it safe.
///
/// Two things are being proved here, and only one of them is visible in a result:
///
///   * **What the outcome is.** A verified handoff resumes the *same* session with the
///     bundle bound; a mismatch ends that same session with exactly one error and no
///     evidence; nothing pending is neither.
///   * **What did not happen.** Requirement 2.19 puts `handoff-error` *before* validation,
///     provenance processing, and pixel inference, and task 4.5 puts Model Bundle binding
///     after successful verification. Both are nonoccurrences, so every failing path
///     asserts the bundle port was never reached.
///
/// **Nothing here is release evidence.** The bundle fixture is synthetic and no verification
/// ran to produce it.
@Suite("Share handoff ingest coordinator")
struct ShareHandoffIngestCoordinatorTests {

    // MARK: - Scaffolding

    private func coordinator(
        claiming: RecordingShareClaimer,
        bundles: RecordingBundleManager
    ) -> ShareHandoffIngestCoordinator {
        ShareHandoffIngestCoordinator(claiming: claiming, bundles: bundles)
    }

    /// An accepted ingest for the pending session, as a verified claim would return.
    private func verifiedAsset(
        sessionID: AnalysisSessionID = Fixture.sessionID("session-pending-0001"),
        route: InputRoute = .shareExtension
    ) -> ImportedEncodedAsset {
        Fixture.importedAsset(route: route, sessionID: sessionID)
    }

    // MARK: - Nothing pending

    @Test("An empty ready slot resumes nothing and never reaches the bundle manager")
    func nothingPendingBindsNoBundle() async throws {
        let claiming = RecordingShareClaimer(peek: .empty)
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(outcome == .noSession(.nothingPending))
        #expect(outcome.error == nil)
        // An ordinary launch takes ownership of nothing and binds nothing.
        #expect(await claiming.calls == [.peek])
        #expect(await bundles.callCount == 0)
    }

    @Test("A slot emptied between the peek and the claim is no session, not an error")
    func slotEmptiedDuringTheClaimIsNoSession() async throws {
        // Another claimer won the slot, or it expired and was discarded under the lifecycle
        // policy. Nothing is pending now and nothing failed, so there is no error to show.
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer()),
            claim: .nothingPending
        )
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(outcome == .noSession(.nothingPending))
        #expect(await bundles.callCount == 0)
    }

    @Test("A ready slot the store cannot read is no session rather than a failed one")
    func unreadableSlotIsNoSession() async throws {
        // Fail closed without attributing a failure to a session that may not exist: with
        // no readable ticket there is no session identifier to terminate.
        let claiming = RecordingShareClaimer(peek: .fail(.storeUnavailable))
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(outcome == .noSession(.pendingHandoffUnreadable))
        #expect(outcome.error == nil)
        // Nothing was claimed, so nothing was taken from the shared container.
        #expect(await claiming.calls == [.peek])
        #expect(await bundles.callCount == 0)
    }

    // MARK: - The verified handoff

    @Test("A verified handoff resumes the same session and binds the bundle after it")
    func verifiedHandoffResumesTheSameSessionThenBinds() async throws {
        let session = Fixture.sessionID("session-pending-0001")
        let ticket = Fixture.shareTicket(sessionID: session)
        let bundle = HandoffBundleFixture.boundBundle()
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: ticket)),
            claim: .verified { _ in Fixture.importedAsset(route: .shareExtension, sessionID: session) }
        )
        let bundles = RecordingBundleManager(.active(bundle))
        let context = HandoffBundleFixture.releaseContext()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: context)

        let resumed = try #require(outcome.resumedSession)
        // The identifier the extension allocated, unchanged (Requirements 2.3 and 11.12).
        #expect(resumed.sessionID == session)
        #expect(resumed.sessionID == ticket.sessionID)
        #expect(resumed.route == .shareExtension)
        #expect(resumed.bundle == bundle)
        // The order is the requirement: peek, claim, and only then bind.
        #expect(await claiming.calls == [.peek, .claim(context.device.appBuild)])
        #expect(await bundles.activeBundleRequests == [context])
        #expect(await bundles.activationRequests.isEmpty)
        #expect(await bundles.rollbackRequests.isEmpty)
    }

    @Test("The claim is handed the running build's identity, not a constant")
    func theClaimingBuildIsTheRunningBuild() async throws {
        // The ticket's staging build is compared against this value, so a coordinator that
        // passed anything else would let a foreign ticket verify or refuse a valid one.
        let build = Fixture.appBuild("build-provenance-0002")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer()),
            claim: .verified { claimingBuild in
                #expect(claimingBuild == build)
                return Fixture.importedAsset(
                    route: .shareExtension,
                    sessionID: Fixture.sessionID("session-pending-0001")
                )
            }
        )
        let bundles = RecordingBundleManager()

        _ = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(
                context: HandoffBundleFixture.releaseContext(appBuild: build)
            )

        #expect(await claiming.claimedBuildIDs == [build])
    }

    // MARK: - The failed handoff

    @Test("A handoff mismatch ends that same session without binding the bundle")
    func handoffErrorTerminatesThePendingSession() async throws {
        let session = Fixture.sessionID("session-mismatched-0001")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: session))),
            claim: .fail(.analysis(.handoffError, stage: .handoffVerification))
        )
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(
            outcome == .sessionFailed(
                ShareHandoffTermination(
                    sessionID: session,
                    error: .handoffError,
                    stage: .handoffVerification
                )
            )
        )
        // The nonoccurrence Requirement 2.19 is about: nothing downstream of verification
        // was reached, starting with Model Bundle binding.
        #expect(await bundles.callCount == 0)
    }

    @Test(
        "Every claim error category ends the pending session with the bundle unbound",
        arguments: [AnalysisError.handoffError, .resourceLimit]
    )
    func everyClaimErrorLeavesTheBundleUnbound(error: AnalysisError) async throws {
        let session = Fixture.sessionID("session-refused-0001")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: session))),
            claim: .fail(.analysis(error, stage: .handoffVerification))
        )
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        let termination = try #require(outcome.termination)
        #expect(termination.sessionID == session)
        // Exactly one category, carried through rather than rewritten (Requirement 11.18).
        #expect(termination.error == error)
        #expect(termination.stage == .handoffVerification)
        #expect(await bundles.callCount == 0)
    }

    @Test("An ingest attributed to another route is refused before the bundle is bound")
    func foreignRouteIsRefused() async throws {
        // Unreachable through the shipping adapter, which carries the ticket's route.
        // Binding a session to bytes recorded under a different route is what
        // Requirement 2.8 forbids, so it fails closed rather than being trusted.
        let session = Fixture.sessionID("session-foreign-route-0001")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: session))),
            claim: .verified { _ in
                Fixture.importedAsset(route: .photosPicker, sessionID: session)
            }
        )
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(
            outcome == .sessionFailed(
                ShareHandoffTermination(
                    sessionID: session,
                    error: .handoffError,
                    stage: .handoffVerification
                )
            )
        )
        #expect(await bundles.callCount == 0)
    }

    // MARK: - Cancellation

    @Test("A cancelled claim is a cancelled session, never an error category")
    func cancelledClaimIsNotAnError() async throws {
        // Cancellation is its own terminal outcome and must never be presented as a failure
        // category (Requirement 11.17).
        let session = Fixture.sessionID("session-cancelled-0001")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: session))),
            claim: .fail(.cancelled)
        )
        let bundles = RecordingBundleManager()

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(outcome == .sessionCancelled(session))
        #expect(outcome.error == nil)
        #expect(outcome.termination == nil)
        #expect(await bundles.callCount == 0)
    }

    // MARK: - After verification

    @Test("A bundle that will not bind keeps its own category rather than a handoff error")
    func bundleFailureKeepsItsOwnCategory() async throws {
        // The handoff verified; the active bundle did not. Rewriting this as
        // `handoff-error` would tell a user their image changed in transit when it did not.
        let session = Fixture.sessionID("session-pending-0001")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: session))),
            claim: .verified { _ in
                Fixture.importedAsset(route: .shareExtension, sessionID: session)
            }
        )
        let bundles = RecordingBundleManager(
            .fail(.analysis(.modelLoadError, stage: .modelLoad))
        )

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(
            outcome == .sessionFailed(
                ShareHandoffTermination(
                    sessionID: session,
                    error: .modelLoadError,
                    stage: .modelLoad
                )
            )
        )
        // The claim happened; the binding was attempted exactly once and failed.
        #expect(await bundles.activeBundleRequests.count == 1)
    }

    @Test("Cancellation during bundle binding cancels the session rather than failing it")
    func cancellationDuringBindingIsNotAnError() async throws {
        let session = Fixture.sessionID("session-pending-0001")
        let claiming = RecordingShareClaimer(
            peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: session))),
            claim: .verified { _ in
                Fixture.importedAsset(route: .shareExtension, sessionID: session)
            }
        )
        let bundles = RecordingBundleManager(.fail(.cancelled))

        let outcome = await coordinator(claiming: claiming, bundles: bundles)
            .resumePendingHandoff(context: HandoffBundleFixture.releaseContext())

        #expect(outcome == .sessionCancelled(session))
        #expect(outcome.error == nil)
    }

    // MARK: - Outcome shape

    @Test("Exactly one outcome carries bytes and exactly one carries an error")
    func outcomesAreDisjoint() throws {
        // The disjointness the presentation layer relies on: no outcome is both a resumed
        // session and a failure, and no failure carries evidence bytes.
        let session = Fixture.sessionID("session-pending-0001")
        let resumed = ShareHandoffIngestOutcome.sessionResumed(
            ResumedShareSession(
                asset: verifiedAsset(sessionID: session),
                bundle: HandoffBundleFixture.boundBundle()
            )
        )
        let failed = ShareHandoffIngestOutcome.sessionFailed(
            ShareHandoffTermination(
                sessionID: session,
                error: .handoffError,
                stage: .handoffVerification
            )
        )
        let cancelled = ShareHandoffIngestOutcome.sessionCancelled(session)
        let none = ShareHandoffIngestOutcome.noSession(.nothingPending)

        #expect(resumed.resumedSession != nil)
        #expect(resumed.termination == nil)
        #expect(resumed.error == nil)
        for outcome in [failed, cancelled, none] {
            #expect(outcome.resumedSession == nil)
        }
        #expect(failed.error == .handoffError)
        #expect(cancelled.termination == nil)
        #expect(none.termination == nil)
        #expect(resumed != failed)
        #expect(cancelled != none)
    }

    @Test("A resumed session and its refusals stay independent across attempts")
    func attemptsShareNothing() async throws {
        // The coordinator holds no state, so a failed handoff leaves no session identity,
        // error, or bytes for the next attempt to inherit (Requirement 3.15).
        let first = Fixture.sessionID("session-first-0001")
        let second = Fixture.sessionID("session-second-0001")
        let bundles = RecordingBundleManager()
        let subject = coordinator(
            claiming: RecordingShareClaimer(
                peek: .pending(Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: first))),
                claim: .fail(.analysis(.handoffError, stage: .handoffVerification))
            ),
            bundles: bundles
        )
        let context = HandoffBundleFixture.releaseContext()

        let failure = await subject.resumePendingHandoff(context: context)
        #expect(failure.termination?.sessionID == first)

        let fresh = coordinator(
            claiming: RecordingShareClaimer(
                peek: .pending(
                    Fixture.readyTransfer(ticket: Fixture.shareTicket(sessionID: second))
                ),
                claim: .verified { _ in
                    Fixture.importedAsset(route: .shareExtension, sessionID: second)
                }
            ),
            bundles: bundles
        )

        let resumed = try #require(
            await fresh.resumePendingHandoff(context: context).resumedSession
        )
        #expect(resumed.sessionID == second)
        // The second attempt bound the bundle; the first never did.
        #expect(await bundles.activeBundleRequests.count == 1)
    }
}

import DefAIkeDomain
import DefAIkeTestSupport
import Testing

@testable import DefAIkeApplication

// Task 10.5: cooperative cancellation and stale-callback suppression.
//
// Five questions, and they fail separately:
//
//   * **Are evidence commits disabled the moment cancellation is requested?** Not when the
//     current stage returns. The terminal slot has to be occupied by `cancelled` from the
//     same synchronous step that latched the request, so every non-cancelled offer after it
//     is refused (Requirements 11.14 and 15.7).
//   * **Is pending work stopped?** The session's structured task and every registered
//     framework hook are cancelled, once each, in registration order; boundaries stop.
//   * **Are late framework results discarded by identity rather than by timing?** A
//     prediction that could not be preempted still returns. It has to be refused because
//     the attempt no longer admits results, and refused just as firmly when the identifier
//     matches but the generation does not.
//   * **Is the cancelled terminal the only one, and is it not an error?** Requirement 11.17
//     keeps the three terminals disjoint, and cancellation acquires no Analysis Error
//     category on any path.
//   * **Does reason-specific cleanup run, with no partial evidence left?** The removal is
//     audited against the cancellation deadline, not the completed or error-terminated one
//     (Requirements 9.8 and 11.15).
//
// Nothing here is timing-based. Every "late" result is made late by holding a port open at
// a rendezvous and then requesting cancellation, so the ordering is established by the test
// rather than raced for. The release under test is `CoordinatorRelease`, which runs the real
// startup gate; no value in it is an approved release input.
//
// Deliberately not here: the properties over cancellation, terminal disjointness, cleanup,
// and synthesized timeouts are tasks 10.6 through 10.12, and the cancellation-point
// integration matrix is task 10.13.

// MARK: - Disabling evidence commits

@Suite("A cancellation request disables every evidence commit")
struct SessionCancellationCommitTests {

    @Test("A request mid-flight makes cancelled the session's only terminal")
    func requestMidFlightCommitsCancellation() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        // The pixel branch is suspended inside inference, so the request lands while the
        // session is genuinely in flight and the pipeline still has stages left to run.
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let result = await harness.coordinator.requestCancellation(for: identity)
        let requestedWhileRunning = await harness.coordinator.isCancellationRequested()
        let terminalWhileRunning = await harness.coordinator.committedTerminal()
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(result.latchedRequest)
        #expect(result.isCancelled)
        #expect(requestedWhileRunning)
        // The slot is occupied before the request returns, which is what "immediately" means
        // here: not after inference resumes.
        #expect(terminalWhileRunning == .cancelled)
        #expect(session.outcome == .cancelled)
        #expect(session.evidenceReport == nil)
        // Cancellation is not an Analysis Error category (Requirement 11.17).
        #expect(session.error == nil)
        #expect(session.outcome.isCompleted == false)
        #expect(session.outcome.isFailed == false)
    }

    @Test("Inference resumes after the request and its result never becomes evidence")
    func anUnpreemptedPredictionIsDiscarded() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        // The gated analyzer returns a logit *after* the request, which is exactly the
        // framework call the design says cannot be forcibly preempted once entered.
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(harness.recorder.callCount(of: .infer) == 1)
        // Nothing downstream of the discarded logit ran, so no Pixel Evidence, no provenance
        // lane, and no summary exist for the cancelled session.
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
        #expect(harness.recorder.didCall(PortCallKind.provenanceAnalyze) == false)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
        #expect(session.outcome == .cancelled)
    }

    @Test("A failure offered after the request is refused, and cancelled still stands")
    func aLaterNonCancelledCommitIsRefused() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        let snapshot = try #require(
            AnalysisFailureSnapshot(
                sessionID: identity.sessionID,
                error: .inferenceError,
                stage: .inference,
                bytePreservationStatus: asset.preservationStatus,
                inputQuality: nil
            )
        )
        let refused = await harness.coordinator.commitTerminal(.failed(snapshot), for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(refused == .refusedAlreadyTerminal(.cancelled))
        #expect(refused.didCommit == false)
        #expect(refused.standingOutcome == .cancelled)
        #expect(session.outcome == .cancelled)
    }

    @Test("A request after the session completed leaves the completed terminal standing")
    func aRequestCannotUndoACompletedTerminal() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()
        let session = try #require(await harness.coordinator.analyze(asset).completed)

        // The session has already ended, so there is nothing running to cancel.
        let result = await harness.coordinator.requestCancellation(
            for: AnalysisSessionIdentity(sessionID: asset.sessionID, generation: 1)
        )

        #expect(session.outcome.isCompleted)
        #expect(result.commit == .refusedNoActiveSession)
        #expect(result.latchedRequest == false)
        #expect(result.isCancelled == false)
        #expect(result.standingOutcome == nil)
    }

    @Test("A request that finds a terminal already committed changes nothing")
    func aRequestAfterAMidFlightTerminalIsRefusedAtTheSlot() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let snapshot = try #require(
            AnalysisFailureSnapshot(
                sessionID: identity.sessionID,
                error: .resourceLimit,
                stage: .inference,
                bytePreservationStatus: asset.preservationStatus,
                inputQuality: nil
            )
        )
        await harness.coordinator.commitTerminal(.failed(snapshot), for: identity)
        // The user activates the cancel control after a resource breach already ended the
        // session. The three terminals cannot transition into one another.
        let result = await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(result.commit == .refusedAlreadyTerminal(.failed(snapshot)))
        #expect(result.isCancelled == false)
        // The request is still recorded, but it stopped nothing: the session was already
        // ending through its own path.
        #expect(result.latchedRequest)
        #expect(result.cancelledStructuredTask == false)
        #expect(result.invokedHookCount == 0)
        #expect(session.outcome == .failed(snapshot))
        #expect(session.error == .resourceLimit)
    }

    @Test("A request naming an attempt that is not running is refused by identity")
    func aStaleRequestIsRefused() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let live = try #require(await harness.coordinator.activeIdentity())
        let stale = AnalysisSessionIdentity(sessionID: live.sessionID, generation: 99)
        let result = await harness.coordinator.requestCancellation(for: stale)
        let stillRunning = await harness.coordinator.isCancellationRequested()
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(result.commit == .refusedStaleIdentity(offered: stale))
        #expect(result.latchedRequest == false)
        // The live session is untouched: a request for the wrong generation must not cancel
        // the one that is running.
        #expect(stillRunning == false)
        #expect(session.outcome.isCompleted)
    }

    @Test("A repeated request latches nothing and reports the same standing outcome")
    func repeatedRequestsAreIdempotent() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let first = await harness.coordinator.requestCancellation(for: identity)
        let second = await harness.coordinator.requestCancellation(for: identity)
        let third = await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(first.latchedRequest)
        #expect(second.latchedRequest == false)
        #expect(third.latchedRequest == false)
        // Requesting twice cannot change the answer.
        #expect(first.standingOutcome == second.standingOutcome)
        #expect(second.standingOutcome == third.standingOutcome)
        #expect(second.isCancelled)
        #expect(session.outcome == .cancelled)
    }
}

// MARK: - Stopping pending work

@Suite("A cancellation request stops the work already in flight")
struct SessionCancellationStopsWorkTests {

    @Test("The coordinator cancels the structured task it started the session in")
    func theOwnedStructuredTaskIsCancelled() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        let handle = try #require(await harness.coordinator.startAnalysis(of: asset))
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let result = await harness.coordinator.requestCancellation(for: identity)
        let cancelledWhileSuspended = handle.isCancelled
        await gate.openGate()
        let session = try #require(await handle.value.completed)

        #expect(result.cancelledStructuredTask)
        // Every adapter in this graph fails closed on task cancellation, so this is the step
        // that makes an in-flight decode, preprocessing pass, or prediction stop rather than
        // run to completion and have its result thrown away.
        #expect(cancelledWhileSuspended)
        #expect(session.outcome == .cancelled)
    }

    @Test("A session awaited directly reports no owned task and still cancels")
    func aCallerOwnedTaskIsNotClaimed() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let result = await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        // The enclosing task belongs to the caller, so the coordinator does not claim it —
        // and the cancelled terminal does not depend on claiming it.
        #expect(result.cancelledStructuredTask == false)
        #expect(result.isCancelled)
        #expect(session.outcome == .cancelled)
    }

    @Test("A session started in an already cancelled task performs no analysis work")
    func anAlreadyCancelledTaskRunsNoStage() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(release: release)
        let asset = try await release.acceptedIngest()

        // The rendezvous makes the ordering the test's rather than a race: the task is
        // cancelled while it waits, and only then is it released into `analyze`.
        let held = BranchGate()
        let handle = Task {
            await held.enter()
            return await harness.coordinator.analyze(asset)
        }
        handle.cancel()
        await held.openGate()
        let session = try #require(await handle.value.completed)

        #expect(session.outcome == .cancelled)
        #expect(session.evidenceReport == nil)
        #expect(session.error == nil)
        // Requirement 11.14: no decode, no preprocessing, no model load, no inference.
        #expect(harness.recorder.didCall(PortCallKind.validate) == false)
        #expect(harness.recorder.didCall(PortCallKind.preprocess) == false)
        #expect(harness.recorder.didCall(PortCallKind.loadModel) == false)
        #expect(harness.recorder.didCall(PortCallKind.infer) == false)
        // The cancelled session's material is still removed under its own deadline.
        #expect(session.cleanup.receipt?.reason == .cancelled)
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("A cancelled enclosing task cannot produce a completed terminal")
    func aCancelledTaskNeverCompletes() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        // No `requestCancellation` at all: the only cancellation here arrives from outside,
        // by cancelling the task the session runs in. The pipeline would otherwise reach its
        // completed terminal, so this is the case that must not produce an Evidence Report.
        let handle = Task { await harness.coordinator.analyze(asset) }
        await gate.waitUntilReached()
        handle.cancel()
        await gate.openGate()
        let session = try #require(await handle.value.completed)

        #expect(session.outcome == .cancelled)
        #expect(session.evidenceReport == nil)
        #expect(session.error == nil)
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
    }

    @Test("A refused start does not strand the handle and block every later start")
    func aRefusedStartLeavesStartingAvailable() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let first = try await release.acceptedIngest(sessionID: "session-0001")
        let refusedAsset = try await release.acceptedIngest(
            sessionID: "session-0002",
            byteSeed: 2
        )
        let third = try await release.acceptedIngest(sessionID: "session-0001", byteSeed: 3)

        let running = try #require(await harness.coordinator.startAnalysis(of: first))
        await gate.waitUntilReached()
        // Refused while the first session runs, so no task exists to be adopted later.
        let refused = await harness.coordinator.startAnalysis(of: refusedAsset)
        await gate.openGate()
        _ = await running.value
        // The gate is open now, so this one runs to completion on its own. It could not even
        // begin if the refused start had left its handle in the reservation slot.
        let next = try #require(await harness.coordinator.startAnalysis(of: third))
        let session = try #require(await next.value.completed)

        #expect(refused == nil)
        #expect(session.outcome.isCompleted)
        // Two sessions ran, not three: a refused start consumes no generation.
        #expect(session.identity.generation == 2)
        // The task the refused start would have stranded is not attributed to this one
        // either: cancelling this session cancels this session's task.
        #expect(next.isCancelled == false)
    }

    @Test("Starting a second session while one runs creates no task")
    func startingIsRefusedWhileASessionRuns() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let first = try await release.acceptedIngest(sessionID: "session-0001")
        let second = try await release.acceptedIngest(sessionID: "session-0002", byteSeed: 2)

        let handle = try #require(await harness.coordinator.startAnalysis(of: first))
        await gate.waitUntilReached()
        let refused = await harness.coordinator.startAnalysis(of: second)
        await gate.openGate()
        let session = try #require(await handle.value.completed)

        #expect(refused == nil)
        #expect(session.identity.sessionID == first.sessionID)
        // The second selection never reached a port.
        #expect(harness.recorder.callCount(of: .validate) == 1)
    }
}

// MARK: - Framework cancellation hooks

@Suite("Framework cancellation hooks are invoked once, in registration order")
struct SessionCancellationHookTests {

    @Test("Every registered hook fires once, in registration order")
    func hooksFireOnceInOrder() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()
        let fired = LockedList<String>()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("progress")
        }
        await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("adapter")
        }
        let first = await harness.coordinator.requestCancellation(for: identity)
        let afterFirst = fired.values
        let second = await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        _ = await running

        #expect(first.invokedHookCount == 2)
        #expect(afterFirst == ["progress", "adapter"])
        // A second request must not re-invoke a hook.
        #expect(second.invokedHookCount == 0)
        #expect(fired.values == ["progress", "adapter"])
    }

    @Test("A withdrawn hook is not invoked")
    func withdrawnHooksDoNotFire() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()
        let fired = LockedList<String>()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let finished = await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("finished")
        }
        await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("running")
        }
        await harness.coordinator.withdrawCancellationHook(finished)
        let result = await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        _ = await running

        #expect(result.invokedHookCount == 1)
        #expect(fired.values == ["running"])
    }

    @Test("A hook registered after the request is invoked immediately")
    func lateHooksFireImmediately() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()
        let fired = LockedList<String>()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let result = await harness.coordinator.requestCancellation(for: identity)
        // Work that starts in the window after the request must not keep running.
        await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("late")
        }
        let secondRequest = await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        _ = await running

        #expect(result.invokedHookCount == 0)
        #expect(fired.values == ["late"])
        // Stored nowhere, so the second request does not invoke it again.
        #expect(secondRequest.invokedHookCount == 0)
        #expect(fired.values == ["late"])
    }

    @Test("A hook registered for an attempt that is not running is invoked immediately")
    func hooksForStaleAttemptsFireImmediately() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()
        let fired = LockedList<String>()

        _ = await harness.coordinator.analyze(asset)
        // The attempt is over: a hook for it has nothing left to protect.
        await harness.coordinator.registerCancellationHook(
            for: AnalysisSessionIdentity(sessionID: asset.sessionID, generation: 1)
        ) {
            fired.append("ended")
        }

        #expect(fired.values == ["ended"])
    }

    @Test("A hook registered after a non-cancelled terminal is invoked immediately")
    func hooksAfterAnyTerminalFireImmediately() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()
        let fired = LockedList<String>()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let snapshot = try #require(
            AnalysisFailureSnapshot(
                sessionID: identity.sessionID,
                error: .resourceLimit,
                stage: .inference,
                bytePreservationStatus: asset.preservationStatus,
                inputQuality: nil
            )
        )
        await harness.coordinator.commitTerminal(.failed(snapshot), for: identity)
        // The session has ended without a cancellation request. Framework work registered
        // now would otherwise be stored only to be discarded unfired.
        await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("after-failure")
        }
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(fired.values == ["after-failure"])
        #expect(session.outcome == .failed(snapshot))
    }

    @Test("Hooks do not survive the session they were registered for")
    func hooksAreDiscardedWithTheSession() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()
        let fired = LockedList<String>()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.registerCancellationHook(for: identity) {
            fired.append("first-session")
        }
        await gate.openGate()
        _ = await running
        // A second attempt, and a request for it: the first attempt's hook must not fire.
        let next = try await release.acceptedIngest(byteSeed: 3)
        async let second = harness.coordinator.analyze(next)
        let outcome = await second

        #expect(outcome.completed?.outcome.isCompleted == true)
        #expect(fired.values.isEmpty)
    }

    @Test("A hook token spells no discriminator")
    func hookTokensAreOpaque() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let token = await harness.coordinator.registerCancellationHook(
            for: AnalysisSessionIdentity(
                sessionID: PortValue.sessionID("session-secret"),
                generation: 7
            )
        ) {}

        #expect(token.description == "CancellationHookToken(opaque)")
        #expect(token.description.contains("session-secret") == false)
        #expect(token.description.contains("7") == false)
    }
}

// MARK: - Discarding late results by identity

@Suite("Late framework results are discarded by session and generation")
struct LateFrameworkResultAdmissionTests {

    @Test("A running attempt with no terminal admits its results")
    func aRunningAttemptAdmits() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let admission = await harness.coordinator.admitFrameworkResult(for: identity)
        let admitted = await harness.coordinator.admit(PortValue.logit(1.5), for: identity)
        await gate.openGate()
        _ = await running

        #expect(admission == .admitted)
        #expect(admission.isAdmitted)
        #expect(admission.standingOutcome == nil)
        #expect(admitted.value == PortValue.logit(1.5))
        #expect(admitted.discardedBecause == nil)
    }

    @Test("A result produced after cancellation is discarded, carrying the reason")
    func cancellationDiscardsLaterResults() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        // A calibrated label, produced by work that had already started. Requirement 15.7
        // says it can never become evidence, and the refusal is by recorded state rather
        // than by when it arrived.
        let evidence: PixelEvidence = .signalsConsistentWithAIGeneration
        let admitted = await harness.coordinator.admit(evidence, for: identity)
        let admission = await harness.coordinator.admitFrameworkResult(for: identity)
        await gate.openGate()
        _ = await running

        #expect(admitted.value == nil)
        #expect(admitted.discardedBecause == .discardedTerminalCommitted(.cancelled))
        #expect(admission.isAdmitted == false)
        #expect(admission.standingOutcome == .cancelled)
        #expect(admission.wasDiscardedByCancellation)
    }

    @Test("The same identifier at an earlier generation is discarded as stale")
    func anEarlierGenerationIsStale() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let session = PortValue.sessionID("session-0001")
        let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
        // The first attempt fails before inference, so it never reaches the rendezvous and
        // the second attempt is the one held open. Two attempts, one identifier.
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome([
                .fault(.analysis(.decodingError, stage: .inputValidation)),
                .success(
                    PortValue.validatedImage(
                        sessionID: session,
                        preprocessingContractID: contractID
                    )
                ),
            ]),
            sessionID: "session-0001",
            gate: gate
        )
        let first = try await release.acceptedIngest(sessionID: "session-0001")
        let second = try await release.acceptedIngest(sessionID: "session-0001", byteSeed: 2)

        let failed = try #require(await harness.coordinator.analyze(first).completed)
        async let running = harness.coordinator.analyze(second)
        await gate.waitUntilReached()
        let live = try #require(await harness.coordinator.activeIdentity())
        let stale = failed.identity
        let admission = await harness.coordinator.admitFrameworkResult(for: stale)
        let admitted = await harness.coordinator.admit(PortValue.logit(2.0), for: stale)
        let liveAdmission = await harness.coordinator.admitFrameworkResult(for: live)
        await gate.openGate()
        _ = await running

        // A released identifier can be bound again, so the identifier alone would let a call
        // still running from the first attempt look like a current one.
        #expect(live.sessionID == stale.sessionID)
        #expect(live.generation != stale.generation)
        #expect(admission == .discardedStaleIdentity(offered: stale))
        #expect(admitted.value == nil)
        #expect(liveAdmission == .admitted)
    }

    @Test("A result offered while the coordinator is idle is discarded")
    func anIdleCoordinatorAdmitsNothing() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()
        _ = await harness.coordinator.analyze(asset)

        let admission = await harness.coordinator.admitFrameworkResult(
            for: AnalysisSessionIdentity(sessionID: asset.sessionID, generation: 1)
        )

        #expect(admission == .discardedNoActiveSession)
        #expect(admission.standingOutcome == nil)
        #expect(admission.wasDiscardedByCancellation == false)
    }
}

// MARK: - Reason-specific cleanup

@Suite("A cancelled session is cleaned up under its own deadline")
struct SessionCancellationCleanupTests {

    @Test("Removal is audited against the cancellation deadline and leaves nothing")
    func cleanupUsesTheCancellationDeadline() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        let receipt = try #require(session.cleanup.receipt)
        // Requirement 11.15 names this deadline specifically, and a cancelled session is not
        // an error-terminated one.
        #expect(receipt.reason == .cancelled)
        #expect(receipt.reason != .errorTerminated)
        #expect(receipt.reason != .completed)
        #expect(receipt.deadline == release.lifecyclePolicy.deadline(for: .cancelled))
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
        // Nothing of the attempt survives it, so a retry inherits no state.
        #expect(await harness.coordinator.activeIdentity() == nil)
        #expect(await harness.coordinator.isCancellationRequested() == false)
        #expect(await harness.coordinator.committedTerminal() == nil)
    }

    @Test("A clean session follows a cancelled one under the same identifier")
    func aRetryAfterCancellationIsClean() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let first = try await release.acceptedIngest(sessionID: "session-0001")

        async let running = harness.coordinator.analyze(first)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        await gate.openGate()
        let cancelled = try #require(await running.completed)

        let second = try await release.acceptedIngest(sessionID: "session-0001", byteSeed: 2)
        let retried = try #require(await harness.coordinator.analyze(second).completed)

        #expect(cancelled.outcome == .cancelled)
        // The gate is already open, so the retry runs the whole pipeline. It inherits no
        // cancellation request and reaches its own completed terminal.
        #expect(retried.outcome.isCompleted)
        #expect(retried.identity.generation > cancelled.identity.generation)
        #expect(retried.evidenceReport != nil)
    }
}

// MARK: - Bounded-loop boundaries

@Suite("Bounded sampling loops stop at a cancellation boundary")
struct ResourceCheckpointCancellationTests {

    /// A main-application controller over the synthetic budget fixture.
    ///
    /// Built here rather than reused from `ResourceControllerTests` because that helper is
    /// private to its suite. No value in the budget is an approved release limit.
    private func makeController() throws -> (ResourceController, RecordingResourceGovernor) {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )
        return (controller, governor)
    }

    /// Samples two metrics and reports the fault, or `nil` when both read in budget.
    ///
    /// A named function rather than an inline `do`/`catch` so the port's typed fault is what
    /// the catch binds, instead of being widened inside a closure's inferred result type.
    private static func faultFromSampling(
        _ controller: ResourceController
    ) async -> AnalysisFault? {
        do {
            try await controller.checkpoint(
                .decodedPixelCount,
                .temporaryStorage,
                at: .preprocessing
            )
            return nil
        } catch {
            return error
        }
    }

    @Test("A cancelled sampling loop reports cancellation and samples nothing")
    func aCancelledCheckpointStopsAtTheFirstMetric() async throws {
        let (controller, governor) = try makeController()
        let held = BranchGate()

        // The rendezvous makes the ordering the test's: the task is cancelled while it
        // waits, so the loop is entered already cancelled rather than racing a cancel.
        let handle = Task<AnalysisFault?, Never> {
            await held.enter()
            return await Self.faultFromSampling(controller)
        }
        handle.cancel()
        await held.openGate()
        let fault = await handle.value

        #expect(fault == .cancelled)
        // Cancellation is not an Analysis Error and must never be presented as one.
        #expect(fault?.analysisError == nil)
        #expect(fault?.stage == nil)
        // It latches no breach, so a later within-limit reading is still answered honestly
        // rather than being overridden by a breach the controller never observed.
        #expect(await controller.currentBreach() == nil)
        #expect(await governor.calls().isEmpty)
        #expect(await controller.permits(.evidenceReport))
    }

    @Test("An uncancelled sampling loop still samples every named metric")
    func anUncancelledCheckpointIsUnchanged() async throws {
        let (controller, governor) = try makeController()

        try await controller.checkpoint(.decodedPixelCount, .temporaryStorage, at: .preprocessing)

        #expect(await governor.calls().count == 2)
        #expect(await controller.currentBreach() == nil)
    }
}

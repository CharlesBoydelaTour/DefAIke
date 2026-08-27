import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 10.1: the Analysis Coordinator actor and its monotonic state machine.
//
// Four questions, and they fail separately:
//
//   * **Does the ordered pipeline run, and only in that order?** Bundle binding, validation,
//     preprocessing, the two evidence branches, and one joined report. Every stage's input
//     is the previous stage's output, so what is worth asserting is the *nonoccurrences*: a
//     failure at one stage means no later port was ever called.
//   * **Is there exactly one terminal?** Requirements 11.17 and 11.18. Offering a second
//     one has to be refused rather than applied, and a failure has to carry one error and
//     no evidence.
//   * **Is arbitration causal?** The design's stage order decides which of several faults a
//     session reports, and the answer cannot depend on which branch returned first.
//   * **Is a retry clean?** Requirement 3.15: a new session after a failure inherits no
//     bytes, dimensions, task, error, or evidence.
//
// The release these tests run against is built by `CoordinatorRelease`, which runs the real
// startup gate; nothing in it is an approved release value and no test asserts that one is
// correct. Cooperative cancellation, framework hooks, and stale-callback suppression are
// task 10.5's and live in `SessionCancellationTests`; the assertions here about a terminal
// committed mid-flight are only about the commit winning, not about the request that raises
// it. The properties over terminal disjointness, retry isolation, cleanup, and
// resource limits are tasks 10.6 through 10.12; the actor, fault-schedule, and interruption
// integration matrix is task 10.13.

// MARK: - The ordered pipeline

@Suite("Analysis Coordinator runs the ordered pipeline")
struct AnalysisCoordinatorPipelineTests {

    @Test("A successful session commits one completed terminal with both source lanes")
    func successfulSessionCompletesWithBothLanes() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        let outcome = await harness.coordinator.analyze(asset)

        let session = try #require(outcome.completed)
        let report = try #require(session.evidenceReport)
        #expect(session.outcome.isCompleted)
        #expect(session.error == nil)
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        // A pixel-only composition resolves its provenance lane rather than leaving it
        // missing, and the unavailable state is what reaches the report.
        #expect(report.provenance == .unavailable(.validatorNotCompiledIntoRelease))
        #expect(report.combinedSummary == nil)
    }

    @Test("The report states the versions the session was bound to")
    func reportStatesBoundVersions() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        let report = try #require(
            await harness.coordinator.analyze(asset).completed?.evidenceReport
        )

        let components = harness.release.bundle.componentVersions
        #expect(report.binding.sessionID == asset.sessionID)
        #expect(report.binding.modelBundleID == harness.release.bundle.bundleID)
        #expect(report.binding.preprocessingContractID == components.preprocessingContract)
        #expect(report.binding.calibrationPolicyID == components.calibrationPolicy)
        // The evidence scope comes from the same bound snapshot the binding did, so the two
        // cannot describe different releases.
        #expect(report.scope.id == components.evidenceScope)
        #expect(report.bytePreservationStatus == asset.preservationStatus)
    }

    @Test("The report's binding and scope come from one bound snapshot")
    func bindingAndScopeCannotDisagree() async throws {
        // `EvidenceCoordinator` takes the binding and the scope as independent parameters and
        // validates only copy compatibility, and `AnalysisSessionBinding` carries no
        // evidence-scope identifier at all, so the pairing is checkable only where both come
        // from one source. That source is `BoundAnalysisSession`, which derives the scope from
        // the bundle's own `componentVersions.evidenceScope` — and the coordinator builds the
        // report from that one value rather than passing two.
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(release: release)
        let asset = try await release.acceptedIngest()
        let bound = try await release.binder().bind(accepting: asset)

        let report = try #require(
            await harness.coordinator.analyze(asset).completed?.evidenceReport
        )

        // The same snapshot an independent bind produces, field for field.
        #expect(report.binding == bound.binding)
        #expect(report.scope == bound.scope)
        #expect(report.scope.id == bound.bundle.componentVersions.evidenceScope)
    }

    @Test("Every stage runs once, in the design's order")
    func stagesRunOnceInOrder() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        _ = await harness.coordinator.analyze(asset)

        let recorder = harness.recorder
        #expect(recorder.callCount(of: .validate) == 1)
        #expect(recorder.callCount(of: .preprocess) == 1)
        #expect(recorder.callCount(of: .loadModel) == 1)
        #expect(recorder.callCount(of: .infer) == 1)
        #expect(recorder.callCount(of: .calibrate) == 1)
        #expect(recorder.allCalls(of: .validate, precede: .preprocess))
        #expect(recorder.allCalls(of: .preprocess, precede: .loadModel))
        #expect(recorder.allCalls(of: .loadModel, precede: .infer))
        #expect(recorder.allCalls(of: .infer, precede: .calibrate))
    }

    @Test("The bound bundle is read once for the session and never re-read per stage")
    func activePointerIsReadOnceForTheSession() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        _ = await harness.coordinator.analyze(asset)

        // One read at binding. Every later stage receives the snapshot's values, so a
        // rollback mid-session has nothing to change (Requirement 10.15).
        #expect(harness.recorder.callCount(of: .verifiedActiveBundle) == 1)
    }

    @Test("A pixel-only composition never invokes a provenance validator")
    func pixelOnlyCompositionInvokesNoValidator() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        _ = await harness.coordinator.analyze(asset)

        #expect(harness.recorder.didCall(.provenanceAnalyze) == false)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
    }

    @Test("The coordinator is idle again once a session ends")
    func coordinatorIsIdleAfterASession() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        _ = await harness.coordinator.analyze(asset)

        #expect(await harness.coordinator.activeIdentity() == nil)
        #expect(await harness.coordinator.currentStage() == nil)
        #expect(await harness.coordinator.committedTerminal() == nil)
        // The bound snapshot is released on the terminal path, so the identifier can be
        // bound again.
        #expect(await harness.binder.boundSessionCount == 0)
    }

    @Test("A terminal outcome selects its own cleanup deadline and removes the bytes")
    func terminalCleanupRunsUnderItsOwnDeadline() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.sessionID == asset.sessionID)
        #expect(receipt.reason == .completed)
        #expect(receipt.deadline == harness.release.lifecyclePolicy.deadline(for: .completed))
        #expect(receipt.removedObjectCount == 1)
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }
}

// MARK: - Failure terminals

@Suite("Analysis Coordinator failures carry one error and no evidence")
struct AnalysisCoordinatorFailureTests {

    /// Each stage's fault, the port that raises it, and the call that must not follow.
    ///
    /// One table rather than five near-identical tests, because the claim is the same at
    /// every stage: the reported category and stage are the port's own, and nothing
    /// downstream ran.
    @Test(
        "A stage fault ends the session with that stage's error and no later work",
        arguments: [
            (AnalysisError.decodingError, AnalysisStage.inputValidation, PortCallKind.preprocess),
            (.unsupportedMedia, .mediaClassification, .preprocess),
            (.resourceLimit, .inputValidation, .preprocess),
        ]
    )
    func validationFaultStopsBeforePreprocessing(
        error: AnalysisError,
        stage: AnalysisStage,
        forbidden: PortCallKind
    ) async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome(alwaysFailing: .analysis(error, stage: stage))
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        let failure = try #require(session.outcome.failure)
        #expect(failure.error == error)
        #expect(failure.stage == stage)
        #expect(session.evidenceReport == nil)
        #expect(harness.recorder.didCall(forbidden) == false)
        #expect(harness.recorder.didCall(.infer) == false)
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
    }

    @Test("A preprocessing fault stops before model load and inference")
    func preprocessingFaultStopsBeforeInference() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            prepared: StubOutcome(
                alwaysFailing: .analysis(.preprocessingError, stage: .preprocessing)
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .preprocessingError)
        #expect(session.outcome.failure?.stage == .preprocessing)
        #expect(harness.recorder.didCall(.loadModel) == false)
        #expect(harness.recorder.didCall(.infer) == false)
    }

    @Test("An inference fault produces no Pixel Evidence and no report")
    func inferenceFaultProducesNoEvidence() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            logit: StubOutcome(alwaysFailing: .analysis(.inferenceError, stage: .inference))
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .inferenceError)
        #expect(session.evidenceReport == nil)
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
    }

    @Test("A failure preserves the byte status and the recorded pre-orientation dimensions")
    func failurePreservesWhatWasAlreadyMeasured() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome(
                always: PortValue.validatedImage(
                    sessionID: PortValue.sessionID("session-0001"),
                    width: 1_024,
                    height: 768,
                    preprocessingContractID: CoordinatorSample.artifact(
                        CoordinatorSample.preprocessingContractID
                    )
                )
            ),
            logit: StubOutcome(
                alwaysFailing: .analysis(.invalidOutputError, stage: .outputValidation)
            )
        )
        let asset = try await release.acceptedIngest()

        let failure = try #require(
            await harness.coordinator.analyze(asset).completed?.outcome.failure
        )

        // Requirement 3.14: measured before the failure, so still reported afterwards.
        #expect(failure.bytePreservationStatus == asset.preservationStatus)
        #expect(failure.inputQuality?.decodedWidthBeforeOrientation == 1_024)
        #expect(failure.inputQuality?.decodedHeightBeforeOrientation == 768)
        #expect(failure.inputQuality?.shortEdgeBeforeOrientation == 768)
    }

    @Test("A failure before validation preserves the byte status with no dimensions")
    func earlyFailurePreservesOnlyWhatExists() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome(
                alwaysFailing: .analysis(.unsupportedStaticFormat, stage: .mediaClassification)
            )
        )
        let asset = try await release.acceptedIngest()

        let failure = try #require(
            await harness.coordinator.analyze(asset).completed?.outcome.failure
        )

        #expect(failure.bytePreservationStatus == asset.preservationStatus)
        // Never reconstructed, defaulted, or guessed: no decode happened.
        #expect(failure.inputQuality == nil)
    }

    @Test("A cancelled port fault commits the cancelled terminal, not a failure")
    func cancellationIsNotAFailureCategory() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            prepared: StubOutcome(alwaysFailing: .cancelled)
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        // Requirement 11.17: cancelled is its own terminal and is never presented as an
        // error category.
        #expect(session.outcome == .cancelled)
        #expect(session.error == nil)
        #expect(session.evidenceReport == nil)
        #expect(session.cleanup.receipt?.reason == .cancelled)
    }

    @Test("A model loaded from another bundle version never reaches inference")
    func aForeignLoadedModelNeverReachesInference() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            model: StubOutcome(
                always: CoordinatorSample.foreignLoadedModel(bundleID: "bundle.other")
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        // Requirement 4.1: inference executes the model from the bundle version bound to the
        // session, so a model from any other bundle is refused rather than run.
        #expect(session.error == .modelLoadError)
        #expect(session.outcome.failure?.stage == .modelLoad)
        #expect(harness.recorder.didCall(PortCallKind.infer) == false)
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
        #expect(session.evidenceReport == nil)
    }

    @Test("A loaded model whose shape matches the bound contract reaches inference")
    func aBoundModelShapeIsAccepted() async throws {
        // The complement of the shape refusal, which is structurally satisfied today:
        // `ModelInputContract` pins 384x384 unsigned 8-bit and `ModelChannelOrder` has one
        // member, so an accepted pair is the only representable one. The coordinator's guard
        // is kept as a fail-closed branch for a later vocabulary; what is testable now is
        // that a conforming model is not refused.
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(release: release)
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.outcome.isCompleted)
        #expect(harness.recorder.didCall(PortCallKind.infer))
    }

    @Test("A validated image stamped with another contract version is refused")
    func aDecodeUnderAnotherContractIsRefused() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome(
                always: PortValue.validatedImage(
                    sessionID: PortValue.sessionID("session-0001"),
                    preprocessingContractID: CoordinatorSample.artifact("contract.other")
                )
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .decodingError)
        #expect(session.outcome.failure?.stage == .inputValidation)
        #expect(harness.recorder.didCall(.preprocess) == false)
    }

    @Test("A decode belonging to another session never governs this one")
    func aForeignDecodeIsRefused() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome(
                always: PortValue.validatedImage(
                    sessionID: PortValue.sessionID("session-9999"),
                    preprocessingContractID: CoordinatorSample.artifact(
                        CoordinatorSample.preprocessingContractID
                    )
                )
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .decodingError)
        #expect(harness.recorder.didCall(.preprocess) == false)
    }
}

// MARK: - One terminal, compare-and-set

@Suite("Analysis Coordinator commits exactly one terminal")
struct AnalysisCoordinatorTerminalTests {

    @Test("A second offer is refused and the first outcome stands")
    func aSecondOfferIsRefused() async throws {
        var slot = TerminalCommitSlot()
        let report = try #require(
            EvidenceReport(
                binding: SessionSample.binding(),
                pixel: .noStrongSignalDetected,
                provenance: .unavailable(.validatorNotCompiledIntoRelease),
                combinedSummary: nil,
                apparentInconsistency: nil,
                bytePreservationStatus: .unknown,
                inputQuality: SessionSample.inputQuality,
                onDeviceProcessing: true,
                scope: SessionSample.scope
            )
        )

        let first = slot.claim(.completed(report))
        let second = slot.claim(.cancelled)
        let third = slot.claim(
            .failed(
                try #require(
                    AnalysisFailureSnapshot(
                        sessionID: PortValue.sessionID(),
                        error: .inferenceError,
                        stage: .inference,
                        bytePreservationStatus: nil,
                        inputQuality: nil
                    )
                )
            )
        )

        #expect(first == .committed(.completed(report)))
        #expect(second == .refusedAlreadyTerminal(.completed(report)))
        #expect(third == .refusedAlreadyTerminal(.completed(report)))
        // The three terminals cannot transition into one another, so the slot still holds
        // the first (Requirement 11.17).
        #expect(slot.committed == .completed(report))
    }

    @Test("Every refusal reports the same standing outcome the commit did")
    func refusalsReportTheStandingOutcome() {
        var slot = TerminalCommitSlot()
        let committed = slot.claim(.cancelled)
        let refused = slot.claim(.cancelled)

        #expect(committed.didCommit)
        #expect(refused.didCommit == false)
        // Committing twice cannot change the answer.
        #expect(committed.standingOutcome == refused.standingOutcome)
    }

    @Test("An unclaimed slot holds nothing")
    func unclaimedSlotIsEmpty() {
        let slot = TerminalCommitSlot()
        #expect(slot.committed == nil)
        #expect(slot.isTerminal == false)
    }

    @Test("A commit offered for another session attempt is refused by identity")
    func aStaleIdentityIsRefused() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let asset = try await harness.release.acceptedIngest()
        _ = await harness.coordinator.analyze(asset)

        // The session has ended, so a late result naming it has nowhere to land.
        let commit = await harness.coordinator.commitTerminal(
            .cancelled,
            for: AnalysisSessionIdentity(sessionID: asset.sessionID, generation: 1)
        )

        #expect(commit == .refusedNoActiveSession)
        #expect(commit.standingOutcome == nil)
    }

    @Test("A second analyze call while one session runs starts nothing")
    func aSecondSessionIsRefusedWhileOneRuns() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome(
                always: PortValue.validatedImage(
                    sessionID: PortValue.sessionID("session-0001"),
                    preprocessingContractID: CoordinatorSample.artifact(
                        CoordinatorSample.preprocessingContractID
                    )
                )
            ),
            prepared: StubOutcome(
                always: PortValue.modelInput(
                    sessionID: PortValue.sessionID("session-0001"),
                    preprocessingContractID: CoordinatorSample.artifact(
                        CoordinatorSample.preprocessingContractID
                    )
                )
            ),
            logit: StubOutcome(always: PortValue.logit(1.0)),
            gate: gate
        )
        let first = try await release.acceptedIngest(sessionID: "session-0001")
        let second = try await release.acceptedIngest(
            sessionID: "session-0002",
            byteSeed: 2
        )

        async let running = harness.coordinator.analyze(first)
        // Wait until the first session is suspended inside inference, then try to start a
        // second one on the same coordinator.
        await gate.waitUntilReached()
        let refused = await harness.coordinator.analyze(second)
        await gate.openGate()
        let completed = await running

        let identity = try #require(refused.refusedIdentity)
        #expect(identity.sessionID == first.sessionID)
        #expect(refused.completed == nil)
        #expect(completed.completed?.outcome.isCompleted == true)
        // The second selection never reached a port.
        #expect(harness.recorder.callCount(of: .validate) == 1)
    }

    @Test("A terminal committed mid-flight stops the remaining stages and stands")
    func aTerminalCommittedMidFlightStands() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        // The pixel branch is suspended inside inference, so a terminal can be committed
        // while the session is genuinely in flight. This is the seam a cancel action uses;
        // what is asserted here is only that the commit wins and the session stops.
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let commit = await harness.coordinator.commitTerminal(.cancelled, for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(commit.didCommit)
        // Requirement 11.17: the committed terminal is the only one, and the completed
        // outcome the pipeline would have produced never replaced it.
        #expect(session.outcome == .cancelled)
        #expect(session.evidenceReport == nil)
        #expect(session.error == nil)
        // Calibration and the provenance lane are past the re-check that found the terminal,
        // so no evidence was produced for a session that had already ended.
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
        #expect(harness.recorder.didCall(PortCallKind.provenanceAnalyze) == false)
        #expect(session.cleanup.receipt?.reason == .cancelled)
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("A completed report offered after a terminal stands is refused, not applied")
    func aLateCompletionCannotOverwriteATerminal() async throws {
        let release = try await CoordinatorRelease.build()
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let failure = try #require(
            AnalysisFailureSnapshot(
                sessionID: identity.sessionID,
                error: .resourceLimit,
                stage: .inference,
                bytePreservationStatus: asset.preservationStatus,
                inputQuality: nil
            )
        )
        _ = await harness.coordinator.commitTerminal(.failed(failure), for: identity)
        // A second offer for the same running attempt, before the pipeline resumes.
        let second = await harness.coordinator.commitTerminal(.cancelled, for: identity)
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(second == .refusedAlreadyTerminal(.failed(failure)))
        #expect(session.outcome == .failed(failure))
        #expect(session.error == .resourceLimit)
        #expect(session.evidenceReport == nil)
    }

    @Test("An identity spells only its generation, never its session identifier")
    func identityDescriptionCarriesNoSessionIdentifier() {
        let identity = AnalysisSessionIdentity(
            sessionID: PortValue.sessionID("session-secret"),
            generation: 7
        )

        #expect(identity.description.contains("session-secret") == false)
        #expect(identity.description.contains("7"))
    }

    @Test("Each session attempt gets a fresh, never-reused generation")
    func generationsAreMonotonic() async throws {
        let harness = try await CoordinatorHarness.pixelOnly()
        let first = try await harness.release.acceptedIngest(sessionID: "session-0001")
        let second = try await harness.release.acceptedIngest(
            sessionID: "session-0001",
            byteSeed: 2
        )

        let one = try #require(await harness.coordinator.analyze(first).completed)
        let two = try #require(await harness.coordinator.analyze(second).completed)

        // The same identifier, two attempts. Without the generation a result still running
        // from the first would look like a current one.
        #expect(one.identity.sessionID == two.identity.sessionID)
        #expect(one.identity.generation == 1)
        #expect(two.identity.generation == 2)
    }
}

// MARK: - Causal arbitration

@Suite("Fault arbitration follows causal stage order")
struct CausalFaultArbitrationTests {

    @Test("The ranking covers the whole stage vocabulary exactly once")
    func rankingIsTotalAndUnique() {
        let ordered = CausalFaultArbitration.causalStageOrder

        #expect(Set(ordered) == Set(AnalysisStage.allCases))
        #expect(ordered.count == AnalysisStage.allCases.count)
        #expect(Set(ordered.map(CausalFaultArbitration.causalRank(of:))).count == ordered.count)
        // The list and the switch agree, so neither can drift from the other.
        for (position, stage) in ordered.enumerated() {
            #expect(CausalFaultArbitration.causalRank(of: stage) == position)
        }
    }

    @Test("The eight stages the design enumerates keep the design's order")
    func designOrderIsPreserved() {
        let designOrder: [AnalysisStage] = [
            .handoffVerification,
            .mediaClassification,
            .inputValidation,
            .preprocessing,
            .modelLoad,
            .inference,
            .outputValidation,
            .calibration,
        ]

        for (earlier, later) in zip(designOrder, designOrder.dropFirst()) {
            #expect(CausalFaultArbitration.stage(earlier, precedes: later))
            #expect(CausalFaultArbitration.stage(later, precedes: earlier) == false)
        }
        // The two stages the design does not enumerate follow every one it does, and a lane
        // resolves before the lanes are joined.
        #expect(CausalFaultArbitration.stage(.calibration, precedes: .provenanceValidation))
        #expect(
            CausalFaultArbitration.stage(.provenanceValidation, precedes: .evidenceJoining)
        )
    }

    @Test("The causally earlier stage wins, whichever order the faults arrive in")
    func theEarlierStageWinsRegardlessOfOrder() {
        let early = AnalysisFault.analysis(.decodingError, stage: .inputValidation)
        let late = AnalysisFault.analysis(.calibrationInputError, stage: .calibration)

        #expect(CausalFaultArbitration.earliest(of: [early, late]) == early)
        #expect(CausalFaultArbitration.earliest(of: [late, early]) == early)
        #expect(CausalFaultArbitration.earlier(early, than: late) == early)
        #expect(CausalFaultArbitration.earlier(late, than: early) == early)
    }

    @Test("A concurrent branch fault never outranks the pixel branch's earlier stage")
    func aProvenanceBranchFaultLosesToAnEarlierPixelStage() {
        let pixel = AnalysisFault.analysis(.inferenceError, stage: .inference)
        let lane = AnalysisFault.analysis(.resourceLimit, stage: .provenanceValidation)

        // Wall-clock race order cannot change the user-visible category.
        #expect(CausalFaultArbitration.earliest(of: [pixel, lane]) == pixel)
        #expect(CausalFaultArbitration.earliest(of: [lane, pixel]) == pixel)
    }

    @Test("Arbitration is invariant under every permutation of distinct stages")
    func arbitrationIsPermutationInvariant() {
        let faults = CausalFaultArbitration.causalStageOrder.map {
            AnalysisFault.analysis(.resourceLimit, stage: $0)
        }
        let expected = AnalysisFault.analysis(.resourceLimit, stage: .handoffVerification)

        for _ in 0..<64 {
            #expect(CausalFaultArbitration.earliest(of: faults.shuffled()) == expected)
        }
    }

    @Test("Cancellation wins over every analysis fault, in either position")
    func cancellationDominates() {
        for stage in AnalysisStage.allCases {
            let fault = AnalysisFault.analysis(.resourceLimit, stage: stage)
            #expect(CausalFaultArbitration.earliest(of: [.cancelled, fault]) == .cancelled)
            #expect(CausalFaultArbitration.earliest(of: [fault, .cancelled]) == .cancelled)
        }
    }

    @Test("Two faults at the same stage keep the first offered")
    func equalStagesKeepTheFirst() {
        let first = AnalysisFault.analysis(.decodingError, stage: .inputValidation)
        let second = AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)

        #expect(CausalFaultArbitration.earliest(of: [first, second]) == first)
        #expect(CausalFaultArbitration.earliest(of: [second, first]) == second)
    }

    @Test("No faults is not a failure")
    func anEmptyListArbitratesToNothing() {
        #expect(CausalFaultArbitration.earliest(of: []) == nil)
    }

    @Test("One fault arbitrates to itself")
    func oneFaultIsItsOwnAnswer() {
        let fault = AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)
        #expect(CausalFaultArbitration.earliest(of: [fault]) == fault)
    }
}

// MARK: - Retry isolation

@Suite("A new session after a failure inherits nothing")
struct AnalysisCoordinatorRetryTests {

    @Test("A failed session is followed by a clean one under the same identifier")
    func aRetryUnderTheSameIdentifierIsClean() async throws {
        let release = try await CoordinatorRelease.build()
        // Fail once, then succeed: one coordinator, one identifier, two attempts.
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome([
                .fault(.analysis(.decodingError, stage: .inputValidation)),
                .success(
                    PortValue.validatedImage(
                        sessionID: PortValue.sessionID("session-0001"),
                        width: 900,
                        height: 640,
                        preprocessingContractID: CoordinatorSample.artifact(
                            CoordinatorSample.preprocessingContractID
                        )
                    )
                ),
            ])
        )
        let first = try await release.acceptedIngest(sessionID: "session-0001")
        let failed = try #require(await harness.coordinator.analyze(first).completed)
        #expect(failed.error == .decodingError)

        // Requirement 3.13: no application restart, and the identifier is bindable again
        // because the terminal path released it.
        let second = try await release.acceptedIngest(sessionID: "session-0001", byteSeed: 7)
        let retried = try #require(await harness.coordinator.analyze(second).completed)

        let report = try #require(retried.evidenceReport)
        // Requirement 3.15: no error category and no session data from the failed attempt.
        #expect(retried.error == nil)
        #expect(retried.outcome.failure == nil)
        #expect(retried.identity.generation == failed.identity.generation + 1)
        #expect(report.inputQuality.decodedWidthBeforeOrientation == 900)
        #expect(report.inputQuality.decodedHeightBeforeOrientation == 640)
        #expect(report.bytePreservationStatus == second.preservationStatus)
    }

    @Test("A failed session leaves no bound snapshot, no state, and no bytes behind")
    func aFailedSessionLeavesNothing() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            prepared: StubOutcome(
                alwaysFailing: .analysis(.preprocessingError, stage: .preprocessing)
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .preprocessingError)
        #expect(await harness.coordinator.activeIdentity() == nil)
        #expect(await harness.coordinator.currentStage() == nil)
        #expect(await harness.coordinator.committedTerminal() == nil)
        #expect(await harness.binder.boundSessionIDs.isEmpty)
        // The failure deadline governed the deletion, and the bytes are gone.
        #expect(session.cleanup.receipt?.reason == .errorTerminated)
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("A retry after a failure re-reads the active bundle rather than reusing one")
    func aRetryBindsAgain() async throws {
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome([
                .fault(.analysis(.resourceLimit, stage: .inputValidation)),
                .success(
                    PortValue.validatedImage(
                        sessionID: PortValue.sessionID("session-0001"),
                        preprocessingContractID: CoordinatorSample.artifact(
                            CoordinatorSample.preprocessingContractID
                        )
                    )
                ),
            ])
        )
        let first = try await release.acceptedIngest(sessionID: "session-0001")
        _ = await harness.coordinator.analyze(first)
        let second = try await release.acceptedIngest(sessionID: "session-0001", byteSeed: 3)
        _ = await harness.coordinator.analyze(second)

        // One read per attempt: the second session binds what is active when *its* input
        // was accepted, rather than inheriting the first attempt's snapshot.
        #expect(harness.recorder.callCount(of: .verifiedActiveBundle) == 2)
    }

    @Test("Three attempts in a row each end with their own terminal")
    func repeatedAttemptsEachEndOnce() async throws {
        let release = try await CoordinatorRelease.build()
        let validatedImage = PortValue.validatedImage(
            sessionID: PortValue.sessionID("session-0001"),
            preprocessingContractID: CoordinatorSample.artifact(
                CoordinatorSample.preprocessingContractID
            )
        )
        let harness = CoordinatorHarness.make(
            release: release,
            validated: StubOutcome([
                .fault(.analysis(.decodingError, stage: .inputValidation)),
                .success(validatedImage),
            ]),
            logit: StubOutcome([
                .fault(.analysis(.inferenceError, stage: .inference)),
                .success(PortValue.logit(2.0)),
            ])
        )

        var outcomes: [SessionTerminalOutcome] = []
        for attempt in 0..<3 {
            let asset = try await release.acceptedIngest(
                sessionID: "session-0001",
                byteSeed: UInt8(attempt + 1)
            )
            outcomes.append(
                try #require(await harness.coordinator.analyze(asset).completed?.outcome)
            )
        }

        #expect(outcomes.count == 3)
        #expect(outcomes[0].error == .decodingError)
        #expect(outcomes[1].error == .inferenceError)
        #expect(outcomes[2].isCompleted)
        // No attempt carried anything of another: each failure has exactly one error, and
        // the completed one carries no error at all.
        #expect(outcomes.filter(\.isCompleted).count == 1)
        #expect(outcomes.compactMap(\.error).count == 2)
    }
}

// MARK: - Execution policy

@Suite("The approved execution policy selects the branch execution")
struct AnalysisCoordinatorExecutionPolicyTests {

    @Test("An approved concurrent policy runs the branches concurrently")
    func anApprovedConcurrentPolicyIsUsed() async throws {
        let release = try await CoordinatorRelease.build(provenance: true, fusion: false)
        let harness = CoordinatorHarness.make(
            release: release,
            branchExecution: ApprovedEvidenceBranchExecution(
                execution: .concurrent,
                validationPlan: CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.branchExecution == .concurrent)
        #expect(session.outcome.isCompleted)
        #expect(harness.recorder.didCall(.provenanceAnalyze))
    }

    @Test("A serial policy runs the branches serially and still resolves both lanes")
    func aSerialPolicyResolvesBothLanes() async throws {
        let release = try await CoordinatorRelease.build(provenance: true, fusion: false)
        let harness = CoordinatorHarness.make(release: release)
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)
        let report = try #require(session.evidenceReport)

        #expect(session.branchExecution == .serial)
        #expect(report.provenance == .available(.absent))
        // Serially the pixel branch runs first, so its work precedes provenance analysis.
        #expect(harness.recorder.allCalls(of: .calibrate, precede: .provenanceAnalyze))
    }

    @Test("A policy recorded against another plan version degrades to serial")
    func aMismatchedPlanDegradesToSerial() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let harness = CoordinatorHarness.make(
            release: release,
            branchExecution: ApprovedEvidenceBranchExecution(
                execution: .concurrent,
                // Not the plan the bound Resource Budget cites, so this answer has not been
                // measured for the session's configuration.
                validationPlan: CoordinatorSample.artifact("plan.other")
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.branchExecution == .serial)
        #expect(session.outcome.isCompleted)
    }

    @Test("A serial pixel-branch failure never starts the provenance branch")
    func aSerialFailureSkipsTheSibling() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let harness = CoordinatorHarness.make(
            release: release,
            logit: StubOutcome(alwaysFailing: .analysis(.inferenceError, stage: .inference))
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .inferenceError)
        // Requirement 3.12: a failed session produces no Provenance Evidence.
        #expect(harness.recorder.didCall(.provenanceAnalyze) == false)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
    }

    @Test("Under the concurrent policy the provenance lane resolves while inference is open")
    func concurrentBranchesGenuinelyOverlap() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(
            release: release,
            branchExecution: ApprovedEvidenceBranchExecution(
                execution: .concurrent,
                validationPlan: CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
            ),
            gate: gate
        )
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        // The pixel branch is suspended inside inference. Under the serial policy the
        // provenance branch would not have started; under the approved concurrent policy it
        // has already run, which is the difference the policy actually buys.
        await gate.waitUntilReached()
        let laneResolvedWhileInferenceOpen = harness.recorder.didCall(
            PortCallKind.provenanceAnalyze
        )
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(laneResolvedWhileInferenceOpen)
        #expect(session.branchExecution == .concurrent)
        #expect(session.outcome.isCompleted)
    }

    @Test("Under the serial policy the provenance lane waits for the pixel branch")
    func serialBranchesDoNotOverlap() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let gate = BranchGate()
        let harness = CoordinatorHarness.make(release: release, gate: gate)
        let asset = try await release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await gate.waitUntilReached()
        let laneResolvedWhileInferenceOpen = harness.recorder.didCall(
            PortCallKind.provenanceAnalyze
        )
        await gate.openGate()
        let session = try #require(await running.completed)

        #expect(laneResolvedWhileInferenceOpen == false)
        #expect(session.branchExecution == .serial)
        #expect(harness.recorder.didCall(PortCallKind.provenanceAnalyze))
    }

    @Test("The recorded plan version decides whether a policy governs a session")
    func policyApplicabilityIsCheckedAgainstTheBoundPlan() async throws {
        let release = try await CoordinatorRelease.build()
        let bound = try await release.binder().bind(
            accepting: try await release.acceptedIngest()
        )
        let matching = ApprovedEvidenceBranchExecution(
            execution: .concurrent,
            validationPlan: bound.resourceBudget.validationPlan
        )
        let other = ApprovedEvidenceBranchExecution(
            execution: .concurrent,
            validationPlan: CoordinatorSample.artifact("plan.other")
        )

        #expect(matching.appliesTo(bound))
        #expect(matching.execution(for: bound) == .concurrent)
        #expect(other.appliesTo(bound) == false)
        #expect(other.execution(for: bound) == .serial)
    }

    @Test("A serial answer always names the plan it was recorded against")
    func theSerialConvenienceCarriesItsPlan() {
        let plan = CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
        let policy = ApprovedEvidenceBranchExecution.serial(validationPlan: plan)

        #expect(policy.execution == .serial)
        #expect(policy.validationPlan == plan)
    }
}

// MARK: - Conditional provenance and fusion

@Suite("Conditional provenance and fusion reach the report unchanged")
struct AnalysisCoordinatorEvidenceLaneTests {

    @Test("An enabled composition reports the validator's state on the exact bytes")
    func anEnabledLaneReportsItsState() async throws {
        let release = try await CoordinatorRelease.build(provenance: true)
        let harness = CoordinatorHarness.make(
            release: release,
            provenanceState: .invalid(
                InvaliditySummary(
                    provenancePolicyID: CoordinatorSample.artifact(
                        CoordinatorSample.provenancePolicyID
                    ),
                    category: .cryptographic,
                    explanationKey: CoordinatorSample.copyKey("copy.provenance.state.invalid")
                )
            )
        )
        let asset = try await release.acceptedIngest()

        let report = try #require(
            await harness.coordinator.analyze(asset).completed?.evidenceReport
        )

        // Both lanes survive verbatim: neither suppresses, overrides, or ranks the other
        // (Requirement 7.1).
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        #expect(report.provenance.evidence?.stateKey == .invalid)
    }

    @Test("An approved rule attaches a Combined Summary beside both unchanged lanes")
    func fusionAttachesASummaryBesideBothLanes() async throws {
        let release = try await CoordinatorRelease.build(provenance: true, fusion: true)
        let harness = CoordinatorHarness.make(release: release)
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)
        let report = try #require(session.evidenceReport)

        let summary = try #require(report.combinedSummary)
        #expect(summary.fusionRuleID == report.binding.fusionRuleID)
        #expect(session.fusionFault == nil)
        // Requirement 7.13: both immutable source-lane fields are retained alongside it.
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        #expect(report.provenance.isAvailable)
        #expect(harness.recorder.didCall(PortCallKind.fuse))
    }

    @Test("A rule the session was not bound to costs the summary and nothing else")
    func aMismatchedRuleOnlyCostsTheSummary() async throws {
        let release = try await CoordinatorRelease.build(provenance: true, fusion: true)
        let refusal = FusionFault.ruleNotBoundToSession(
            expected: CoordinatorSample.artifact(CoordinatorSample.fusionRuleID),
            found: CoordinatorSample.artifact("rule.other")
        )
        let harness = CoordinatorHarness.make(
            release: release,
            fuser: RefusingEvidenceFuser(refusing: refusal, recorder: release.recorder)
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)
        let report = try #require(session.evidenceReport)

        // Requirement 7.16: a rule that cannot be applied costs a sentence, not a session.
        #expect(session.outcome.isCompleted)
        #expect(report.combinedSummary == nil)
        #expect(session.fusionFault == refusal)
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        #expect(report.provenance.isAvailable)
        #expect(harness.recorder.didCall(PortCallKind.fuse))
    }

    @Test("A pixel-only composition omits the Combined Summary and consults no fuser")
    func anUnavailableLaneOmitsTheSummary() async throws {
        // A pixel-only release cannot even declare fusion: `ReleaseCapabilityManifest`
        // refuses `evidence-fusion` beside an unavailable provenance lane, which is
        // Requirement 7.10 enforced one layer down. So the reachable case is a session bound
        // to no rule, and a fuser is injected anyway to prove it is never consulted.
        let release = try await CoordinatorRelease.build()
        let harness = CoordinatorHarness.make(
            release: release,
            fuser: RefusingEvidenceFuser(
                refusing: .ruleNotBoundToSession(
                    expected: nil,
                    found: CoordinatorSample.artifact(CoordinatorSample.fusionRuleID)
                ),
                recorder: release.recorder
            )
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)
        let report = try #require(session.evidenceReport)

        #expect(report.provenance.isAvailable == false)
        #expect(report.binding.fusionRuleID == nil)
        #expect(report.combinedSummary == nil)
        #expect(session.fusionFault == nil)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
    }

    @Test("A classifier from an incompatible copy catalogue fails before any analysis")
    func anIncompatibleClassifierStopsBeforeValidation() async throws {
        let release = try await CoordinatorRelease.build()
        let classifier = try #require(
            ApparentInconsistencyClassifier(
                catalog: CopyCatalogSample.catalog(
                    compatibilityID: SessionSample.otherCopyCompatibilityID
                ),
                contradictoryCombinations: [
                    FusionLaneCombination.lookupKey(
                        pixel: .signalsConsistentWithAIGeneration,
                        provenance: .absent
                    )
                ]
            )
        )
        let harness = CoordinatorHarness.make(release: release, classifier: classifier)
        let asset = try await release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .modelLoadError)
        #expect(session.outcome.failure?.stage == .modelLoad)
        // No analysis work ran for a session that could never have produced a report.
        #expect(harness.recorder.didCall(.validate) == false)
        #expect(harness.recorder.didCall(.infer) == false)
    }
}

import DefAIkeDomain
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeSharedTransfer
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 12.4: the cross-module analysis flow, driven end to end.
//
// These are **example-based integration tests** over the span three sibling modules make and
// no one of them can. Every stage the task enumerates is driven by the real component that
// owns it, from a real Photos or claimed-Share ingest through to a real `AnalysisScreen`.
// `CrossModuleAnalysisFlowFixtures.swift` states exactly what is real and what is
// substituted, and why.
//
// ## What this file adds over what already exists
//
// Task 10.13's `CoordinatorIntegrationMatrixTests` already covers every error stage, branch
// ordering, retry, termination boundary, cleanup reason, resource breach, cancellation point,
// and late callback — but only inside `DefAIkeApplicationTests`' former dependency closure,
// which contained no ingest adapter and no presentation module. It reported three things as
// out of reach, and all three are reached here:
//
//   * the real ingest adapters, because `DefAIkeSharedTransfer` was not linked;
//   * actual extension staging, consent, and the atomic `staging → ready` promotion;
//   * the `handoff-error` cell, which it had to raise through the input-validation port
//     because the coordinator has no handoff port at all.
//
// So this file does not re-cover 10.13's axes. It covers the *joins*: ingest → coordinator,
// coordinator → presentation, and the two ends of one handoff. Where an assertion would
// restate 10.13, this file states the cross-module half of it instead — a cleanup deadline is
// asserted against material a *real ingest* wrote, and a terminal outcome is asserted against
// the *screen* it projects to.
//
// ## The four verification claims, and where each is made
//
// | Claim | Where |
// |---|---|
// | One report **or** one non-evidence terminal | `CrossModuleCompletedFlowTests`, `CrossModuleNonEvidenceTerminalTests`, `CrossModuleHandoffErrorTests` |
// | Immutable binding | `theReportsBindingIsTheReleasesActiveBundleSnapshot`, `theSessionBindingSurvivesALaterActivation` |
// | Exact route and status preservation | `CrossModuleRoutePreservationTests` |
// | No orphaned component output | `noComponentOutputSurvivesTheTerminal`, and the nonoccurrence arms of every failure suite |
//
// ## Nothing here is an approved release value, and no host result is device evidence
//
// The five cleanup deadlines, the budget limits, the payload sizes, the buffer sizes, the
// protection level, and every copy key are synthetic. No assertion below claims any of them
// is correct. `PlatformDataProtection.enforcesDataProtection` is `false` off iOS and no real
// file is created anywhere in this file, so **nothing here is Requirement 9.6 evidence**.

extension Tag {
    /// Task 12.4's cross-module flow scenarios.
    ///
    /// Declared in this file rather than in a shared namespace, for the same reason each
    /// property file declares its own: a shared namespace would be a merge point between
    /// files written independently of each other.
    @Tag static var crossModuleAnalysisFlow: Self
}

// MARK: - One completed flow

@Suite(
    "Cross-module flow: one real ingest reaches one report and one completed screen",
    .tags(.crossModuleAnalysisFlow)
)
@MainActor
struct CrossModuleCompletedFlowTests {

    @Test(
        "Every route and composition reaches exactly one Evidence Report",
        arguments: FlowRoute.allCases,
        FlowComposition.allCases
    )
    func aRouteReachesOneReportAndOneCompletedScreen(
        route: FlowRoute,
        composition: FlowComposition
    ) async throws {
        let flow = try await AnalysisFlow.make(composition)
        let run = try await flow.runFlow(route)
        let session = run.session

        // One terminal, and it is the completed one.
        #expect(session.outcome.isCompleted)
        #expect(!session.outcome.isCancelled)
        #expect(!session.outcome.isFailed)
        #expect(session.error == nil)
        #expect(session.identity.generation == 1)
        let report = try #require(session.evidenceReport)
        #expect(report.binding.sessionID == run.sessionID)

        // Both source lanes are present and independent (Requirements 7.1 through 7.3).
        #expect(report.pixel == .signalsConsistentWithAIGeneration)
        #expect(report.provenance.isAvailable == composition.enablesProvenance)
        #expect((report.combinedSummary != nil) == composition.enablesFusion)
        if composition.enablesFusion {
            let summary = try #require(report.combinedSummary)
            #expect(summary.fusionRuleID == report.binding.fusionRuleID)
        }

        // Every stage the flow claims to have driven actually ran, and the two
        // capability-conditional ones ran exactly when the composition enables them.
        let kinds = flow.recorder.callKinds
        #expect(kinds.contains(.validate))
        #expect(kinds.contains(.preprocess))
        #expect(kinds.contains(.loadModel))
        #expect(kinds.contains(.infer))
        #expect(kinds.contains(.calibrate))
        #expect(kinds.contains(.provenanceAnalyze) == composition.enablesProvenance)
        #expect(kinds.contains(.fuse) == composition.enablesFusion)
        #expect(flow.recorder.allCalls(of: .validate, precede: .infer))

        // The presentation half: one completed screen, both cards, and no error surface.
        let copy = try await flow.copyBinding(for: run.asset)
        let screen = try flow.project(
            session,
            copy: copy,
            onto: AnalysisViewStateProjector()
        ).screen
        #expect(screen.family == .completed)
        #expect(screen.evidenceReport == report)
        #expect(screen.analysisError == nil)
        #expect(screen.workProgress == nil)
        #expect(screen.cancellation == nil)
        #expect(screen.recovery == .selectAnotherImage)
        #expect(screen.sessionID == run.sessionID)

        let completed = try #require(screen.completedScreen)
        #expect(completed.pixel.evidence == report.pixel)
        #expect(completed.pixel.fixedLabelText.label == report.pixel.labelKey)
        #expect(completed.pixel.labelCopy.catalogID == copy.catalogID)
        #expect(completed.provenance.stateCopy.catalogID == copy.catalogID)
        #expect((completed.combinedSummary != nil) == composition.enablesFusion)
    }

    @Test(
        "The report's binding is the release's active bundle snapshot for that session",
        arguments: FlowRoute.allCases
    )
    func theReportsBindingIsTheReleasesActiveBundleSnapshot(route: FlowRoute) async throws {
        let flow = try await AnalysisFlow.make()
        let run = try await flow.runFlow(route)
        let report = try #require(run.session.evidenceReport)

        // The independently bound snapshot the presentation side uses is exactly the binding
        // the report carries. That is what makes the copy binding the non-evidence arms build
        // a reproduction rather than an invention.
        let independent = try await flow.presentationBinder.bind(accepting: run.asset)
        #expect(independent.binding == report.binding)
        #expect(report.binding.modelBundleID == flow.release.bundle.bundleID)
        #expect(
            report.binding.modelBundleIntegrity.activationReceiptID
                == flow.release.bundle.integrity.activationReceiptID
        )
        #expect(report.binding.capabilityManifestID == flow.configuration.capabilityManifest.id)
        #expect(report.binding.provenancePolicyID == nil)
        #expect(report.binding.fusionRuleID == nil)
    }

    @Test("A bundle activated mid-session cannot change the session it did not begin")
    func theSessionBindingSurvivesALaterActivation() async throws {
        // The gate holds the session open inside inference, which is after binding, so the
        // activation below genuinely lands while one session is running.
        let flow = try await AnalysisFlow.make(gateAt: .inference)
        let asset = try await flow.acceptedIngest(.photos)
        let boundBefore = flow.release.bundle

        let task = try #require(await flow.coordinator.startAnalysis(of: asset))
        await flow.harness.gate.waitUntilReached()

        // A second activation of the same bundle identity at a later generation. The
        // identifier is unchanged and the activation receipt is not, so "the session kept the
        // snapshot it took" is a claim a wrong answer can fail.
        let reactivated = CoordinatorSample.boundBundle(generation: 2)
        #expect(
            reactivated.integrity.activationReceiptID != boundBefore.integrity.activationReceiptID
        )
        await flow.release.bundles.installAndActivate(reactivated)
        await flow.harness.gate.openGate()

        let session = try #require(await task.value.completed)
        let report = try #require(session.evidenceReport)
        #expect(
            report.binding.modelBundleIntegrity.activationReceiptID
                == boundBefore.integrity.activationReceiptID
        )
        #expect(
            report.binding.modelBundleIntegrity.activationReceiptID
                != reactivated.integrity.activationReceiptID
        )
    }

    @Test(
        "The terminal leaves no component's output behind, on either route",
        arguments: FlowRoute.allCases
    )
    func noComponentOutputSurvivesTheTerminal(route: FlowRoute) async throws {
        let flow = try await AnalysisFlow.make(.provenanceAndFusion)
        let asset = try await flow.acceptedIngest(route)

        // The ingest really wrote something, so "nothing is left" is not vacuously true.
        let objectsAfterIngest = await flow.sessionObjectCount(asset.sessionID)
        #expect(objectsAfterIngest == 1)
        let session = try #require(await flow.coordinator.analyze(asset).completed)

        // The session's own material is gone, under the deadline its committed outcome
        // selects.
        let objectsAfterTerminal = await flow.sessionObjectCount(asset.sessionID)
        #expect(objectsAfterTerminal == 0)
        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.sessionID == asset.sessionID)
        #expect(receipt.reason == .completed)
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: .completed))
        #expect(receipt.removedObjectCount == 1)

        // Nothing partial is left anywhere, and the binder released its snapshot so the
        // identifier can be bound again for a clean retry.
        let unfinalized = await flow.sessions.unfinalizedKeys
        #expect(unfinalized.isEmpty)
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
        let boundCount = await flow.harness.binder.boundSessionCount
        #expect(boundCount == 0)

        // The App Group container is the Share route's own orphan risk. A verified claim
        // releases it, and a Photos session never wrote there at all.
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
        let appGroupUnfinalized = await flow.appGroupObjects.unfinalizedKeys
        #expect(appGroupUnfinalized.isEmpty)
        let outstanding = await flow.extensionGovernor.outstandingReservations()
        #expect(outstanding.isEmpty)
    }

    @Test("A second ingest cannot overlap a running session, and runs cleanly after")
    func aSecondIngestCannotOverlapARunningSession() async throws {
        let flow = try await AnalysisFlow.make(gateAt: .inference)
        let first = try await flow.acceptedIngest(.photos, sessionID: "session-0001")
        let task = try #require(await flow.coordinator.startAnalysis(of: first))
        await flow.harness.gate.waitUntilReached()

        // A real second ingest, on the other route, while the first session is suspended. It
        // creates its own session — ingest is not gated by the coordinator — and the
        // coordinator refuses to analyze it without touching the running one.
        let second = try await flow.acceptedIngest(.claimedShare, sessionID: "session-0002")
        let refused = await flow.coordinator.analyze(second)
        let refusedIdentity = try #require(refused.refusedIdentity)
        #expect(refusedIdentity.sessionID == first.sessionID)
        #expect(refused.completed == nil)

        await flow.harness.gate.openGate()
        let firstSession = try #require(await task.value.completed)
        #expect(firstSession.outcome.isCompleted)
        #expect(firstSession.identity.generation == 1)

        // The refused ingest's bytes were never analyzed and never deleted by a terminal, so
        // they are exactly what the next start sweeps as abandoned.
        let orphaned = await flow.sessionObjectCount(second.sessionID)
        #expect(orphaned == 1)
    }
}

// MARK: - Route and status preservation

@Suite(
    "Cross-module flow: what each route records, and what survives into the report",
    .tags(.crossModuleAnalysisFlow)
)
struct CrossModuleRoutePreservationTests {

    @Test(
        "Each route records exactly its own route on the accepted ingest",
        arguments: FlowRoute.allCases
    )
    func theAcceptedIngestRecordsExactlyOneRoute(route: FlowRoute) async throws {
        let flow = try await AnalysisFlow.make()
        let asset = try await flow.acceptedIngest(route)
        #expect(asset.route == route.recordedRoute)
    }

    @Test(
        "The conservative status the route derived is the status the report shows",
        arguments: FlowRoute.allCases
    )
    func theReportsStatusIsTheStatusTheRouteRecorded(route: FlowRoute) async throws {
        let flow = try await AnalysisFlow.make()
        let run = try await flow.runFlow(route)

        // Neither seam declares originality, so the most conservative status is the only one
        // either route can record (Requirements 2.9 through 2.11).
        #expect(run.asset.preservationBasis == .providerDeclaredCurrentRepresentationOnly)
        #expect(run.asset.preservationStatus == .unknown)

        let report = try #require(run.session.evidenceReport)
        #expect(report.bytePreservationStatus == run.asset.preservationStatus)
    }

    @Test("An untyped representation records the weaker basis and the same status")
    func anUntypedRepresentationRecordsTheWeakerBasis() async throws {
        let flow = try await AnalysisFlow.make()
        let outcome = await flow.ingestPhotos(form: .untypedFileRepresentation)
        let asset = try #require(outcome.acceptedIngest)
        #expect(asset.preservationBasis == .preservationHistoryNotEstablished)
        #expect(asset.preservationStatus == .unknown)
    }

    @Test("The published ticket's status and digest are what the claimed session analyzes")
    func theTicketsStatusAndDigestCrossTheHandoffUnchanged() async throws {
        let flow = try await AnalysisFlow.make()
        let bytes = FlowSample.payload()
        guard case let .published(published) = try await flow.publishShareHandoff(bytes: bytes)
        else {
            throw FlowSetupFailure.noPublishedHandoff
        }
        let ticket = published.ticket
        let resumed = try #require(await flow.claimShareHandoff().resumedSession)

        // The same session, the same status, the same basis, and a digest this process
        // recomputed over the bytes that reached its own storage.
        #expect(resumed.sessionID == ticket.sessionID)
        #expect(resumed.asset.preservationStatus == ticket.preservationStatus)
        #expect(resumed.asset.preservationBasis == ticket.preservationBasis)
        #expect(resumed.asset.byteCount == ticket.byteCount)
        #expect(resumed.asset.sha256 == ticket.sha256)
        #expect(resumed.asset.contentTypeHint == ticket.contentTypeHint)
        #expect(resumed.asset.route == .shareExtension)

        // The bundle was bound only after verification, and it is the release's active one.
        #expect(resumed.bundle.bundleID == flow.release.bundle.bundleID)

        let session = try #require(await flow.coordinator.analyze(resumed.asset).completed)
        let report = try #require(session.evidenceReport)
        #expect(report.bytePreservationStatus == ticket.preservationStatus)
    }

    // A recorded gap, pinned as the behaviour actually is.
    //
    // The route is recorded on the accepted ingest, and Requirement 2.8 is satisfied there. It
    // is *not* carried into the Evidence Report: `EvidenceReport` has no route field,
    // `AnalysisSessionBinding` has none either, and the only presentation value that carries
    // an `InputRoute` is `ImportAttemptSnapshot`, which belongs to the importing screen and is
    // gone by the time a terminal exists. So a completed session's route is unobservable from
    // its report or its screen.
    //
    // Reported, not fixed. Requirement 8.12's disclosure list does not name the route, so this
    // is a traceability gap rather than a requirement violation, and adding a field to an
    // immutable domain value is outside this task.
    @Test("The route is absent from the Evidence Report, so two routes report identically")
    func theRouteIsAbsentFromTheReport() async throws {
        let photosFlow = try await AnalysisFlow.make()
        let shareFlow = try await AnalysisFlow.make()
        let bytes = FlowSample.payload()

        let photos = try await photosFlow.runFlow(.photos, bytes: bytes)
        let share = try await shareFlow.runFlow(.claimedShare, bytes: bytes)
        let photosReport = try #require(photos.session.evidenceReport)
        let shareReport = try #require(share.session.evidenceReport)

        // The two accepted ingests differ in exactly one observable: the recorded route.
        #expect(photos.asset.route != share.asset.route)
        #expect(photos.sessionID == share.sessionID)
        #expect(photosReport == shareReport)

        // And no member of the report is an input route, by name or by type.
        let labels = Mirror(reflecting: photosReport).children.compactMap(\.label)
        let hasRouteLabel = labels.contains("route")
        #expect(!hasRouteLabel)
        let routeValued = Mirror(reflecting: photosReport).children
            .filter { $0.value is InputRoute }
        #expect(routeValued.isEmpty)
    }

    @Test("Byte-for-byte identical inputs on the two routes retain identical bytes")
    func bothRoutesRetainTheSameBytes() async throws {
        let photosFlow = try await AnalysisFlow.make()
        let shareFlow = try await AnalysisFlow.make()
        let bytes = FlowSample.payload(count: 300, seed: 7)

        let photos = try await photosFlow.acceptedIngest(.photos, bytes: bytes)
        let share = try await shareFlow.acceptedIngest(.claimedShare, bytes: bytes)

        #expect(photos.byteCount == UInt64(bytes.count))
        #expect(share.byteCount == photos.byteCount)
        #expect(share.sha256 == photos.sha256)
        #expect(share.preservationStatus == photos.preservationStatus)
        #expect(share.preservationBasis == photos.preservationBasis)

        // The retained objects hold the host's bytes, unchanged, on both routes.
        let photosBytes = try #require(
            await photosFlow.sessions.finalizedBytes(photos.handle.storageKey)
        )
        let shareBytes = try #require(
            await shareFlow.sessions.finalizedBytes(share.handle.storageKey)
        )
        #expect(photosBytes == bytes)
        #expect(shareBytes == bytes)
    }
}

// MARK: - Non-evidence terminals

/// One fault the flow can raise after ingest, at the port that raises it.
///
/// Five cells, one per stage the pipeline reaches between an accepted ingest and the join. The
/// set is deliberately not every `AnalysisError`: the categories reachable only before or
/// outside this span — `unsupported-media`, `unsupported-static-format`, `resource-limit`, and
/// `handoff-error` — are covered by their own suites, and 10.13 already drives all ten
/// categories through the coordinator.
struct FlowFaultCell: Sendable, CustomStringConvertible {
    let stage: AnalysisStage
    let error: AnalysisError

    /// Whether the fault lands after validation recorded the quality record.
    let preservesInputQuality: Bool

    var description: String { "\(stage.rawValue)/\(error.rawValue)" }

    var fault: AnalysisFault { .analysis(error, stage: stage) }

    static let all: [FlowFaultCell] = [
        FlowFaultCell(
            stage: .inputValidation,
            error: .decodingError,
            preservesInputQuality: false
        ),
        FlowFaultCell(
            stage: .preprocessing,
            error: .preprocessingError,
            preservesInputQuality: true
        ),
        FlowFaultCell(stage: .modelLoad, error: .modelLoadError, preservesInputQuality: true),
        FlowFaultCell(stage: .inference, error: .inferenceError, preservesInputQuality: true),
        FlowFaultCell(
            stage: .calibration,
            error: .calibrationInputError,
            preservesInputQuality: true
        ),
    ]

    /// A flow whose pipeline raises this cell's fault every time.
    func flow(
        _ composition: FlowComposition = .provenanceAndFusion
    ) async throws -> AnalysisFlow {
        switch stage {
        case .inputValidation:
            return try await AnalysisFlow.make(
                composition,
                validated: StubOutcome(alwaysFailing: fault)
            )
        case .preprocessing:
            return try await AnalysisFlow.make(
                composition,
                prepared: StubOutcome(alwaysFailing: fault)
            )
        case .modelLoad:
            return try await AnalysisFlow.make(
                composition,
                model: StubOutcome(alwaysFailing: fault)
            )
        case .inference:
            return try await AnalysisFlow.make(
                composition,
                logit: StubOutcome(alwaysFailing: fault)
            )
        default:
            return try await AnalysisFlow.make(
                composition,
                evidence: StubOutcome(alwaysFailing: fault)
            )
        }
    }

    /// A flow whose pipeline raises this cell's fault once and then succeeds.
    ///
    /// Built over an explicitly constructed release because the model-load cell's success
    /// value is *this release's* bundle, which cannot be named before the release exists.
    func flowThenSucceeding(
        _ composition: FlowComposition = .pixelOnly
    ) async throws -> AnalysisFlow {
        let release = try await CoordinatorRelease.build(
            provenance: composition.enablesProvenance,
            fusion: composition.enablesFusion
        )
        switch stage {
        case .inputValidation:
            return await AnalysisFlow.make(
                over: release,
                composition: composition,
                validated: StubOutcome([
                    .fault(fault), .success(FlowSuccess.validatedImage()),
                ])
            )
        case .preprocessing:
            return await AnalysisFlow.make(
                over: release,
                composition: composition,
                prepared: StubOutcome([.fault(fault), .success(FlowSuccess.modelInput())])
            )
        case .modelLoad:
            return await AnalysisFlow.make(
                over: release,
                composition: composition,
                model: StubOutcome([
                    .fault(fault),
                    .success(CoordinatorSample.loadedModel(bundle: release.bundle)),
                ])
            )
        case .inference:
            return await AnalysisFlow.make(
                over: release,
                composition: composition,
                logit: StubOutcome([.fault(fault), .success(PortValue.logit(1.5))])
            )
        default:
            return await AnalysisFlow.make(
                over: release,
                composition: composition,
                evidence: StubOutcome([
                    .fault(fault), .success(.signalsConsistentWithAIGeneration),
                ])
            )
        }
    }
}

@Suite(
    "Cross-module flow: a fault after ingest ends one session with one error and no report",
    .tags(.crossModuleAnalysisFlow)
)
@MainActor
struct CrossModuleNonEvidenceTerminalTests {

    @Test(
        "Every post-ingest fault commits exactly one error and reaches the error screen",
        arguments: FlowFaultCell.all,
        FlowRoute.allCases
    )
    func aFaultAfterIngestCommitsOneErrorAndNoReport(
        cell: FlowFaultCell,
        route: FlowRoute
    ) async throws {
        let flow = try await cell.flow()
        let asset = try await flow.acceptedIngest(route)
        let session = try #require(await flow.coordinator.analyze(asset).completed)

        // One terminal, and it is the error one.
        #expect(session.outcome.isFailed)
        #expect(!session.outcome.isCompleted)
        #expect(!session.outcome.isCancelled)
        #expect(session.evidenceReport == nil)
        #expect(session.error == cell.error)
        let failure = try #require(session.outcome.failure)
        #expect(failure.sessionID == asset.sessionID)
        #expect(failure.stage == cell.stage)

        // What was measured before the failure survives it (Requirement 3.14).
        #expect(failure.bytePreservationStatus == asset.preservationStatus)
        #expect((failure.inputQuality != nil) == cell.preservesInputQuality)

        // No summary for a session that failed (Requirement 3.12).
        #expect(!flow.recorder.didCall(PortCallKind.fuse))

        // The material is gone, under the error terminal's own deadline.
        let remaining = await flow.sessionObjectCount(asset.sessionID)
        #expect(remaining == 0)
        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.reason == .errorTerminated)
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: .errorTerminated))
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)

        // The presentation half: the error family, one category, and both preserved values
        // carried through unchanged.
        let copy = try await flow.copyBinding(for: asset)
        let screen = try flow.project(
            session,
            copy: copy,
            onto: AnalysisViewStateProjector()
        ).screen
        #expect(screen.family == .error)
        #expect(screen.analysisError == cell.error)
        #expect(screen.evidenceReport == nil)
        #expect(screen.workProgress == nil)
        #expect(screen.recovery == .selectAnotherImage)
        let errorScreen = try #require(screen.errorScreen)
        #expect(errorScreen.bytePreservationStatus == asset.preservationStatus)
        #expect((errorScreen.inputQuality != nil) == cell.preservesInputQuality)
        #expect(errorScreen.presentation.recoveryCopy.catalogID == copy.catalogID)
    }

    @Test(
        "A cancellation at each pipeline suspension ends the flow cancelled, with no report",
        arguments: PipelineGatePoint.allCases
    )
    func aCancellationAtEverySuspensionEndsTheFlowCancelled(
        point: PipelineGatePoint
    ) async throws {
        // Provenance is enabled so the provenance suspension exists at all.
        let flow = try await AnalysisFlow.make(.provenanceEnabled, gateAt: point)
        let asset = try await flow.acceptedIngest(.photos)
        let copy = try await flow.copyBinding(for: asset)
        let task = try #require(await flow.coordinator.startAnalysis(of: asset))
        await flow.harness.gate.waitUntilReached()

        let identity = try #require(await flow.coordinator.activeIdentity())
        let request = await flow.coordinator.requestCancellation(for: identity)
        #expect(request.commit.didCommit)
        await flow.harness.gate.openGate()

        let session = try #require(await task.value.completed)
        #expect(session.outcome.isCancelled)
        #expect(session.evidenceReport == nil)
        #expect(session.error == nil)
        let remaining = await flow.sessionObjectCount(asset.sessionID)
        #expect(remaining == 0)
        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.reason == .cancelled)
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: .cancelled))

        let screen = try flow.project(
            session,
            copy: copy,
            onto: AnalysisViewStateProjector()
        ).screen
        #expect(screen.family == .cancelled)
        #expect(screen.analysisError == nil)
        #expect(screen.evidenceReport == nil)
        #expect(screen.recovery == .selectAnotherImage)
    }

    @Test("A cancelled claimed-Share session commits the cancelled terminal too")
    func aCancelledClaimedShareSessionIsCancelled() async throws {
        let flow = try await AnalysisFlow.make(gateAt: .inference)
        let asset = try await flow.acceptedIngest(.claimedShare)
        let task = try #require(await flow.coordinator.startAnalysis(of: asset))
        await flow.harness.gate.waitUntilReached()
        let identity = try #require(await flow.coordinator.activeIdentity())
        await flow.coordinator.requestCancellation(for: identity)
        await flow.harness.gate.openGate()

        let session = try #require(await task.value.completed)
        #expect(session.outcome.isCancelled)
        #expect(session.evidenceReport == nil)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
        let remaining = await flow.sessionObjectCount(asset.sessionID)
        #expect(remaining == 0)
    }
}

// MARK: - The handoff-error cell

@Suite(
    "Cross-module flow: a handoff that does not verify ends its own pending session",
    .tags(.crossModuleAnalysisFlow)
)
struct CrossModuleHandoffErrorTests {

    /// Publishes one handoff and replaces its payload's bytes, leaving the ticket alone.
    ///
    /// The substitution is installed against the ready slot's own `storageKey`, which is the
    /// finalized payload object, and the manifest is deliberately left untouched: a slot whose
    /// *record* cannot be read is an unusable slot that names no session and is discarded,
    /// which is a different outcome from the one this arm is about.
    private func publishAndCorrupt(
        _ flow: AnalysisFlow
    ) async throws -> ShareTransferTicket {
        guard case let .published(published) = try await flow.publishShareHandoff(
            bytes: FlowSample.payload()
        ) else {
            throw FlowSetupFailure.noPublishedHandoff
        }
        let slot = try await flow.transfers.readySlotState()
        let ready = try #require(slot.publishedTransfer)

        // The published slot holds the payload and its record, and nothing else. Asserted so
        // the substitution below is known to be hitting the payload.
        let readyObjects = await flow.appGroupObjects.keys(
            in: .transfer(published.ticket.transferID, .ready)
        )
        #expect(readyObjects.count == 2)
        #expect(readyObjects.contains(ready.storageKey))

        // Same length, different content. Every check that does not read the payload passes,
        // the recopy completes, and the digest the app-private store computed over what
        // actually arrived is the thing that disagrees.
        flow.appGroup.substituteRead(FlowSample.payload(seed: 99), for: ready.storageKey)
        return published.ticket
    }

    @Test("A published payload whose bytes changed fails the same session with handoff-error")
    func aCorruptedPayloadFailsTheSameSessionWithHandoffError() async throws {
        let flow = try await AnalysisFlow.make()
        let ticket = try await publishAndCorrupt(flow)

        let outcome = await flow.claimShareHandoff()
        let termination = try #require(outcome.termination)
        #expect(termination.error == .handoffError)
        #expect(termination.stage == .handoffVerification)
        // The session that ends is the one the publication created (Requirements 2.19, 11.13).
        #expect(termination.sessionID == ticket.sessionID)
        #expect(outcome.resumedSession == nil)

        // Nothing downstream of the handoff ran, and the ordering is structural: the bundle
        // port is unreachable until the claim returned an accepted ingest.
        #expect(!flow.recorder.didCall(PortCallKind.verifiedActiveBundle))
        #expect(!flow.recorder.didCall(PortCallKind.validate))
        #expect(!flow.recorder.didCall(PortCallKind.preprocess))
        #expect(!flow.recorder.didCall(PortCallKind.infer))
        let active = await flow.coordinator.activeIdentity()
        #expect(active == nil)

        // Both namespaces are emptied: the App Group states and the partial session copy.
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
        let sessionObjects = await flow.sessionObjectCount(ticket.sessionID)
        #expect(sessionObjects == 0)
    }

    @Test("The fact that disagreed is the recomputed digest, not the ticketed length")
    func theRecomputedDigestIsWhatDisagrees() async throws {
        let flow = try await AnalysisFlow.make()
        let ticket = try await publishAndCorrupt(flow)

        // The adapter's own surface, which names the fact rather than the category. A digest
        // mismatch is only reachable *after* the recopy completed, so this also establishes
        // that the failure is the second measurement disagreeing rather than an earlier check
        // refusing.
        let outcome = await flow.claimAdapter.attemptClaim(
            claimingBuildID: flow.context.device.appBuild
        )
        let failed = try #require(outcome.failedHandoff)
        #expect(failed.sessionID == ticket.sessionID)
        #expect(failed.transferID == ticket.transferID)
        #expect(failed.failure == .mismatch(.digest))
        #expect(failed.fault == .analysis(.handoffError, stage: .handoffVerification))

        // The recopy's partial object is gone with it.
        let sessionObjects = await flow.sessionObjectCount(ticket.sessionID)
        #expect(sessionObjects == 0)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
    }

    @Test("A ticket staged by another build is refused before a byte is recopied")
    func aTicketFromAnotherBuildIsRefusedBeforeTheRecopy() async throws {
        let flow = try await AnalysisFlow.make()

        // A store that stamps a build identity this app is not. Two installed compositions
        // share no App Group by design, so reaching this means the container held a foreign
        // ticket; it costs nothing to refuse, and this arm shows that it costs nothing.
        let foreignBuild = PortValue.appBuildID("build-other-composition")
        #expect(foreignBuild != flow.context.device.appBuild)
        let foreignStore = SharedTransferStore(
            store: flow.appGroup,
            lifecyclePolicy: flow.configuration.lifecyclePolicy,
            extensionPolicy: flow.configuration.extensionExecutionPolicy,
            buildID: foreignBuild,
            clock: flow.release.clock,
            chunkSizeInBytes: 64
        )
        guard let extensionIngest = ShareExtensionIngestCoordinator(
            access: FlowSharedItemProvider(bytes: FlowSample.payload()),
            consentPresenter: FlowConsentPresenter(.confirm),
            transfers: foreignStore,
            governor: flow.extensionGovernor,
            budget: flow.configuration.resourceBudgets.shareExtension,
            instruction: FlowSample.openInstruction,
            candidateSessions: FlowCandidateSessions("session-0001")
        ) else {
            throw FlowSetupFailure.bindingUnavailable
        }
        let provider = try #require(
            SharedItemProvider(
                token: ProviderToken(rawValue: 1),
                itemCount: 1,
                contentTypeHint: Fixture.contentTypeHint()
            )
        )
        guard case let .published(published) = await extensionIngest.handleActivation(
            ShareActivation(providers: [provider])
        ) else {
            throw FlowSetupFailure.noPublishedHandoff
        }

        let outcome = await flow.claimShareHandoff()
        let termination = try #require(outcome.termination)
        #expect(termination.error == .handoffError)
        #expect(termination.sessionID == published.ticket.sessionID)

        // Refused before any byte reached app-private storage: the session scope was never
        // even created.
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
    }

    // A recorded hole in "exact status preservation", measured rather than assumed.
    //
    // Requirement 2.19 forbids the Byte Preservation Status changing across the handoff, and
    // Requirement 11.12 requires it to cross unchanged. What is actually enforced is *internal
    // coherence*: `ShareTransferTicket`'s decoder refuses a status its basis does not support,
    // and the claim rechecks the same pair. Neither is integrity-bound to the payload — the
    // ticket's SHA-256 covers the payload bytes, not the record — so a record whose status
    // **and** basis are changed together to another supported pair decodes, resolves, and
    // verifies, and the resumed session analyzes those bytes under an *upgraded* status.
    //
    // This arm pins that. The published pair is the most conservative one either seam can
    // produce; the spliced pair is the strongest one the vocabulary has, which is precisely the
    // direction the requirement forbids. Reported, not fixed: closing it needs the record
    // covered by a digest or signature, which is a design change to the transfer format.
    @Test("A status and basis changed together cross the handoff and upgrade the session")
    func aCoherentStatusAndBasisSpliceIsNotRefused() async throws {
        let flow = try await AnalysisFlow.make()
        guard case let .published(published) = try await flow.publishShareHandoff(
            bytes: FlowSample.payload()
        ) else {
            throw FlowSetupFailure.noPublishedHandoff
        }
        let ticket = published.ticket
        #expect(ticket.preservationStatus == .unknown)
        #expect(ticket.preservationBasis == .providerDeclaredCurrentRepresentationOnly)

        let slot = try await flow.transfers.readySlotState()
        let ready = try #require(slot.publishedTransfer)
        let readyObjects = await flow.appGroupObjects.keys(
            in: .transfer(ticket.transferID, .ready)
        )
        let manifestKey = try #require(readyObjects.subtracting([ready.storageKey]).first)
        let recordBytes = try #require(
            await flow.appGroupObjects.finalizedBytes(manifestKey)
        )

        // A text splice of exactly two members. Each is required to occur exactly once, so a
        // schema that duplicated either name fails this arm rather than silently splicing the
        // wrong occurrence.
        let text = try #require(String(bytes: recordBytes, encoding: .utf8))
        let statusMember = "\"preservationStatus\":\"unknown\""
        let basisMember =
            "\"preservationBasis\":\"providerDeclaredCurrentRepresentationOnly\""
        #expect(text.components(separatedBy: statusMember).count == 2)
        #expect(text.components(separatedBy: basisMember).count == 2)
        let spliced = text
            .replacingOccurrences(
                of: statusMember,
                with: "\"preservationStatus\":\"originalBytes\""
            )
            .replacingOccurrences(
                of: basisMember,
                with: "\"preservationBasis\":\"providerDeclaredOriginalRepresentation\""
            )
        flow.appGroup.substituteRead(Array(spliced.utf8), for: manifestKey)

        // The claim accepts it. Nothing about the payload changed, so every fact the claim
        // recomputes still agrees, and the pair it rechecks is coherent.
        let resumed = try #require(await flow.claimShareHandoff().resumedSession)
        #expect(resumed.sessionID == ticket.sessionID)
        #expect(resumed.asset.preservationStatus == .originalBytes)
        #expect(resumed.asset.preservationBasis == .providerDeclaredOriginalRepresentation)
        #expect(resumed.asset.preservationStatus != ticket.preservationStatus)

        // And the upgraded status is what the Evidence Report shows, which is the harm: a
        // report states byte originality the ingest never established.
        let session = try #require(await flow.coordinator.analyze(resumed.asset).completed)
        let report = try #require(session.evidenceReport)
        #expect(report.bytePreservationStatus == .originalBytes)
    }

    @Test("A status changed on its own is refused, because the pair must stay coherent")
    func anIncoherentStatusSpliceIsRefused() async throws {
        let flow = try await AnalysisFlow.make()
        guard case let .published(published) = try await flow.publishShareHandoff(
            bytes: FlowSample.payload()
        ) else {
            throw FlowSetupFailure.noPublishedHandoff
        }
        let ticket = published.ticket
        let slot = try await flow.transfers.readySlotState()
        let ready = try #require(slot.publishedTransfer)
        let readyObjects = await flow.appGroupObjects.keys(
            in: .transfer(ticket.transferID, .ready)
        )
        let manifestKey = try #require(readyObjects.subtracting([ready.storageKey]).first)
        let recordBytes = try #require(
            await flow.appGroupObjects.finalizedBytes(manifestKey)
        )
        let text = try #require(String(bytes: recordBytes, encoding: .utf8))
        let statusMember = "\"preservationStatus\":\"unknown\""
        #expect(text.components(separatedBy: statusMember).count == 2)
        let spliced = text.replacingOccurrences(
            of: statusMember,
            with: "\"preservationStatus\":\"originalBytes\""
        )
        flow.appGroup.substituteRead(Array(spliced.utf8), for: manifestKey)

        // The record no longer decodes, so the peek resolves no published transfer and the app
        // resumes nothing, terminates nothing, and shows nothing. That is the behaviour
        // Property 6 already reports as an open question against Requirements 2.19 and 11.13,
        // which ask for `handoff-error`. Pinned as it is, not fixed.
        let outcome = await flow.claimShareHandoff()
        #expect(outcome == .noSession(.nothingPending))
        #expect(outcome.termination == nil)
        #expect(outcome.resumedSession == nil)

        // And the material is *not* removed by the attempt. An initial version of this arm
        // asserted that it was; the peek is a pure read that takes no ownership, so the
        // assertion over-claimed and is weakened to what actually happens. The unresolvable
        // slot survives until the next startup cleanup treats it as abandoned, which is what
        // the store documents and what this arm now shows.
        let scopesAfterAttempt = await flow.occupiedTransferScopes()
        #expect(scopesAfterAttempt == [.transfer(ticket.transferID, .ready)])
        let sweep = try await flow.transfers.runStartupCleanup()
        #expect(sweep.retainedTransfer == nil)
        let scopesAfterSweep = await flow.occupiedTransferScopes()
        #expect(scopesAfterSweep.isEmpty)
    }

    // A recorded, irreducible presentation gap. Task 12.1 named the same one.
    //
    // Requirement 2.19 requires `handoff-error` *before* Model Bundle binding, and this suite
    // shows that ordering holds. The consequence is that the failed session has no
    // `AnalysisSessionBinding`, and `ApprovedCopyBinding.bind` takes one — so there is no way
    // to resolve the category and recovery action Requirements 3.12 and 4.17 require to be
    // presented. The failure *snapshot* is constructible; the screen is not.
    //
    // Reported, not fixed. Closing it needs either a binding-free copy path or a session
    // binding taken before verification, and both are design decisions outside this task.
    @Test("A handoff-error terminal has no bundle binding to resolve its copy through")
    func theHandoffErrorTerminalHasNoBindingToResolveCopyThrough() async throws {
        let flow = try await AnalysisFlow.make()
        _ = try await publishAndCorrupt(flow)
        let termination = try #require(await flow.claimShareHandoff().termination)

        // The terminal outcome itself is representable.
        let snapshot = try #require(
            AnalysisFailureSnapshot(
                sessionID: termination.sessionID,
                error: termination.error,
                stage: termination.stage,
                bytePreservationStatus: nil,
                inputQuality: nil
            )
        )
        #expect(SessionTerminalOutcome.failed(snapshot).error == .handoffError)

        // The binding a screen would need does not exist and was never created: no bundle was
        // bound, and no session is bound under that identifier anywhere.
        #expect(!flow.recorder.didCall(PortCallKind.verifiedActiveBundle))
        let coordinatorBinding = await flow.harness.binder.boundSession(termination.sessionID)
        #expect(coordinatorBinding == nil)
        let presentationBinding = await flow.presentationBinder.boundSession(
            termination.sessionID
        )
        #expect(presentationBinding == nil)
    }
}

// MARK: - No session, no side effect

@Suite(
    "Cross-module flow: a refused ingest creates no session anywhere",
    .tags(.crossModuleAnalysisFlow)
)
struct CrossModuleRefusedIngestTests {

    @Test(
        "A consent decision that is not a confirmation reads no byte and publishes nothing",
        arguments: [FlowConsentPresenter.Answer.decline, .cancel]
    )
    func aDeclinedOrCancelledConsentLeavesNothing(
        answer: FlowConsentPresenter.Answer
    ) async throws {
        let flow = try await AnalysisFlow.make()
        let provider = FlowSharedItemProvider(bytes: FlowSample.payload())
        let presenter = FlowConsentPresenter(answer)
        let outcome = try await flow.publishShareHandoff(
            consent: answer,
            presenter: presenter,
            provider: provider
        )

        switch answer {
        case .decline: #expect(outcome == .declined)
        case .cancel: #expect(outcome == .cancelled)
        case .confirm: Issue.record("this arm does not confirm consent")
        }

        // The visible action was presented, and nothing after it happened: the host was never
        // asked, so no byte of the shared item was read (Requirements 2.2, 2.4, 11.10).
        #expect(presenter.presentationCount == 1)
        #expect(provider.requestCount == 0)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)

        // Nothing is pending, so the main app resumes nothing and reports nothing.
        let claimed = await flow.claimShareHandoff()
        #expect(claimed == .noSession(.nothingPending))
        let active = await flow.coordinator.activeIdentity()
        #expect(active == nil)
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
    }

    @Test(
        "An activation offering any count but one never reaches the host",
        arguments: [0, 2, 5]
    )
    func aRefusedActivationNeverReachesTheHost(itemCount: Int) async throws {
        let flow = try await AnalysisFlow.make()
        let provider = FlowSharedItemProvider(bytes: FlowSample.payload())
        let presenter = FlowConsentPresenter(.confirm)
        let outcome = try await flow.publishShareHandoff(
            itemCount: itemCount,
            presenter: presenter,
            provider: provider
        )
        #expect(outcome == .activationRefused(.itemCountUnsupported(itemCount)))

        // Counted before the consent action, so a refused activation shows the user nothing
        // and reads nothing (Requirement 2.7).
        #expect(presenter.presentationCount == 0)
        #expect(provider.requestCount == 0)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
    }

    @Test("A dismissed picker and a multi-item selection create no session")
    func aRefusedPickerSelectionCreatesNoSession() async throws {
        let flow = try await AnalysisFlow.make()

        let dismissed = FlowPhotosProvider(bytes: FlowSample.payload())
        let dismissal = await flow.ingestPhotos(itemCount: 0, provider: dismissed)
        #expect(dismissal.refusal == .pickerCancelled)
        #expect(dismissed.requestCount == 0)

        let many = FlowPhotosProvider(bytes: FlowSample.payload())
        let refused = await flow.ingestPhotos(itemCount: 3, provider: many)
        #expect(refused.refusal == .itemCountRefused(3))
        #expect(many.requestCount == 0)

        // No session on either path, so nothing was written and nothing can be analyzed.
        #expect(dismissal.acceptedIngest == nil)
        #expect(refused.acceptedIngest == nil)
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
        let active = await flow.coordinator.activeIdentity()
        #expect(active == nil)
    }

    @Test("A provider that produced nothing is an ingest attempt, not a failed session")
    func aProviderFailureIsAnIngestAttemptRatherThanASession() async throws {
        let flow = try await AnalysisFlow.make()
        let outcome = await flow.ingestPhotos(providerFault: .representationUnavailable)

        // Recorded for an audit as the import port's category, and never presented: no session
        // exists to carry an Analysis Error.
        #expect(outcome.refusal == .noLocalRepresentation(.decodingError))
        #expect(outcome.acceptedIngest == nil)
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
        let active = await flow.coordinator.activeIdentity()
        #expect(active == nil)
        let terminal = await flow.coordinator.committedTerminal()
        #expect(terminal == nil)
    }
}

// MARK: - Retry

@Suite(
    "Cross-module flow: a session after any terminal inherits nothing",
    .tags(.crossModuleAnalysisFlow)
)
@MainActor
struct CrossModuleRetryTests {

    @Test(
        "A claimed-Share retry after every post-ingest fault completes cleanly",
        arguments: FlowFaultCell.all
    )
    func aRetryAcrossRoutesSucceedsAfterEveryFault(cell: FlowFaultCell) async throws {
        // The faulting port answers once and then succeeds, so the second attempt runs the
        // whole pipeline rather than a shortened one.
        let flow = try await cell.flowThenSucceeding()
        let failedAsset = try await flow.acceptedIngest(.photos)
        let failed = try #require(await flow.coordinator.analyze(failedAsset).completed)
        #expect(failed.error == cell.error)

        // A different route, the same identifier. The stub pipeline is stamped for this
        // identifier, and reusing it is the harder case: nothing may survive from the failed
        // attempt even when the two attempts are named the same.
        let retryAsset = try await flow.acceptedIngest(.claimedShare)
        let retried = try #require(await flow.coordinator.analyze(retryAsset).completed)

        #expect(retried.outcome.isCompleted)
        #expect(retried.error == nil)
        let report = try #require(retried.evidenceReport)
        #expect(report.binding.sessionID == retryAsset.sessionID)

        // A fresh attempt: a new generation, and no error, dimension, byte status, or lane
        // from the failed one (Requirement 3.15).
        #expect(retried.identity.generation == failed.identity.generation + 1)
        #expect(retried.outcome.failure == nil)
        #expect(report.bytePreservationStatus == retryAsset.preservationStatus)

        // Neither attempt left material behind.
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
        let transferScopes = await flow.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
        let boundCount = await flow.harness.binder.boundSessionCount
        #expect(boundCount == 0)
    }

    @Test("A retry after a cancellation completes, and the two attempts stay distinct")
    func aRetryAfterCancellationCompletes() async throws {
        let flow = try await AnalysisFlow.make(gateAt: .inference)
        let first = try await flow.acceptedIngest(.photos)
        let task = try #require(await flow.coordinator.startAnalysis(of: first))
        await flow.harness.gate.waitUntilReached()
        let identity = try #require(await flow.coordinator.activeIdentity())
        await flow.coordinator.requestCancellation(for: identity)
        await flow.harness.gate.openGate()
        let cancelled = try #require(await task.value.completed)
        #expect(cancelled.outcome.isCancelled)

        // The gate stays open once opened, so the retry runs straight through.
        let second = try await flow.acceptedIngest(.claimedShare)
        let retried = try #require(await flow.coordinator.analyze(second).completed)
        #expect(retried.outcome.isCompleted)
        #expect(retried.identity.generation == cancelled.identity.generation + 1)
        let sessionScopes = await flow.sessions.occupiedScopes()
        #expect(sessionScopes.isEmpty)
    }

    @Test("The screen advances to the retry and refuses the attempt it moved past")
    func theProjectorRefusesTheSupersededAttempt() async throws {
        let flow = try await FlowFaultCell.all[0].flowThenSucceeding()
        let failedAsset = try await flow.acceptedIngest(.photos)
        let failed = try #require(await flow.coordinator.analyze(failedAsset).completed)
        let failedCopy = try await flow.copyBinding(for: failedAsset)

        let retryAsset = try await flow.acceptedIngest(.claimedShare)
        let retried = try #require(await flow.coordinator.analyze(retryAsset).completed)
        let retriedCopy = try await flow.copyBinding(for: retryAsset)

        let projector = AnalysisViewStateProjector()
        let firstScreen = try flow.project(failed, copy: failedCopy, onto: projector)
        #expect(firstScreen.wasAccepted)
        #expect(firstScreen.screen.family == .error)

        let secondScreen = try flow.project(retried, copy: retriedCopy, onto: projector)
        #expect(secondScreen.wasAccepted)
        #expect(secondScreen.screen.family == .completed)

        // The superseded attempt cannot re-enter the screen.
        let late = try flow.project(failed, copy: failedCopy, onto: projector)
        #expect(!late.wasAccepted)
        #expect(late.screen == secondScreen.screen)

        // And the recovery action carries nothing forward.
        let ready = projector.startNewSelection()
        #expect(ready.screen.family == .ready)
        #expect(ready.screen.evidenceReport == nil)
        #expect(ready.screen.analysisError == nil)
        #expect(ready.screen.identity == nil)
    }
}

// MARK: - Progress and cancellation surfaces

@Suite(
    "Cross-module flow: derived progress reaches the screen without gaining a meaning",
    .tags(.crossModuleAnalysisFlow)
)
@MainActor
struct CrossModuleProgressTests {

    /// A snapshot of one attempt with work in flight.
    private func working(
        _ sessionID: AnalysisSessionID,
        generation: UInt64 = 1,
        _ progress: DerivedAnalysisProgress,
        copy: ApprovedCopyBinding
    ) -> CoordinatorSnapshot {
        .session(
            AnalysisSessionSnapshot(
                identity: SessionAttemptIdentity(
                    sessionID: sessionID,
                    attemptGeneration: generation
                ),
                phase: .working(progress.state),
                copy: copy
            )
        )
    }

    @Test("A reliable measurement reaches the screen as a measured work readout")
    func aReliableMeasurementBecomesAMeasuredReadout() async throws {
        let flow = try await AnalysisFlow.make(gateAt: .inference)
        let asset = try await flow.acceptedIngest(.photos)
        let copy = try await flow.copyBinding(for: asset)
        let task = try #require(await flow.coordinator.startAnalysis(of: asset))
        await flow.harness.gate.waitUntilReached()
        let identity = try #require(await flow.coordinator.activeIdentity())
        let stage = try #require(await flow.coordinator.currentStage())
        #expect(stage == .inference)

        let progress = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: WorkAmount(amount: 3, unit: .encodedBytes, reliability: .reliable),
                total: WorkAmount(amount: 4, unit: .encodedBytes, reliability: .reliable)
            ),
            at: stage
        )
        #expect(progress.isDeterminate)

        let snapshot = working(
            identity.sessionID,
            generation: identity.generation,
            progress,
            copy: copy
        )
        let screen = try AnalysisViewStateProjector().apply(snapshot).screen
        #expect(screen.family == .active)
        // The cancel control is visible and enabled for the whole of active work
        // (Requirement 15.5).
        #expect(screen.cancellation == .visibleAndEnabled)
        let readout = try #require(screen.workProgress?.readout)
        #expect(readout.completedWorkAmount == 3)
        #expect(readout.totalWorkAmount == 4)
        #expect(readout.workUnit == .encodedBytes)
        #expect(readout.stage == .inference)
        #expect(readout.completedWorkOutOfOneHundred == 75)
        #expect(WorkProgressReadout.quantity == .analysisWorkProgress)
        #expect(!readout.isMeasuredWorkFinished)

        await flow.harness.gate.openGate()
        _ = await task.value
    }

    @Test(
        "Every unusable measurement reaches the screen as continuing work",
        arguments: FlowUnmeasuredCase.all
    )
    func anUnusableMeasurementBecomesContinuingWork(
        unmeasured: FlowUnmeasuredCase
    ) async throws {
        let flow = try await AnalysisFlow.make()
        let asset = try await flow.acceptedIngest(.photos)
        let copy = try await flow.copyBinding(for: asset)
        let progress = DerivedAnalysisProgress(
            reported: unmeasured.reported,
            at: .preprocessing
        )
        #expect(!progress.isDeterminate)
        #expect(progress.indeterminateAssertion == .analysisIsContinuing)

        let snapshot = working(asset.sessionID, progress, copy: copy)
        let screen = try AnalysisViewStateProjector().apply(snapshot).screen
        #expect(screen.family == .active)
        #expect(screen.cancellation == .visibleAndEnabled)
        #expect(screen.workProgress?.readout == nil)
        #expect(screen.workProgress?.continuingAssertion == .analysisIsContinuing)
        #expect(screen.workProgress?.stage == .preprocessing)
    }

    // A recorded inexactness, pinned as it is.
    //
    // `AnalysisWorkPercentage.percent` is `Double(completed) / Double(total) * 100`, which for
    // 29 out of 100 is 28.999999999999996 and truncates to 28. The shipping surface is not
    // affected: `WorkProgressReadout.completedWorkOutOfOneHundred` computes the same quantity
    // in exact full-width integer arithmetic and answers 29. This arm asserts *both*, so the
    // application-side inexactness stays visible and the presentation-side exactness stays
    // guaranteed. Reported, not fixed.
    @Test("The displayed percentage is exact where the derived percentage is not")
    func theDisplayedPercentageIsExactWhereTheDerivedOneIsNot() async throws {
        let flow = try await AnalysisFlow.make()
        let asset = try await flow.acceptedIngest(.photos)
        let copy = try await flow.copyBinding(for: asset)
        let progress = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: WorkAmount(amount: 29, unit: .encodedBytes, reliability: .reliable),
                total: WorkAmount(amount: 100, unit: .encodedBytes, reliability: .reliable)
            ),
            at: .inputValidation
        )

        let percentage = try #require(progress.percentage)
        #expect(percentage.percent != 29.0)
        #expect(UInt8(percentage.percent) == 28)
        #expect(AnalysisWorkPercentage.semantics == .analysisWorkProgress)

        let snapshot = working(asset.sessionID, progress, copy: copy)
        let screen = try AnalysisViewStateProjector().apply(snapshot).screen
        let readout = try #require(screen.workProgress?.readout)
        #expect(readout.completedWorkOutOfOneHundred == 29)
    }

    @Test("A committed terminal replaces the active progress state on the screen")
    func aTerminalReplacesTheActiveProgressState() async throws {
        let flow = try await AnalysisFlow.make(gateAt: .inference)
        let asset = try await flow.acceptedIngest(.photos)
        let copy = try await flow.copyBinding(for: asset)
        let task = try #require(await flow.coordinator.startAnalysis(of: asset))
        await flow.harness.gate.waitUntilReached()
        let identity = try #require(await flow.coordinator.activeIdentity())

        let projector = AnalysisViewStateProjector()
        let active = try projector.apply(
            working(
                identity.sessionID,
                generation: identity.generation,
                DerivedAnalysisProgress(at: .inference),
                copy: copy
            )
        )
        #expect(active.screen.family == .active)
        #expect(active.screen.workProgress != nil)
        #expect(active.screen.cancellation == .visibleAndEnabled)

        // A recovery action must not take a visible, enabled cancel control off screen while
        // the work continues (Requirement 15.5).
        let refused = projector.startNewSelection()
        #expect(!refused.wasAccepted)
        #expect(refused.screen == active.screen)

        await flow.harness.gate.openGate()
        let session = try #require(await task.value.completed)
        let terminal = try flow.project(session, copy: copy, onto: projector)
        #expect(terminal.wasAccepted)
        #expect(terminal.screen.family == .completed)
        // Requirement 15.7 as a type: a terminal screen has no progress and no cancel control
        // to read.
        #expect(terminal.screen.workProgress == nil)
        #expect(terminal.screen.cancellation == nil)
        #expect(terminal.screen.isTerminal)
    }
}

/// One report that cannot produce a completion fraction, and why.
///
/// Every prerequisite the design's progress rule names, so "an unusable measurement shows
/// continuing work" is exhaustive over the ways a measurement can be unusable rather than one
/// example of it.
struct FlowUnmeasuredCase: Sendable, CustomStringConvertible {
    let name: String
    let reported: ReportedWork?

    var description: String { name }

    private static func amount(
        _ value: UInt64,
        _ unit: ProgressUnit = .encodedBytes,
        _ reliability: WorkMeasurementReliability = .reliable
    ) -> WorkAmount {
        WorkAmount(amount: value, unit: unit, reliability: reliability)
    }

    static let all: [FlowUnmeasuredCase] = [
        FlowUnmeasuredCase(name: "nothing-reported", reported: nil),
        FlowUnmeasuredCase(
            name: "no-total",
            reported: ReportedWork(completed: amount(3), total: nil)
        ),
        FlowUnmeasuredCase(
            name: "no-completed",
            reported: ReportedWork(completed: nil, total: amount(4))
        ),
        FlowUnmeasuredCase(
            name: "unit-mismatch",
            reported: ReportedWork(completed: amount(3, .imageRows), total: amount(4, .encodedBytes))
        ),
        FlowUnmeasuredCase(
            name: "unreliable-completed",
            reported: ReportedWork(
                completed: amount(3, .encodedBytes, .unreliable),
                total: amount(4)
            )
        ),
        FlowUnmeasuredCase(
            name: "zero-total",
            reported: ReportedWork(completed: amount(0), total: amount(0))
        ),
        FlowUnmeasuredCase(
            name: "completed-above-total",
            reported: ReportedWork(completed: amount(5), total: amount(4))
        ),
    ]
}

// MARK: - A fixture gap this file had to work around

@Suite(
    "Cross-module flow: the shared release fixture's copy catalogue",
    .tags(.crossModuleAnalysisFlow)
)
struct CrossModuleCopyCatalogueGapTests {

    // A recorded fixture gap, pinned so the workaround in `FlowCopy` cannot quietly outlive
    // the reason for it.
    //
    // `CoordinatorSample.copyCatalog()` covers the unconditional surfaces plus the five
    // enabled provenance states. `ReachableCopySurfaces` additionally requires one
    // `combinedSummary(_:)` entry per key a bound fusion rule can produce, so a fusion-enabled
    // release cannot bind approved copy from its own registered catalogue. This is a
    // test-fixture gap rather than a production defect — a shipping release's catalogue is a
    // signed artifact release validation checks for exactly this coverage — and the shared
    // fixture is not edited here because other suites compile against it.
    @Test("A fusion-enabled release's own catalogue cannot bind its Combined Summaries")
    func aFusionEnabledReleasesOwnCatalogueCannotBindItsSummaries() async throws {
        let flow = try await AnalysisFlow.make(.provenanceAndFusion)
        let asset = try await flow.acceptedIngest(.photos)
        let bound = try await flow.presentationBinder.bind(accepting: asset)
        let rule = try #require(flow.configuration.fusionRule)

        let missing = ReachableCopySurfaces(
            capabilities: flow.configuration.capabilityManifest,
            fusionRule: rule
        ).missingSurfaces(in: flow.configuration.verdictCopyCatalog)
        #expect(!missing.isEmpty)
        let allCombinedSummaries = missing.allSatisfy { surface in
            if case .combinedSummary = surface { return true }
            return false
        }
        #expect(allCombinedSummaries)

        #expect(throws: PresentationCopyError.missingSurfaces(missing)) {
            _ = try ApprovedCopyBinding.bind(
                catalog: flow.configuration.verdictCopyCatalog,
                session: bound.binding,
                capabilities: flow.configuration.capabilityManifest,
                fusionRule: rule
            )
        }

        // The superset this file binds through covers every reachable surface, including
        // those, and carries the same compatibility identifier under its own artifact
        // identifier.
        let superset = FlowCopy.catalog(
            capabilities: flow.configuration.capabilityManifest,
            fusionRule: rule
        )
        #expect(
            superset.compatibilityID == flow.configuration.verdictCopyCatalog.compatibilityID
        )
        #expect(superset.id != flow.configuration.verdictCopyCatalog.id)
        let supersetMissing = ReachableCopySurfaces(
            capabilities: flow.configuration.capabilityManifest,
            fusionRule: rule
        ).missingSurfaces(in: superset)
        #expect(supersetMissing.isEmpty)
    }

    @Test("A pixel-only release's own catalogue binds without a superset")
    func aPixelOnlyReleasesOwnCatalogueBinds() async throws {
        let flow = try await AnalysisFlow.make()
        let asset = try await flow.acceptedIngest(.photos)
        let bound = try await flow.presentationBinder.bind(accepting: asset)
        let binding = try ApprovedCopyBinding.bind(
            catalog: flow.configuration.verdictCopyCatalog,
            session: bound.binding,
            capabilities: flow.configuration.capabilityManifest,
            fusionRule: nil
        )
        #expect(binding.sessionID == asset.sessionID)
        #expect(binding.catalogID == flow.configuration.verdictCopyCatalog.id)
        #expect(!binding.reachableSurfaces.isProvenanceEnabled)
        #expect(!binding.reachableSurfaces.isFusionEnabled)
    }
}

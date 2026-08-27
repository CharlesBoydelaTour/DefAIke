import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// The view-state projection: six families, one at a time, with honest progress and a
// cancellation that never leaves.
//
// These are example tests over the projection's own behavior. They check the four claims the
// projection is responsible for:
//
//   1. exactly one screen family is inhabited, and each family can reach only what it is
//      supposed to show (Requirements 4.17, 11.17, 11.18, 15.7);
//   2. progress is whatever the coordinator already derived, expressed as a work-progress
//      readout that is not a result magnitude (Requirements 15.1, 15.3, 15.4, 15.11);
//   3. cancellation is visible and enabled for the whole of active work
//      (Requirement 15.5); and
//   4. recovery returns to a ready screen that retains nothing from the ended session
//      (Requirements 3.13 and 3.15).
//
// The exhaustive per-report property over generated reports is separate work. What is here
// is the reducer behavior, the refusal paths, and the arithmetic edges.

@Suite("Screen families are mutually exclusive")
struct AnalysisScreenFamilyTests {

    @Test("Every snapshot projects to exactly the expected family")
    func familyPerSnapshot() throws {
        for (expected, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            #expect(try AnalysisScreen.projecting(snapshot).family == expected)
        }
    }

    @Test("Progress is reachable from the active family and from no other")
    func progressOnlyWhileActive() throws {
        for (family, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            let screen = try AnalysisScreen.projecting(snapshot)

            #expect((screen.workProgress != nil) == (family == .active), "\(family)")
            #expect((screen.cancellation != nil) == (family == .active), "\(family)")
        }
    }

    @Test("An Evidence Report is reachable from the completed family and from no other")
    func reportOnlyWhenCompleted() throws {
        for (family, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            let screen = try AnalysisScreen.projecting(snapshot)

            #expect((screen.evidenceReport != nil) == (family == .completed), "\(family)")
        }
    }

    @Test("An Analysis Error is reachable from the error family and from no other")
    func errorOnlyWhenFailed() throws {
        for (family, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            let screen = try AnalysisScreen.projecting(snapshot)

            #expect((screen.analysisError != nil) == (family == .error), "\(family)")
        }
    }

    @Test("Recovery is offered by exactly the three terminal families")
    func recoveryOnlyWhenTerminal() throws {
        for (family, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            let screen = try AnalysisScreen.projecting(snapshot)

            #expect(screen.isTerminal == [.completed, .cancelled, .error].contains(family))
            #expect((screen.recovery != nil) == screen.isTerminal, "\(family)")
        }
    }

    @Test("Cancellation is not an Analysis Error category")
    func cancellationIsNotAnError() throws {
        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.ended(outcome: .cancelled)
        )

        #expect(screen.family == .cancelled)
        #expect(screen.analysisError == nil)
        #expect(screen.evidenceReport == nil)
        #expect(screen.workProgress == nil)
        #expect(screen.recovery == .selectAnotherImage)
    }

    @Test("Every error category projects to the error family with no evidence",
          arguments: AnalysisError.allCases)
    func everyErrorCategory(error: AnalysisError) throws {
        let snapshot = try ViewStateFixture.ended(
            outcome: .failed(ViewStateFixture.failure(error: error))
        )

        let screen = try AnalysisScreen.projecting(snapshot)

        #expect(screen.family == .error)
        #expect(screen.analysisError == error)
        #expect(screen.evidenceReport == nil)
        #expect(screen.workProgress == nil)
        #expect(screen.recovery == .selectAnotherImage)
    }

    @Test("A failed screen preserves the byte status and dimensions recorded before failure")
    func failurePreservesRecordedMeasurements() throws {
        let failure = ViewStateFixture.failure(
            error: .preprocessingError,
            stage: .preprocessing,
            bytePreservationStatus: .unknown,
            inputQuality: ViewStateFixture.quality(width: 300, height: 500)
        )

        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.ended(outcome: .failed(failure))
        )
        let errorScreen = try #require({ () -> AnalysisErrorScreen? in
            guard case let .error(screen) = screen else { return nil }
            return screen
        }())

        #expect(errorScreen.bytePreservationStatus == .unknown)
        #expect(errorScreen.inputQuality?.decodedWidthBeforeOrientation == 300)
        #expect(errorScreen.inputQuality?.shortEdgeBeforeOrientation == 300)
    }

    @Test("A session that failed before recording anything preserves nothing invented")
    func failureWithoutMeasurementsInventsNothing() throws {
        let failure = AnalysisFailureSnapshot(
            sessionID: ViewStateFixture.sessionID(),
            error: .handoffError,
            stage: .handoffVerification,
            bytePreservationStatus: nil,
            inputQuality: nil
        )!

        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.ended(outcome: .failed(failure))
        )
        guard case let .error(errorScreen) = screen else {
            Issue.record("expected the error family, found \(screen.family)")
            return
        }

        #expect(errorScreen.bytePreservationStatus == nil)
        #expect(errorScreen.inputQuality == nil)
    }

    @Test("A completed screen resolves both source lanes separately")
    func completedResolvesBothLanes() throws {
        let report = ViewStateFixture.pixelOnlyReport(pixel: .notEnoughSignal)

        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.ended(outcome: .completed(report))
        )
        guard case let .completed(completed) = screen else {
            Issue.record("expected the completed family, found \(screen.family)")
            return
        }

        #expect(completed.pixel.evidence == .notEnoughSignal)
        #expect(completed.pixel.fixedLabelText.value == FixedPixelLabelText.notEnoughSignal)
        #expect(completed.provenance.state == .unavailable(.validatorNotCompiledIntoRelease))
        #expect(completed.combinedSummary == nil)
        #expect(completed.apparentInconsistency == nil)
        #expect(completed.report == report)
    }

    @Test("A Combined Summary and an inconsistency notice sit alongside both lanes")
    func completedResolvesSummaryAndNotice() throws {
        let report = ViewStateFixture.fusedReport()
        let snapshot = try ViewStateFixture.ended(
            outcome: .completed(report),
            copy: try ViewStateFixture.fusionBinding()
        )

        let screen = try AnalysisScreen.projecting(snapshot)
        guard case let .completed(completed) = screen else {
            Issue.record("expected the completed family, found \(screen.family)")
            return
        }

        #expect(completed.pixel.evidence == .signalsConsistentWithAIGeneration)
        #expect(completed.provenance.state == .available(.absent))
        #expect(completed.combinedSummary?.fusionRuleID == CopyFixture.fusionRuleID)
        #expect(completed.apparentInconsistency?.surface == .apparentInconsistency)
    }

    @Test("The importing family carries a route and no session, progress, or error")
    func importingCarriesOnlyTheRoute() throws {
        for route in InputRoute.allCases {
            let screen = try AnalysisScreen.projecting(
                .importing(ImportAttemptSnapshot(route: route))
            )
            guard case let .importing(importing) = screen else {
                Issue.record("expected the importing family, found \(screen.family)")
                return
            }

            #expect(importing.attempt.route == route)
            #expect(screen.identity == nil)
            #expect(screen.workProgress == nil)
            #expect(screen.analysisError == nil)
            #expect(screen.evidenceReport == nil)
        }
    }

    @Test("The family vocabulary is closed and enumerable")
    func familyVocabularyIsClosed() {
        #expect(AnalysisScreenFamily.allCases.count == 6)
        #expect(
            Set(AnalysisScreenFamily.allCases.map(\.rawValue)).count
                == AnalysisScreenFamily.allCases.count
        )
    }
}

@Suite("Progress is measured work, never a result magnitude")
struct WorkProgressReadoutTests {

    static func determinate(
        completed: UInt64,
        total: UInt64,
        unit: ProgressUnit = .encodedBytes,
        stage: AnalysisStage = .inputValidation
    ) -> AnalysisProgressState {
        .determinate(completed: completed, total: total, unit: unit, stage: stage)
    }

    @Test("A readout counts measured work out of one hundred, truncated toward zero")
    func readoutTruncates() throws {
        let cases: [(completed: UInt64, total: UInt64, expected: UInt8)] = [
            (0, 100, 0),
            (1, 3, 33),
            (2, 3, 66),
            (99_999, 100_000, 99),
            (1, 2, 50),
            (100, 100, 100),
        ]

        for sample in cases {
            let state = Self.determinate(completed: sample.completed, total: sample.total)
            let readout = try #require(WorkProgressReadout(state))
            #expect(readout.completedWorkOutOfOneHundred == sample.expected, "\(sample)")
        }
    }

    @Test("A readout never reaches one hundred before the measured work does")
    func readoutReachesOneHundredOnlyWhenFinished() throws {
        let almost = try #require(
            WorkProgressReadout(Self.determinate(completed: 999, total: 1000))
        )
        let finished = try #require(
            WorkProgressReadout(Self.determinate(completed: 1000, total: 1000))
        )

        #expect(almost.completedWorkOutOfOneHundred == 99)
        #expect(almost.isMeasuredWorkFinished == false)
        #expect(finished.completedWorkOutOfOneHundred == 100)
        #expect(finished.isMeasuredWorkFinished)
    }

    @Test("Very large measured amounts do not overflow the readout")
    func readoutSurvivesLargeAmounts() throws {
        let total = UInt64.max
        let readout = try #require(
            WorkProgressReadout(Self.determinate(completed: total / 2, total: total))
        )

        #expect(readout.completedWorkOutOfOneHundred == 49)

        let full = try #require(
            WorkProgressReadout(Self.determinate(completed: total, total: total))
        )
        #expect(full.completedWorkOutOfOneHundred == 100)
    }

    @Test("An unusable determinate measurement yields no readout")
    func unusableMeasurementYieldsNoReadout() {
        #expect(WorkProgressReadout(Self.determinate(completed: 0, total: 0)) == nil)
        #expect(WorkProgressReadout(Self.determinate(completed: 5, total: 4)) == nil)
        #expect(WorkProgressReadout(.indeterminate(stage: .inference)) == nil)
    }

    @Test(
        "Indeterminate progress asserts that analysis is continuing",
        arguments: AnalysisStage.allCases
    )
    func indeterminateAssertsContinuation(stage: AnalysisStage) {
        let projected = ProjectedWorkProgress(.indeterminate(stage: stage))

        #expect(projected.readout == nil)
        #expect(projected.continuingAssertion == .analysisIsContinuing)
        #expect(projected.stage == stage)
    }

    @Test("An unusable determinate state degrades to continuing rather than zero")
    func unusableMeasurementDegradesToContinuing() {
        let projected = ProjectedWorkProgress(Self.determinate(completed: 3, total: 0))

        #expect(projected.readout == nil)
        #expect(projected.continuingAssertion == .analysisIsContinuing)
    }

    @Test("A usable determinate state projects the measurement unchanged")
    func usableMeasurementProjectsUnchanged() throws {
        let projected = ProjectedWorkProgress(
            Self.determinate(completed: 7, total: 9, unit: .imageRows, stage: .preprocessing)
        )
        let readout = try #require(projected.readout)

        #expect(readout.completedWorkAmount == 7)
        #expect(readout.totalWorkAmount == 9)
        #expect(readout.workUnit == .imageRows)
        #expect(readout.stage == .preprocessing)
        #expect(projected.continuingAssertion == nil)
    }

    @Test("A progress quantity can only mean analysis work progress")
    func quantityHasOneMeaning() {
        #expect(WorkProgressReadout.quantity == .analysisWorkProgress)
        #expect(WorkProgressQuantity.allCases.count == 1)
        #expect(ContinuingWorkAssertion.allCases.count == 1)
        #expect(CancellationAvailability.allCases.count == 1)
    }

    @Test("A readout carries no field a result magnitude could occupy")
    func readoutIsProbabilityFree() throws {
        let readout = try #require(WorkProgressReadout(Self.determinate(completed: 1, total: 4)))

        let continuing = ProjectedWorkProgress(.indeterminate(stage: .calibration))

        #expect(ProhibitedClaimAudit.findings(in: readout).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: continuing).isEmpty)
        #expect(
            ProhibitedClaimAudit.findings(
                in: ProjectedWorkProgress(Self.determinate(completed: 1, total: 4))
            ).isEmpty
        )
    }
}

@Suite("Cancellation stays available throughout active work")
struct CancellationAvailabilityTests {

    @Test("Every active stage keeps the control visible and enabled",
          arguments: AnalysisStage.allCases)
    func availableAtEveryStage(stage: AnalysisStage) throws {
        let indeterminate = try AnalysisScreen.projecting(
            try ViewStateFixture.working(progress: .indeterminate(stage: stage))
        )
        let determinate = try AnalysisScreen.projecting(
            try ViewStateFixture.working(
                progress: .determinate(
                    completed: 1,
                    total: 2,
                    unit: .encodedBytes,
                    stage: stage
                )
            )
        )

        #expect(indeterminate.cancellation == .visibleAndEnabled)
        #expect(determinate.cancellation == .visibleAndEnabled)
    }

    @Test("Recovery is refused while work is in flight, so the control stays on screen")
    func recoveryRefusedWhileActive() async throws {
        let projector = await AnalysisViewStateProjector()
        try await projector.apply(try ViewStateFixture.working())

        let refusal = await projector.startNewSelection()

        #expect(refusal.wasAccepted == false)
        #expect(refusal.screen.family == .active)
        #expect(refusal.screen.cancellation == .visibleAndEnabled)
        #expect(await projector.screen.family == .active)
    }

    @Test("Recovery is refused while an ingest attempt is in flight")
    func recoveryRefusedWhileImporting() async throws {
        let projector = await AnalysisViewStateProjector()
        try await projector.apply(.importing(ImportAttemptSnapshot(route: .shareExtension)))

        let refusal = await projector.startNewSelection()

        #expect(refusal.wasAccepted == false)
        #expect(refusal.screen.family == .importing)
    }
}

@MainActor
@Suite("Recovery retains nothing from the ended session")
struct ViewStateRecoveryTests {

    @Test("A projector starts on the ready screen")
    func startsReady() {
        let projector = AnalysisViewStateProjector()

        #expect(projector.screen == .awaitingSelection)
        #expect(projector.projectedAttemptGeneration == nil)
    }

    @Test("The ready screen after a failure equals the launch ready screen")
    func readyAfterFailureIsIndistinguishable() throws {
        let launch = AnalysisViewStateProjector().screen

        let projector = AnalysisViewStateProjector()
        try projector.apply(
            try ViewStateFixture.ended(outcome: .failed(ViewStateFixture.failure()))
        )
        #expect(projector.screen.family == .error)

        let recovered = projector.startNewSelection()

        #expect(recovered.wasAccepted)
        #expect(projector.screen == launch)
        #expect(projector.screen == .ready(.awaitingSelection))
        #expect(projector.screen.identity == nil)
        #expect(projector.screen.analysisError == nil)
        #expect(projector.screen.evidenceReport == nil)
        #expect(projector.screen.workProgress == nil)
        #expect(projector.screen.recovery == nil)
    }

    @Test("The ready screen is the same value after every terminal outcome")
    func readyIsIdenticalAfterEveryTerminal() throws {
        let outcomes: [SessionTerminalOutcome] = [
            .completed(ViewStateFixture.pixelOnlyReport()),
            .cancelled,
            .failed(ViewStateFixture.failure()),
        ]

        var recovered: Set<AnalysisScreen> = []
        for outcome in outcomes {
            let projector = AnalysisViewStateProjector()
            try projector.apply(try ViewStateFixture.ended(outcome: outcome))
            projector.startNewSelection()
            recovered.insert(projector.screen)
        }

        #expect(recovered == [.awaitingSelection])
    }

    @Test("A new attempt shows only its own session")
    func newAttemptCarriesNoPriorSessionData() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(
            try ViewStateFixture.ended(
                session: "session.first",
                generation: 1,
                outcome: .failed(
                    ViewStateFixture.failure(session: "session.first", error: .resourceLimit)
                )
            )
        )
        projector.startNewSelection()

        try projector.apply(
            try ViewStateFixture.working(
                session: "session.second",
                generation: 2,
                progress: .determinate(
                    completed: 1,
                    total: 4,
                    unit: .encodedBytes,
                    stage: .inputValidation
                )
            )
        )

        #expect(projector.screen.family == .active)
        #expect(projector.screen.sessionID == ViewStateFixture.sessionID("session.second"))
        #expect(projector.screen.identity?.attemptGeneration == 2)
        #expect(projector.screen.analysisError == nil)
        #expect(projector.screen.workProgress?.readout?.completedWorkOutOfOneHundred == 25)
    }

    @Test("An observation of an earlier attempt cannot reappear on screen")
    func earlierAttemptIsRefused() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(
            try ViewStateFixture.ended(
                session: "session.first",
                generation: 1,
                outcome: .failed(ViewStateFixture.failure(session: "session.first"))
            )
        )
        try projector.apply(try ViewStateFixture.working(session: "session.second", generation: 2))
        let standing = projector.screen

        let refusal = try projector.apply(
            try ViewStateFixture.ended(
                session: "session.first",
                generation: 1,
                outcome: .failed(ViewStateFixture.failure(session: "session.first"))
            )
        )

        #expect(refusal.wasAccepted == false)
        #expect(refusal.screen == standing)
        #expect(projector.screen == standing)
        #expect(projector.screen.family == .active)
    }

    @Test("A finished attempt cannot go back to active work")
    func terminalDoesNotReturnToActive() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(try ViewStateFixture.ended(outcome: .cancelled))
        let standing = projector.screen

        let refusal = try projector.apply(try ViewStateFixture.working())

        #expect(refusal.wasAccepted == false)
        #expect(projector.screen == standing)
        #expect(projector.screen.family == .cancelled)
    }

    @Test("A second, different terminal for one attempt is refused")
    func secondTerminalIsRefused() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(try ViewStateFixture.ended(outcome: .cancelled))

        let refusal = try projector.apply(
            try ViewStateFixture.ended(outcome: .completed(ViewStateFixture.pixelOnlyReport()))
        )

        #expect(refusal.wasAccepted == false)
        #expect(projector.screen.family == .cancelled)
        #expect(projector.screen.evidenceReport == nil)
    }

    @Test("Observing the same terminal again changes nothing")
    func repeatedTerminalIsIdempotent() throws {
        let projector = AnalysisViewStateProjector()
        let snapshot = try ViewStateFixture.ended(
            outcome: .completed(ViewStateFixture.pixelOnlyReport())
        )
        try projector.apply(snapshot)
        let standing = projector.screen

        let repeated = try projector.apply(snapshot)

        #expect(repeated.wasAccepted)
        #expect(projector.screen == standing)
        #expect(projector.screen.family == .completed)
    }

    @Test("A second failure with the same category but different measurements is refused")
    func secondFailureWithSameCategoryIsRefused() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(
            try ViewStateFixture.ended(
                outcome: .failed(
                    ViewStateFixture.failure(
                        error: .decodingError,
                        inputQuality: ViewStateFixture.quality(width: 100, height: 200)
                    )
                )
            )
        )
        let standing = projector.screen

        let refusal = try projector.apply(
            try ViewStateFixture.ended(
                outcome: .failed(
                    ViewStateFixture.failure(
                        error: .decodingError,
                        inputQuality: ViewStateFixture.quality(width: 900, height: 800)
                    )
                )
            )
        )

        #expect(refusal.wasAccepted == false)
        #expect(projector.screen == standing)
        guard case let .error(errorScreen) = projector.screen else {
            Issue.record("expected the error family, found \(projector.screen.family)")
            return
        }
        #expect(errorScreen.inputQuality?.decodedWidthBeforeOrientation == 100)
    }

    @Test("A different completed report for a finished attempt is refused")
    func secondReportForFinishedAttemptIsRefused() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(
            try ViewStateFixture.ended(
                outcome: .completed(ViewStateFixture.pixelOnlyReport(pixel: .notEnoughSignal))
            )
        )
        let standing = projector.screen

        let refusal = try projector.apply(
            try ViewStateFixture.ended(
                outcome: .completed(
                    ViewStateFixture.pixelOnlyReport(pixel: .signalsConsistentWithAIGeneration)
                )
            )
        )

        #expect(refusal.wasAccepted == false)
        #expect(projector.screen == standing)
        #expect(projector.screen.evidenceReport?.pixel == .notEnoughSignal)
    }

    @Test("Idle and importing observations never lower the attempt watermark")
    func watermarkIsMonotonic() throws {
        let projector = AnalysisViewStateProjector()
        try projector.apply(try ViewStateFixture.working(session: "session.first", generation: 4))
        try projector.apply(.idle)

        #expect(projector.screen.family == .ready)
        #expect(projector.projectedAttemptGeneration == 4)

        let refusal = try projector.apply(
            try ViewStateFixture.working(session: "session.first", generation: 3)
        )

        #expect(refusal.wasAccepted == false)
        #expect(projector.screen.family == .ready)
    }
}

@MainActor
@Suite("Records that must agree are checked before anything is rendered")
struct ViewStateProjectionRefusalTests {

    @Test("A copy binding for another session is refused")
    func foreignCopyBindingIsRefused() throws {
        let snapshot = AnalysisSessionSnapshot(
            identity: ViewStateFixture.identity("session.first"),
            phase: .working(.indeterminate(stage: .inference)),
            copy: try ViewStateFixture.pixelOnlyBinding(session: "session.other")
        )

        #expect(throws: ViewStateProjectionError.copyBindingSessionMismatch(
            snapshot: ViewStateFixture.sessionID("session.first"),
            binding: ViewStateFixture.sessionID("session.other")
        )) {
            try AnalysisScreen.projecting(.session(snapshot))
        }
    }

    @Test("An Evidence Report from another session is refused")
    func foreignReportIsRefused() throws {
        let snapshot = AnalysisSessionSnapshot(
            identity: ViewStateFixture.identity("session.first"),
            phase: .ended(
                .completed(ViewStateFixture.pixelOnlyReport(session: "session.other"))
            ),
            copy: try ViewStateFixture.pixelOnlyBinding(session: "session.first")
        )

        #expect(throws: ViewStateProjectionError.reportSessionMismatch(
            snapshot: ViewStateFixture.sessionID("session.first"),
            report: ViewStateFixture.sessionID("session.other")
        )) {
            try AnalysisScreen.projecting(.session(snapshot))
        }
    }

    @Test("A failure snapshot from another session is refused")
    func foreignFailureIsRefused() throws {
        let snapshot = AnalysisSessionSnapshot(
            identity: ViewStateFixture.identity("session.first"),
            phase: .ended(.failed(ViewStateFixture.failure(session: "session.other"))),
            copy: try ViewStateFixture.pixelOnlyBinding(session: "session.first")
        )

        #expect(throws: ViewStateProjectionError.failureSessionMismatch(
            snapshot: ViewStateFixture.sessionID("session.first"),
            failure: ViewStateFixture.sessionID("session.other")
        )) {
            try AnalysisScreen.projecting(.session(snapshot))
        }
    }

    @Test("An unreachable copy surface fails closed rather than rendering a key")
    func unreachableSurfaceIsRefused() throws {
        // A pixel-only composition cannot address an enabled provenance state, so a report
        // claiming one cannot be rendered through a pixel-only binding.
        let report = EvidenceReport(
            binding: CopyFixture.sessionBinding(sessionID: "session.first"),
            pixel: .noStrongSignalDetected,
            provenance: .available(.absent),
            combinedSummary: nil,
            apparentInconsistency: nil,
            bytePreservationStatus: .originalBytes,
            inputQuality: ViewStateFixture.quality(),
            onDeviceProcessing: true,
            scope: .version1(id: CopyFixture.artifact("scope.evidence.synthetic"))
        )!
        let snapshot = AnalysisSessionSnapshot(
            identity: ViewStateFixture.identity("session.first"),
            phase: .ended(.completed(report)),
            copy: try ViewStateFixture.pixelOnlyBinding(session: "session.first")
        )

        #expect(throws: ViewStateProjectionError.copy(
            .unreachableSurface(.provenanceState(.absent))
        )) {
            try AnalysisScreen.projecting(.session(snapshot))
        }
    }

    @Test("A refused snapshot does not advance the attempt watermark")
    func refusedSnapshotDoesNotAdvanceTheWatermark() throws {
        let projector = AnalysisViewStateProjector()
        let mismatched = AnalysisSessionSnapshot(
            identity: ViewStateFixture.identity("session.first", generation: 5),
            phase: .ended(.failed(ViewStateFixture.failure(session: "session.other"))),
            copy: try ViewStateFixture.pixelOnlyBinding(session: "session.first")
        )

        #expect(throws: ViewStateProjectionError.self) {
            try projector.apply(.session(mismatched))
        }
        #expect(projector.projectedAttemptGeneration == nil)
        #expect(projector.screen == .awaitingSelection)

        // The correct snapshot for the same attempt still applies.
        try projector.apply(
            try ViewStateFixture.ended(
                session: "session.first",
                generation: 5,
                outcome: .failed(ViewStateFixture.failure(session: "session.first"))
            )
        )
        #expect(projector.screen.family == .error)
        #expect(projector.projectedAttemptGeneration == 5)
    }
}

@Suite("View-state models represent no prohibited claim")
struct ViewStateProhibitedClaimTests {

    @Test("Every projected screen payload is probability-free")
    func everyScreenIsClean() throws {
        for (family, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            let findings: [ProhibitedClaimAudit.Finding]
            switch try AnalysisScreen.projecting(snapshot) {
            case let .ready(screen): findings = ProhibitedClaimAudit.findings(in: screen)
            case let .importing(screen): findings = ProhibitedClaimAudit.findings(in: screen)
            case let .active(screen): findings = ProhibitedClaimAudit.findings(in: screen)
            case let .completed(screen): findings = ProhibitedClaimAudit.findings(in: screen)
            case let .cancelled(screen): findings = ProhibitedClaimAudit.findings(in: screen)
            case let .error(screen): findings = ProhibitedClaimAudit.findings(in: screen)
            }
            #expect(findings.isEmpty, "\(family): \(findings)")
        }
    }

    @Test("A fused completed screen is probability-free")
    func fusedScreenIsClean() throws {
        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.ended(
                outcome: .completed(ViewStateFixture.fusedReport()),
                copy: try ViewStateFixture.fusionBinding()
            )
        )
        guard case let .completed(completed) = screen else {
            Issue.record("expected the completed family, found \(screen.family)")
            return
        }

        #expect(ProhibitedClaimAudit.findings(in: completed).isEmpty)
    }

    @Test("The surfaces with no approved copy are written down and closed")
    func unapprovedSurfacesAreEnumerable() {
        #expect(UnapprovedViewStateSurface.allCases.count == 6)
        #expect(
            Set(UnapprovedViewStateSurface.allCases.map(\.rawValue)).count
                == UnapprovedViewStateSurface.allCases.count
        )
        #expect(SessionRecovery.allCases == [.selectAnotherImage])
    }
}

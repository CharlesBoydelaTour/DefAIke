import DefAIkeDomain
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeSharedTransfer
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 15.2: the final deterministic application-composition tests.
//
// Read `CompositionRootFidelityFixtures.swift` first. It states the blocker — the two
// composition roots live in Xcode-only targets no SwiftPM test can import, and the project
// declares no app-target unit-test target to put such a test in — and it states what this file
// does instead: it reproduces the composition roots' argument shape over their real
// collaborators, and it pins that shape against the composition roots' own source text so the
// reproduction cannot silently drift.
//
// Nothing below re-covers task 12.4 (both real ingest routes through the coordinator to a
// screen), 10.13 (the coordinator's error, ordering, retry, cleanup, resource, and
// cancellation matrix), 11.8 (reducer value snapshots), 11.9 (the accessibility projection
// over 74 screens), or 12.5 (archive-level offline behaviour). What is new is the composition
// root's own graph: the `nil` fuser, the `nil` provenance analyzer, the session-store-only
// deleter, the real `ProtectedEphemeralFileStore` under it, and the shipping default identity
// source and chunk size.

extension Tag {
    /// Task 15.2's application-composition scenarios.
    @Tag static var compositionRootFidelity: Self
}

// MARK: - Reading a cancelled screen

extension AnalysisScreen {
    /// The cancelled screen, or `nil` for every other family.
    ///
    /// The completed, error, and active accessors are task 12.4's and are reused. This one is
    /// added here because the terminal axis below covers all three terminals and the cancelled
    /// screen is the one no earlier accessor names.
    var cancelledScreenValue: CancelledScreen? {
        guard case let .cancelled(screen) = self else { return nil }
        return screen
    }
}

// MARK: - 1. Source-text correspondence

@Suite(
    "Composition roots: every wiring decision this file reproduces is the one they make",
    .tags(.compositionRootFidelity)
)
struct CompositionRootWiringFidelityTests {

    @Test(
        "Each reproduced wiring decision appears in the composition root that makes it",
        arguments: CompositionWiringDecision.allCases
    )
    func eachWiringDecisionIsMadeInItsCompositionRoot(
        decision: CompositionWiringDecision
    ) async throws {
        let code = try CompositionRootSourceAudit.strippedSource(of: decision.file)
        #expect(code.contains(decision.pinnedText))
        if let accompanying = decision.accompanyingText {
            #expect(code.contains(accompanying))
        }
    }

    @Test("Every composition-root source this file reads is present and nonempty")
    func everyCompositionRootSourceIsReadable() async throws {
        for file in CompositionRootFile.allCases {
            let code = try CompositionRootSourceAudit.strippedSource(of: file)
            #expect(!code.isEmpty)
        }
        #expect(CompositionRootFile.allCases.count == 6)
    }

    @Test("The main app's terminal cleanup is given the session store and no other namespace")
    func terminalCleanupIsGivenTheSessionStoreAlone() async throws {
        let code = try CompositionRootSourceAudit.strippedSource(of: .mainAppComposition)
        // The deleter the coordinator's terminal cleanup holds.
        #expect(code.contains("deleter: ProtectedSessionDataDeleter(namespaces: [sessionStore]),"))
        // No variant that would also hand it the App Group transfer subtree. A session
        // lifecycle that could delete a consented pending handoff would remove bytes the user
        // already agreed to hand over.
        #expect(!code.contains("namespaces: [sessionStore, transferStore]"))
        #expect(!code.contains("namespaces: [transferStore"))
        // `transferStore` exists in exactly two places: the store's own binding, and the
        // `SharedTransferStore` that owns the handoff lifecycle.
        let transferMentions = code.components(separatedBy: "transferStore").count - 1
        #expect(transferMentions == 2)
    }

    @Test("The startup sweep stores carry zero capacity, so the gate can retain nothing")
    func theStartupSweepStoresCarryZeroCapacity() async throws {
        let code = try CompositionRootSourceAudit.strippedSource(of: .mainAppComposition)
        #expect(code.contains("capacityInBytes: 0,"))
        // The two swept namespaces are the app-private root and the App Group session root.
        // Transfer scopes are deliberately not swept.
        #expect(code.contains("SessionStorageRoots.appPrivateRoot()"))
        #expect(code.contains("appGroupSessionRoot,"))
        #expect(code.contains("ProtectedSessionDataDeleter(namespaces: sweepStores)"))
    }

    @Test("The provenance lane is resolved from the composition's analyzer, never constructed")
    func theProvenanceLaneComesFromTheCompositionAnalyzer() async throws {
        let code = try CompositionRootSourceAudit.strippedSource(of: .mainAppComposition)
        #expect(code.contains("ProvenanceLaneProvider.resolve("))
        #expect(code.contains("analyzer: composition.provenanceAnalyzer("))
        // Neither fixed provider is reachable from the composition root: `pixelOnly` and
        // `capabilityNotEnabled` would each assert an unavailability reason rather than
        // resolving one from the module graph and the signed manifest together.
        #expect(!code.contains("ProvenanceLaneProvider.pixelOnly"))
        #expect(!code.contains("ProvenanceLaneProvider.capabilityNotEnabled"))
    }

    @Test("Comment stripping is load-bearing for the network sweep, not tidiness")
    func commentStrippingIsLoadBearing() async throws {
        let files = CompositionRootFile.allCases
        let stripped = try CompositionRootSourceAudit.networkFindings(in: files)
        let unstripped = try CompositionRootSourceAudit.unstrippedNetworkFindings(in: files)
        // Measured, not asserted in prose: the composition roots document that there is no
        // download and no remote catalogue, in three sentences that a naive sweep reads as
        // three findings.
        #expect(stripped.isEmpty)
        #expect(unstripped.count == 3)
        let unstrippedTokens = Set(unstripped.map(\.token))
        #expect(unstrippedTokens == ["download", "remote"])
    }
}

// MARK: - 2. Complete Photos and Share flows under the composition root's wiring

@Suite(
    "Composition graph: both routes complete under the composition root's own arguments",
    .tags(.compositionRootFidelity)
)
struct CompositionFaithfulFlowTests {

    @Test(
        "Each route reaches one report on the pixel-only composition",
        arguments: FlowRoute.allCases
    )
    func aRouteCompletesUnderTheCompositionRootsWiring(route: FlowRoute) async throws {
        // Pixel-only, because it is the only composition whose sessions can complete under the
        // composition root's own wiring today. See
        // `CompositionProvenanceLaneTests.aProvenanceCompositionCannotCompleteASessionAtAll`
        // for what the other two do and why.
        let graph = try await CompositionGraph.make(.pixelOnly)
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)

        let report = try #require(run.session.evidenceReport)
        #expect(report.binding.sessionID == run.sessionID)
        #expect(run.session.identity.generation == 1)
        // The route the ingest recorded survives to the accepted asset, and the report does
        // not carry it: two routes report identically.
        #expect(run.asset.route == route.recordedRoute)

        // The composition root's branch execution: serial, under the admitted plan.
        #expect(run.session.branchExecution == .serial)

        // No fusion port exists in any composition, so no fusion call can have happened and
        // no fusion fault can have been recorded.
        #expect(!graph.recorder.didCall(PortCallKind.fuse))
        #expect(run.session.fusionFault == nil)

        // No analyzer exists in any composition, so no provenance work can have happened.
        #expect(!graph.recorder.didCall(.provenanceAnalyze))

        let copy = try await graph.copyBinding(for: run.asset)
        let screen = try graph.screen(for: run.session, copy: copy)
        #expect(screen.family == .completed)
        let completed = try #require(screen.completedScreen)
        #expect(completed.identity.sessionID == run.sessionID)
        #expect(completed.recovery == .selectAnotherImage)
    }

    @Test(
        "Which terminal each composition reaches is decided by the composition, not the route",
        arguments: FlowRoute.allCases,
        FlowComposition.allCases
    )
    func theTerminalEachCompositionReachesIsTheSameOnBothRoutes(
        route: FlowRoute,
        composition: FlowComposition
    ) async throws {
        let graph = try await CompositionGraph.make(composition)
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)

        if composition.enablesProvenance {
            // Not a route difference and not a stub artefact: the session binding names the
            // Provenance Policy the signed manifest enabled, the lane resolved from a `nil`
            // analyzer names none, and the evidence join refuses a mismatch rather than
            // misattributing evidence.
            #expect(run.session.outcome.isFailed)
            #expect(run.session.error == .modelLoadError)
            let failure = try #require(run.session.outcome.failure)
            #expect(failure.stage == .evidenceJoining)
        } else {
            #expect(run.session.outcome.isCompleted)
            #expect(run.session.error == nil)
        }
        // Whatever the terminal, the session's material is gone and the branch execution is
        // the approved one.
        let remaining = await graph.sessionObjectCount(run.sessionID)
        #expect(remaining == 0)
        #expect(run.session.branchExecution == .serial)
    }

    @Test(
        "Every retained byte is gone from the session store once the terminal is committed",
        arguments: FlowRoute.allCases
    )
    func theSessionStoreKeepsNothingAfterTheTerminal(route: FlowRoute) async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)

        let remaining = await graph.sessionObjectCount(run.sessionID)
        #expect(remaining == 0)
        let occupied = await graph.sessionStore.occupiedScopes()
        #expect(occupied.isEmpty)
        // The handoff lifecycle's own subtree is empty too, because the claim resolved its
        // ticket — not because the session cleanup reached into it.
        let transferScopes = await graph.occupiedTransferScopes()
        #expect(transferScopes.isEmpty)
    }

    @Test(
        "Both stores request exactly the protection level the signed policy names",
        arguments: FlowRoute.allCases
    )
    func everyCreatedItemRequestedTheApprovedProtectionLevel(route: FlowRoute) async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        _ = try await graph.run(route)

        // The composition root reads one level from the Extension Execution Policy and passes
        // it everywhere. A run that requested two levels would mean two sources of truth.
        let requested = graph.protection.requestedLevels
        #expect(requested == [graph.protectionLevel])
        #expect(graph.protectionLevel == .complete)
        #expect(graph.protection.createdItemCount > 0)
        // Stated rather than implied: this host applier does not enforce the level, so nothing
        // here is Requirement 9.6 evidence.
        #expect(!graph.protection.enforcesDataProtection)
        let storeEnforces = await graph.sessionStore.enforcesDataProtection
        #expect(!storeEnforces)
    }

    @Test("The store's capacity is the bound budget's temporary-storage ceiling")
    func theStoreCapacityIsTheBoundBudgetCeiling() async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let budget = graph.configuration.resourceBudgets.budget(for: .mainApplication)
        let expected = try ProtectedEphemeralFileStore.configuration(
            rootDirectory: URL(filePath: "/dev/null"),
            budget: budget,
            containerProtection: graph.protectionLevel
        )
        let capacity = await graph.sessionStore.capacityInBytes
        #expect(capacity == expected.capacityInBytes)
        #expect(capacity == 1_000_000)
    }

    @Test("A second ingest cannot overlap a running session under this wiring")
    func aSecondIngestCannotOverlapARunningSession() async throws {
        let graph = try await CompositionGraph.make(gateInference: true)
        defer { graph.removeHostRoots() }
        let first = try await graph.acceptedIngest(.photos)
        let task = try #require(await graph.coordinator.startAnalysis(of: first))
        await graph.gate.waitUntilReached()

        let second = try await graph.acceptedIngest(.photos)
        let refused = await graph.coordinator.analyze(second)
        let refusedIdentity = refused.refusedIdentity
        #expect(refusedIdentity?.sessionID == first.sessionID)
        #expect(refused.completed == nil)

        await graph.gate.openGate()
        let session = try #require(await task.value.completed)
        #expect(session.outcome.isCompleted)
        #expect(session.sessionID == first.sessionID)
    }
}

// MARK: - 3. All terminal paths

@Suite(
    "Composition graph: all three terminal paths, on both routes",
    .tags(.compositionRootFidelity)
)
struct CompositionTerminalPathTests {

    @Test(
        "Each terminal is committed exactly once with nothing from the other two",
        arguments: FlowRoute.allCases,
        CompositionTerminal.allCases
    )
    func eachTerminalIsCommittedAloneOnEachRoute(
        route: FlowRoute,
        terminal: CompositionTerminal
    ) async throws {
        let session: CompletedAnalysisSession
        let sessionID: AnalysisSessionID
        let graph: CompositionGraph

        switch terminal {
        case .completed:
            graph = try await CompositionGraph.make()
            let run = try await graph.run(route)
            session = run.session
            sessionID = run.sessionID
        case .failed:
            // One post-ingest fault. Which one is 10.13's subject; that a failed terminal is
            // reachable under *this* wiring is this arm's.
            graph = try await CompositionGraph.make(
                validationFault: .analysis(.unsupportedMedia, stage: .inputValidation)
            )
            let asset = try await graph.acceptedIngest(route)
            sessionID = asset.sessionID
            session = try #require(await graph.coordinator.analyze(asset).completed)
        case .cancelled:
            graph = try await CompositionGraph.make(gateInference: true)
            let asset = try await graph.acceptedIngest(route)
            sessionID = asset.sessionID
            let task = try #require(await graph.coordinator.startAnalysis(of: asset))
            await graph.gate.waitUntilReached()
            let identity = try #require(await graph.coordinator.activeIdentity())
            await graph.coordinator.requestCancellation(for: identity)
            await graph.gate.openGate()
            session = try #require(await task.value.completed)
        }
        defer { graph.removeHostRoots() }

        #expect(session.sessionID == sessionID)
        switch terminal {
        case .completed:
            #expect(session.outcome.isCompleted)
            #expect(session.error == nil)
            #expect(!session.outcome.isCancelled)
        case .cancelled:
            #expect(session.outcome.isCancelled)
            #expect(session.evidenceReport == nil)
            #expect(session.error == nil)
        case .failed:
            #expect(session.outcome.isFailed)
            #expect(session.evidenceReport == nil)
            #expect(!session.outcome.isCancelled)
        }

        // Every terminal removes the session's material, and none of them leaves the handoff
        // subtree holding anything for a claimed ticket.
        let remaining = await graph.sessionObjectCount(sessionID)
        #expect(remaining == 0)
    }

    @Test(
        "Each terminal projects to its own screen family and no other",
        arguments: CompositionTerminal.allCases
    )
    func eachTerminalProjectsToItsOwnScreenFamily(
        terminal: CompositionTerminal
    ) async throws {
        let graph: CompositionGraph
        let asset: ImportedEncodedAsset
        let session: CompletedAnalysisSession

        switch terminal {
        case .completed:
            graph = try await CompositionGraph.make()
            let run = try await graph.run(.photos)
            asset = run.asset
            session = run.session
        case .failed:
            graph = try await CompositionGraph.make(
                model: StubOutcome(alwaysFailing: .analysis(.modelLoadError, stage: .modelLoad))
            )
            asset = try await graph.acceptedIngest(.photos)
            session = try #require(await graph.coordinator.analyze(asset).completed)
        case .cancelled:
            graph = try await CompositionGraph.make(gateInference: true)
            asset = try await graph.acceptedIngest(.photos)
            let task = try #require(await graph.coordinator.startAnalysis(of: asset))
            await graph.gate.waitUntilReached()
            let identity = try #require(await graph.coordinator.activeIdentity())
            await graph.coordinator.requestCancellation(for: identity)
            await graph.gate.openGate()
            session = try #require(await task.value.completed)
        }
        defer { graph.removeHostRoots() }

        let copy = try await graph.copyBinding(for: asset)
        let screen = try graph.screen(for: session, copy: copy)
        switch terminal {
        case .completed:
            #expect(screen.family == .completed)
            #expect(screen.completedScreen != nil)
            #expect(screen.errorScreen == nil)
            #expect(screen.cancelledScreenValue == nil)
        case .cancelled:
            #expect(screen.family == .cancelled)
            #expect(screen.cancelledScreenValue != nil)
            #expect(screen.completedScreen == nil)
            #expect(screen.errorScreen == nil)
        case .failed:
            #expect(screen.family == .error)
            #expect(screen.errorScreen != nil)
            #expect(screen.completedScreen == nil)
            #expect(screen.cancelledScreenValue == nil)
        }
    }

    @Test("The unpresentable fourth terminal stays unpresentable: no third outcome case")
    func thereIsNoFourthTerminalToPresent() async throws {
        // `SessionTerminalOutcome` has three cases, so a `handoff-error` failure committed
        // before Model Bundle binding is a `failed` terminal like any other — and the reason it
        // cannot be *shown* is not the outcome vocabulary but the copy binding: Requirement
        // 2.19 requires the terminal before binding, and `ApprovedCopyBinding.bind` needs a
        // binding. The composition root records that as `UnpresentableTerminalOutcome`, which
        // this package cannot import; task 12.4 pins that neither binder binds a session for
        // it. What is checkable here is that no fourth terminal exists to be handled instead.
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let run = try await graph.run(.claimedShare)
        let outcome = run.session.outcome
        let isOneOfThree = outcome.isCompleted || outcome.isCancelled || outcome.isFailed
        #expect(isOneOfThree)
        // A completed session is exactly one of the three, never two.
        let flags = [outcome.isCompleted, outcome.isCancelled, outcome.isFailed]
        let trueCount = flags.filter { $0 }.count
        #expect(trueCount == 1)
    }
}

// MARK: - 4. Pixel-only and provenance compositions

@Suite(
    "Composition graph: the provenance lane both shipping compositions actually get",
    .tags(.compositionRootFidelity)
)
struct CompositionProvenanceLaneTests {

    @Test(
        "With no conforming analyzer the lane is unavailable in every composition",
        arguments: FlowComposition.allCases
    )
    func theLaneIsUnavailableInEveryShippingComposition(
        composition: FlowComposition
    ) async throws {
        let graph = try await CompositionGraph.make(composition, analyzer: .absent)
        defer { graph.removeHostRoots() }

        #expect(!graph.provenance.isEnabled)
        #expect(graph.provenance.boundPolicyID == nil)
        #expect(!graph.provenance.canProduceCombinedSummary)
        // The reason is the same in all three, including the two whose signed manifest enables
        // the capability: a `nil` analyzer is the pixel-only lane regardless of the manifest.
        #expect(graph.provenance.unavailableReason == .validatorNotCompiledIntoRelease)
    }

    @Test(
        "The manifest still enables provenance in the two provenance compositions",
        arguments: FlowComposition.allCases
    )
    func theManifestStillEnablesWhatTheBinaryCannotSupply(
        composition: FlowComposition
    ) async throws {
        let graph = try await CompositionGraph.make(composition, analyzer: .absent)
        defer { graph.removeHostRoots() }

        // This is the pair that makes the reason wrong for a provenance build: the manifest
        // enables the capability and binds a policy, and the lane still reports that no
        // validator was compiled in — while the pixel-plus-provenance build *does* link
        // `DefAIkeProvenanceC2PA`. The honest reason would be "a validator is linked and does
        // not conform to the analysis port", and `UnavailableReason` has no case for it.
        #expect(graph.configuration.capabilityManifest.enablesProvenance
            == composition.enablesProvenance)
        if composition.enablesProvenance {
            #expect(graph.configuration.provenancePolicy != nil)
            #expect(graph.provenance.unavailableReason == .validatorNotCompiledIntoRelease)
        }
        // Pinned so the gap is auditable: adding a third reason is a copy-approval change.
        let reasons = UnavailableReason.allCases
        #expect(reasons.count == 2)
    }

    @Test(
        "The pixel-only report carries the unavailable lane and no bound policy",
        arguments: FlowRoute.allCases
    )
    func theReportCarriesTheUnavailableLane(route: FlowRoute) async throws {
        let graph = try await CompositionGraph.make(.pixelOnly, analyzer: .absent)
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)
        let report = try #require(run.session.evidenceReport)

        #expect(!report.provenance.isAvailable)
        #expect(report.combinedSummary == nil)
        // The binding names no policy either, which is what makes the lane and the binding
        // agree — and is exactly what a provenance-enabled build cannot arrange today.
        #expect(report.binding.provenancePolicyID == nil)
        #expect(report.provenance.unavailableReason == .validatorNotCompiledIntoRelease)
    }

    @Test(
        "A provenance composition cannot complete a session at all, on either route",
        arguments: FlowRoute.allCases,
        [FlowComposition.provenanceEnabled, .provenanceAndFusion]
    )
    func aProvenanceCompositionCannotCompleteASessionAtAll(
        route: FlowRoute,
        composition: FlowComposition
    ) async throws {
        // **Defect, reported and not fixed here.**
        //
        // `AnalysisSessionBinder` takes `provenancePolicyID` from `admission.enablesProvenance`
        // — a signed-manifest fact — so every session in a provenance-enabled build is bound to
        // a Provenance Policy. `ProvenanceLaneProvider.resolve(analyzer: nil, ...)` reports no
        // bound policy, because a `nil` analyzer is the pixel-only lane regardless of the
        // manifest. `EvidenceLaneJoin` then refuses "an unavailable lane in a session bound to
        // one" and the coordinator commits `model-load-error` at `evidenceJoining`.
        //
        // `CapabilityComposition.provenanceAnalyzer(store:policy:)` returns `nil` in *both*
        // shipping compositions, because `C2PAProvenanceValidator` deliberately does not conform
        // to `ProvenanceAnalyzing`. So as shipped, a pixel-plus-provenance build whose signed
        // manifest enables the capability cannot complete a single Analysis Session: every
        // session on both routes ends with an Analysis Error, and the "unavailable lane"
        // presentation is never reached at all.
        //
        // That is a stronger statement than the already-known one about the *reason* being
        // wrong: the reason is never displayed, because there is no completed report to display
        // it in. Resolving it is a release-configuration or adapter-conformance decision, not a
        // test change, so this arm pins the current behaviour rather than asserting the
        // behaviour anyone wants.
        let graph = try await CompositionGraph.make(composition, analyzer: .absent)
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)

        #expect(run.session.evidenceReport == nil)
        #expect(run.session.error == .modelLoadError)
        let failure = try #require(run.session.outcome.failure)
        #expect(failure.stage == .evidenceJoining)
        // The two halves that disagree, each read from its own side.
        let binder = graph.presentationBinder
        let bound = try await binder.bind(accepting: run.asset)
        await binder.release(run.asset.sessionID)
        #expect(bound.binding.provenancePolicyID == graph.configuration.provenancePolicy?.id)
        #expect(graph.provenance.boundPolicyID == nil)
    }

    @Test(
        "A conforming analyzer would produce an enabled lane, which no shipping module has",
        arguments: FlowComposition.allCases
    )
    func aConformingAnalyzerWouldEnableTheLane(
        composition: FlowComposition
    ) async throws {
        let graph = try await CompositionGraph.make(composition, analyzer: .fixture)
        defer { graph.removeHostRoots() }

        if composition.enablesProvenance {
            #expect(graph.provenance.isEnabled)
            #expect(graph.provenance.canProduceCombinedSummary)
            #expect(graph.provenance.boundPolicyID == graph.configuration.provenancePolicy?.id)
            #expect(graph.provenance.unavailableReason == nil)
        } else {
            // A validator compiled into a build whose manifest does not enable it.
            #expect(!graph.provenance.isEnabled)
            #expect(graph.provenance.unavailableReason
                == .capabilityNotEnabledByReleaseCapabilityManifest)
        }
    }

    @Test("An enabled lane is analyzed once per session, and the report carries its state")
    func anEnabledLaneIsAnalyzedOncePerSession() async throws {
        let graph = try await CompositionGraph.make(
            .provenanceEnabled,
            analyzer: .fixture,
            provenanceState: .absent
        )
        defer { graph.removeHostRoots() }
        let run = try await graph.run(.photos)
        let report = try #require(run.session.evidenceReport)

        #expect(report.provenance.isAvailable)
        #expect(graph.recorder.callCount(of: .provenanceAnalyze) == 1)
        // Still no summary: the composition root supplies no fusion port at all.
        #expect(report.combinedSummary == nil)
        #expect(!graph.recorder.didCall(PortCallKind.fuse))
    }
}

// MARK: - 5. No-summary fallbacks

@Suite(
    "Composition graph: no Combined Summary is reachable, and the reason is recorded",
    .tags(.compositionRootFidelity)
)
struct CompositionNoSummaryTests {

    @Test("The composition root's omitted fusion has no rule to hand the coordinator")
    func theOmittedFusionHasNoRule() async throws {
        // The exact value the composition root binds, and the exact member it reads from it.
        let fusion: OptionalFusion = .omitted(.noRuleBound)
        #expect(fusion.approvedRule == nil)
        let graph = try await CompositionGraph.make(.provenanceAndFusion)
        defer { graph.removeHostRoots() }
        // A fusion-enabled release still reaches the coordinator with no fusion port.
        #expect(graph.fusion == .omitted(.noRuleBound))
        #expect(graph.fusion.approvedRule == nil)
        #expect(graph.configuration.fusionRule != nil)
    }

    @Test(
        "The only composition that completes a session omits the summary for the lane",
        arguments: FlowRoute.allCases
    )
    func theSummaryIsOmittedForTheUnavailableLane(route: FlowRoute) async throws {
        // Pixel-only only. The two provenance compositions reach no completed screen at all
        // under the composition root's wiring, for the reason
        // `aProvenanceCompositionCannotCompleteASessionAtAll` records.
        let graph = try await CompositionGraph.make(.pixelOnly, analyzer: .absent)
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)
        let copy = try await graph.copyBinding(for: run.asset)
        let screen = try graph.screen(for: run.session, copy: copy)
        let completed = try #require(screen.completedScreen)
        let presentation = try EvidenceReportPresentation.assembling(completed, copy: copy)

        #expect(completed.combinedSummary == nil)
        #expect(presentation.combinedSummary == .omitted(.provenanceLaneUnavailable))
        #expect(presentation.combinedSummary.summary == nil)
        #expect(presentation.combinedSummary.fusionRuleID == nil)
    }

    @Test(
        "An available lane with no fusion port omits the summary for the other reason",
        arguments: FlowRoute.allCases
    )
    func theSummaryIsOmittedForTheCombinationInstead(route: FlowRoute) async throws {
        // The only way to reach the second omission reason at all: both lanes available and no
        // approved rule produced a summary. It needs a conforming analyzer, which no shipping
        // module supplies — so this arm is about the presentation layer's reason mapping over a
        // lane the current release cannot actually make available.
        let graph = try await CompositionGraph.make(
            .provenanceAndFusion,
            analyzer: .fixture,
            provenanceState: .absent
        )
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)
        let copy = try await graph.copyBinding(for: run.asset)
        let screen = try graph.screen(for: run.session, copy: copy)
        let completed = try #require(screen.completedScreen)
        let presentation = try EvidenceReportPresentation.assembling(completed, copy: copy)

        #expect(completed.combinedSummary == nil)
        #expect(presentation.combinedSummary == .omitted(.noApprovedSummaryForThisCombination))
    }

    @Test("Both omission reasons are covered, and there is no third")
    func bothOmissionReasonsAreCovered() async throws {
        let reasons = FusionOmissionReason.allCases
        #expect(reasons.count == 2)
        let raw = Set(reasons.map(\.rawValue))
        #expect(raw == ["provenance-lane-unavailable", "no-approved-summary-for-this-combination"])
    }
}

// MARK: - 6. Cleanup

@Suite(
    "Composition graph: terminal cleanup, over the real deleter the composition root builds",
    .tags(.compositionRootFidelity)
)
struct CompositionCleanupTests {

    @Test(
        "Each terminal's receipt carries that reason's own deadline",
        arguments: FlowRoute.allCases,
        CompositionTerminal.allCases
    )
    func theReceiptCarriesTheReasonsOwnDeadline(
        route: FlowRoute,
        terminal: CompositionTerminal
    ) async throws {
        let graph: CompositionGraph
        let session: CompletedAnalysisSession
        let expectedReason: SessionCleanupReason

        switch terminal {
        case .completed:
            graph = try await CompositionGraph.make()
            session = try await graph.run(route).session
            expectedReason = .completed
        case .failed:
            graph = try await CompositionGraph.make(
                preprocessingFault: .analysis(.preprocessingError, stage: .preprocessing)
            )
            let asset = try await graph.acceptedIngest(route)
            session = try #require(await graph.coordinator.analyze(asset).completed)
            expectedReason = .errorTerminated
        case .cancelled:
            graph = try await CompositionGraph.make(gateInference: true)
            let asset = try await graph.acceptedIngest(route)
            let task = try #require(await graph.coordinator.startAnalysis(of: asset))
            await graph.gate.waitUntilReached()
            let identity = try #require(await graph.coordinator.activeIdentity())
            await graph.coordinator.requestCancellation(for: identity)
            await graph.gate.openGate()
            session = try #require(await task.value.completed)
            expectedReason = .cancelled
        }
        defer { graph.removeHostRoots() }

        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.reason == expectedReason)
        // Non-vacuous: the five deadlines in this policy differ, so a mapping that selected
        // another reason's number fails here.
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: expectedReason))
        #expect(receipt.lifecyclePolicyID == graph.policy.id)
        #expect(receipt.sessionID == session.sessionID)
    }

    @Test("The five deadlines this cleanup is audited against are all different")
    func theFiveDeadlinesAreAllDifferent() async throws {
        let policy = IntegrationLifecycle.distinctPolicy()
        let deadlines = SessionCleanupReason.allCases.map { policy.deadline(for: $0) }
        #expect(Set(deadlines).count == SessionCleanupReason.allCases.count)
        #expect(deadlines.count == 5)
    }

    @Test(
        "The real deleter kept receipts and nothing image-derived",
        arguments: FlowRoute.allCases
    )
    func theDeleterKeptReceiptsAndNothingElse(route: FlowRoute) async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let run = try await graph.run(route)

        let records = await graph.deleter.retainedRecords()
        #expect(records.sessionReceipts.count == 1)
        let receipt = try #require(records.sessionReceipts.first)
        #expect(receipt.sessionID == run.sessionID)
        #expect(receipt.removedObjectCount >= 1)
        // The composition root's deleter holds only the session store, so it produced no
        // transfer receipts even on the Share route.
        #expect(records.transferReceipts.isEmpty)
    }

    @Test("A repeated cleanup of the same session removes nothing and still reports")
    func aRepeatedCleanupRemovesNothing() async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let run = try await graph.run(.photos)
        let first = try #require(run.session.cleanup.receipt)
        #expect(first.removedObjectCount >= 1)

        let cleanup = SessionTerminalCleanup(deleter: graph.deleter, policy: graph.policy)
        let second = await cleanup.removeMaterial(for: run.sessionID, after: run.session.outcome)
        let receipt = try #require(second.receipt)
        #expect(receipt.removedObjectCount == 0)
        #expect(receipt.reason == .completed)
    }

    @Test("The session cleanup leaves the handoff subtree to the transfer lifecycle")
    func theSessionCleanupDoesNotOwnTheTransferSubtree() async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        // Publish a handoff and never claim it, so the transfer subtree holds something.
        guard case .published = try await graph.publishShareHandoff() else {
            throw CompositionGraphFailure.noPublishedHandoff
        }
        let beforeScopes = await graph.occupiedTransferScopes()
        #expect(!beforeScopes.isEmpty)

        // Run an unrelated Photos session to a terminal. Its cleanup owns the session store
        // alone, so the pending handoff the user already consented to survives it.
        let run = try await graph.run(.photos)
        #expect(run.session.outcome.isCompleted)
        let afterScopes = await graph.occupiedTransferScopes()
        #expect(afterScopes == beforeScopes)
    }
}

// MARK: - 7. Retry

@Suite(
    "Composition graph: a retry is a new attempt that inherits nothing",
    .tags(.compositionRootFidelity)
)
struct CompositionRetryTests {

    @Test(
        "A retry after a fault completes as a second generation on each route",
        arguments: FlowRoute.allCases
    )
    func aRetryAfterAFaultCompletes(route: FlowRoute) async throws {
        // Fail once, then succeed, so the first attempt's fault cannot reach the second.
        let graph = try await CompositionGraph.make(
            logit: StubOutcome([.fault(.analysis(.inferenceError, stage: .inference)), .success(PortValue.logit(1.5))])
        )
        defer { graph.removeHostRoots() }

        let firstAsset = try await graph.acceptedIngest(route)
        let first = try #require(await graph.coordinator.analyze(firstAsset).completed)
        #expect(first.outcome.isFailed)
        #expect(first.identity.generation == 1)

        let secondAsset = try await graph.acceptedIngest(route)
        let second = try #require(await graph.coordinator.analyze(secondAsset).completed)
        #expect(second.outcome.isCompleted)
        #expect(second.error == nil)
        #expect(second.evidenceReport != nil)

        // A retry from a new selection is a new session, so the identifiers differ. The
        // generation is the coordinator's attempt counter rather than a per-session one, so the
        // second attempt is generation 2 even though it is a different session. Recorded as
        // measured rather than as expected: an attempt counter is what makes a late observation
        // refusable by identity, and it does not carry anything from the first attempt.
        #expect(secondAsset.sessionID != firstAsset.sessionID)
        #expect(second.identity.generation == 2)
        // Neither attempt's material survives.
        let firstRemaining = await graph.sessionObjectCount(firstAsset.sessionID)
        let secondRemaining = await graph.sessionObjectCount(secondAsset.sessionID)
        #expect(firstRemaining == 0)
        #expect(secondRemaining == 0)
    }

    @Test("Re-analyzing the same accepted ingest increments the attempt generation")
    func reanalyzingTheSameIngestIncrementsTheGeneration() async throws {
        let graph = try await CompositionGraph.make(
            logit: StubOutcome([.fault(.analysis(.inferenceError, stage: .inference)), .success(PortValue.logit(1.5))])
        )
        defer { graph.removeHostRoots() }
        let asset = try await graph.acceptedIngest(.photos)

        let first = try #require(await graph.coordinator.analyze(asset).completed)
        #expect(first.outcome.isFailed)
        #expect(first.identity.generation == 1)

        let second = try #require(await graph.coordinator.analyze(asset).completed)
        #expect(second.identity.generation == 2)
        #expect(second.sessionID == asset.sessionID)
        #expect(second.outcome.isCompleted)
        // The second attempt carries its own report, and the first carried none.
        #expect(first.evidenceReport == nil)
        let report = try #require(second.evidenceReport)
        #expect(report.binding.sessionID == asset.sessionID)
    }

    @Test("The retry's screen names the retry, and the superseded attempt is refused")
    func theScreenAdvancesToTheRetry() async throws {
        let graph = try await CompositionGraph.make(
            logit: StubOutcome([.fault(.analysis(.inferenceError, stage: .inference)), .success(PortValue.logit(1.5))])
        )
        defer { graph.removeHostRoots() }
        let asset = try await graph.acceptedIngest(.photos)
        let copy = try await graph.copyBinding(for: asset)

        let first = try #require(await graph.coordinator.analyze(asset).completed)
        let second = try #require(await graph.coordinator.analyze(asset).completed)

        let projector = await AnalysisViewStateProjector()
        let firstScreen = try await projector.apply(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: first.sessionID,
                        attemptGeneration: first.identity.generation
                    ),
                    phase: .ended(first.outcome),
                    copy: copy
                )
            )
        )
        #expect(firstScreen.wasAccepted)

        let secondScreen = try await projector.apply(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: second.sessionID,
                        attemptGeneration: second.identity.generation
                    ),
                    phase: .ended(second.outcome),
                    copy: copy
                )
            )
        )
        #expect(secondScreen.wasAccepted)
        #expect(secondScreen.screen.family == .completed)

        // Offering the superseded attempt again leaves the standing screen alone.
        let superseded = try await projector.apply(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: first.sessionID,
                        attemptGeneration: first.identity.generation
                    ),
                    phase: .ended(first.outcome),
                    copy: copy
                )
            )
        )
        #expect(!superseded.wasAccepted)
        #expect(superseded.screen.family == .completed)
    }
}

// MARK: - 8. Accessibility projection of the screens this graph produces

@Suite(
    "Composition graph: the accessibility projection of the screens it actually produces",
    .tags(.compositionRootFidelity)
)
struct CompositionAccessibilityProjectionTests {

    /// The snapshot for one terminal this graph reached.
    private func snapshot(
        for terminal: CompositionTerminal
    ) async throws -> AccessibilitySemanticsSnapshot {
        let graph: CompositionGraph
        let asset: ImportedEncodedAsset
        let session: CompletedAnalysisSession

        switch terminal {
        case .completed:
            graph = try await CompositionGraph.make()
            let run = try await graph.run(.photos)
            asset = run.asset
            session = run.session
        case .failed:
            graph = try await CompositionGraph.make(
                evidence: StubOutcome(alwaysFailing: .analysis(.calibrationInputError, stage: .calibration))
            )
            asset = try await graph.acceptedIngest(.photos)
            session = try #require(await graph.coordinator.analyze(asset).completed)
        case .cancelled:
            graph = try await CompositionGraph.make(gateInference: true)
            asset = try await graph.acceptedIngest(.photos)
            let task = try #require(await graph.coordinator.startAnalysis(of: asset))
            await graph.gate.waitUntilReached()
            let identity = try #require(await graph.coordinator.activeIdentity())
            await graph.coordinator.requestCancellation(for: identity)
            await graph.gate.openGate()
            session = try #require(await task.value.completed)
        }
        defer { graph.removeHostRoots() }

        let copy = try await graph.copyBinding(for: asset)
        let screen = try graph.screen(for: session, copy: copy)
        return try AccessibilitySemanticsSnapshot.projecting(screen: screen, copy: copy)
    }

    @Test("The shipped copy resolver the composition root reads resolves four elements in nine")
    func theShippedCopyResolverIsReadable() async throws {
        // The composition root's last startup step before the graph is assembled: a build that
        // cannot read its approved English is refused rather than shown a localization key. So
        // the resolver has to load — and then the honest measurement is how little of the
        // completed screen it can render.
        let resolver = try AccessibleTextResolver.shipped()
        let snapshot = try await snapshot(for: .completed)
        let renderable = resolver.renderableElements(in: snapshot)
        let unresolvable = resolver.unresolvableElements(in: snapshot)
        #expect(renderable.count + unresolvable.count == snapshot.elements.count)

        // Measured on the completed screen this graph produces: nine exposed elements, four of which
        // the shipped English String Catalog can render.
        //
        // The element count fell from ten to nine even as the screen gained a control. Three per-path
        // rows became one `informationPath`, and one `limitationsDisclosure` was added:
        // 10 - 3 + 1 + 1 = 9.
        //
        // The four renderable ones are the pixel label, which resolves through `FixedPixelLabelText`
        // with no catalog lookup at all, and three chrome-addressed controls: the disclosure, the
        // information path, and the recovery.
        //
        // **Why the five verdict-addressed fields still miss, even though the shipped catalog now
        // carries proposed wording for every one of those surfaces.** This suite's fixture builds its
        // own catalogue (`catalog.verdict-copy.flow-superset`) under a *different key convention*:
        // `copy.surface.evidence-scope`, where the shipped catalog and the development provisioning
        // both use `copy.evidence-scope`. So the addresses these elements carry are not the addresses
        // the shipped catalog holds, and the miss is a fixture-convention mismatch rather than a
        // measure of the copy gap.
        //
        // That distinction is worth stating rather than papering over, because the number here no
        // longer means what it used to. `StringCatalogCoverageTests` and
        // `PresentationReducerSnapshotTests` measure the real coverage against a binding whose keys
        // follow the shipped convention; this test measures that the resolver *loads* and that a
        // mismatched address fails closed instead of rendering a key.
        #expect(snapshot.elements.count == 9)
        #expect(renderable.count == 4)
        #expect(unresolvable.count == 5)
        #expect(
            unresolvable.allSatisfy { $0.label.copyReference != nil },
            "every unresolvable element must be verdict-addressed; a chrome address should resolve"
        )
        #expect(
            renderable.allSatisfy { $0.label.copyReference == nil },
            "every renderable element is either the fixed pixel label or chrome-addressed"
        )
        #expect(snapshot.recordedCopyGaps.isEmpty == false)
    }

    @Test(
        "No element in the snapshot exposes an accessibility value",
        arguments: CompositionTerminal.allCases
    )
    func noElementExposesAValue(terminal: CompositionTerminal) async throws {
        let snapshot = try await snapshot(for: terminal)
        let values = snapshot.elements.map(\.value)
        #expect(values.allSatisfy { $0 == nil })

        // Non-vacuous on the completed screen, which really does expose nine elements. It was ten
        // before three per-path rows became one `informationPath` and a `limitationsDisclosure` was
        // added.
        if terminal == .completed {
            #expect(values.count == 9)
            #expect(snapshot.exposes(.limitationsDisclosure))
        }

        // Requirement 12.2 is still satisfied here only by its escape hatch: "every exposed value is
        // nonempty" is vacuously true when no value is exposed at all.
        //
        // **Known audit boundary, and it is new.** The limitations disclosure does speak a state on
        // screen - `AccessibleElementView` resolves `ChromeCopySurface.disclosureExpandedState` or
        // `.disclosureCollapsedState` and applies it as the element's accessibility value, so
        // Requirement 12.7 is met and the chevron is not the only channel. But whether a group is
        // expanded is *view* state, and `AccessibilityScreenInput` carries none, so the snapshot
        // cannot model it and this seam cannot see it.
        //
        // That is a real gap in what a host test can check, not a claim that the value is absent:
        // the value exists at the view layer and is asserted there by a simulator run, not here.
        // Closing it properly means threading expansion state into the projection, which is a
        // change to the projection's inputs rather than to this test.
        #expect(snapshot.everyExposedValueIsNonempty)
        #expect(snapshot.everyElementHasANonemptyLabel)
        #expect(snapshot.everyElementCarriesItsRoleTraits)
    }

    @Test(
        "The workflows operable on each terminal screen this graph produces, per terminal",
        arguments: CompositionTerminal.allCases
    )
    func operableWorkflowsPerTerminal(terminal: CompositionTerminal) async throws {
        let snapshot = try await snapshot(for: terminal)
        let operability = WorkflowOperability.evaluating(snapshot)
        #expect(operability.count == 7)
        let operable = operability.filter(\.isOperable).map(\.workflow)
        let operableSet = Set(operable)
        // Measured per terminal. Previously the completed report was the only screen on which any
        // workflow was operable, and the cancelled and error screens had none — because the
        // controls those workflows need had no approved label.
        //
        // The chrome copy vocabulary labels the selection control, so ingest and retry become
        // operable wherever that control appears: on the completed report and on the cancelled
        // screen. The error screen is unchanged and still has none, because it exposes its
        // recovery as `.analysisErrorRecovery` while both workflows require
        // `.imageSelectionControl` — see `retryIsInoperableWithNoBlockingGap` below.
        switch terminal {
        case .completed:
            #expect(operableSet == [.ingest, .retry, .resultReview, .limitationReview])
        case .cancelled:
            #expect(operableSet == [.ingest, .retry])
        case .failed:
            #expect(operableSet.isEmpty)
        }
        // Analysis and cancellation are never operable on a *terminal* screen, and that is a
        // structural fact rather than a copy gap: both require the progress field, which only the
        // active family carries. Handoff consent is never operable here at all, because its
        // presenter is the Share Extension.
        let neverOperableOnATerminal: Set<AccessibilityWorkflow> = [
            .handoffConsent, .analysis, .cancellation,
        ]
        #expect(operableSet.isDisjoint(with: neverOperableOnATerminal))
    }

    @Test("Retry is inoperable on an error screen with no recorded gap to point at")
    func retryIsInoperableWithNoBlockingGap() async throws {
        let snapshot = try await snapshot(for: .failed)
        let retry = WorkflowOperability.evaluating(.retry, in: snapshot)
        #expect(!retry.isOperable)
        // The mismatch, stated as a value: retry requires the image-selection control, and an
        // error screen exposes the analysis-error recovery control instead. So the element is
        // absent from this screen rather than blocked, and nothing is waiting on an approval —
        // `blockingGaps` is empty even though the workflow cannot be completed.
        let required = WorkflowOperability.requiredIdentities(for: .retry)
        #expect(required == [.imageSelectionControl])
        let gaps = retry.blockingGaps
        #expect(gaps.isEmpty)
        let unusable = retry.unusableElements.map(\.identity)
        #expect(unusable == [.imageSelectionControl])
    }

    @Test("Handoff consent is presented by a target this module cannot reach")
    func handoffConsentIsPresentedElsewhere() async throws {
        let snapshot = try await snapshot(for: .completed)
        let consent = WorkflowOperability.evaluating(.handoffConsent, in: snapshot)
        #expect(consent.presenter == .shareExtension)
        #expect(!consent.isOperable)
        // Not a gap in this module: consent is collected in the Share Extension, whose module
        // closure cannot reach the presentation layer at all. The composition root that
        // presents it is `ShareExtensionComposition`, and it is not importable from here.
        #expect(consent.requiredElements.isEmpty)
        #expect(consent.blockingGaps.isEmpty)
    }

    @Test("The two assistive conditions this layer answers for are the element-availability ones")
    func theCoveredConditionsAreTheElementOnes() async throws {
        let covered = WorkflowOperability.coveredConditions
        #expect(covered == [.voiceOver, .switchControl])
        let all = Set(AssistiveCondition.allCases)
        #expect(all.subtracting(covered) == [.largestDynamicType, .reduceMotion])
    }
}

// MARK: - 9. The startup collaborators each refusal branch runs through

@Suite(
    "Composition roots: each startup step's collaborator refuses the way the root reports",
    .tags(.compositionRootFidelity)
)
struct CompositionStartupCollaboratorTests {

    @Test("A budget with no usable temporary-storage ceiling leaves no store configurable")
    func anUnusableStorageCeilingLeavesNoStoreConfigurable() async throws {
        // The `sessionStoreNotConfigurable` branch. `ProtectedEphemeralFileStore` truncates a
        // ceiling rather than rounding it, so a sub-byte approved limit yields no capacity and
        // the store refuses instead of choosing a number.
        let budget = CompositionSample.budgetWithUnusableTemporaryStorage()
        var thrown: ProtectedEphemeralFileStore.ConfigurationError?
        do {
            _ = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: URL(filePath: "/dev/null"),
                budget: budget,
                containerProtection: .complete
            )
        } catch {
            thrown = error
        }
        #expect(thrown == .temporaryStorageLimitUnavailable(budget.id))
    }

    @Test("A usable ceiling configures a store whose capacity is exactly that ceiling")
    func aUsableCeilingConfiguresTheStore() async throws {
        let configuration = try ProtectedEphemeralFileStore.configuration(
            rootDirectory: URL(filePath: "/dev/null"),
            budget: CoordinatorSample.budgetSet().mainApplication,
            containerProtection: .complete
        )
        #expect(configuration.capacityInBytes == 1_000_000)
        #expect(configuration.containerProtection == .complete)
    }

    @Test("The startup sweep store is structurally incapable of retaining a byte")
    func theStartupSweepStoreHasNoCapacity() async throws {
        // The composition root builds its sweep stores with `capacityInBytes: 0`, so the store
        // the gate cleans up with cannot become the store a session writes to. This checks the
        // configured capacity only; whether a `create` inside a data-protected directory
        // refuses is a file-system question and is not asked on this host.
        guard let root = CompositionGraph.makeHostRoot("sweep") else {
            throw CompositionGraphFailure.hostDirectoryUnavailable
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProtectedEphemeralFileStore(
            configuration: ProtectedEphemeralFileStore.Configuration(
                rootDirectory: root,
                capacityInBytes: 0,
                containerProtection: .complete
            ),
            protection: HostRecordingDataProtection()
        )
        let capacity = await store.capacityInBytes
        #expect(capacity == 0)
    }

    @Test("The Resource Controller refuses the other target's governor and binds this one")
    func theResourceControllerRefusesTheOtherTargetsGovernor() async throws {
        // The `resourceControllerNotBindable` branch. A controller holding the other target's
        // governor has no correct behaviour available to it.
        let budgets = CoordinatorSample.budgetSet()
        let mismatched = ResourceController(
            target: .mainApplication,
            budgets: budgets,
            governor: FakeResourceGovernor(target: .shareExtension)
        )
        #expect(mismatched == nil)

        let bound = ResourceController(
            target: .mainApplication,
            budgets: budgets,
            governor: FakeResourceGovernor(target: .mainApplication)
        )
        let controller = try #require(bound)
        let boundTarget = await controller.target
        let boundBudgetID = await controller.budget.id
        #expect(boundTarget == .mainApplication)
        #expect(boundBudgetID == budgets.mainApplication.id)
    }

    @Test("A Calibration Policy citing absent evidence cannot be activated")
    func aPolicyCitingAbsentEvidenceCannotBeActivated() async throws {
        // The `calibrationPolicyNotActivatable` branch: a policy that does not activate keeps
        // the bundle unusable rather than becoming a `calibration-input-error`.
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let manifest = graph.release.bundle.manifest

        let activated = try ValidatedCalibrationPolicy(
            activating: graph.configuration.calibrationPolicy,
            for: manifest,
            evidence: try CompositionSample.evidenceIndex()
        )
        #expect(activated.id == graph.configuration.calibrationPolicy.id)
        #expect(activated.modelBundle == manifest.bundleID)

        var refused = false
        do {
            _ = try ValidatedCalibrationPolicy(
                activating: graph.configuration.calibrationPolicy,
                for: manifest,
                evidence: try CompositionSample.mismatchedEvidenceIndex()
            )
        } catch {
            refused = true
        }
        #expect(refused)
    }

    @Test("The two App Group namespaces are siblings, so neither lifecycle can reach the other")
    func theTwoAppGroupNamespacesAreSiblings() async throws {
        // What this arm originally tried to establish was the
        // `appGroupContainerUnresolvable` branch: an unregistered App Group refusing to resolve.
        // Measured, that is **not** what happens on this host — `FileManager` hands back a
        // Group Containers path for an unentitled identifier on macOS, so both resolvers
        // succeed and the refusal branch is unreachable here. It is left unverified rather than
        // asserted, and it is stated as unverified rather than quietly dropped.
        //
        // What *is* checkable is the claim the composition root makes about the two namespaces
        // it resolves: they are siblings, so the session lifecycle and the transfer lifecycle
        // cannot delete each other's bytes. The composition root's terminal cleanup owns only
        // the session store, and this is the structural half of why that is safe.
        let group = "group.dev.defaike.t152-probe"
        let sessionRoot = try SessionStorageRoots.appGroupRoot(forAppGroup: group)
        let transferRoot = try AppGroupContainer.transferRoot(forAppGroup: group)

        #expect(sessionRoot != transferRoot)
        #expect(sessionRoot.deletingLastPathComponent() == transferRoot.deletingLastPathComponent())
        // Neither contains the other, so removing one subtree cannot remove the other's bytes.
        let sessionPath = sessionRoot.path
        let transferPath = transferRoot.path
        #expect(!sessionPath.hasPrefix(transferPath + "/"))
        #expect(!transferPath.hasPrefix(sessionPath + "/"))

        // The app-private namespace needs no App Group at all, and is distinct from both.
        let appPrivate = SessionStorageRoots.appPrivateRoot()
        #expect(!appPrivate.path.isEmpty)
        #expect(appPrivate != sessionRoot)
        #expect(appPrivate != transferRoot)
    }

    @Test("The branch execution the composition root approves is serial under its bound plan")
    func theApprovedBranchExecutionIsSerialUnderTheBoundPlan() async throws {
        let graph = try await CompositionGraph.make()
        defer { graph.removeHostRoots() }
        let approved = ApprovedEvidenceBranchExecution(
            execution: .serial,
            validationPlan: graph.release.admission.boundValidationPlan
        )
        #expect(approved.execution == .serial)
        #expect(approved.validationPlan == graph.release.admission.boundValidationPlan)
        // And the sessions this graph ran really ran that way.
        let run = try await graph.run(.photos)
        #expect(run.session.branchExecution == .serial)
    }
}

// MARK: - 10. Offline operation

@Suite(
    "Composition roots: no network surface in either graph, and the archive asymmetry stated",
    .tags(.compositionRootFidelity)
)
struct CompositionOfflineSurfaceTests {

    @Test(
        "No composition-root source mentions a network entry point",
        arguments: CompositionRootFile.allCases
    )
    func noCompositionRootMentionsANetworkEntryPoint(
        file: CompositionRootFile
    ) async throws {
        let findings = try CompositionRootSourceAudit.networkFindings(in: [file])
        #expect(findings.isEmpty)
    }

    @Test("A full session on both routes reaches no port that could leave the device")
    func aFullSessionReachesNoNetworkCapablePort() async throws {
        for route in FlowRoute.allCases {
            let graph = try await CompositionGraph.make(.pixelOnly)
            defer { graph.removeHostRoots() }
            let run = try await graph.run(route)
            #expect(run.session.outcome.isCompleted)
            // The port vocabulary is closed and has no network member, so the strongest
            // available statement is about which ports ran. Every one of them is local.
            let kinds = graph.recorder.recordedKinds
            let localOnly = kinds.isSubset(of: Set(PortCallKind.allCases))
            #expect(localOnly)
            #expect(!kinds.contains(.provenanceAnalyze))
        }
    }

    @Test("The provenance composition's offline guarantee is configuration, not absence")
    func theProvenanceOfflineGuaranteeIsConfigurationRatherThanAbsence() async throws {
        // The asymmetry, stated precisely rather than flattened:
        //
        //   * The pixel-only composition links no validator, so no network symbol exists in
        //     its archive at all. Its guarantee is absence.
        //   * The pixel-plus-provenance composition statically links a Rust HTTP/2 and TLS
        //     stack through `c2pa-swift`, plus swift-certificates' OCSP client. Its guarantee
        //     is runtime configuration: remote manifest fetch off, OCSP fetch off, no allowed
        //     network hosts.
        //
        // Task 12.5 owns the archive-level evidence for both halves and is not repeated here.
        // What this arm establishes is the composition-root half: with no conforming analyzer
        // in either build, the validator is never reached from the graph at all, so today
        // neither composition can make a network call *through the analysis lane* regardless
        // of what its archive contains.
        for composition in FlowComposition.allCases {
            let graph = try await CompositionGraph.make(composition, analyzer: .absent)
            defer { graph.removeHostRoots() }
            #expect(!graph.provenance.isEnabled)
            #expect(graph.provenance.inspectionRequest(
                for: try await graph.acceptedIngest(.photos)
            ) == nil)
        }
    }
}

import DefAIkeDomain
import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 29: hard resource limits fail without evidence.
//
// The design states it as: for any main-app or extension resource-measurement stream and
// its valid target budget, measurements within every hard limit do not cause a resource
// failure, while the first value whose continued work would exceed a hard limit stops
// pending work and returns only `resource-limit`; the main app commits no evidence, and the
// extension creates no ready ticket, session, or inference (Requirements 11.6 and 11.8).
//
// ## The sentence has three halves, and each one needs a different kind of measurement
//
//   1. **In budget is not a failure.** Every case runs the *same* generated stream twice
//      over two independently constructed controller pairs: once with every reading inside
//      its limit, once with one reading over. The clean pass must produce no fault, latch no
//      breach, keep permitting its target's commit, keep the headroom it was granted, and
//      keep sampling the governor once per event. Without that pass, "the breach stopped the
//      work" would be indistinguishable from a controller that stops everything.
//   2. **The *first* would-exceed event, and only `resource-limit`.** The breach position is
//      generated inside the stream rather than fixed at the front, so every case has a
//      measured in-budget prefix and a measured post-breach tail. The tail is where the
//      sharp claim lives: every later event — including one whose reading has *recovered* to
//      inside the limit — must report the same latched fault, carrying the *first* breach's
//      metric and stage, and the set of error categories the whole stream produced must be
//      exactly `["resource-limit"]`. "Only" is asserted as set equality over ten
//      categories, not as "one of them was resource-limit".
//   3. **Two different consequences on two different targets.** Requirements 11.6 and 11.8
//      are not the same statement twice, so this file does not assert one and infer the
//      other:
//        * On the **main application** the consequence is *no evidence*. It is measured on a
//          real ``AnalysisCoordinator`` session, not on the controller alone: the fault the
//          main-app controller actually returned is handed to the pipeline port that owns
//          the stage it names, and the session's single terminal must be `failed` with
//          exactly `resource-limit`, with no Evidence Report, no calibrated Pixel Evidence
//          past the stopping point, no Provenance Evidence, and no Combined Summary.
//        * On the **Share Extension** the consequence is *no ready session*. The extension's
//          only session-creating commit is the ready transfer ticket (Requirement 11.11), so
//          the observable form is that ``ResourceController/permits(_:)`` answers `true` for
//          it on every in-budget event and `false` from the first would-exceed event onward.
//          It **flips**, which an assertion about the main-app controller could not show:
//          a main-app controller refuses a ready ticket even with no breach at all.
//
// ## Every absence is measured beside a presence
//
// Three pairings, all on the same case:
//
//   * the breaching controller pair sits beside the clean controller pair, over the same
//     stream, the same budgets, and the same governor programming;
//   * the failed session sits beside a positive-control session on the *same* release, the
//     same ports, and the same shared call log, which completes with a real Evidence Report
//     — and, in a provenance-enabled composition, a real provenance lane and a real Combined
//     Summary, so "the failure has neither" is a measured zero beside a measured one rather
//     than a property of a composition that never produces either; and
//   * the extension's refused ready ticket sits beside the same controller permitting it
//     before the breach.
//
// Both compositions are generated. A pixel-only release cannot produce a provenance result
// or a summary at all, so a run that only ever built one would make two of the "no evidence"
// zeros vacuous; the witness requires provenance-enabled cases to have produced both.
//
// ## Nothing is raced, and nothing sleeps
//
// Every event is a synchronous actor step delivered in the order this file chose. The
// governor is programmed immediately before the checkpoint that samples it, so a stream is a
// sequence of decided measurements rather than a sampling race. No arm sleeps, polls a wall
// clock, or starts a task it does not await.
//
// ## No approved value appears anywhere in this file
//
// **No limit, reading, amount, or unit here is an approved release value.** Every hard limit
// is read out of the release's own signed ``ResourceBudgetSet`` — this file never states a
// limit, it states "one more than whatever the bound budget says" and "the bound limit minus
// a small offset" — and the release is ``CoordinatorRelease``, whose every artifact is
// synthetic. The real budgets are an unresolved external decision measured by the Device
// Validation Plan (design decision D6), and a test that hard-coded one would be making that
// decision in code.
//
// ## What this file does not claim
//
//   * **Property 28 (task 2.7) owns budget completeness and authority.** Nothing here claims
//     a budget is well formed; the budgets come from a release that already passed its own
//     startup gate.
//   * **Property 30 (task 10.9) owns terminal disjointness and causal arbitration.** This
//     file asserts the singularity Requirement 11.18 needs — exactly one error, and exactly
//     `resource-limit` — but it never arbitrates between competing faults and never claims
//     which category wins when two arrive.
//   * **Property 36 (task 10.12) owns the absence of a synthesized timeout.** Nothing here
//     advances a clock.
//   * **Property 35 (task 10.11) owns cancellation.** Sibling cancellation appears here only
//     as the measured effect of a breach stopping pending work, never as a terminal outcome.
//   * **Property 25 (task 10.7) owns cleanup.** No deadline is asserted.
//   * A resource breach detected at ``AnalysisStage/provenanceValidation`` or
//     ``AnalysisStage/evidenceJoining`` is generated into the *controller* streams but is not
//     delivered to a coordinator session: the provenance port cannot return a fault
//     (`ProvenanceAnalyzing` is non-throwing by design, Requirement 6.9) and the join is not
//     a port at all. Delivering a breach on the provenance branch is task 10.13's
//     integration matrix. The eight stages a pixel port owns are delivered here.
//   * The Share Extension's inability to *reach* an inference module is a module-graph fact
//     owned by `Package.swift` and `check-module-boundaries.py`. What this file measures is
//     the narrower runtime statement: an extension controller authorizes no commit at all
//     after a breach, and the commit vocabulary is closed at two cases partitioned by target,
//     so there is no third commit a breached extension could authorize.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?` and discards a thrown error, so a `throw` in
// the body reports a passing run in milliseconds with every arm skipped. Nothing below
// rethrows: the release build, the controllers, the reservations, the ingests, and every
// throwing port call are turned into recorded values or into an `Issue.record` plus a counted
// unbuildable input. The witness counters live *outside* the body, `recordCompletedBody()` is
// the body's last statement, and `completedBodies == cases` is paired with
// `cases == requestedCount` and a case floor because it passes vacuously as `0 == 0` when the
// body throws on case one.

extension Tag {
    /// Design Property 29.
    ///
    /// Declared here rather than in a shared namespace: each design property owns one file,
    /// and a shared tag namespace would be a merge point between independently written
    /// property files.
    @Tag static var property29HardResourceLimits: Self
}

@Suite(
    "Property 29: Hard resource limits fail without evidence",
    .tags(.property29HardResourceLimits)
)
struct HardResourceLimitPropertyTests {

    /// The number of generated cases requested.
    ///
    /// Each case builds a release through the real startup gate, constructs four resource
    /// controllers, drives two measurement streams twice over, and runs two complete
    /// coordinator sessions, so the per-case cost is high. Two hundred is what the witness's
    /// coverage product needs — ten stream stages, thirteen target metrics, eight delivery
    /// stages, two compositions, and five stream lengths — while keeping the suite's runtime
    /// honest. No assertion is relaxed to fit it; if a cell ever thins out, the count is what
    /// moves.
    static let generatedCaseCount = 200

    /// **Validates: Requirements 11.6, 11.8**
    @Test("The first would-exceed measurement returns only resource-limit, with no evidence")
    func theFirstWouldExceedMeasurementReturnsOnlyResourceLimit() async {
        let witness = HardLimitWitness()

        await propertyCheck(
            count: Self.generatedCaseCount,
            input: ResourceStreamShape.generator
        ) { shape in
            witness.record(shape)
            guard let run = await ResourceStreamRun.execute(shape: shape, witness: witness)
            else { return }

            run.checkTheCleanStreamCausedNoResourceFailure()
            run.checkEveryInBudgetPrefixEventPassed()
            run.checkTheFirstWouldExceedEventReturnedResourceLimit()
            run.checkNoLaterEventChangedOrRevivedTheOutcome()
            run.checkOnlyResourceLimitWasEverReturned()
            run.checkTheBreachStoppedPendingWork()
            run.checkTheMainApplicationCommittedNoEvidence()
            run.checkTheExtensionCreatedNoReadySession()
            run.checkTheCommitVocabularyIsClosedAndPartitioned()
            run.checkThePositiveControlProducedEvidence()

            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }
}

// MARK: - The generated vocabulary

/// Which pipeline port a breach stage is delivered through.
///
/// Eight of the ten stages are owned by a port a coordinator session actually calls, and
/// those are the ones a resource fault can be delivered at in this harness. The mapping is
/// written from the design's stage descriptions: media classification runs inside validation,
/// and output validation runs inside inference, so neither has a port of its own.
private enum BreachDelivery {
    /// The ordered pixel-branch ports, in the order a running session visits them.
    ///
    /// The order is not read out of ``AnalysisCoordinator``; it is the order the positive
    /// control's own call log is separately required to exhibit, so a disagreement fails an
    /// arm rather than being absorbed into this list.
    static let pixelPipeline: [PortCallKind] = [
        .validate, .preprocess, .loadModel, .infer, .calibrate,
    ]

    /// The two ports whose invocation would mean evidence beyond the pixel branch was
    /// produced. Neither may be reached by a session the pixel branch stopped.
    static let beyondThePixelBranch: [PortCallKind] = [.provenanceAnalyze, .fuse]

    /// The port that owns `stage`, or `nil` when no port does.
    static func port(for stage: AnalysisStage) -> PortCallKind? {
        switch stage {
        case .handoffVerification, .mediaClassification, .inputValidation: .validate
        case .preprocessing: .preprocess
        case .modelLoad: .loadModel
        case .inference, .outputValidation: .infer
        case .calibration: .calibrate
        case .provenanceValidation, .evidenceJoining: nil
        }
    }

    /// The stages a breach can be delivered at, in a stable order.
    static let deliverableStages: [AnalysisStage] = AnalysisStage.allCases
        .filter { port(for: $0) != nil }
}

/// Everything one generated case decides, as plain data.
///
/// The generator produces integers only. The release, the controllers, the governors, the
/// ingests, and the coordinator harnesses are built from them inside the run, where a
/// construction that unexpectedly fails becomes an `Issue.record` and a counted unbuildable
/// input rather than a throw `propertyCheck` would discard.
///
/// ## How the baseline varies
///
///   * the **capability composition**, over pixel-only and provenance-plus-fusion, so the
///     "no provenance result and no Combined Summary" zeros are measured in a composition
///     that provably produces both;
///   * the **length** of each target's stream, over two to six events, independently per
///     target, so orderings of different sizes are exercised rather than one template;
///   * each event's **metric**, over the seven the main-application budget defines and the
///     six the Share Extension budget defines, so no target's stream can name the other's;
///   * each event's **stage**, over all ten;
///   * each in-budget event's **reading**, over ten offsets below its bound limit, including
///     the boundary value itself, which must pass;
///   * whether each post-breach event's reading has **recovered** to inside the limit, so the
///     latch is exercised against a reading that would otherwise pass;
///   * the **position** of the first would-exceed event, independently per target, always at
///     or after position one so every case has a measured in-budget prefix; and
///   * the **stage** the main-application breach is delivered at, over the eight a pixel port
///     owns.
///
/// One selector decides one event. The main-application range is
/// 1400 = 7 x 10 x 10 x 2 and the Share Extension range is 1200 = 6 x 10 x 10 x 2 — each a
/// multiple of every modulus it is reduced by, with each field reading a different digit, so
/// the four choices are uniform and independent of one another. The two ranges differ because
/// the two budgets define different numbers of metrics, and a single shared range would make
/// one target's metric draw nonuniform.
private struct ResourceStreamShape: Sendable, CustomStringConvertible {

    /// The main-application budget's metrics, in a stable order.
    static let mainApplicationMetrics: [ResourceMetric] = ResourceMetric
        .requiredMetrics(for: .mainApplication)
        .sorted { $0.rawValue < $1.rawValue }

    /// The Share Extension budget's metrics, in a stable order.
    static let shareExtensionMetrics: [ResourceMetric] = ResourceMetric
        .requiredMetrics(for: .shareExtension)
        .sorted { $0.rawValue < $1.rawValue }

    /// Selector range for one main-application event. See the note above on the exact size.
    static let mainEventSelectorBound = 1_399

    /// Selector range for one Share Extension event.
    static let extensionEventSelectorBound = 1_199

    /// Selector range for a breach position: 120 is a multiple of every stream length minus
    /// one, so the position is uniform over the positions available to the stream it indexes.
    static let breachPositionBound = 119

    /// Drives the synthetic byte seeds, so a case's ingests vary.
    let seed: Int

    /// One selector per main-application event, in delivery order.
    let mainEventSelectors: [Int]

    /// One selector per Share Extension event, in delivery order.
    let extensionEventSelectors: [Int]

    /// Selects the first would-exceed position in the main-application stream.
    let mainBreachSelector: Int

    /// Selects the first would-exceed position in the Share Extension stream.
    let extensionBreachSelector: Int

    /// Selects the stage the main-application breach is delivered at.
    let deliveryStageSelector: Int

    /// Selects the capability composition.
    let compositionSelector: Int

    // MARK: Derived

    /// Whether this case's release binds the provenance validator and a fusion rule.
    ///
    /// The two are bound together because a Combined Summary requires both lanes: a rule
    /// with no provenance result has nothing to resolve.
    var provenanceEnabled: Bool { compositionSelector % 2 == 1 }

    var fusionEnabled: Bool { provenanceEnabled }

    /// The stage the main-application breach is delivered at, and therefore the stage the
    /// fault the controller returns must carry.
    var deliveryStage: AnalysisStage {
        BreachDelivery.deliverableStages[
            deliveryStageSelector % BreachDelivery.deliverableStages.count
        ]
    }

    /// A byte seed that is never zero, so an ingest's bytes differ from an empty pattern.
    var byteSeed: UInt8 { UInt8(truncatingIfNeeded: seed % 251) | 1 }

    func metrics(for target: ExecutionTarget) -> [ResourceMetric] {
        target == .mainApplication ? Self.mainApplicationMetrics : Self.shareExtensionMetrics
    }

    func selectors(for target: ExecutionTarget) -> [Int] {
        target == .mainApplication ? mainEventSelectors : extensionEventSelectors
    }

    /// The first would-exceed position in `target`'s stream.
    ///
    /// Always at least one, so the in-budget prefix every case must exhibit is nonempty, and
    /// always inside the stream, so the tail after it is what the recovery events land in.
    func breachPosition(for target: ExecutionTarget) -> Int {
        let count = selectors(for: target).count
        let selector = target == .mainApplication ? mainBreachSelector : extensionBreachSelector
        return 1 + (selector % max(count - 1, 1))
    }

    /// The stream one target's controllers are driven with.
    ///
    /// The main-application stream's breaching event is forced onto ``deliveryStage`` so the
    /// fault the controller returns is one a pixel port can deliver, and so the breach stage,
    /// the delivery port, and the failure snapshot's stage form one coherent chain rather than
    /// three independently generated values that happen to agree.
    func stream(for target: ExecutionTarget) -> [StreamEvent] {
        let metrics = metrics(for: target)
        let position = breachPosition(for: target)
        return selectors(for: target).enumerated().map { index, selector in
            let isBreach = index == position
            var stage = AnalysisStage.allCases[(selector / metrics.count) % 10]
            if isBreach, target == .mainApplication { stage = deliveryStage }
            return StreamEvent(
                index: index,
                metric: metrics[selector % metrics.count],
                stage: stage,
                readingOffset: (selector / (metrics.count * 10)) % 10,
                // Before the first would-exceed event every reading is inside its limit. At
                // it, one reading is over. After it, a generated share of events recover to
                // inside the limit, which is the interesting tail: a recovered reading must
                // not revive a session the controller already stopped.
                wouldExceed: index == position
                    || (index > position && (selector / (metrics.count * 100)) % 2 == 1)
            )
        }
    }

    var description: String {
        let composition = provenanceEnabled ? "provenance+fusion" : "pixel-only"
        return "seed \(seed), \(composition), app breach \(breachPosition(for: .mainApplication))/\(mainEventSelectors.count) at \(deliveryStage.rawValue), ext breach \(breachPosition(for: .shareExtension))/\(extensionEventSelectors.count)"
    }

    static var generator: Generator<ResourceStreamShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...mainEventSelectorBound).array(of: 2...6),
            Gen.int(in: 0...extensionEventSelectorBound).array(of: 2...6),
            Gen.int(in: 0...breachPositionBound),
            Gen.int(in: 0...breachPositionBound),
            Gen.int(in: 0...79),
            Gen.int(in: 0...99)
        )
        .map { seed, main, ext, mainBreach, extBreach, delivery, composition in
            ResourceStreamShape(
                seed: seed,
                mainEventSelectors: main,
                extensionEventSelectors: ext,
                mainBreachSelector: mainBreach,
                extensionBreachSelector: extBreach,
                deliveryStageSelector: delivery,
                compositionSelector: composition
            )
        }
        .eraseToAny()
    }
}

/// One measurement a stream delivers.
private struct StreamEvent: Hashable, Sendable, CustomStringConvertible {
    let index: Int

    /// The metric this event samples. Always one the target's own budget defines, so the
    /// comparison in force is always the bound artifact's.
    let metric: ResourceMetric

    /// The stage the checkpoint reports.
    let stage: AnalysisStage

    /// How far below its bound limit an in-budget reading sits. Zero is the boundary value,
    /// which must pass: a reading *at* the limit has not exceeded it.
    let readingOffset: Int

    /// Whether this event's programmed reading is over its bound limit.
    let wouldExceed: Bool

    var description: String {
        "\(index):\(metric.rawValue)@\(stage.rawValue)\(wouldExceed ? "!" : "")"
    }
}

// MARK: - What one controller answered

/// Everything read back after one delivered measurement.
///
/// Recorded rather than asserted inline, so the arms compare a whole stream and an event that
/// never reached the controller has nothing to be entered as.
private struct StreamObservation: Sendable {
    let event: StreamEvent
    let target: ExecutionTarget

    /// Whether this event is at or after the stream's first would-exceed position.
    let isAtOrAfterTheFirstBreach: Bool

    /// Whether this event *is* the first would-exceed position.
    let isTheFirstBreach: Bool

    /// The fault the checkpoint returned, or `nil` when it returned normally.
    let fault: AnalysisFault?

    /// ``ResourceController/currentBreach()`` read immediately afterwards.
    let breach: ResourceBreach?

    /// Whether the controller still permits its own target's gated commit.
    let permitsOwnCommit: Bool

    /// Whether the controller permits the other target's gated commit. Always `false`.
    let permitsOtherTargetsCommit: Bool

    /// How much headroom the controller is still holding.
    let outstandingCount: Int

    /// How many port calls the governor has recorded in total.
    let governorCallCount: Int

    /// The sibling work cancelled so far, in cancellation order.
    let cancelledSiblings: [String]
}

/// One target's controller driven over one stream.
private struct StreamPass: Sendable {
    let target: ExecutionTarget

    /// Whether this pass programmed the generated would-exceed readings, or held every
    /// reading inside its limit.
    let deliversTheBreach: Bool

    /// The commit only this target may perform.
    let ownCommit: ResourceGatedCommit

    /// The commit only the other target may perform.
    let otherCommit: ResourceGatedCommit

    /// The bound budget's identifier, so a pass can show which artifact was in force.
    let budgetID: ArtifactID

    /// The governor's call count after the pre-stream reservation and before event zero.
    let governorCallsBeforeTheStream: Int

    let observations: [StreamObservation]

    /// The sibling work cancelled by the end of the pass, in cancellation order.
    let cancelledSiblings: [String]

    /// The headroom still held at the end of the pass.
    let outstandingAtEnd: Int

    /// The names registered as pending work, in registration order.
    static let pendingWorkNames = ["pending-primary", "pending-sibling"]

    /// The observation at the stream's first would-exceed position, when this pass delivered
    /// one.
    var firstBreachObservation: StreamObservation? {
        observations.first(where: \.isTheFirstBreach)
    }

    /// Every error category this pass produced, as raw values.
    var producedCategories: Set<String> {
        Set(observations.compactMap { $0.fault?.analysisError?.rawValue })
    }
}

// MARK: - One executed case

/// One generated case: two clean passes, two breaching passes, one failed session, and one
/// positive control.
private struct ResourceStreamRun: Sendable {
    let shape: ResourceStreamShape

    /// The main-application pass with every reading inside its limit.
    let mainCleanPass: StreamPass

    /// The Share Extension pass with every reading inside its limit.
    let extensionCleanPass: StreamPass

    /// The main-application pass that delivers the generated would-exceed readings.
    let mainBreachPass: StreamPass

    /// The Share Extension pass that delivers the generated would-exceed readings.
    let extensionBreachPass: StreamPass

    /// The fault the main-application controller returned at its first would-exceed event.
    ///
    /// This exact value is what the coordinator session below is handed, so the terminal the
    /// session commits is a consequence of the controller's own output rather than of a fault
    /// this file invented.
    let deliveredFault: AnalysisFault

    /// The port the fault was delivered through.
    let deliveryPort: PortCallKind

    /// The session the delivered fault ended.
    let failedSession: CompletedAnalysisSession

    /// The failed session's own call log.
    let failedCallCounts: [PortCallKind: Int]

    /// The positive control: one clean session through the same release and ports.
    let control: CompletedAnalysisSession

    /// The control's own call log, taken after the failed session's log was cleared.
    let controlCallCounts: [PortCallKind: Int]

    /// Every port whose invocation this file counts.
    static let countedPorts: [PortCallKind] =
        BreachDelivery.pixelPipeline + BreachDelivery.beyondThePixelBranch

    /// The requirements' closed Analysis Error set, transcribed rather than read out of
    /// ``AnalysisError``.
    ///
    /// A test that asked the enumeration under test what its members are would assert
    /// nothing. "Only `resource-limit`" is a claim about these ten names.
    static let closedErrorCategories: Set<String> = [
        "unsupported-media",
        "unsupported-static-format",
        "decoding-error",
        "resource-limit",
        "preprocessing-error",
        "model-load-error",
        "inference-error",
        "invalid-output-error",
        "calibration-input-error",
        "handoff-error",
    ]

    // MARK: Execution

    static func execute(
        shape: ResourceStreamShape,
        witness: HardLimitWitness
    ) async -> ResourceStreamRun? {
        let release: CoordinatorRelease
        do {
            release = try await CoordinatorRelease.build(
                provenance: shape.provenanceEnabled,
                fusion: shape.fusionEnabled
            )
        } catch {
            Issue.record("the synthetic release must pass its own startup gate: \(error)")
            witness.recordUnbuildableInput()
            return nil
        }
        let budgets = release.admission.configuration.resourceBudgets

        // Four independently constructed controllers: a clean pass and a breaching pass for
        // each target. Separate controllers rather than one reset, because the breach latch
        // is monotonic by design and a reused controller could not run a clean pass after a
        // breaching one.
        var passes: [StreamPass] = []
        for target in [ExecutionTarget.mainApplication, .shareExtension] {
            for deliversTheBreach in [false, true] {
                guard let pass = await Self.drive(
                    target: target,
                    deliversTheBreach: deliversTheBreach,
                    stream: shape.stream(for: target),
                    breachPosition: shape.breachPosition(for: target),
                    budgets: budgets,
                    shape: shape,
                    witness: witness
                ) else {
                    return nil
                }
                passes.append(pass)
            }
        }
        let mainCleanPass = passes[0]
        let mainBreachPass = passes[1]
        let extensionCleanPass = passes[2]
        let extensionBreachPass = passes[3]

        // The fault the main-application controller actually returned. Everything downstream
        // is a consequence of this value, not of a category chosen here.
        guard let deliveredFault = mainBreachPass.firstBreachObservation?.fault else {
            Issue.record(
                "the main-application controller must return a fault at its first would-exceed event [\(shape)]"
            )
            witness.recordUnbuildableInput()
            return nil
        }
        guard let deliveryPort = BreachDelivery.port(for: shape.deliveryStage) else {
            Issue.record("the delivery stage must be owned by a pixel port [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        // The main-application half of the claim, on a real session: the controller's own
        // fault is handed to the port that owns the stage it names, and the session's single
        // terminal is what must carry no evidence.
        let failedSessionID = "session-0001"
        let failingHarness = Self.harness(
            release: release,
            failingAt: shape.deliveryStage,
            with: deliveredFault,
            sessionID: failedSessionID
        )
        let failedAsset: ImportedEncodedAsset
        do {
            failedAsset = try await release.acceptedIngest(
                sessionID: failedSessionID,
                byteSeed: shape.byteSeed
            )
        } catch {
            Issue.record("the accepted ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        guard let failedSession = await failingHarness.coordinator.analyze(failedAsset).completed
        else {
            Issue.record("the delivered breach must reach a terminal [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        let failedCallCounts = Self.callCounts(release.recorder)

        // The positive control, over the same release, the same ports, and the same shared
        // call log. The log is cleared first so the two are never mixed.
        release.recorder.reset()
        let controlSessionID = "session-0002"
        let controlHarness = CoordinatorHarness.make(
            release: release,
            sessionID: controlSessionID
        )
        let controlAsset: ImportedEncodedAsset
        do {
            controlAsset = try await release.acceptedIngest(
                sessionID: controlSessionID,
                byteSeed: shape.byteSeed ^ 0x5A | 1
            )
        } catch {
            Issue.record("the control ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        guard let control = await controlHarness.coordinator.analyze(controlAsset).completed
        else {
            Issue.record("the positive control must reach a terminal [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        let controlCallCounts = Self.callCounts(release.recorder)

        let run = ResourceStreamRun(
            shape: shape,
            mainCleanPass: mainCleanPass,
            extensionCleanPass: extensionCleanPass,
            mainBreachPass: mainBreachPass,
            extensionBreachPass: extensionBreachPass,
            deliveredFault: deliveredFault,
            deliveryPort: deliveryPort,
            failedSession: failedSession,
            failedCallCounts: failedCallCounts,
            control: control,
            controlCallCounts: controlCallCounts
        )
        witness.recordExecutedCase(run)
        return run
    }

    /// Drives one target's controller over one stream and records every answer.
    ///
    /// Nothing rethrows: every throwing call becomes a recorded value, because an error
    /// escaping the property body would be discarded and report a passing run.
    private static func drive(
        target: ExecutionTarget,
        deliversTheBreach: Bool,
        stream: [StreamEvent],
        breachPosition: Int,
        budgets: ResourceBudgetSet,
        shape: ResourceStreamShape,
        witness: HardLimitWitness
    ) async -> StreamPass? {
        let governor = RecordingResourceGovernor(target: target)
        guard let controller = ResourceController(
            target: target,
            budgets: budgets,
            governor: governor
        ) else {
            Issue.record("a \(target.rawValue) controller over the bound budget must exist")
            witness.recordUnbuildableInput()
            return nil
        }
        let budget = budgets.budget(for: target)

        // Pending work the breach must stop. Registered before the stream so a breach at any
        // position has something to cancel, and named so the cancellation *order* is
        // observable rather than only its occurrence.
        let cancelled = LockedList<String>()
        for name in StreamPass.pendingWorkNames {
            _ = await controller.registerSiblingWork { cancelled.append(name) }
        }

        // Headroom granted before the stream, against a metric the target's own budget states
        // in its own unit. One unit: the smallest request that still exercises the reservation
        // path, so the grant cannot be read as a judgement about an approved amount.
        let reservationMetric: ResourceMetric =
            target == .mainApplication ? .decodedPixelCount : .encodedInputSize
        guard let reservation = await Self.reserve(
            controller,
            metric: reservationMetric,
            at: stream[0].stage
        ) else {
            Issue.record(
                "in-budget headroom must be grantable for \(target.rawValue) [\(shape)]"
            )
            witness.recordUnbuildableInput()
            return nil
        }
        let governorCallsBeforeTheStream = await governor.calls().count

        var observations: [StreamObservation] = []
        for event in stream {
            let exceeds = deliversTheBreach && event.wouldExceed
            await Self.program(
                governor,
                metric: event.metric,
                limit: budget.limit(for: event.metric),
                offset: event.readingOffset,
                exceeds: exceeds
            )
            let fault = await Self.checkpointFault(controller, event.metric, at: event.stage)
            let observation = StreamObservation(
                event: event,
                target: target,
                isAtOrAfterTheFirstBreach: deliversTheBreach && event.index >= breachPosition,
                isTheFirstBreach: deliversTheBreach && event.index == breachPosition,
                fault: fault,
                breach: await controller.currentBreach(),
                permitsOwnCommit: await controller.permits(Self.ownCommit(of: target)),
                permitsOtherTargetsCommit: await controller.permits(
                    Self.ownCommit(of: Self.otherTarget(of: target))
                ),
                outstandingCount: await controller.outstandingReservations().count,
                governorCallCount: await governor.calls().count,
                cancelledSiblings: cancelled.values
            )
            observations.append(observation)
            witness.recordObservation(observation)
        }

        // Returned unconditionally, the way a cleanup path would. Idempotent by contract, so
        // a pass that already handed it back on the breach is unaffected.
        await controller.release(reservation)

        let pass = StreamPass(
            target: target,
            deliversTheBreach: deliversTheBreach,
            ownCommit: Self.ownCommit(of: target),
            otherCommit: Self.ownCommit(of: Self.otherTarget(of: target)),
            budgetID: budget.id,
            governorCallsBeforeTheStream: governorCallsBeforeTheStream,
            observations: observations,
            cancelledSiblings: cancelled.values,
            outstandingAtEnd: await controller.outstandingReservations().count
        )
        witness.recordPass(pass)
        return pass
    }

    /// Programs the governor's answer for one metric, from the bound budget's own limit.
    ///
    /// **The number never comes from this file.** A would-exceed reading is one more than
    /// whatever the bound budget states, and an in-budget reading is that same value less a
    /// small offset — including an offset of zero, the boundary itself. A thermal breach is
    /// the hottest state, which is above any maximum a budget can name.
    private static func program(
        _ governor: RecordingResourceGovernor,
        metric: ResourceMetric,
        limit: ValidatedLimit?,
        offset: Int,
        exceeds: Bool
    ) async {
        switch limit {
        case .numeric(let value, _):
            let inBudget = max(value.value - Decimal(offset), 0)
            await governor.setReading(exceeds ? value.value + 1 : inBudget, for: metric)
        case .thermal:
            await governor.setThermalState(exceeds ? .critical : .nominal)
        case nil:
            // Unreachable: every generated metric belongs to the target's required set, so
            // the bound budget defines a limit for it. Recorded rather than ignored, because
            // a missing limit would make the case's cause `limitNotDefined` instead of
            // `wouldExceedHardLimit` and the arms below would be measuring something else.
            Issue.record(
                "the bound budget must define a limit for \(metric.rawValue)"
            )
        }
    }

    /// Samples one metric and reports the fault, or `nil` when it read in budget.
    private static func checkpointFault(
        _ controller: ResourceController,
        _ metric: ResourceMetric,
        at stage: AnalysisStage
    ) async -> AnalysisFault? {
        do {
            try await controller.checkpoint(metric, at: stage)
            return nil
        } catch {
            return error
        }
    }

    /// Reserves one unit of headroom, or `nil` when the reservation was refused.
    private static func reserve(
        _ controller: ResourceController,
        metric: ResourceMetric,
        at stage: AnalysisStage
    ) async -> ResourceReservation? {
        do {
            return try await controller.reserve(
                metric,
                amount: CoordinatorSample.positive(1),
                unit: CoordinatorSample.limitUnit(for: metric),
                at: stage
            )
        } catch {
            return nil
        }
    }

    /// The only commit `target` may perform.
    private static func ownCommit(of target: ExecutionTarget) -> ResourceGatedCommit {
        target == .mainApplication ? .evidenceReport : .readyTransferTicket
    }

    private static func otherTarget(of target: ExecutionTarget) -> ExecutionTarget {
        target == .mainApplication ? .shareExtension : .mainApplication
    }

    /// A harness whose port for `stage` returns `fault` and whose every other port succeeds.
    ///
    /// The fault is delivered at the port that owns the stage the *controller* named, so the
    /// session fails where the breach was measured rather than at a convenient boundary.
    private static func harness(
        release: CoordinatorRelease,
        failingAt stage: AnalysisStage,
        with fault: AnalysisFault,
        sessionID: String
    ) -> CoordinatorHarness {
        switch stage {
        case .handoffVerification, .mediaClassification, .inputValidation:
            return .make(
                release: release,
                validated: StubOutcome<ValidatedImage>(alwaysFailing: fault),
                sessionID: sessionID
            )
        case .preprocessing:
            return .make(
                release: release,
                prepared: StubOutcome<ModelImageInput>(alwaysFailing: fault),
                sessionID: sessionID
            )
        case .modelLoad:
            return .make(
                release: release,
                model: StubOutcome<BoundCoreMLModel>(alwaysFailing: fault),
                sessionID: sessionID
            )
        case .inference, .outputValidation:
            return .make(
                release: release,
                logit: StubOutcome<RawLogit>(alwaysFailing: fault),
                sessionID: sessionID
            )
        case .calibration, .provenanceValidation, .evidenceJoining:
            // The last two are excluded from ``BreachDelivery/deliverableStages`` and cannot
            // be selected; the calibration port is the one this arm serves.
            return .make(
                release: release,
                evidence: StubOutcome<PixelEvidence>(alwaysFailing: fault),
                sessionID: sessionID
            )
        }
    }

    /// Every port-call count this file asserts on, read from the shared log.
    private static func callCounts(_ recorder: PortCallRecorder) -> [PortCallKind: Int] {
        var counts: [PortCallKind: Int] = [:]
        for kind in Self.countedPorts {
            counts[kind] = recorder.callCount(of: kind)
        }
        return counts
    }

    // MARK: - Arms

    /// Measurements inside every hard limit did not cause a resource failure.
    ///
    /// The first half of the design's sentence, and the presence the whole rest of this file's
    /// absences are read beside. Both targets, over the *same* generated stream the breaching
    /// passes use, with every reading held inside its bound limit: no fault, no latched
    /// breach, the target's own commit still permitted at every event, the granted headroom
    /// still held, no pending work cancelled, and one governor sample per event — which is
    /// what proves the checkpoints did compare rather than return without looking.
    func checkTheCleanStreamCausedNoResourceFailure() {
        for pass in [mainCleanPass, extensionCleanPass] {
            #expect(
                pass.deliversTheBreach == false,
                "a clean pass must not deliver a would-exceed reading [\(shape)]"
            )
            #expect(
                pass.observations.count >= 2,
                "a clean pass must deliver at least two measurements, delivered \(pass.observations.count) [\(shape)]"
            )
            for observation in pass.observations {
                #expect(
                    observation.fault == nil,
                    "the clean \(pass.target.rawValue) pass stopped in-budget work at \(observation.event.description) with \(String(describing: observation.fault)) [\(shape)]"
                )
                #expect(
                    observation.breach == nil,
                    "the clean \(pass.target.rawValue) pass latched a breach with every reading inside its limit: \(String(describing: observation.breach)) [\(shape)]"
                )
                #expect(
                    observation.permitsOwnCommit,
                    "the clean \(pass.target.rawValue) pass stopped permitting \(pass.ownCommit) at \(observation.event.description) [\(shape)]"
                )
                #expect(
                    observation.outstandingCount == 1,
                    "the clean \(pass.target.rawValue) pass lost the granted headroom at \(observation.event.description) [\(shape)]"
                )
                #expect(
                    observation.cancelledSiblings.isEmpty,
                    "the clean \(pass.target.rawValue) pass cancelled pending work with no breach: \(observation.cancelledSiblings) [\(shape)]"
                )
                // One sample per event, cumulative on top of the pre-stream reservation. A
                // checkpoint that returned without asking the governor would leave this
                // count behind.
                #expect(
                    observation.governorCallCount
                        == pass.governorCallsBeforeTheStream + observation.event.index + 1,
                    "the clean \(pass.target.rawValue) pass performed \(observation.governorCallCount - pass.governorCallsBeforeTheStream) samples by event \(observation.event.index), expected \(observation.event.index + 1) [\(shape)]"
                )
            }
            #expect(
                pass.producedCategories.isEmpty,
                "the clean \(pass.target.rawValue) pass produced categories \(pass.producedCategories.sorted()) [\(shape)]"
            )
            #expect(
                pass.cancelledSiblings.isEmpty,
                "the clean \(pass.target.rawValue) pass cancelled \(pass.cancelledSiblings) with no breach [\(shape)]"
            )
        }
    }

    /// The in-budget prefix of each breaching stream also passed.
    ///
    /// The same claim as the arm above, but inside the stream that *does* breach — which is
    /// what makes the breach attributable to the first would-exceed reading rather than to
    /// the controller having been called at all. Every case has a nonempty prefix by
    /// construction: the generated breach position is never zero.
    func checkEveryInBudgetPrefixEventPassed() {
        for pass in [mainBreachPass, extensionBreachPass] {
            let prefix = pass.observations.filter { !$0.isAtOrAfterTheFirstBreach }
            #expect(
                !prefix.isEmpty,
                "the breaching \(pass.target.rawValue) stream must have an in-budget prefix [\(shape)]"
            )
            for observation in prefix {
                #expect(
                    observation.event.wouldExceed == false,
                    "an event before the first breach must read inside its limit [\(shape)]"
                )
                #expect(
                    observation.fault == nil,
                    "the \(pass.target.rawValue) prefix event \(observation.event.description) failed before any limit was exceeded: \(String(describing: observation.fault)) [\(shape)]"
                )
                #expect(
                    observation.breach == nil,
                    "the \(pass.target.rawValue) prefix event \(observation.event.description) latched a breach early [\(shape)]"
                )
                #expect(
                    observation.permitsOwnCommit,
                    "the \(pass.target.rawValue) prefix event \(observation.event.description) already refused \(pass.ownCommit) [\(shape)]"
                )
                #expect(
                    observation.outstandingCount == 1,
                    "the \(pass.target.rawValue) prefix event \(observation.event.description) returned headroom early [\(shape)]"
                )
                #expect(
                    observation.cancelledSiblings.isEmpty,
                    "the \(pass.target.rawValue) prefix event \(observation.event.description) cancelled pending work early [\(shape)]"
                )
            }
        }
    }

    /// The first would-exceed event returned exactly one `resource-limit`, located where the
    /// measurement was taken.
    ///
    /// The core of Requirements 11.6 and 11.8. Asserted as value equality against the fault a
    /// single `resource-limit` at that stage constructs, so a second category, a cancellation,
    /// or a fault at a different stage all fail — and the breach record is required to name
    /// the metric that was measured, the stage it was measured at, the target whose budget was
    /// in force, and `wouldExceedHardLimit` as the cause rather than one of the other
    /// fail-closed causes, which would mean this case measured something else.
    func checkTheFirstWouldExceedEventReturnedResourceLimit() {
        for pass in [mainBreachPass, extensionBreachPass] {
            guard let observation = pass.firstBreachObservation else {
                Issue.record(
                    "the breaching \(pass.target.rawValue) stream must contain a first would-exceed event [\(shape)]"
                )
                continue
            }
            #expect(
                observation.event.wouldExceed,
                "the first breach event must be the one whose reading exceeds its limit [\(shape)]"
            )
            #expect(
                observation.fault
                    == .analysis(.resourceLimit, stage: observation.event.stage),
                "the first would-exceed \(pass.target.rawValue) event returned \(String(describing: observation.fault)), expected exactly resource-limit at \(observation.event.stage.rawValue) [\(shape)]"
            )
            #expect(
                observation.fault?.isCancelled == false,
                "a hard-limit breach must not be reported as cancellation [\(shape)]"
            )
            guard let breach = observation.breach else {
                Issue.record(
                    "the \(pass.target.rawValue) controller must record the breach it returned [\(shape)]"
                )
                continue
            }
            #expect(
                breach.cause == .wouldExceedHardLimit,
                "the breach cause must be a measured would-exceed, found \(breach.cause) [\(shape)]"
            )
            #expect(
                breach.metric == observation.event.metric,
                "the breach names \(breach.metric.rawValue), the measurement was \(observation.event.metric.rawValue) [\(shape)]"
            )
            #expect(
                breach.stage == observation.event.stage,
                "the breach is located at \(breach.stage.rawValue), the measurement was at \(observation.event.stage.rawValue) [\(shape)]"
            )
            #expect(
                breach.target == pass.target,
                "the breach names target \(breach.target.rawValue), expected \(pass.target.rawValue) [\(shape)]"
            )
            #expect(
                breach.fault == observation.fault,
                "the breach's fault and the returned fault must be the same value [\(shape)]"
            )
            // The metric was one of *this* target's, so the number in force was the bound
            // artifact's rather than the other target's or a constant of this file's.
            #expect(
                ResourceMetric.requiredMetrics(for: pass.target)
                    .contains(observation.event.metric),
                "the breached metric must belong to the \(pass.target.rawValue) budget [\(shape)]"
            )
        }
    }

    /// No later event changed the outcome, and a recovered reading did not revive the work.
    ///
    /// The sharpest arm in the file. Every event after the first would-exceed one must report
    /// the *same* fault — same category, same stage, the first breach's and not its own — and
    /// that must hold for the generated events whose reading has *recovered* to inside its
    /// limit, which is the case a controller without a monotonic latch would get wrong. The
    /// governor is also required to stop being sampled, because continuing to measure is
    /// continuing the work the breach was supposed to stop.
    func checkNoLaterEventChangedOrRevivedTheOutcome() {
        for pass in [mainBreachPass, extensionBreachPass] {
            guard let first = pass.firstBreachObservation else { continue }
            let tail = pass.observations.filter {
                $0.isAtOrAfterTheFirstBreach && !$0.isTheFirstBreach
            }
            for observation in tail {
                #expect(
                    observation.fault == first.fault,
                    "the \(pass.target.rawValue) event \(observation.event.description) reported \(String(describing: observation.fault)) instead of the first breach's \(String(describing: first.fault)) [\(shape)]"
                )
                #expect(
                    observation.breach == first.breach,
                    "the \(pass.target.rawValue) event \(observation.event.description) changed the recorded breach [\(shape)]"
                )
                #expect(
                    observation.permitsOwnCommit == false,
                    "the \(pass.target.rawValue) event \(observation.event.description) permitted \(pass.ownCommit) after a breach [\(shape)]"
                )
                if observation.event.wouldExceed == false {
                    // A reading that has recovered to inside its limit. It must not revive the
                    // work, and the reported location must still be the first breach's.
                    #expect(
                        observation.fault?.stage == first.event.stage,
                        "a recovered reading at \(observation.event.description) relocated the failure to \(String(describing: observation.fault?.stage?.rawValue)) [\(shape)]"
                    )
                }
                #expect(
                    observation.governorCallCount == first.governorCallCount,
                    "the \(pass.target.rawValue) event \(observation.event.description) kept sampling after the breach: \(observation.governorCallCount) calls against \(first.governorCallCount) [\(shape)]"
                )
            }
        }
    }

    /// Only `resource-limit` was ever returned, on either target.
    ///
    /// Set equality against the requirements' own ten-category vocabulary, transcribed in
    /// this file. "Only" means the other nine never appeared and cancellation never appeared,
    /// which is stronger than "a resource-limit was among them".
    func checkOnlyResourceLimitWasEverReturned() {
        #expect(
            Set(AnalysisError.allCases.map(\.rawValue)) == Self.closedErrorCategories,
            "the closed Analysis Error set has drifted from the requirements' ten categories: extra \(Set(AnalysisError.allCases.map(\.rawValue)).subtracting(Self.closedErrorCategories).sorted()), missing \(Self.closedErrorCategories.subtracting(Set(AnalysisError.allCases.map(\.rawValue))).sorted())"
        )
        for pass in [mainBreachPass, extensionBreachPass] {
            #expect(
                pass.producedCategories == ["resource-limit"],
                "the breaching \(pass.target.rawValue) stream produced \(pass.producedCategories.sorted()), expected only resource-limit [\(shape)]"
            )
            for observation in pass.observations {
                #expect(
                    observation.fault?.isCancelled != true,
                    "the \(pass.target.rawValue) event \(observation.event.description) reported cancellation, which is not an Analysis Error [\(shape)]"
                )
            }
        }
        // The delivered fault, which is the one the session below commits, is the same single
        // category located at the same single stage.
        #expect(
            deliveredFault == .analysis(.resourceLimit, stage: shape.deliveryStage),
            "the delivered fault is \(deliveredFault), expected exactly resource-limit at \(shape.deliveryStage.rawValue) [\(shape)]"
        )
    }

    /// The breach stopped pending work and returned the headroom it was holding.
    ///
    /// "Stop the affected work" has three observable parts, and all three are asserted:
    /// registered pending work is cancelled, in registration order and once each; the granted
    /// headroom is handed back; and — from the arm above — sampling stops. Order matters:
    /// dictionary-ordered cancellation would make which branch stops first unpredictable.
    func checkTheBreachStoppedPendingWork() {
        for pass in [mainBreachPass, extensionBreachPass] {
            guard let first = pass.firstBreachObservation else { continue }
            #expect(
                first.cancelledSiblings == StreamPass.pendingWorkNames,
                "the \(pass.target.rawValue) breach cancelled \(first.cancelledSiblings), expected \(StreamPass.pendingWorkNames) in registration order [\(shape)]"
            )
            #expect(
                first.outstandingCount == 0,
                "the \(pass.target.rawValue) breach left \(first.outstandingCount) reservations outstanding [\(shape)]"
            )
            // Once each: a later failing event must not cancel a second time.
            #expect(
                pass.cancelledSiblings == StreamPass.pendingWorkNames,
                "the \(pass.target.rawValue) stream cancelled pending work \(pass.cancelledSiblings.count) times, expected \(StreamPass.pendingWorkNames.count) [\(shape)]"
            )
            #expect(
                pass.outstandingAtEnd == 0,
                "the \(pass.target.rawValue) stream ended holding \(pass.outstandingAtEnd) reservations [\(shape)]"
            )
        }
    }

    /// Requirement 11.6: the main application committed no evidence.
    ///
    /// Measured on a real session rather than on the controller, because "commits no evidence"
    /// is a statement about what the session produced. Four things are required, and the
    /// fourth is the one a structural check alone would miss:
    ///
    ///   * the terminal is exactly one of the three kinds, and it is `failed`;
    ///   * the snapshot carries exactly `resource-limit`, at the stage the breach named;
    ///   * there is no Evidence Report, so no pixel label, no provenance state, and no
    ///     Combined Summary reached a user; and
    ///   * the call log shows the pipeline *stopped where the breach was measured*: every port
    ///     up to and including the breaching one was called exactly once, and every port after
    ///     it exactly zero times — so the failure interrupted work that had genuinely started,
    ///     rather than a session that never began.
    func checkTheMainApplicationCommittedNoEvidence() {
        let kinds = [
            failedSession.outcome.isCompleted,
            failedSession.outcome.isCancelled,
            failedSession.outcome.isFailed,
        ]
        #expect(
            kinds.filter { $0 }.count == 1,
            "the failed session's terminal must be exactly one of the three kinds, found \(kinds) [\(shape)]"
        )
        #expect(
            failedSession.outcome.isFailed,
            "a delivered resource breach must reach the failed terminal, found \(failedSession.outcome) [\(shape)]"
        )
        guard let snapshot = failedSession.outcome.failure else {
            Issue.record("a failed terminal must carry a snapshot [\(shape)]")
            return
        }
        #expect(
            snapshot.error == .resourceLimit,
            "the committed category is \(snapshot.error.rawValue), expected resource-limit [\(shape)]"
        )
        #expect(
            snapshot.stage == shape.deliveryStage,
            "the failure is located at \(snapshot.stage.rawValue), the breach was measured at \(shape.deliveryStage.rawValue) [\(shape)]"
        )
        #expect(
            failedSession.error == .resourceLimit,
            "the session reports \(String(describing: failedSession.error)) [\(shape)]"
        )
        #expect(
            failedSession.evidenceReport == nil,
            "a resource failure carried an Evidence Report [\(shape)]"
        )
        #expect(
            failedSession.outcome.evidenceReport == nil,
            "the failed terminal carried an Evidence Report [\(shape)]"
        )
        #expect(
            failedSession.fusionFault == nil,
            "fusion was attempted for a session that failed on a resource limit [\(shape)]"
        )

        // Where the pipeline stopped. The breaching port ran; nothing after it did.
        guard let breachIndex = BreachDelivery.pixelPipeline.firstIndex(of: deliveryPort) else {
            Issue.record("the delivery port must be part of the pixel pipeline [\(shape)]")
            return
        }
        for (index, kind) in BreachDelivery.pixelPipeline.enumerated() {
            let expected = index <= breachIndex ? 1 : 0
            #expect(
                failedCallCounts[kind] == expected,
                "the failed session made \(String(describing: failedCallCounts[kind])) \(kind.rawValue) calls, expected \(expected) for a breach at \(shape.deliveryStage.rawValue) [\(shape)]"
            )
        }
        for kind in BreachDelivery.beyondThePixelBranch {
            #expect(
                failedCallCounts[kind] == 0,
                "the failed session made \(String(describing: failedCallCounts[kind])) \(kind.rawValue) calls; a stopped session produces no provenance result and no Combined Summary [\(shape)]"
            )
        }
    }

    /// Requirement 11.8: the Share Extension created no ready session.
    ///
    /// The extension's only session-creating commit is the ready transfer ticket, so its
    /// refusal is the observable form of "without starting an Analysis Session". The claim is
    /// asserted as a **flip**, which is what makes it about the breach: the same controller
    /// permitted the ticket at every in-budget event and refuses it from the first
    /// would-exceed event onward. An assertion taken on the main-application controller could
    /// not show this — that controller refuses a ready ticket with no breach at all — which is
    /// exactly why Requirements 11.6 and 11.8 are measured separately here.
    ///
    /// Model inference is covered structurally rather than by a call count: after a breach the
    /// extension controller authorizes *no* commit at all, and the commit vocabulary is closed
    /// and partitioned by target, so there is nothing left for a breached extension to
    /// authorize. The module-graph fact that the extension cannot reach an inference module is
    /// `Package.swift`'s and the boundary script's.
    func checkTheExtensionCreatedNoReadySession() {
        let pass = extensionBreachPass
        #expect(
            pass.target == .shareExtension,
            "this arm must read the Share Extension pass [\(shape)]"
        )
        #expect(
            pass.ownCommit == .readyTransferTicket,
            "the Share Extension's gated commit must be the ready transfer ticket [\(shape)]"
        )
        guard let first = pass.firstBreachObservation else {
            Issue.record("the extension stream must contain a first would-exceed event [\(shape)]")
            return
        }

        // Before: permitted. This is the presence the refusal below is read beside, and it is
        // taken on the very same controller.
        for observation in pass.observations where !observation.isAtOrAfterTheFirstBreach {
            #expect(
                observation.permitsOwnCommit,
                "the extension refused a ready ticket at in-budget event \(observation.event.description) [\(shape)]"
            )
        }
        for observation in extensionCleanPass.observations {
            #expect(
                observation.permitsOwnCommit,
                "the clean extension pass refused a ready ticket at \(observation.event.description) [\(shape)]"
            )
        }

        // From the first would-exceed event onward: refused, and refused for every event after
        // it, including the ones whose reading recovered.
        for observation in pass.observations where observation.isAtOrAfterTheFirstBreach {
            #expect(
                observation.permitsOwnCommit == false,
                "the extension permitted a ready ticket at \(observation.event.description), at or after its first breach [\(shape)]"
            )
            #expect(
                observation.permitsOtherTargetsCommit == false,
                "the extension permitted the main application's evidence commit [\(shape)]"
            )
        }
        #expect(
            first.permitsOwnCommit == false,
            "the extension's first would-exceed event must refuse the ready ticket [\(shape)]"
        )
        // The refusal is total: no commit in the closed vocabulary is authorized afterwards.
        #expect(
            first.permitsOtherTargetsCommit == false,
            "a breached extension authorized a commit outside its own target [\(shape)]"
        )
    }

    /// The commit vocabulary is closed at two cases, partitioned by target.
    ///
    /// This is what makes "no ready ticket, session, or inference" a statement with no third
    /// option: there are exactly two gated commits, each owned by exactly one target, so a
    /// breached controller that authorizes neither has authorized everything there is. A new
    /// case added later would fail here rather than quietly becoming a commit a breach does
    /// not gate.
    func checkTheCommitVocabularyIsClosedAndPartitioned() {
        #expect(
            ResourceGatedCommit.allCases.count == 2,
            "the gated-commit vocabulary must hold exactly two cases, found \(ResourceGatedCommit.allCases.count)"
        )
        #expect(
            Set(ResourceGatedCommit.allCases) == [.evidenceReport, .readyTransferTicket],
            "the gated-commit vocabulary has drifted: \(ResourceGatedCommit.allCases)"
        )
        #expect(
            ResourceGatedCommit.evidenceReport.governingTarget == .mainApplication,
            "only the main application may commit an Evidence Report"
        )
        #expect(
            ResourceGatedCommit.readyTransferTicket.governingTarget == .shareExtension,
            "only the Share Extension may publish a ready transfer ticket"
        )
        // A partition, not merely a mapping: each target owns exactly one commit.
        for target in ExecutionTarget.allCases {
            let owned = ResourceGatedCommit.allCases.filter { $0.governingTarget == target }
            #expect(
                owned.count == 1,
                "\(target.rawValue) owns \(owned.count) gated commits, expected one"
            )
        }
        // The two controllers bound different artifacts, so neither target's limits could
        // have stood in for the other's and "the number in force was this target's" is a
        // measured fact rather than an assumption (Requirement 11.1).
        #expect(
            mainBreachPass.budgetID != extensionBreachPass.budgetID,
            "the two targets' controllers bound the same budget artifact \(mainBreachPass.budgetID) [\(shape)]"
        )
        #expect(
            mainCleanPass.budgetID == mainBreachPass.budgetID,
            "the two main-application passes bound different budgets [\(shape)]"
        )
        #expect(
            extensionCleanPass.budgetID == extensionBreachPass.budgetID,
            "the two Share Extension passes bound different budgets [\(shape)]"
        )
    }

    /// The positive control produced, through identical wiring, what the arms above required
    /// to be absent.
    ///
    /// Same release, same ports, same shared call log — only the delivered fault is missing.
    /// Without this, "the failed session has no Evidence Report" would be satisfied by a
    /// release that cannot produce one. In a provenance-enabled composition the control also
    /// produces a real provenance lane and a real Combined Summary, so the two zeros the arm
    /// above measures beyond the pixel branch are measured against ones. A pixel-only release
    /// has neither by construction and neither is asserted for it; the witness requires both
    /// compositions to have run.
    func checkThePositiveControlProducedEvidence() {
        #expect(
            control.outcome.isCompleted,
            "the positive control must complete, found \(control.outcome) [\(shape)]"
        )
        #expect(control.error == nil, "the control reported a category [\(shape)]")
        guard let report = control.evidenceReport else {
            Issue.record("the positive control must produce an Evidence Report [\(shape)]")
            return
        }
        #expect(
            control.sessionID != failedSession.sessionID,
            "the control must be a different session from the failed one [\(shape)]"
        )
        for kind in BreachDelivery.pixelPipeline {
            #expect(
                controlCallCounts[kind] == 1,
                "the control made \(String(describing: controlCallCounts[kind])) \(kind.rawValue) calls, expected one [\(shape)]"
            )
        }
        if shape.provenanceEnabled {
            #expect(
                report.provenance.isAvailable,
                "a provenance-enabled control must produce a provenance result [\(shape)]"
            )
            #expect(
                report.combinedSummary != nil,
                "a fusion-bound control must produce a Combined Summary [\(shape)]"
            )
            #expect(
                control.fusionFault == nil,
                "the control's fusion rule did not apply [\(shape)]"
            )
            for kind in BreachDelivery.beyondThePixelBranch {
                #expect(
                    controlCallCounts[kind] == 1,
                    "the control made \(String(describing: controlCallCounts[kind])) \(kind.rawValue) calls, expected one [\(shape)]"
                )
            }
        } else {
            // A pixel-only composition links no validator and binds no rule, so both are
            // absent for the control as well. Nothing is claimed about them here; the
            // provenance-enabled cases are where those zeros acquire meaning.
            #expect(
                report.provenance.isAvailable == false,
                "a pixel-only control must report an unavailable provenance lane [\(shape)]"
            )
            for kind in BreachDelivery.beyondThePixelBranch {
                #expect(
                    controlCallCounts[kind] == 0,
                    "a pixel-only control reached \(kind.rawValue) [\(shape)]"
                )
            }
        }
    }
}

// MARK: - Non-vacuity witness

/// Counts what the run generated, measured, stopped, and produced — outside the property
/// body.
///
/// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
/// failed on its first statement would report a passing test in milliseconds with every arm
/// skipped. `completedBodies == cases` alone does not catch that: it passes vacuously as
/// `0 == 0`. The case floor, `cases == requestedCases`, the per-case counts, and the produced
/// sets are what close the gap, and they live here because an issue recorded outside the body
/// is not suppressed.
///
/// The substantive half is the produced sets. Every stage must have been checkpointed, every
/// metric of both budgets must have been sampled, every deliverable breach stage must have
/// been delivered to a real session, both compositions must have run, in-budget events and
/// would-exceed events must both have been measured in quantity, recovered post-breach
/// readings must have been exercised, and *every* case must have produced a positive-control
/// Evidence Report — which is what turns each measured zero into a measurement.
private final class HardLimitWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var executedCases = 0
    private var unbuildableInputs = 0

    // Measurement volume.
    private var observations = 0
    private var cleanObservations = 0
    private var inBudgetPrefixObservations = 0
    private var firstBreachObservations = 0
    private var postBreachObservations = 0
    private var recoveredPostBreachObservations = 0
    private var passes = 0

    // Consequences.
    private var breachesReturningResourceLimit = 0
    private var breachesCancellingPendingWork = 0
    private var refusedReadyTickets = 0
    private var permittedReadyTickets = 0
    private var failedSessionsWithNoReport = 0
    private var controlReports = 0
    private var controlSummaries = 0
    private var provenanceEnabledCases = 0
    private var pixelOnlyCases = 0

    // Produced coverage.
    private var observedStages: Set<AnalysisStage> = []
    private var observedMetrics: Set<ResourceMetric> = []
    private var observedBreachMetrics: Set<ResourceMetric> = []
    private var observedBreachCauses: Set<String> = []
    private var observedDeliveryStages: Set<AnalysisStage> = []
    private var observedDeliveryPorts: Set<PortCallKind> = []
    private var observedBoundaryReadings = 0

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var mainStreamLengths: Set<Int> = []
    private var extensionStreamLengths: Set<Int> = []
    private var breachPositions: Set<Int> = []

    func record(_ shape: ResourceStreamShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        mainStreamLengths.insert(shape.mainEventSelectors.count)
        extensionStreamLengths.insert(shape.extensionEventSelectors.count)
        breachPositions.insert(shape.breachPosition(for: .mainApplication))
        breachPositions.insert(shape.breachPosition(for: .shareExtension))
        observedDeliveryStages.insert(shape.deliveryStage)
        if shape.provenanceEnabled { provenanceEnabledCases += 1 } else { pixelOnlyCases += 1 }
    }

    func recordObservation(_ observation: StreamObservation) {
        lock.lock()
        defer { lock.unlock() }
        observations += 1
        observedStages.insert(observation.event.stage)
        observedMetrics.insert(observation.event.metric)
        if observation.event.readingOffset == 0, !observation.event.wouldExceed {
            observedBoundaryReadings += 1
        }
        if observation.isTheFirstBreach {
            firstBreachObservations += 1
            observedBreachMetrics.insert(observation.event.metric)
            if let breach = observation.breach {
                observedBreachCauses.insert("\(breach.cause)")
            }
            if observation.fault?.analysisError == .resourceLimit {
                breachesReturningResourceLimit += 1
            }
            if observation.cancelledSiblings == StreamPass.pendingWorkNames {
                breachesCancellingPendingWork += 1
            }
        } else if observation.isAtOrAfterTheFirstBreach {
            postBreachObservations += 1
            if !observation.event.wouldExceed { recoveredPostBreachObservations += 1 }
        }
        if observation.target == .shareExtension {
            if observation.permitsOwnCommit {
                permittedReadyTickets += 1
            } else {
                refusedReadyTickets += 1
            }
        }
    }

    func recordPass(_ pass: StreamPass) {
        lock.lock()
        defer { lock.unlock() }
        passes += 1
        if !pass.deliversTheBreach {
            cleanObservations += pass.observations.count
        } else {
            inBudgetPrefixObservations += pass.observations
                .filter { !$0.isAtOrAfterTheFirstBreach }
                .count
        }
    }

    /// Records the outcomes one fully executed case produced.
    func recordExecutedCase(_ run: ResourceStreamRun) {
        lock.lock()
        defer { lock.unlock() }
        executedCases += 1
        observedDeliveryPorts.insert(run.deliveryPort)
        if run.failedSession.outcome.isFailed, run.failedSession.evidenceReport == nil {
            failedSessionsWithNoReport += 1
        }
        if run.control.evidenceReport != nil { controlReports += 1 }
        if run.control.evidenceReport?.combinedSummary != nil { controlSummaries += 1 }
    }

    /// Records an input this file described but could not build.
    ///
    /// Never a finding about the controller or the coordinator: every input here is built
    /// from generated integers inside validated ranges, so a refusal is a defect in this
    /// file. It is counted so a run whose inputs quietly stopped being buildable fails
    /// outside the body rather than shrinking its own coverage.
    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectMeasuredRun(requestedCases: Int) {
        lock.lock()
        defer { lock.unlock() }

        let allMetrics =
            ResourceMetric.requiredMetrics(for: .mainApplication)
                .union(ResourceMetric.requiredMetrics(for: .shareExtension))
        let readOut = """
            cases \(cases)/\(requestedCases), completed bodies \(completedBodies), \
            executed \(executedCases), unbuildable \(unbuildableInputs); \
            passes \(passes), observations \(observations) \
            (clean \(cleanObservations), in-budget prefix \(inBudgetPrefixObservations), \
            first breaches \(firstBreachObservations), post-breach \(postBreachObservations), \
            recovered \(recoveredPostBreachObservations), \
            boundary readings \(observedBoundaryReadings)); \
            breaches returning resource-limit \(breachesReturningResourceLimit), \
            breaches stopping pending work \(breachesCancellingPendingWork), \
            causes \(observedBreachCauses.sorted()); \
            ready tickets permitted \(permittedReadyTickets), \
            refused \(refusedReadyTickets); \
            failed sessions with no report \(failedSessionsWithNoReport), \
            control reports \(controlReports), control summaries \(controlSummaries); \
            compositions provenance \(provenanceEnabledCases) / pixel-only \(pixelOnlyCases); \
            stages \(observedStages.count)/\(AnalysisStage.allCases.count), \
            metrics \(observedMetrics.count)/\(allMetrics.count), \
            breached metrics \(observedBreachMetrics.count)/\(allMetrics.count), \
            delivery stages \(observedDeliveryStages.count)/\(BreachDelivery.deliverableStages.count), \
            delivery ports \(observedDeliveryPorts.count)/\(BreachDelivery.pixelPipeline.count); \
            seeds \(seeds.count), main lengths \(mainStreamLengths.sorted()), \
            extension lengths \(extensionStreamLengths.sorted()), \
            breach positions \(breachPositions.sorted())
            """

        // The run happened at all.
        #expect(
            cases == requestedCases && completedBodies == cases && executedCases == cases,
            "read-out: \(readOut)"
        )
        #expect(
            cases == requestedCases,
            "the run must generate \(requestedCases) cases; ran \(cases)"
        )
        #expect(
            cases >= 100,
            "a run this thin cannot support the coverage floors below; ran \(cases) cases"
        )
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            executedCases == cases,
            "\(cases - executedCases) of \(cases) cases did not execute a probe"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Four passes per case, each of two to six events, and exactly one
        // first-breach event in each of the two breaching passes.
        #expect(passes == 4 * cases, "resource passes driven: \(passes)")
        #expect(observations >= 8 * cases, "measurements delivered: \(observations)")
        #expect(
            firstBreachObservations == 2 * cases,
            "\(firstBreachObservations) first-breach events for \(cases) cases, expected \(2 * cases)"
        )
        #expect(
            cleanObservations >= 4 * cases,
            "measurements taken with every reading inside its limit: \(cleanObservations)"
        )
        #expect(
            inBudgetPrefixObservations >= 2 * cases,
            "in-budget prefix measurements inside a breaching stream: \(inBudgetPrefixObservations)"
        )
        #expect(
            postBreachObservations >= 100,
            "measurements delivered after a breach: \(postBreachObservations)"
        )
        #expect(
            recoveredPostBreachObservations >= 50,
            "post-breach measurements whose reading recovered to inside its limit: \(recoveredPostBreachObservations)"
        )
        #expect(
            observedBoundaryReadings >= 50,
            "readings taken exactly at a bound limit, which must pass: \(observedBoundaryReadings)"
        )

        // Every breach did the two things a breach must do.
        #expect(
            breachesReturningResourceLimit == firstBreachObservations,
            "\(firstBreachObservations - breachesReturningResourceLimit) first-breach events returned something other than resource-limit"
        )
        #expect(
            breachesCancellingPendingWork == firstBreachObservations,
            "\(firstBreachObservations - breachesCancellingPendingWork) first-breach events did not stop both registered pending work items"
        )
        #expect(
            observedBreachCauses == ["wouldExceedHardLimit"],
            "every generated breach must be a measured would-exceed; observed \(observedBreachCauses.sorted())"
        )

        // The extension claim flipped, in both directions, in quantity.
        #expect(
            permittedReadyTickets >= 2 * cases,
            "in-budget extension measurements that permitted a ready ticket: \(permittedReadyTickets)"
        )
        #expect(
            refusedReadyTickets >= cases,
            "extension measurements at or after a breach that refused a ready ticket: \(refusedReadyTickets)"
        )

        // Every absence was measured beside a presence, on every case.
        #expect(
            failedSessionsWithNoReport == cases,
            "\(cases - failedSessionsWithNoReport) cases did not produce a failed terminal with no Evidence Report"
        )
        #expect(
            controlReports == cases,
            "\(cases - controlReports) cases produced no positive-control Evidence Report"
        )
        #expect(
            controlSummaries == provenanceEnabledCases,
            "\(provenanceEnabledCases - controlSummaries) provenance-enabled cases produced no Combined Summary, so the summary zeros are not measured against ones"
        )
        #expect(
            provenanceEnabledCases >= 50,
            "provenance-and-fusion cases, without which two of the no-evidence zeros are vacuous: \(provenanceEnabledCases)"
        )
        #expect(pixelOnlyCases >= 50, "pixel-only cases: \(pixelOnlyCases)")

        // The substantive half: the inputs were actually varied.
        #expect(
            observedStages == Set(AnalysisStage.allCases),
            "stages never checkpointed: \(Set(AnalysisStage.allCases).subtracting(observedStages).map(\.rawValue).sorted())"
        )
        #expect(
            observedMetrics == allMetrics,
            "metrics never sampled: \(allMetrics.subtracting(observedMetrics).map(\.rawValue).sorted())"
        )
        #expect(
            observedBreachMetrics == allMetrics,
            "metrics never driven to a would-exceed reading: \(allMetrics.subtracting(observedBreachMetrics).map(\.rawValue).sorted())"
        )
        #expect(
            observedDeliveryStages == Set(BreachDelivery.deliverableStages),
            "breach stages never delivered to a session: \(Set(BreachDelivery.deliverableStages).subtracting(observedDeliveryStages).map(\.rawValue).sorted())"
        )
        #expect(
            observedDeliveryPorts == Set(BreachDelivery.pixelPipeline),
            "pipeline ports never used to deliver a breach: \(Set(BreachDelivery.pixelPipeline).subtracting(observedDeliveryPorts).map(\.rawValue).sorted())"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            mainStreamLengths == [2, 3, 4, 5, 6],
            "generated main-application stream lengths: \(mainStreamLengths.sorted())"
        )
        #expect(
            extensionStreamLengths == [2, 3, 4, 5, 6],
            "generated Share Extension stream lengths: \(extensionStreamLengths.sorted())"
        )
        #expect(
            breachPositions == [1, 2, 3, 4, 5],
            "generated first-breach positions: \(breachPositions.sorted())"
        )
    }
}

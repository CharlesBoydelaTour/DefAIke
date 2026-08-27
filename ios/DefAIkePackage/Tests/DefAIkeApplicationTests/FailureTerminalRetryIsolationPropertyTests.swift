import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 11: failure terminals and retry sessions are isolated.
//
// The design states it as: for any validation or preprocessing failure followed by any
// valid new selection, the failed session contains exactly one applicable error and no
// evidence, while the new session receives a new identity and initial state with none of
// the prior session's error, bytes, dimensions, tasks, or evidence.
//
// That is two claims, and both of them are claims about *absence*. A property built from
// absences is the easiest kind to pass for free, so almost all of the machinery below
// exists to make each absence measured against a presence.
//
// ## Half one: the failure terminal (Requirement 3.12)
//
// Six failure shapes are generated, and they are the closed set of applicable
// (category, stage) pairs a validation or preprocessing failure can take: the five
// categories Requirement 3.12 enumerates, at the stage each is detected in. Four are
// raised by the Input Validator (`unsupported-media` and `unsupported-static-format` at
// media classification, `decoding-error` and `resource-limit` at input validation) and two
// by the Preprocessor (`preprocessing-error` and `resource-limit` at preprocessing).
// `resource-limit` appears twice on purpose: Requirement 3.4 raises it during validation
// and Requirement 3.11's stage raises it during preprocessing, and a property that pinned
// one stage per category would not notice a session that reported the wrong one.
//
// For each, the session is required to end with **exactly one** category out of the ten —
// asserted by filtering the whole `AnalysisError` vocabulary down to the reported value and
// requiring a single member, not by checking that *some* error is present — at **exactly**
// the generated stage, with the terminal disjoint from both `completed` and `cancelled`, and
// with no evidence of any kind: no Evidence Report, no calibrated Pixel Evidence, no
// provenance result, no Combined Summary, and no fusion attempt.
//
// Requirement 3.14 is the reason nothing here asserts that measurements were discarded. A
// failure *preserves* the Byte Preservation Status and every pre-orientation dimension
// recorded before it, so the preprocessing-stage failures are required to carry the failed
// attempt's own dimensions, and the validation-stage failures are required to carry none —
// because none had been recorded yet, not because they were thrown away.
//
// ## Half two: the retry (Requirements 3.13 and 3.15)
//
// A valid new selection follows every generated failure, and it is generated under the
// **same session identifier** in about half the cases. That is the case an identifier-only
// check cannot see: a released identifier can be bound again, so while the retry is in
// flight the failed attempt's identity has the same `AnalysisSessionID` as the running one
// and differs only in generation. The retry is therefore held open at its own input
// validation call and, from there, the failed identity is required to be refused as
// **stale** by result admission, by a cancellation request, and by a terminal offer — while
// the running retry is required to admit its own results, to hold no committed terminal, and
// to carry no cancellation request.
//
// The retry then reaches its own terminal on its own merits, generated as either a completed
// session or a *differently categorised* failure, and is required to retain nothing: no
// error category (the retry's error is `nil` or its own, never the first attempt's), no
// dimensions, no Byte Preservation Status, no evidence, no task, and no identity.
//
// ## Why every absence is measured against a presence
//
// Three things guard against a property that passes because the coordinator never ran.
//
//   * **A positive control on every case.** Before the failure, the *same* coordinator, the
//     same release, and the same ports run one session that completes with an Evidence
//     Report, an available provenance lane, and a Combined Summary. So every "no evidence"
//     assertion on the failed attempt is measured against a path that provably produces
//     evidence through the identical wiring, and the call log proves it: the control's
//     `calibrate`, `provenanceAnalyze`, and `fuse` calls are counted before the log is
//     cleared for the failed attempt.
//   * **The failure reached the stage it was meant to.** The shared call log is cleared
//     between attempts, so the failed attempt's log is its own. A validator-raised failure
//     must show exactly one `validate` call and no `preprocess` call; a preprocessor-raised
//     one must show exactly one of each. Either way `loadModel`, `infer`, `calibrate`,
//     `provenanceAnalyze`, and `fuse` must be absent. A failure that degenerated into
//     "failed before anything ran" shows zero `validate` calls and fails, rather than
//     satisfying isolation for free.
//   * **Three mutually distinct baselines.** The control, the failed attempt, and the retry
//     draw their decoded dimensions from three disjoint ranges and their Byte Preservation
//     Status from a rotation over the three distinct statuses, so all three attempts differ
//     in every preserved field in every case. "The retry inherited nothing" is then a
//     comparison against concrete different values rather than against a coincidence.
//
// ``IsolationWitness`` counts all of that *outside* the property body, because
// `propertyCheck` runs its body under `try?` and discards a thrown error: a body that threw
// on its first statement would report a passing run in milliseconds with every assertion
// skipped. `completedBodies == cases` alone does not catch it — it passes vacuously as
// `0 == 0` — so the witness also pins the case count against the requested count, requires
// one release, three ended sessions, one control report, one failed terminal, one retry
// terminal, and one in-flight stale probe *per case*, and requires every failure shape,
// both retry terminals, both identifier modes, all three statuses in each of the three
// positions, and all four preservation bases to have been **produced**. Nothing in the body
// throws: every fallible construction is turned into an `Issue.record` and a counted
// unbuildable input.
//
// ## What this file does not assert, and what it does not decide
//
//   * **Nothing here is an approved release value.** The release is `CoordinatorRelease`,
//     whose every artifact is synthetic; the failure categories and stages are the
//     requirements' own closed vocabulary rather than a chosen policy; and the byte counts,
//     dimensions, identifiers, and byte seeds are synthetic. No budget, deadline, boundary,
//     tolerance, or approved value is fabricated, and no fixture artifact is invented.
//   * **Cancellation is not this property's subject.** A cancelled terminal appears only as
//     the thing a failure must be disjoint from. Properties 25 and 34 through 36 own
//     cancellation, terminal disjointness, and cleanup; task 10.13 owns the cancellation-point
//     integration matrix.
//   * **Only the serial branch execution is exercised**, which is the harness default. Both
//     approved executions resolve the two evidence branches at step five of the pipeline,
//     and every failure generated here ends the session before step five, so the concurrent
//     policy would exercise the identical path with an extra degree of freedom that changes
//     nothing.
//   * `AnalysisCoordinatorFailureTests` and `AnalysisCoordinatorRetryTests` already pin these
//     behaviours at examples: one stage-fault table over three shapes, one clean retry under
//     the same identifier, one "leaves nothing behind" check, one re-bind count, and one
//     three-attempt sequence. This file quantifies the same statements over all six
//     applicable shapes, both retry terminals, both identifier modes, three distinct
//     dimension baselines, and three distinct byte statuses — and adds the in-flight stale
//     probe, which no example covers.

extension Tag {
    /// Design Property 11.
    ///
    /// Declared here rather than in a shared namespace: each design property owns one file,
    /// and a shared tag namespace would be a merge point between independently written
    /// property files.
    @Tag static var property11FailureTerminalRetryIsolation: Self
}

@Suite(
    "Property 11: Failure terminals and retry sessions are isolated",
    .tags(.property11FailureTerminalRetryIsolation)
)
struct FailureTerminalRetryIsolationPropertyTests {

    /// The number of generated cases requested.
    ///
    /// Above the library default of 100 because the coverage the witness requires is a
    /// product: six applicable failure shapes crossed with two retry terminals and with two
    /// identifier modes is twelve cells in each product, and 240 uniform draws put roughly
    /// twenty cases in each. Raising the count is the only honest way to reach that; the
    /// assertions are never relaxed to fit a smaller run.
    static let generatedCaseCount = 240

    /// **Validates: Requirements 3.12, 3.13, 3.15**
    @Test("A failure ends in one error with no evidence, and the retry inherits nothing")
    func failureTerminalsAndRetrySessionsAreIsolated() async {
        let witness = IsolationWitness()

        await propertyCheck(count: Self.generatedCaseCount, input: IsolationShape.generator) {
            shape in
            witness.record(shape)
            await runIsolationCase(shape, witness: witness)
            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }
}

// MARK: - The applicable failure shapes

/// One applicable validation or preprocessing failure: a category and the stage it is
/// detected in.
///
/// The six values are not a chosen sample. Requirement 3.12 names exactly five presentable
/// categories, and each is detected at the stage the requirements assign it — with
/// `resource-limit` detected at two different stages, which is why the pair rather than the
/// category is the unit.
private struct ApplicableFailure: Hashable, Sendable, CustomStringConvertible {
    let error: AnalysisError
    let stage: AnalysisStage

    /// Whether the Input Validator raises this fault, as opposed to the Preprocessor.
    ///
    /// Decides which port the fault is queued on, and therefore which call log the failed
    /// attempt must show.
    var isRaisedByValidator: Bool { stage != .preprocessing }

    var fault: AnalysisFault { .analysis(error, stage: stage) }

    var description: String { "\(error.rawValue)@\(stage.rawValue)" }

    /// The five categories Requirement 3.12 permits a validation or preprocessing failure to
    /// present. Any other category reaching a terminal here is a finding.
    static let presentableCategories: Set<AnalysisError> = [
        .unsupportedMedia,
        .unsupportedStaticFormat,
        .decodingError,
        .resourceLimit,
        .preprocessingError,
    ]

    /// Every applicable (category, stage) pair, swept by the generator.
    static let all: [ApplicableFailure] = [
        ApplicableFailure(error: .unsupportedMedia, stage: .mediaClassification),
        ApplicableFailure(error: .unsupportedStaticFormat, stage: .mediaClassification),
        ApplicableFailure(error: .decodingError, stage: .inputValidation),
        ApplicableFailure(error: .resourceLimit, stage: .inputValidation),
        ApplicableFailure(error: .preprocessingError, stage: .preprocessing),
        ApplicableFailure(error: .resourceLimit, stage: .preprocessing),
    ]
}

// MARK: - Preservation baselines

/// One Byte Preservation Status with a basis that supports it.
///
/// Paired rather than chosen independently because `ImportedEncodedAsset` refuses a status
/// its basis does not support, and each basis supports exactly one status. Only three
/// distinct statuses exist, so a case assigns all three — one to the control, one to the
/// failed attempt, one to the retry — which is what makes "the retry did not inherit the
/// failed attempt's byte status" a comparison between two different values in every case.
private struct PreservationBaseline: Hashable, Sendable, CustomStringConvertible {
    let status: BytePreservationStatus
    let basis: PreservationBasis

    var description: String { "\(status.rawValue)/\(basis.rawValue)" }

    /// The three distinct statuses, in a fixed order the rotation indexes into.
    static let statuses: [BytePreservationStatus] = [
        .originalBytes,
        .platformTransformedCopy,
        .unknown,
    ]

    /// The baseline for `status`, choosing between the two bases that report `unknown`.
    ///
    /// Both of them are exercised across a run, so all four bases are produced rather than
    /// three.
    static func baseline(
        for status: BytePreservationStatus,
        unknownBasisSelector: Int
    ) -> PreservationBaseline {
        switch status {
        case .originalBytes:
            return PreservationBaseline(
                status: status,
                basis: .providerDeclaredOriginalRepresentation
            )
        case .platformTransformedCopy:
            return PreservationBaseline(
                status: status,
                basis: .providerDeclaredTransformedRepresentation
            )
        case .unknown:
            return PreservationBaseline(
                status: status,
                basis: unknownBasisSelector % 2 == 0
                    ? .providerDeclaredCurrentRepresentationOnly
                    : .preservationHistoryNotEstablished
            )
        }
    }
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain integers.
///
/// Integers only, resolved into failures, baselines, and dimensions through computed
/// properties, so the generator has no fallible construction in it and the shrinkers that
/// `zip` composes stay composed.
///
/// Every selector is drawn from `0...959`. 960 is divisible by 2, 3, 4, 5, and 6, so every
/// modulus taken below partitions the range into equal parts and no reduction skews the
/// distribution toward a low index.
private struct IsolationShape: Sendable, CustomStringConvertible {
    /// Varies the byte seeds, so no two cases analyse the same bytes.
    let seed: Int

    /// Selects the generated failure among the six applicable shapes.
    let failureSelector: Int

    /// Selects the retry's failure among the shapes with a *different* category.
    let retryFailureSelector: Int

    /// Selects whether the retry completes or fails.
    let retryTerminalSelector: Int

    /// Selects whether the retry runs under the failed session's identifier.
    let identifierSelector: Int

    /// Rotates which of the three statuses each of the three attempts records.
    let statusRotationSelector: Int

    /// Selects which of the two `unknown`-reporting bases is used.
    let unknownBasisSelector: Int

    /// The control attempt's decoded dimensions.
    let controlWidth: Int
    let controlHeight: Int

    /// The failed attempt's decoded dimensions.
    let failedWidth: Int
    let failedHeight: Int

    /// The retry's decoded dimensions.
    let retryWidth: Int
    let retryHeight: Int

    // MARK: Derived

    var failure: ApplicableFailure {
        ApplicableFailure.all[failureSelector % ApplicableFailure.all.count]
    }

    /// Whether the retry ends in a failure of its own.
    var retryFails: Bool { retryTerminalSelector % 2 == 0 }

    /// The retry's own failure, or `nil` when the retry completes.
    ///
    /// Always a *different* category from the first attempt's, so "the retry did not inherit
    /// an error category" is a comparison between two distinguishable categories rather than
    /// a tautology.
    var retryFailure: ApplicableFailure? {
        guard retryFails else { return nil }
        let others = ApplicableFailure.all.filter { $0.error != failure.error }
        guard !others.isEmpty else { return nil }
        return others[retryFailureSelector % others.count]
    }

    /// Whether the retry is a new selection under the failed session's own identifier.
    var retryUnderSameIdentifier: Bool { identifierSelector % 2 == 0 }

    /// The failed session's identifier. Synthetic.
    var failedSessionIdentifier: String { "session-0001" }

    /// The retry's identifier: the same one about half the time, a different one otherwise.
    var retrySessionIdentifier: String {
        retryUnderSameIdentifier ? failedSessionIdentifier : "session-0002"
    }

    /// The control session's identifier, distinct from both of the others so a value
    /// carried over from it would be visible rather than ambiguous. Synthetic.
    var controlSessionIdentifier: String { "session-0900" }

    private var rotation: Int { statusRotationSelector % PreservationBaseline.statuses.count }

    private func baseline(offsetBy offset: Int) -> PreservationBaseline {
        let statuses = PreservationBaseline.statuses
        return PreservationBaseline.baseline(
            for: statuses[(rotation + offset) % statuses.count],
            unknownBasisSelector: unknownBasisSelector
        )
    }

    /// The three attempts' preservation baselines, pairwise distinct in status.
    var controlPreservation: PreservationBaseline { baseline(offsetBy: 0) }
    var failedPreservation: PreservationBaseline { baseline(offsetBy: 1) }
    var retryPreservation: PreservationBaseline { baseline(offsetBy: 2) }

    /// Byte seeds, distinct per attempt so the three assets are distinguishable.
    var controlByteSeed: UInt8 { UInt8(truncatingIfNeeded: seed &* 3 &+ 1) }
    var failedByteSeed: UInt8 { UInt8(truncatingIfNeeded: seed &* 3 &+ 2) }
    var retryByteSeed: UInt8 { UInt8(truncatingIfNeeded: seed &* 3 &+ 3) }

    var description: String {
        """
        seed \(seed), failure \(failure), \
        retry \(retryFailure.map(\.description) ?? "completed"), \
        sameIdentifier \(retryUnderSameIdentifier), \
        preservation \(controlPreservation)|\(failedPreservation)|\(retryPreservation), \
        dimensions \(controlWidth)x\(controlHeight)|\(failedWidth)x\(failedHeight)|\
        \(retryWidth)x\(retryHeight)
        """
    }

    // MARK: Generators

    /// The composed generator.
    ///
    /// Two nested `zip`s rather than one flat one: the library's `zip` composes at most ten
    /// generators, and thirteen integers are needed.
    static var generator: Generator<IsolationShape, AnySequence<Any>> {
        zip(selectors, dimensions)
            .map { raw in
                IsolationShape(
                    seed: raw.0.0,
                    failureSelector: raw.0.1,
                    retryFailureSelector: raw.0.2,
                    retryTerminalSelector: raw.0.3,
                    identifierSelector: raw.0.4,
                    statusRotationSelector: raw.0.5,
                    unknownBasisSelector: raw.0.6,
                    controlWidth: raw.1.0,
                    controlHeight: raw.1.1,
                    failedWidth: raw.1.2,
                    failedHeight: raw.1.3,
                    retryWidth: raw.1.4,
                    retryHeight: raw.1.5
                )
            }
            .eraseToAny()
    }

    private static var selectors:
        Generator<(Int, Int, Int, Int, Int, Int, Int), AnySequence<Any>>
    {
        zip(
            Gen.int(in: 0...959),
            Gen.int(in: 0...959),
            Gen.int(in: 0...959),
            Gen.int(in: 0...959),
            Gen.int(in: 0...959),
            Gen.int(in: 0...959),
            Gen.int(in: 0...959)
        )
        .eraseToAny()
    }

    /// Three dimension pairs from three **disjoint** ranges.
    ///
    /// Disjointness is what makes the inheritance question decidable. If a retry's recorded
    /// dimensions could coincide with the failed attempt's, "the retry did not inherit them"
    /// would be unfalsifiable on those cases; here every recorded width, height, and short
    /// edge is different across the three attempts in every case.
    private static var dimensions: Generator<(Int, Int, Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 101...400),
            Gen.int(in: 101...400),
            Gen.int(in: 401...700),
            Gen.int(in: 401...700),
            Gen.int(in: 701...1_000),
            Gen.int(in: 701...1_000)
        )
        .eraseToAny()
    }
}

// MARK: - One generated case

/// Runs the control, the generated failure, and the retry through one coordinator.
///
/// Nothing in here throws. `propertyCheck` runs its body under `try?`, so an escaping error
/// would report a passing case with every assertion skipped; each fallible construction is
/// therefore reported through `Issue.record` and counted as an unbuildable input, and the
/// case returns before reaching ``IsolationWitness/recordCompletedBody()``.
private func runIsolationCase(_ shape: IsolationShape, witness: IsolationWitness) async {
    let release: CoordinatorRelease
    do {
        // Provenance and fusion both enabled, so the control produces a provenance result
        // and a Combined Summary. Without them, "the failed session has no provenance result
        // and no Combined Summary" would hold in a composition that never produces either.
        release = try await CoordinatorRelease.build(provenance: true, fusion: true)
    } catch {
        Issue.record("the synthetic release must pass its own startup gate: \(error) [\(shape)]")
        witness.recordUnbuildableInput()
        return
    }
    witness.recordRelease()

    let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
    let controlSession = PortValue.sessionID(shape.controlSessionIdentifier)
    let failedSession = PortValue.sessionID(shape.failedSessionIdentifier)
    let retrySession = PortValue.sessionID(shape.retrySessionIdentifier)

    // Each attempt's decode is stamped with its own session and the bound contract version,
    // which the coordinator checks; a mismatch would be refused as a foreign decode and the
    // generated failure would never be reached.
    let controlImage = PortValue.validatedImage(
        sessionID: controlSession,
        width: shape.controlWidth,
        height: shape.controlHeight,
        preprocessingContractID: contractID
    )
    let failedImage = PortValue.validatedImage(
        sessionID: failedSession,
        width: shape.failedWidth,
        height: shape.failedHeight,
        preprocessingContractID: contractID
    )
    let retryImage = PortValue.validatedImage(
        sessionID: retrySession,
        width: shape.retryWidth,
        height: shape.retryHeight,
        preprocessingContractID: contractID
    )

    var validateSteps: [StubOutcome<ValidatedImage>.Step] = [.success(controlImage)]
    validateSteps.append(
        shape.failure.isRaisedByValidator
            ? .fault(shape.failure.fault)
            : .success(failedImage)
    )
    var preprocessSteps: [StubOutcome<ModelImageInput>.Step] = [
        .success(
            PortValue.modelInput(sessionID: controlSession, preprocessingContractID: contractID)
        )
    ]
    if !shape.failure.isRaisedByValidator {
        preprocessSteps.append(.fault(shape.failure.fault))
    }
    if let retryFailure = shape.retryFailure {
        if retryFailure.isRaisedByValidator {
            validateSteps.append(.fault(retryFailure.fault))
            // The retry never reaches preprocessing, so no step is queued for it.
        } else {
            validateSteps.append(.success(retryImage))
            preprocessSteps.append(.fault(retryFailure.fault))
        }
    } else {
        validateSteps.append(.success(retryImage))
        preprocessSteps.append(
            .success(
                PortValue.modelInput(sessionID: retrySession, preprocessingContractID: contractID)
            )
        )
    }

    // The retry is the third validation call, whichever stage each attempt fails at, because
    // every attempt reaches validation. Holding there is what creates the window in which the
    // failed attempt's identity and the running retry's identity coexist.
    let gate = AttemptGate()
    let validator = SequencedInputValidator(
        outcome: StubOutcome(validateSteps),
        recorder: release.recorder,
        gate: gate,
        gateCallNumber: 3
    )
    let coordinator = AnalysisCoordinator(
        binder: release.binder(),
        validator: validator,
        preprocessor: StubImagePreprocessor(
            outcome: StubOutcome(preprocessSteps),
            recorder: release.recorder
        ),
        modelLoader: StubPixelModelLoader(
            outcome: StubOutcome(always: CoordinatorSample.loadedModel(bundle: release.bundle)),
            recorder: release.recorder
        ),
        analyzer: StubPixelAnalyzer(
            outcome: StubOutcome(always: PortValue.logit(1.5)),
            recorder: release.recorder
        ),
        calibrator: StubPixelCalibrator(
            outcome: StubOutcome(always: .signalsConsistentWithAIGeneration),
            recorder: release.recorder
        ),
        provenance: ProvenanceLaneProvider.resolve(
            analyzer: StubProvenanceAnalyzer(always: .absent, recorder: release.recorder),
            policy: release.admission.configuration.provenancePolicy,
            manifest: release.admission.configuration.capabilityManifest
        ),
        fuser: StubEvidenceFuser(recorder: release.recorder),
        inconsistencyClassifier: nil,
        cleanup: SessionTerminalCleanup(
            deleter: release.deleter,
            policy: release.lifecyclePolicy
        ),
        // The harness default: serial under the release's own validation plan. Every failure
        // generated here ends the session before either evidence branch starts, so the
        // concurrent policy would take the identical path.
        branchExecution: .serial(
            validationPlan: CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
        )
    )

    // MARK: The positive control

    guard let controlAsset = await makeAcceptedIngest(
        release: release,
        sessionID: shape.controlSessionIdentifier,
        byteSeed: shape.controlByteSeed,
        preservation: shape.controlPreservation,
        shape: shape,
        witness: witness
    ) else { return }
    guard let control = await coordinator.analyze(controlAsset).completed else {
        Issue.record("the control session must end with a terminal outcome [\(shape)]")
        witness.recordUnbuildableInput()
        return
    }
    witness.recordEndedSession()
    guard let controlReport = control.evidenceReport else {
        Issue.record(
            """
            the control session must produce an Evidence Report, otherwise every \
            "no evidence" assertion below is measured against nothing [\(shape)]
            """
        )
        witness.recordUnbuildableInput()
        return
    }
    witness.recordControlReport()

    // The control is the presence half of the property. It proves this wiring produces every
    // kind of evidence the failed attempt must then be shown not to have.
    #expect(control.outcome.isCompleted)
    #expect(control.error == nil)
    #expect(control.outcome.failure == nil)
    #expect(controlReport.provenance.isAvailable)
    #expect(controlReport.combinedSummary != nil)
    #expect(control.fusionFault == nil)
    #expect(controlReport.bytePreservationStatus == shape.controlPreservation.status)
    #expect(controlReport.inputQuality.decodedWidthBeforeOrientation == shape.controlWidth)
    #expect(controlReport.inputQuality.decodedHeightBeforeOrientation == shape.controlHeight)
    let controlLog = release.recorder
    #expect(controlLog.callCount(of: .validate) == 1)
    #expect(controlLog.callCount(of: .preprocess) == 1)
    #expect(controlLog.callCount(of: .loadModel) == 1)
    #expect(controlLog.callCount(of: .infer) == 1)
    #expect(controlLog.callCount(of: .calibrate) == 1)
    #expect(controlLog.callCount(of: .provenanceAnalyze) == 1)
    #expect(controlLog.callCount(of: .fuse) == 1)

    // MARK: The generated failure (Requirement 3.12)

    // Cleared so the failed attempt's log is its own, which is what makes the stage claim and
    // the nonoccurrence claims below statements about this attempt rather than about the run.
    release.recorder.reset()
    guard let failedAsset = await makeAcceptedIngest(
        release: release,
        sessionID: shape.failedSessionIdentifier,
        byteSeed: shape.failedByteSeed,
        preservation: shape.failedPreservation,
        shape: shape,
        witness: witness
    ) else { return }
    guard let failed = await coordinator.analyze(failedAsset).completed else {
        Issue.record("the failed session must end with a terminal outcome [\(shape)]")
        witness.recordUnbuildableInput()
        return
    }
    witness.recordEndedSession()
    guard let snapshot = failed.outcome.failure else {
        Issue.record(
            """
            a \(shape.failure) fault must produce a failed terminal, \
            found \(failed.outcome) [\(shape)]
            """
        )
        witness.recordUnbuildableInput()
        return
    }
    witness.recordFailureTerminal(shape: shape, snapshot: snapshot)

    // Exactly one category, out of the whole vocabulary rather than "some error present".
    let reportedCategories = AnalysisError.allCases.filter {
        $0 == snapshot.error || $0 == failed.error
    }
    #expect(reportedCategories == [shape.failure.error])
    #expect(snapshot.error == shape.failure.error)
    #expect(failed.error == shape.failure.error)
    // Requirement 3.12 permits exactly these five categories for a validation or
    // preprocessing failure.
    #expect(ApplicableFailure.presentableCategories.contains(snapshot.error))
    // Exactly the generated stage, not "somewhere upstream".
    #expect(snapshot.stage == shape.failure.stage)
    #expect(snapshot.sessionID == failedAsset.sessionID)

    // One terminal, disjoint from the other two.
    #expect(failed.outcome.isFailed)
    #expect(failed.outcome.isCompleted == false)
    #expect(failed.outcome.isCancelled == false)
    #expect(failed.outcome != .cancelled)
    #expect(failed.outcome == .failed(snapshot))

    // No evidence of any kind.
    #expect(failed.evidenceReport == nil)
    #expect(failed.outcome.evidenceReport == nil)
    #expect(failed.fusionFault == nil)
    let failureLog = release.recorder
    #expect(failureLog.didCall(PortCallKind.loadModel) == false)
    #expect(failureLog.didCall(PortCallKind.infer) == false)
    #expect(failureLog.didCall(PortCallKind.calibrate) == false)
    #expect(failureLog.didCall(PortCallKind.provenanceAnalyze) == false)
    #expect(failureLog.didCall(PortCallKind.fuse) == false)

    // The failure happened where it was generated to happen. A session that failed before
    // validation ran shows no `validate` call and fails here.
    #expect(failureLog.callCount(of: .validate) == 1)
    #expect(failureLog.callCount(of: .preprocess) == (shape.failure.isRaisedByValidator ? 0 : 1))

    // Requirement 3.14: what had been recorded before the failure is preserved, and nothing
    // that had not been recorded is invented. This is also a second, port-independent reading
    // of where the failure happened.
    #expect(snapshot.bytePreservationStatus == shape.failedPreservation.status)
    #expect(snapshot.bytePreservationStatus != shape.controlPreservation.status)
    if shape.failure.isRaisedByValidator {
        #expect(snapshot.inputQuality == nil)
    } else {
        #expect(snapshot.inputQuality?.decodedWidthBeforeOrientation == shape.failedWidth)
        #expect(snapshot.inputQuality?.decodedHeightBeforeOrientation == shape.failedHeight)
        #expect(
            snapshot.inputQuality?.shortEdgeBeforeOrientation
                == min(shape.failedWidth, shape.failedHeight)
        )
    }

    // The failed attempt left nothing behind, which is the structural precondition for a
    // clean retry (Requirement 3.15).
    #expect(failed.cleanup.receipt?.reason == .errorTerminated)
    #expect(await release.ephemeral.occupiedScopes().isEmpty)
    #expect(await coordinator.activeIdentity() == nil)
    #expect(await coordinator.currentStage() == nil)
    #expect(await coordinator.committedTerminal() == nil)
    #expect(await coordinator.isCancellationRequested() == false)
    #expect(await release.binder().boundSessionIDs.isEmpty)
    // No task, no identity: a request naming the failed attempt finds nothing to cancel.
    let idleRequest = await coordinator.requestCancellation(for: failed.identity)
    #expect(idleRequest.commit == .refusedNoActiveSession)
    #expect(idleRequest.latchedRequest == false)
    #expect(idleRequest.cancelledStructuredTask == false)
    #expect(idleRequest.invokedHookCount == 0)
    let idleAdmission = await coordinator.admitFrameworkResult(for: failed.identity)
    #expect(idleAdmission == .discardedNoActiveSession)

    // MARK: The retry (Requirements 3.13 and 3.15)

    release.recorder.reset()
    guard let retryAsset = await makeAcceptedIngest(
        release: release,
        sessionID: shape.retrySessionIdentifier,
        byteSeed: shape.retryByteSeed,
        preservation: shape.retryPreservation,
        shape: shape,
        witness: witness
    ) else { return }

    // No application restart between the two: the same coordinator, the same release, the
    // same ports (Requirement 3.13).
    async let running = coordinator.analyze(retryAsset)
    await gate.waitUntilReached()

    let liveIdentity = await coordinator.activeIdentity()
    let staleAdmission = await coordinator.admitFrameworkResult(for: failed.identity)
    let staleRequest = await coordinator.requestCancellation(for: failed.identity)
    let staleCommit = await coordinator.commitTerminal(.cancelled, for: failed.identity)
    let requestedAfterStale = await coordinator.isCancellationRequested()
    let terminalWhileRunning = await coordinator.committedTerminal()
    var liveAdmission: FrameworkResultAdmission?
    if let liveIdentity {
        liveAdmission = await coordinator.admitFrameworkResult(for: liveIdentity)
    }
    await gate.openGate()
    let retryOutcome = await running

    witness.recordStaleProbe()
    #expect(await gate.timedOut() == false)

    // The retry is a new attempt with a new identity, and the failed attempt's identity is
    // stale rather than merely absent. Under the same identifier this is the whole point: the
    // session identifiers match and only the generation differs, so a check that compared
    // identifiers alone would admit the first attempt's results into the second.
    guard let live = liveIdentity else {
        Issue.record("the retry must be the running attempt while it is held [\(shape)]")
        witness.recordUnbuildableInput()
        return
    }
    #expect(live.generation == failed.identity.generation + 1)
    #expect(live.sessionID == retryAsset.sessionID)
    if shape.retryUnderSameIdentifier {
        #expect(live.sessionID == failed.identity.sessionID)
    } else {
        #expect(live.sessionID != failed.identity.sessionID)
    }
    #expect(staleAdmission == .discardedStaleIdentity(offered: failed.identity))
    #expect(staleAdmission.isAdmitted == false)
    #expect(staleRequest.commit == .refusedStaleIdentity(offered: failed.identity))
    #expect(staleRequest.latchedRequest == false)
    #expect(staleRequest.cancelledStructuredTask == false)
    #expect(staleRequest.invokedHookCount == 0)
    #expect(staleCommit == .refusedStaleIdentity(offered: failed.identity))
    #expect(staleCommit.didCommit == false)
    // The retry's own state is initial: no inherited terminal, no inherited request.
    #expect(requestedAfterStale == false)
    #expect(terminalWhileRunning == nil)
    #expect(liveAdmission == .admitted)

    guard let retried = retryOutcome.completed else {
        Issue.record("the retry must end with its own terminal outcome [\(shape)]")
        witness.recordUnbuildableInput()
        return
    }
    witness.recordEndedSession()
    witness.recordRetryTerminal(shape: shape, session: retried)

    #expect(retried.identity == live)
    #expect(retried.identity.generation == failed.identity.generation + 1)
    #expect(retried.sessionID == retryAsset.sessionID)

    // The retry reached its own terminal on its own merits.
    let retryLog = release.recorder
    #expect(retryLog.callCount(of: .validate) == 1)
    if let retryFailure = shape.retryFailure {
        guard let retrySnapshot = retried.outcome.failure else {
            Issue.record(
                """
                a \(retryFailure) fault must produce a failed terminal, \
                found \(retried.outcome) [\(shape)]
                """
            )
            witness.recordUnbuildableInput()
            return
        }
        #expect(retrySnapshot.error == retryFailure.error)
        #expect(retrySnapshot.stage == retryFailure.stage)
        // No error category from the failed session, checked against a distinguishable
        // category rather than against `nil` (Requirement 3.15).
        #expect(retrySnapshot.error != shape.failure.error)
        #expect(retried.error != shape.failure.error)
        #expect(retrySnapshot.sessionID == retryAsset.sessionID)
        #expect(retried.evidenceReport == nil)
        #expect(retrySnapshot.bytePreservationStatus == shape.retryPreservation.status)
        #expect(retrySnapshot.bytePreservationStatus != shape.failedPreservation.status)
        #expect(retrySnapshot.bytePreservationStatus != shape.controlPreservation.status)
        #expect(
            retryLog.callCount(of: .preprocess) == (retryFailure.isRaisedByValidator ? 0 : 1)
        )
        if retryFailure.isRaisedByValidator {
            #expect(retrySnapshot.inputQuality == nil)
        } else {
            #expect(retrySnapshot.inputQuality?.decodedWidthBeforeOrientation == shape.retryWidth)
            #expect(retrySnapshot.inputQuality?.decodedHeightBeforeOrientation == shape.retryHeight)
        }
        // No dimensions from either earlier attempt.
        #expect(retrySnapshot.inputQuality?.decodedWidthBeforeOrientation != shape.failedWidth)
        #expect(retrySnapshot.inputQuality?.decodedWidthBeforeOrientation != shape.controlWidth)
        #expect(retried.cleanup.receipt?.reason == .errorTerminated)
    } else {
        guard let retryReport = retried.evidenceReport else {
            Issue.record("a valid new selection must complete with a report [\(shape)]")
            witness.recordUnbuildableInput()
            return
        }
        #expect(retried.outcome.isCompleted)
        // No error category at all (Requirement 3.15).
        #expect(retried.error == nil)
        #expect(retried.outcome.failure == nil)
        // Its own dimensions and its own byte status, both different from either earlier
        // attempt's.
        #expect(retryReport.inputQuality.decodedWidthBeforeOrientation == shape.retryWidth)
        #expect(retryReport.inputQuality.decodedHeightBeforeOrientation == shape.retryHeight)
        #expect(retryReport.inputQuality != controlReport.inputQuality)
        #expect(retryReport.bytePreservationStatus == shape.retryPreservation.status)
        #expect(retryReport.bytePreservationStatus != shape.failedPreservation.status)
        #expect(retryReport.bytePreservationStatus != shape.controlPreservation.status)
        // Its own evidence, produced by its own run rather than carried over.
        #expect(retryReport != controlReport)
        #expect(retryReport.provenance.isAvailable)
        #expect(retryReport.combinedSummary != nil)
        #expect(retryLog.callCount(of: .preprocess) == 1)
        #expect(retryLog.callCount(of: .calibrate) == 1)
        #expect(retryLog.callCount(of: .provenanceAnalyze) == 1)
        #expect(retryLog.callCount(of: .fuse) == 1)
        #expect(retried.cleanup.receipt?.reason == .completed)
    }

    // Nothing of the retry survives it either, so the next selection would be equally clean.
    #expect(await coordinator.activeIdentity() == nil)
    #expect(await coordinator.committedTerminal() == nil)
    #expect(await coordinator.isCancellationRequested() == false)
    #expect(await release.ephemeral.occupiedScopes().isEmpty)
    let afterRetryRequest = await coordinator.requestCancellation(for: retried.identity)
    #expect(afterRetryRequest.commit == .refusedNoActiveSession)
    #expect(afterRetryRequest.latchedRequest == false)
}

/// Writes one accepted ingest's bytes into the release's store and builds the asset.
///
/// A local builder rather than `CoordinatorRelease.acceptedIngest(sessionID:route:byteSeed:)`
/// because that helper fixes the Byte Preservation Status, and this property needs three
/// attempts with three *different* statuses in order to detect one being carried over.
/// Nothing else about it differs: the bytes are really written, so terminal cleanup has
/// something to remove and a receipt's count is meaningful.
private func makeAcceptedIngest(
    release: CoordinatorRelease,
    sessionID raw: String,
    byteSeed: UInt8,
    preservation: PreservationBaseline,
    shape: IsolationShape,
    witness: IsolationWitness
) async -> ImportedEncodedAsset? {
    let sessionID = PortValue.sessionID(raw)
    let receipt: EphemeralWriteReceipt
    do {
        receipt = try await release.ephemeral.writeComplete(
            PortValue.bytes(count: 256, seed: byteSeed),
            in: .session(sessionID)
        )
    } catch {
        Issue.record("the synthetic ingest bytes must be writable: \(error) [\(shape)]")
        witness.recordUnbuildableInput()
        return nil
    }
    await release.deleter.registerLiveSession(sessionID)
    witness.recordPreservation(preservation)
    return PortValue.asset(
        route: .photosPicker,
        receipt: receipt,
        preservationStatus: preservation.status,
        preservationBasis: preservation.basis
    )
}

// MARK: - Holding one attempt open

/// A rendezvous that suspends a chosen port call until the test releases it.
///
/// This is how the window in which two attempts' identities coexist is created by the test
/// rather than raced for: the retry is suspended inside input validation, so the coordinator
/// is genuinely mid-session and the failed attempt's identity can be offered to it.
///
/// Bounded, and it records having run out. A wiring mistake then fails an assertion instead
/// of hanging the suite or passing quietly.
private actor AttemptGate {
    private var wasReached = false
    private var isOpen = false
    private var exhaustedSpins = false

    /// Called from inside the port. Suspends until ``openGate()``.
    func hold() async {
        wasReached = true
        var spins = 0
        while !isOpen, spins < 200_000 {
            spins += 1
            await Task.yield()
        }
        if !isOpen { exhaustedSpins = true }
    }

    /// Suspends until the gated call has been entered.
    func waitUntilReached() async {
        var spins = 0
        while !wasReached, spins < 200_000 {
            spins += 1
            await Task.yield()
        }
        if !wasReached { exhaustedSpins = true }
    }

    /// Lets the suspended call finish.
    func openGate() { isOpen = true }

    /// Whether either bounded wait ran out, which is a wiring mistake rather than a finding.
    func timedOut() -> Bool { exhaustedSpins }
}

/// An ``InputValidating`` double that suspends on one chosen call.
///
/// `StubInputValidator` already does everything else, but it cannot be held open, and the
/// harness's gate is on the inference boundary — which the failing attempts here never
/// reach. Validation is the one stage every attempt reaches, so gating the *n*th validation
/// call selects an attempt regardless of where that attempt fails.
private final class SequencedInputValidator: InputValidating, Sendable {
    private let outcome: StubOutcome<ValidatedImage>
    private let recorder: PortCallRecorder
    private let gate: AttemptGate?
    private let gateCallNumber: Int
    private let callCount = LockedCounter()

    init(
        outcome: StubOutcome<ValidatedImage>,
        recorder: PortCallRecorder,
        gate: AttemptGate? = nil,
        gateCallNumber: Int = 0
    ) {
        self.outcome = outcome
        self.recorder = recorder
        self.gate = gate
        self.gateCallNumber = gateCallNumber
    }

    func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage {
        // Recorded before the hold, so the shared log reflects the call having started even
        // while it is suspended.
        recorder.record(.validate(asset.sessionID))
        if callCount.next() == gateCallNumber, let gate {
            await gate.hold()
        }
        return try outcome.resolve()
    }
}

/// A monotonic counter behind a lock.
///
/// A local type because `DefAIkeTestSupport`'s equivalent box is internal to that module.
/// `NSLock` rather than `Synchronization.Mutex`, matching the package's macOS 14 and
/// iOS 17 minimums.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increments and returns the new value.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the coordinator actually did.
///
/// Kept outside the property body on purpose. `propertyCheck` runs its body under `try?`, so
/// an error thrown from the body — or from anything the body calls — is swallowed and the run
/// reports success with every assertion skipped. An issue recorded here, after
/// `propertyCheck` returns, is not suppressed.
///
/// `completedBodies == cases` cannot detect that on its own: if the body throws on the first
/// case it passes vacuously as `0 == 0`. So the case count is additionally pinned against the
/// count that was *requested*, and every piece of counted work is compared against `cases`
/// rather than against an absolute floor — one release, three ended sessions, one control
/// report, one failed terminal, one retry terminal, and one in-flight stale probe per case.
///
/// The produced sets are the substantive half. Every applicable failure shape, both retry
/// terminals, both identifier modes, all three Byte Preservation Statuses in each of the
/// three attempt positions, and all four preservation bases are required to have been
/// *observed in a committed terminal or a written asset* rather than merely offered. The two
/// products — failure shape crossed with retry terminal, and failure shape crossed with
/// identifier mode — are twelve cells each, which 240 uniform draws fill about twenty deep.
private final class IsolationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Counted work.
    private var cases = 0
    private var completedBodies = 0
    private var releases = 0
    private var endedSessions = 0
    private var controlReports = 0
    private var failureTerminals = 0
    private var retryTerminals = 0
    private var staleProbes = 0
    private var unbuildableInputs = 0

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var generatedFailures: Set<ApplicableFailure> = []
    private var generatedRetryTerminals: Set<Bool> = []
    private var generatedIdentifierModes: Set<Bool> = []
    private var generatedFailureByRetryTerminal: Set<String> = []
    private var generatedFailureByIdentifierMode: Set<String> = []
    private var writtenPreservations: Set<PreservationBaseline> = []
    private var controlStatuses: Set<BytePreservationStatus> = []
    private var failedStatuses: Set<BytePreservationStatus> = []
    private var retryStatuses: Set<BytePreservationStatus> = []

    // Produced outputs.
    private var producedFailures: Set<ApplicableFailure> = []
    private var producedFailureCategories: Set<AnalysisError> = []
    private var producedFailureStages: Set<AnalysisStage> = []
    private var producedRetryTerminalKinds: Set<String> = []
    private var producedPreservedFailureStatuses: Set<BytePreservationStatus> = []
    private var producedQualityPreservation: Set<Bool> = []

    /// Every applicable shape crossed with the retry's terminal kind.
    static let requiredFailureByRetryTerminal: Set<String> = {
        var keys: Set<String> = []
        for failure in ApplicableFailure.all {
            keys.insert("\(failure)/retryFails")
            keys.insert("\(failure)/retryCompletes")
        }
        return keys
    }()

    /// Every applicable shape crossed with the identifier mode.
    static let requiredFailureByIdentifierMode: Set<String> = {
        var keys: Set<String> = []
        for failure in ApplicableFailure.all {
            keys.insert("\(failure)/sameIdentifier")
            keys.insert("\(failure)/newIdentifier")
        }
        return keys
    }()

    func record(_ shape: IsolationShape) {
        lock.withLock {
            cases += 1
            seeds.insert(shape.seed)
            generatedFailures.insert(shape.failure)
            generatedRetryTerminals.insert(shape.retryFails)
            generatedIdentifierModes.insert(shape.retryUnderSameIdentifier)
            generatedFailureByRetryTerminal.insert(
                "\(shape.failure)/\(shape.retryFails ? "retryFails" : "retryCompletes")"
            )
            generatedFailureByIdentifierMode.insert(
                "\(shape.failure)/"
                    + (shape.retryUnderSameIdentifier ? "sameIdentifier" : "newIdentifier")
            )
            controlStatuses.insert(shape.controlPreservation.status)
            failedStatuses.insert(shape.failedPreservation.status)
            retryStatuses.insert(shape.retryPreservation.status)
        }
    }

    func recordRelease() {
        lock.withLock { releases += 1 }
    }

    func recordEndedSession() {
        lock.withLock { endedSessions += 1 }
    }

    func recordControlReport() {
        lock.withLock { controlReports += 1 }
    }

    func recordPreservation(_ baseline: PreservationBaseline) {
        lock.withLock { _ = writtenPreservations.insert(baseline) }
    }

    /// Records one committed failed terminal, from the snapshot itself.
    func recordFailureTerminal(shape: IsolationShape, snapshot: AnalysisFailureSnapshot) {
        lock.withLock {
            failureTerminals += 1
            producedFailures.insert(
                ApplicableFailure(error: snapshot.error, stage: snapshot.stage)
            )
            producedFailureCategories.insert(snapshot.error)
            producedFailureStages.insert(snapshot.stage)
            producedPreservedFailureStatuses.insert(snapshot.bytePreservationStatus ?? .unknown)
            // Both halves of Requirement 3.14's preservation must be observed: a failure that
            // had dimensions recorded before it, and one that had none.
            producedQualityPreservation.insert(snapshot.inputQuality != nil)
            _ = shape
        }
    }

    /// Records one committed retry terminal.
    func recordRetryTerminal(shape: IsolationShape, session: CompletedAnalysisSession) {
        lock.withLock {
            retryTerminals += 1
            if session.outcome.isCompleted {
                producedRetryTerminalKinds.insert("completed")
            } else if let error = session.error {
                producedRetryTerminalKinds.insert("failed/\(error.rawValue)")
            } else {
                producedRetryTerminalKinds.insert("other/\(session.outcome)")
            }
            _ = shape
        }
    }

    /// Records that the in-flight probe of the failed attempt's identity ran.
    func recordStaleProbe() {
        lock.withLock { staleProbes += 1 }
    }

    /// Records that something this file described could not be built or did not end.
    ///
    /// Never a finding about the coordinator: every input is built from generated integers
    /// inside validated ranges, so a refusal is a defect in this file. Counted so a run whose
    /// inputs quietly stopped being buildable fails outside the body rather than shrinking
    /// its own coverage.
    func recordUnbuildableInput() {
        lock.withLock { unbuildableInputs += 1 }
    }

    /// Called as the very last statement of the body, so a case that stopped early is
    /// countable.
    func recordCompletedBody() {
        lock.withLock { completedBodies += 1 }
    }

    func expectMeasuredRun(requestedCases: Int) {
        lock.lock()
        defer { lock.unlock() }

        // The run happened, and it happened the requested number of times. Paired with the
        // per-case counts below, this is what a body that threw before its first assertion
        // cannot satisfy.
        #expect(cases == requestedCases, "requested \(requestedCases) cases, ran \(cases)")
        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built or did not end"
        )

        // Counted work, per case rather than against an absolute floor.
        #expect(releases == cases, "releases built: \(releases) for \(cases) cases")
        #expect(
            endedSessions == cases * 3,
            "sessions ended: \(endedSessions), expected \(cases * 3)"
        )
        #expect(
            controlReports == cases,
            "positive controls that produced an Evidence Report: \(controlReports) of \(cases)"
        )
        #expect(
            failureTerminals == cases,
            "failed terminals committed: \(failureTerminals) of \(cases)"
        )
        #expect(retryTerminals == cases, "retry terminals committed: \(retryTerminals) of \(cases)")
        #expect(
            staleProbes == cases,
            "in-flight stale-identity probes performed: \(staleProbes) of \(cases)"
        )

        // The generated baseline actually varied.
        let allShapes = Set(ApplicableFailure.all)
        let allStatuses = Set(PreservationBaseline.statuses)
        let ungeneratedShapes = allShapes.subtracting(generatedFailures)
            .map(\.description).sorted()
        let ungeneratedRetryCells = Self.requiredFailureByRetryTerminal
            .subtracting(generatedFailureByRetryTerminal).sorted()
        let ungeneratedIdentifierCells = Self.requiredFailureByIdentifierMode
            .subtracting(generatedFailureByIdentifierMode).sorted()
        let unwrittenBases = Set(PreservationBasis.allCases)
            .subtracting(writtenPreservations.map(\.basis)).map(\.rawValue).sorted()

        #expect(seeds.count >= 50, "distinct generated seeds: \(seeds.count)")
        #expect(
            generatedFailures == allShapes,
            "applicable failure shapes never generated: \(ungeneratedShapes)"
        )
        #expect(generatedRetryTerminals == [false, true], "only one retry terminal was generated")
        #expect(
            generatedIdentifierModes == [false, true],
            "only one identifier mode was generated, so the same-identifier retry was untested"
        )
        #expect(
            ungeneratedRetryCells.isEmpty,
            "failure/retry-terminal cells never generated: \(ungeneratedRetryCells)"
        )
        #expect(
            ungeneratedIdentifierCells.isEmpty,
            "failure/identifier-mode cells never generated: \(ungeneratedIdentifierCells)"
        )
        // All three statuses in each position, so "the retry did not inherit the failed
        // attempt's status" was asserted with every pairing rather than one.
        #expect(
            controlStatuses == allStatuses,
            "control statuses: \(controlStatuses.map(\.rawValue).sorted())"
        )
        #expect(
            failedStatuses == allStatuses,
            "failed statuses: \(failedStatuses.map(\.rawValue).sorted())"
        )
        #expect(
            retryStatuses == allStatuses,
            "retry statuses: \(retryStatuses.map(\.rawValue).sorted())"
        )
        #expect(unwrittenBases.isEmpty, "preservation bases never written: \(unwrittenBases)")

        // The substantive half: the outcomes were produced, not merely requested.
        let unproducedShapes = allShapes.subtracting(producedFailures)
            .map(\.description).sorted()
        let unproducedCategories = ApplicableFailure.presentableCategories
            .subtracting(producedFailureCategories).map(\.rawValue).sorted()
        #expect(
            producedFailures == allShapes,
            "applicable failure shapes never produced in a committed terminal: \(unproducedShapes)"
        )
        #expect(
            producedFailureCategories == ApplicableFailure.presentableCategories,
            "presentable categories never produced: \(unproducedCategories)"
        )
        #expect(
            producedFailureStages == [.mediaClassification, .inputValidation, .preprocessing],
            "failure stages produced: \(producedFailureStages.map(\.rawValue).sorted())"
        )
        #expect(
            producedPreservedFailureStatuses == allStatuses,
            """
            byte statuses preserved through a failure: \
            \(producedPreservedFailureStatuses.map(\.rawValue).sorted())
            """
        )
        #expect(
            producedQualityPreservation == [false, true],
            "only one side of Requirement 3.14's dimension preservation was produced"
        )
        #expect(
            producedRetryTerminalKinds.contains("completed"),
            "no retry ever completed: \(producedRetryTerminalKinds.sorted())"
        )
        #expect(
            producedRetryTerminalKinds.count >= 2,
            "retries only ever reached one kind of terminal: \(producedRetryTerminalKinds.sorted())"
        )
    }
}

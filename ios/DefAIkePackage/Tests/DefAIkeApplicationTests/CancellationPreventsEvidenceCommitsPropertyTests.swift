import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication

// Design Property 35: cancellation prevents all evidence commits.
//
// The design states it as: for any active analysis stage, task schedule, and cancellation
// point, accepting cancellation makes `cancelled` the only possible session terminal,
// prevents every pending or late pixel/provenance/fusion callback from committing
// evidence, and replaces active progress with the cancelled state.
//
// Four claims, and they fail separately:
//
//   1. **Cancelled is the only terminal.** For a cancellation accepted at any generated
//      point, exactly one terminal is committed and it is `cancelled`. Every later offer —
//      the completed report the pipeline was about to produce, and a failure a branch
//      returns afterwards — is refused by the slot with the standing outcome reported
//      unchanged (Requirements 11.14 and 15.6).
//   2. **Every pending or late lane or fusion callback is ignored.** A pixel lane result, a
//      provenance lane result, and a fusion result are all offered *after* the
//      cancellation. Each is discarded by session and generation, carries no value, and
//      never becomes evidence (Requirement 15.6).
//   3. **No partial evidence survives**, even where a framework call cannot be preempted.
//      Measured against the shared call log rather than against the absent result:
//      `calibrate` is the only way Pixel Evidence exists, `provenanceAnalyze` the only way
//      a provenance result exists, and `fuse` the only way a Combined Summary exists, so
//      three counted zeros over the log's suffix after the request are the direct form of
//      Requirement 15.7.
//   4. **Evidence commits are disabled from the instant of the request**, not when the
//      current stage returns. The terminal slot is read *while* the pipeline is still
//      suspended mid-flight and must already be occupied.
//
// ## The cancellation points
//
// A property about cancellation is worthless if it cancels at one convenient instant, so
// the point is generated across the whole pipeline: before the session starts, at the
// input-validation, preprocessing, and model-load boundaries, mid-pixel-branch inside
// inference, mid-provenance-branch inside the validator, after both lane values exist but
// before the join, inside a bounded sampling loop, and after a terminal already stands —
// where the request must be refused and change nothing. ``CancellationPoint`` enumerates
// them and ``CancellationPoint/expectedEvidenceCallsBeforeTheRequest`` says, for each,
// exactly which evidence-producing port calls must already have happened when the request
// lands. That list is checked, so a point that degenerated into "cancelled before anything
// ran" fails the reached-ledger instead of satisfying the property for free.
//
// ## Nothing is raced
//
// Every ordering here is established by a gated rendezvous, never by hoping a cancellation
// wins a race. One ``StageRendezvous`` holds exactly one armed stage; each port double
// records its call and then reaches the rendezvous, suspending only when it is the armed
// one. So `analyze` is itself suspended at the generated point, the request is delivered as
// a synchronous actor step, and the pipeline resumes only after the last callback. A "late"
// callback is late *by construction*: the port is held, the cancellation is requested, the
// callback is offered, and only then is the port released. At the one point with no running
// attempt — before the session starts — there is nothing to hold, so the schedule is
// delivered after the session has already ended, which is later still.
//
// A pending callback is distinguished from a purely late one by *when its value came into
// existence*: a pending value is constructed before the request is delivered, while the
// session is still admitting results, and offered afterwards. Both must be refused, and the
// witness requires both to have been observed.
//
// The rendezvous and the loop gate spin a bounded number of yields and **record having run
// out**, so a wiring mistake fails an assertion rather than hanging the suite or passing
// quietly. Nothing in this file sleeps or polls unboundedly.
//
// ## Every absence is measured beside a presence
//
// On **every** case, before the subject session runs, the *same* coordinator, harness,
// ports, release, and call log run one clean session that provably completes with an
// Evidence Report, an available provenance lane, and a Combined Summary, calling
// `calibrate`, `provenanceAnalyze`, and `fuse` exactly once each. So every measured zero
// sits beside a measured one taken through identical wiring. The release binds provenance
// **and** fusion for exactly this reason: in a pixel-only composition "no provenance result
// and no Combined Summary" would hold trivially. The control runs first so its real
// Evidence Report and real Combined Summary are the values the late callbacks offer — the
// completed report the pipeline was about to produce is a report this release actually
// produced, not a synthetic stand-in.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: the release
// build, the ingests, and every fallible construction become an `Issue.record` and a
// counted unbuildable input, and the assertions run over recordings. The witness counts the
// cases, the reached points, the delivered callbacks, the refused offers, the discarded
// admissions, and the control reports *outside* the body, where an issue is not suppressed.
// `completedBodies == cases` is paired with a case floor and with `cases == requestedCount`,
// because it passes vacuously as `0 == 0` when the body throws on the first case.
//
// The read-out travels as the message on the first witness expectation, so a failing run
// prints the whole measured shape of the run beside the failure. Shrinking is enabled by
// default on this toolchain, so a failing run re-executes the body while it narrows the
// input and the counters below are inflated for that run; on a passing run no shrinking
// happens and every count is exactly one per case.
//
// ## What this file does not assert, and what it does not decide
//
//   * **No value here is an approved release input.** The release is `CoordinatorRelease`,
//     whose every artifact is synthetic; the offered failure snapshots draw from the
//     requirements' own closed category and stage vocabularies; and the session
//     identifiers, byte seeds, and offered provenance lanes are synthetic. No budget,
//     deadline, boundary, tolerance, or approved value is fabricated, and no fixture
//     artifact is invented.
//   * **Cancellation is not an Analysis Error.** ``AnalysisFault/cancelled`` carries no
//     category and no stage and ``SessionTerminalOutcome/cancelled`` has no payload
//     (Requirement 11.17). Asserted, never given one.
//   * **The cancel control is the only generated mechanism.** External task cancellation
//     reaches the coordinator through ``AnalysisCoordinator/continuesAfterBoundary(_:)``,
//     which commits `cancelled` at the *next boundary* rather than at the instant of the
//     request — so claim 4 above is deliberately not true of it, and folding it in would
//     mean weakening claim 4 for every point. `SessionCancellationTests` pins that path at
//     the example level (`aCancelledTaskNeverCompletes`, `anAlreadyCancelledTaskRunsNoStage`).
//     The one exception is the before-start point, where cancelling the enclosing task is
//     the only mechanism available: no session exists yet for a control to name.
//   * **Property 30 owns disjointness and singularity over arbitrary event schedules.** It
//     says in its own header that it claims nothing about cancellation points, hooks, or
//     preemption. This file does not restate its arms: it does not arbitrate faults, does
//     not compare terminals pairwise across the whole vocabulary, and does not check that
//     an error category cannot decode as evidence.
//   * **Property 25 owns cleanup completeness**, **Property 29 the resource-limit rule**,
//     **Property 34 progress derivation**, **Property 36 synthesized timeouts**, and **task
//     10.13** the cancellation-point integration matrix. The cleanup assertion here is
//     narrow on purpose: a cancelled session's receipt names the cancelled reason and the
//     store is left empty, which is what "no partial evidence survives" needs.
//   * `SessionCancellationTests` (task 10.5) pins all of this at 28 examples. This file
//     quantifies it over generated cancellation points, generated callback schedules, and
//     generated prior-terminal categories and stages, and adds no example.

extension Tag {
    /// Design Property 35.
    ///
    /// Declared here rather than in a shared namespace: each design property owns one file,
    /// and a shared tag namespace would be a merge point between independently written
    /// property files.
    @Tag static var property35CancellationPreventsEvidenceCommits: Self
}

@Suite(
    "Property 35: Cancellation prevents all evidence commits",
    .tags(.property35CancellationPreventsEvidenceCommits)
)
struct CancellationPreventsEvidenceCommitsPropertyTests {

    /// The number of generated cases requested.
    ///
    /// Three hundred rather than the library default of 100 because the coverage the
    /// witness requires is a product over nine cancellation points, two task-ownership
    /// choices, six callback kinds, and ten prior-terminal categories and stages — and the
    /// prior-terminal fields only vary on the one point in nine that uses them, so a
    /// hundred draws would leave that cell at roughly eleven samples. Raising the count is
    /// the only honest way to reach the coverage; no assertion is relaxed to fit a smaller
    /// run.
    static let generatedCaseCount = 300

    /// **Validates: Requirements 11.14, 15.6, 15.7**
    @Test("Cancelling at any point commits only cancelled and ignores every late callback")
    func cancellationPreventsEveryEvidenceCommit() async {
        let witness = CancellationWitness()

        await propertyCheck(
            count: Self.generatedCaseCount,
            input: CancellationCaseShape.generator
        ) { shape in
            witness.record(shape)
            guard let run = await CancellationRun.execute(shape: shape, witness: witness)
            else { return }

            run.checkTheSelectorArithmeticIsUniform()
            run.checkTheGeneratedPointWasActuallyReached()
            run.checkEvidenceCommitsWereDisabledAtTheInstantOfTheRequest()
            run.checkTheAcceptedTerminalIsTheOnlyOne()
            run.checkEveryPendingOrLateCallbackWasIgnored()
            run.checkNoEvidenceWorkRanAfterTheRequest()
            run.checkNoPartialEvidenceSurvived()
            run.checkCancellationCarriesNoAnalysisErrorCategory()
            run.checkTheBoundedLoopStoppedAtItsNextMetricBoundary()
            run.checkARequestAfterAStandingTerminalChangedNothing()
            run.checkThePositiveControlProducedEvidence()

            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }
}

// MARK: - The generated cancellation points

/// Where in the pipeline the cancellation lands.
///
/// Nine points across the whole session rather than one convenient instant. Each names the
/// rendezvous stage that holds the pipeline open there, and each states exactly which
/// evidence-producing port calls must already have happened when the request is delivered —
/// which is how a point that degenerated into "nothing had run yet" is caught.
private enum CancellationPoint: String, Sendable, CaseIterable {
    /// The enclosing task is cancelled before `analyze` runs at all.
    case beforeSessionStart

    /// The request lands while the input validator is suspended.
    case atInputValidationBoundary

    /// The request lands while the preprocessor is suspended.
    case atPreprocessingBoundary

    /// The request lands while the model loader is suspended.
    case atModelLoadBoundary

    /// The request lands while inference is suspended — a framework call that has already
    /// entered and cannot be forcibly preempted.
    case midPixelBranchInsideInference

    /// The request lands while the provenance validator is suspended, with the pixel lane
    /// already resolved.
    case midProvenanceBranchInsideTheValidator

    /// The request lands after both lane values exist and before the join runs.
    case afterBothLaneValuesExistBeforeTheJoin

    /// The request fires a registered framework hook that cancels an in-flight bounded
    /// metric-sampling loop.
    case insideABoundedSamplingLoop

    /// The request arrives after a terminal already stands, and must change nothing.
    case afterATerminalAlreadyStands

    /// The rendezvous stage that holds the pipeline open at this point.
    var armedStage: GatedStage {
        switch self {
        case .beforeSessionStart: .sessionEntry
        case .atInputValidationBoundary: .validate
        case .atPreprocessingBoundary: .preprocess
        case .atModelLoadBoundary: .loadModel
        case .midPixelBranchInsideInference: .infer
        case .midProvenanceBranchInsideTheValidator: .provenanceEnter
        case .afterBothLaneValuesExistBeforeTheJoin: .provenanceReturn
        case .insideABoundedSamplingLoop: .infer
        case .afterATerminalAlreadyStands: .infer
        }
    }

    /// The evidence-producing calls that must already have happened when the request lands.
    ///
    /// Under the serial branch-execution policy the order is fixed: validate, preprocess,
    /// load model, infer, calibrate, provenance analyze, fuse. Each double records its call
    /// before reaching the rendezvous, so the armed stage's own call is included.
    ///
    /// `fuse` never appears: the join runs after every generated point, so a Combined
    /// Summary is never resolved for a cancelled session at any of them.
    var expectedEvidenceCallsBeforeTheRequest: [PortCallKind] {
        switch self {
        case .beforeSessionStart:
            []
        case .atInputValidationBoundary:
            [.validate]
        case .atPreprocessingBoundary:
            [.validate, .preprocess]
        case .atModelLoadBoundary:
            [.validate, .preprocess, .loadModel]
        case .midPixelBranchInsideInference,
             .insideABoundedSamplingLoop,
             .afterATerminalAlreadyStands:
            [.validate, .preprocess, .loadModel, .infer]
        case .midProvenanceBranchInsideTheValidator,
             .afterBothLaneValuesExistBeforeTheJoin:
            [.validate, .preprocess, .loadModel, .infer, .calibrate, .provenanceAnalyze]
        }
    }

    /// Whether a session exists to name when the cancellation is delivered.
    ///
    /// False only before the session starts, where the sole available mechanism is
    /// cancelling the enclosing task: there is no running attempt for the visible control
    /// to name.
    var hasARunningAttemptAtTheRequest: Bool { self != .beforeSessionStart }

    /// Whether a terminal already stands before the cancellation is delivered.
    var aTerminalAlreadyStands: Bool { self == .afterATerminalAlreadyStands }

    /// Whether the coordinator may own the structured task at this point.
    ///
    /// False before the session starts: the pre-entry rendezvous has to be inside a task
    /// this file created, because a task the coordinator created may already have entered
    /// `analyze` before the handle is returned, and racing that would be exactly the
    /// timing dependence this file refuses.
    var permitsCoordinatorOwnedTask: Bool { self != .beforeSessionStart }
}

/// One kind of callback delivered after the cancellation.
private enum LateCallbackKind: String, Sendable, CaseIterable {
    /// A calibrated pixel label produced by work already in flight.
    case pixelLaneResult

    /// A resolved provenance source lane.
    case provenanceLaneResult

    /// A Combined Summary produced by fusion.
    case fusionResult

    /// The completed Evidence Report the pipeline was about to commit.
    case completedReportOffer

    /// A failure a branch returned after the cancellation.
    case failureOffer

    /// The visible cancel control activated again.
    case repeatedCancellationRequest
}

/// One delivered callback, as plain data.
private struct LateCallback: Hashable, Sendable, CustomStringConvertible {
    let kind: LateCallbackKind

    /// The pixel label this callback carries, for ``LateCallbackKind/pixelLaneResult``.
    let pixel: PixelEvidence

    /// Which synthetic provenance lane this callback carries.
    let laneIndex: Int

    /// Whether the callback's value existed *before* the cancellation was requested.
    ///
    /// The pending/late distinction of Requirement 15.6. A pending callback's value is
    /// constructed before the request and offered after it; a late one comes into existence
    /// only afterwards. Both are delivered after, and neither may become evidence.
    let wasArmedBeforeTheRequest: Bool

    var description: String {
        "\(kind.rawValue)(\(wasArmedBeforeTheRequest ? "pending" : "late"))"
    }
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain data.
///
/// The generator produces integers only. The release, the coordinator, the ingests, and the
/// offered values are built from them inside the run, where a construction that unexpectedly
/// fails is recorded as an issue rather than thrown: `propertyCheck` discards an error
/// thrown by its body, so a refusal that escaped as a throw would report a passing test with
/// every arm skipped.
///
/// ## How the baseline varies
///
///   * the **cancellation point**, over all nine;
///   * whether the **coordinator owns the structured task** the session runs in, which
///     changes what a request reports about stopping it;
///   * the **category** and **stage** of the terminal that already stands at the
///     prior-terminal point, over all ten of each, drawn independently so a category is
///     never implied by its stage;
///   * the **length** of the callback schedule, over two to five callbacks;
///   * each callback's **kind**, over all six, its **pixel label**, its **provenance lane**,
///     and whether it was **pending** before the request or arose after it; and
///   * the synthetic byte seed, so each case's ingest differs.
///
/// One point selector decides the first four fields. Its range is 1800 = 9 x 2 x 10 x 10, a
/// multiple of every modulus it is reduced by, and each field reads a different digit, so the
/// four choices are uniform and independent. One callback selector decides one callback over
/// a range of 540 = 3 x (6 x 3 x 3 x 2), likewise a multiple of every modulus.
private struct CancellationCaseShape: Sendable, CustomStringConvertible {

    /// Selector range for the point, task ownership, and prior terminal.
    static let pointSelectorBound = 1_799

    /// Selector range for one callback.
    static let callbackSelectorBound = 539

    /// Drives the synthetic byte seeds, so a case's ingests differ.
    let seed: Int

    /// Selects the point, the task ownership, and the prior terminal's category and stage.
    let pointSelector: Int

    /// One selector per delivered callback, in delivery order.
    let callbackSelectors: [Int]

    // MARK: Derived

    var point: CancellationPoint {
        CancellationPoint.allCases[pointSelector % CancellationPoint.allCases.count]
    }

    /// Whether the coordinator started the session in a task it owns.
    ///
    /// Forced false where the point cannot support it, and the forcing is recorded rather
    /// than hidden: the witness reports both the generated and the effective value.
    var coordinatorOwnsTask: Bool {
        point.permitsCoordinatorOwnedTask && generatedOwnsTask
    }

    var generatedOwnsTask: Bool { (pointSelector / 9) % 2 == 1 }

    /// **Synthetic.** The category of the terminal that already stands at the
    /// prior-terminal point, drawn from the requirements' own closed ten-category
    /// vocabulary.
    var priorError: AnalysisError {
        AnalysisError.allCases[(pointSelector / 18) % AnalysisError.allCases.count]
    }

    /// **Synthetic.** The stage that terminal was detected at, from the closed ten-stage
    /// vocabulary.
    var priorStage: AnalysisStage {
        AnalysisStage.allCases[(pointSelector / 180) % AnalysisStage.allCases.count]
    }

    var callbacks: [LateCallback] { callbackSelectors.map(Self.callback(from:)) }

    /// A byte seed that is never zero, so the ingest's bytes differ from an empty pattern.
    var controlByteSeed: UInt8 { UInt8(truncatingIfNeeded: seed % 251) | 1 }

    /// A different seed for the subject, so the two sessions are not byte-identical.
    var subjectByteSeed: UInt8 { controlByteSeed ^ 0x5A | 1 }

    static func callback(from selector: Int) -> LateCallback {
        let pixel = PixelEvidence.allCases[(selector / 6) % PixelEvidence.allCases.count]
        return LateCallback(
            kind: LateCallbackKind.allCases[selector % LateCallbackKind.allCases.count],
            pixel: pixel,
            laneIndex: (selector / 18) % 3,
            wasArmedBeforeTheRequest: (selector / 54) % 2 == 1
        )
    }

    var description: String {
        """
        seed \(seed), point \(point.rawValue), coordinator-owned task \(coordinatorOwnsTask), \
        prior \(priorError.rawValue)@\(priorStage.rawValue), \
        callbacks [\(callbacks.map(\.description).joined(separator: " "))]
        """
    }

    static var generator: Generator<CancellationCaseShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...pointSelectorBound),
            Gen.int(in: 0...callbackSelectorBound).array(of: 2...5)
        )
        .map { seed, point, callbacks in
            CancellationCaseShape(
                seed: seed,
                pointSelector: point,
                callbackSelectors: callbacks
            )
        }
        .eraseToAny()
    }
}

// MARK: - The rendezvous that makes every ordering the test's

/// A place in the session a port double can be held open at.
private enum GatedStage: String, Sendable, CaseIterable {
    /// Not a port: the moment before `analyze` is entered at all.
    case sessionEntry
    case validate
    case preprocess
    case loadModel
    case infer

    /// The provenance validator has been entered and has produced nothing yet.
    case provenanceEnter

    /// The provenance validator has produced its state and has not returned it yet, so both
    /// lane values exist and the join has not run.
    case provenanceReturn
}

/// Holds exactly one armed stage open until the test releases it.
///
/// This is how the schedule becomes the test's rather than the scheduler's: with the armed
/// port suspended, `analyze` is itself suspended, so a cancellation request and every
/// callback after it are delivered as synchronous actor steps in the order this file chose.
/// A stage that is not the armed one passes straight through, which is what lets the same
/// wiring run the positive control with nothing armed.
///
/// Bounded, and it **records having run out**: an exhausted wait is a wiring mistake in this
/// file, and ``exhaustedWaitCount()`` is asserted to be zero so the mistake fails an
/// assertion instead of hanging the suite or passing quietly. Nothing here sleeps.
private actor StageRendezvous {
    /// Yields before a wait gives up. Large enough that a correctly wired case never
    /// reaches it, finite so a miswired one cannot spin forever.
    private static let yieldLimit = 200_000

    private var armed: GatedStage?
    private var reached: Set<GatedStage> = []
    private var isReleased = false
    private var exhaustedWaits = 0

    /// Arms `stage`, or arms nothing so every stage passes through.
    ///
    /// The reached set is cleared, which is load-bearing rather than tidy: the positive
    /// control runs first through the same wiring and enters every port, so a set carried
    /// over from it would make ``waitUntilTheArmedStageIsReached()`` return before the
    /// subject session had started — and the cancellation would then land at an instant
    /// nobody chose. A probe confirmed that: without the reset the first case failed with
    /// no running attempt to name.
    func arm(_ stage: GatedStage?) {
        armed = stage
        isReleased = false
        reached = []
    }

    /// Called from inside a port double. Suspends only when this is the armed stage.
    func reach(_ stage: GatedStage) async {
        reached.insert(stage)
        guard armed == stage else { return }
        var yields = 0
        while !isReleased, yields < Self.yieldLimit {
            yields += 1
            await Task.yield()
        }
        if !isReleased { exhaustedWaits += 1 }
    }

    /// Suspends until the armed stage has been entered.
    func waitUntilTheArmedStageIsReached() async {
        guard let armed else { return }
        var yields = 0
        while !reached.contains(armed), yields < Self.yieldLimit {
            yields += 1
            await Task.yield()
        }
        if !reached.contains(armed) { exhaustedWaits += 1 }
    }

    /// Lets the held port finish.
    func release() { isReleased = true }

    func wasReached(_ stage: GatedStage) -> Bool { reached.contains(stage) }

    func reachedStages() -> Set<GatedStage> { reached }

    func exhaustedWaitCount() -> Int { exhaustedWaits }
}

/// Holds the first call open until the test releases it.
///
/// Used for the governor inside a bounded sampling loop, where what has to be true is that
/// the loop is genuinely *mid*-loop when cancellation arrives. Bounded and exhaustion-
/// recording for the same reason ``StageRendezvous`` is.
private actor FirstCallGate {
    private static let yieldLimit = 200_000

    private var wasEntered = false
    private var isReleased = false
    private var exhaustedWaits = 0

    func holdFirstCall() async {
        if wasEntered { return }
        wasEntered = true
        var yields = 0
        while !isReleased, yields < Self.yieldLimit {
            yields += 1
            await Task.yield()
        }
        if !isReleased { exhaustedWaits += 1 }
    }

    func waitUntilEntered() async {
        var yields = 0
        while !wasEntered, yields < Self.yieldLimit {
            yields += 1
            await Task.yield()
        }
        if !wasEntered { exhaustedWaits += 1 }
    }

    func release() { isReleased = true }

    func entered() -> Bool { wasEntered }

    func exhaustedWaitCount() -> Int { exhaustedWaits }
}

// MARK: - Port doubles that can be held at the rendezvous

/// Records the validation call, then reaches the rendezvous.
///
/// Recording happens *before* the rendezvous in every double below, matching
/// `GatedPixelAnalyzer`: a held call has provably been entered, which is what makes the
/// expected call prefix at each cancellation point checkable.
private final class RendezvousInputValidator: InputValidating, Sendable {
    private let value: ValidatedImage
    private let recorder: PortCallRecorder
    private let rendezvous: StageRendezvous

    init(value: ValidatedImage, recorder: PortCallRecorder, rendezvous: StageRendezvous) {
        self.value = value
        self.recorder = recorder
        self.rendezvous = rendezvous
    }

    func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage {
        recorder.record(.validate(asset.sessionID))
        await rendezvous.reach(.validate)
        return value
    }
}

/// Records the preprocessing call, then reaches the rendezvous.
private final class RendezvousImagePreprocessor: ImagePreprocessing, Sendable {
    private let value: ModelImageInput
    private let recorder: PortCallRecorder
    private let rendezvous: StageRendezvous

    init(value: ModelImageInput, recorder: PortCallRecorder, rendezvous: StageRendezvous) {
        self.value = value
        self.recorder = recorder
        self.rendezvous = rendezvous
    }

    func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        recorder.record(.preprocess(image.sessionID))
        await rendezvous.reach(.preprocess)
        return value
    }
}

/// Records the model-load call, then reaches the rendezvous.
private final class RendezvousModelLoader: PixelModelLoading, Sendable {
    private let value: BoundCoreMLModel
    private let recorder: PortCallRecorder
    private let rendezvous: StageRendezvous

    init(value: BoundCoreMLModel, recorder: PortCallRecorder, rendezvous: StageRendezvous) {
        self.value = value
        self.recorder = recorder
        self.rendezvous = rendezvous
    }

    func loadModel(
        from bundle: BoundModelBundle
    ) async throws(AnalysisFault) -> BoundCoreMLModel {
        recorder.record(.loadModel(bundle.bundleID))
        await rendezvous.reach(.loadModel)
        return value
    }
}

/// Records the inference call, then reaches the rendezvous.
///
/// The framework call the design is explicit cannot be forcibly preempted once entered: it
/// returns a logit *after* the cancellation, and nothing downstream of it may run.
private final class RendezvousPixelAnalyzer: PixelAnalyzing, Sendable {
    private let value: RawLogit
    private let recorder: PortCallRecorder
    private let rendezvous: StageRendezvous

    init(value: RawLogit, recorder: PortCallRecorder, rendezvous: StageRendezvous) {
        self.value = value
        self.recorder = recorder
        self.rendezvous = rendezvous
    }

    func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit {
        recorder.record(.infer(input.sessionID))
        await rendezvous.reach(.infer)
        return value
    }
}

/// Records the provenance call and reaches the rendezvous twice.
///
/// Two seams rather than one, because they are different cancellation points. The first is
/// entered before any provenance state exists; the second is entered after the state has
/// been produced and before it is returned, which is the last controllable instant before
/// the join — both lane values exist and nothing has been fused. There is no suspension
/// point between the branch returning and the join under the serial policy, so this is as
/// close to "after both lanes resolve, before the join" as the production seams allow, and
/// the arm says exactly that rather than claiming more.
private final class RendezvousProvenanceAnalyzer: ProvenanceAnalyzing, Sendable {
    private let state: ProvenanceEvidence
    private let recorder: PortCallRecorder
    private let rendezvous: StageRendezvous

    init(state: ProvenanceEvidence, recorder: PortCallRecorder, rendezvous: StageRendezvous) {
        self.state = state
        self.recorder = recorder
        self.rendezvous = rendezvous
    }

    func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence {
        recorder.record(.provenanceAnalyze(asset.sessionID))
        await rendezvous.reach(.provenanceEnter)
        let produced = state
        await rendezvous.reach(.provenanceReturn)
        return produced
    }
}

/// A minimal locked box, so a `Sendable` double can record what it was called with.
///
/// Written here rather than reused because `DefAIkeTestSupport`'s equivalent is internal to
/// that module. Every critical section is a single field assignment with no reentrancy and no
/// suspension point inside it.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

/// Samples the bounded loop's two metrics and reports the fault, or `nil` when both read in
/// budget.
///
/// A named function rather than an inline `do`/`catch` so the port's typed fault is what the
/// catch binds, instead of being widened to `any Error` inside a closure's inferred result
/// type.
private func faultFromBoundedSampling(
    _ controller: ResourceController,
    first: ResourceMetric,
    second: ResourceMetric
) async -> AnalysisFault? {
    do {
        try await controller.checkpoint(first, second, at: .inference)
        return nil
    } catch {
        return error
    }
}

/// A governor whose first observation is held open, so a bounded sampling loop can be caught
/// mid-loop.
///
/// Every reading is within limit: this double is not about breaches, and Property 29 owns
/// that rule. ``reserveCallCount`` exists so the arm can state that the loop reserved
/// nothing, and a reservation would be a wiring mistake in this file rather than a finding.
private final class RendezvousResourceGovernor: ResourceGoverning, Sendable {
    let target: ExecutionTarget

    private let gate: FirstCallGate
    private let observedMetrics = Locked<[ResourceMetric]>([])
    private let reserveCalls = Locked<Int>(0)

    init(target: ExecutionTarget, gate: FirstCallGate) {
        self.target = target
        self.gate = gate
    }

    var observed: [ResourceMetric] { observedMetrics.value }
    var reserveCallCount: Int { reserveCalls.value }

    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ResourceReservation {
        reserveCalls.withValue { $0 += 1 }
        throw .analysis(.resourceLimit, stage: .inference)
    }

    func release(_ reservation: ResourceReservation) async {}

    func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) async -> ResourceObservation {
        observedMetrics.withValue { $0.append(metric) }
        await gate.holdFirstCall()
        return .withinHardLimit(metric)
    }
}

// MARK: - What the coordinator answered

/// The coordinator's own response to one delivered callback.
///
/// A response per callback is what makes the ledger more than a restatement of the
/// schedule: a callback that never reached the actor has no response to record.
private enum CallbackResponse: Sendable {
    /// A calibrated pixel label was offered. `landed` is `nil` when it was discarded.
    case pixelAdmission(FrameworkResultAdmission, landed: PixelEvidence?)

    /// A resolved provenance lane was offered.
    case laneAdmission(FrameworkResultAdmission, landed: ProvenanceLane?)

    /// A Combined Summary was offered.
    case summaryAdmission(FrameworkResultAdmission, landed: CombinedSummary?)

    /// A terminal outcome was offered to the write-once slot.
    case offer(TerminalCommit, offered: SessionTerminalOutcome)

    /// The visible cancel control was activated again.
    case repeatedRequest(CancellationRequestResult)

    /// The admission answer, or `nil` for a callback that offered a terminal instead.
    var admission: FrameworkResultAdmission? {
        switch self {
        case let .pixelAdmission(admission, _): admission
        case let .laneAdmission(admission, _): admission
        case let .summaryAdmission(admission, _): admission
        case .offer, .repeatedRequest: nil
        }
    }

    /// Whether a value reached the caller. `false` for every discarded admission.
    var carriedAValue: Bool {
        switch self {
        case let .pixelAdmission(_, landed): landed != nil
        case let .laneAdmission(_, landed): landed != nil
        case let .summaryAdmission(_, landed): landed != nil
        case .offer, .repeatedRequest: false
        }
    }

    /// The slot's answer, or `nil` for a callback that offered no terminal.
    var terminalCommit: TerminalCommit? {
        switch self {
        case let .offer(commit, _): commit
        case let .repeatedRequest(result): result.commit
        case .pixelAdmission, .laneAdmission, .summaryAdmission: nil
        }
    }
}

/// One delivered callback, its response, and what stood afterwards.
private struct DeliveredCallback: Sendable {
    let index: Int
    let callback: LateCallback
    let response: CallbackResponse

    /// ``AnalysisCoordinator/committedTerminal()`` read immediately after delivery.
    let standingAfter: SessionTerminalOutcome?
}

/// Bounded waits that gave up, across every rendezvous one case used.
///
/// Summed rather than checked per gate so one arm can state the whole claim: a case in which
/// any wait ran out was not deterministic, whichever gate it was.
private func totalExhaustedWaits(
    rendezvous: StageRendezvous,
    loopGate: FirstCallGate?
) async -> Int {
    var total = await rendezvous.exhaustedWaitCount()
    if let loopGate {
        total += await loopGate.exhaustedWaitCount()
    }
    return total
}

/// What the bounded sampling loop did, when the case generated that point.
private struct BoundedLoopObservation: Sendable {
    /// Whether the loop was suspended inside its first observation when the hook fired.
    let wasEnteredMidLoop: Bool

    /// The fault the loop reported.
    let fault: AnalysisFault?

    /// Metrics the governor actually sampled, in order.
    let observedMetrics: [ResourceMetric]

    /// The metrics the loop was asked to sample.
    let requestedMetrics: [ResourceMetric]

    /// Reservations the loop asked for. Zero: sampling reserves nothing.
    let reserveCallCount: Int

    /// The controller's latched breach afterwards. Cancellation latches none.
    let latchedBreach: ResourceBreach?

    /// Whether the controller still permits an evidence commit, which cancellation must not
    /// change: only a latched breach may withdraw that permission.
    let permitsEvidenceCommit: Bool

    /// Hooks the request invoked.
    let invokedHookCount: Int
}

// MARK: - The reference model over one case

/// What the generated point and schedule predict, computed from the shape alone.
///
/// Built before any assertion runs and never from an observation, so a disagreement between
/// the coordinator and this model fails an arm rather than being absorbed into it.
private struct CancellationExpectation: Sendable {
    /// The outcome that must stand from the instant the cancellation is accepted.
    let standingOutcome: SessionTerminalOutcome

    /// The outcome the session must end with.
    let finalOutcome: SessionTerminalOutcome

    /// The admission answer every late callback carrying a value must receive.
    let admission: FrameworkResultAdmission

    /// The slot's answer to every late terminal offer.
    let refusal: TerminalCommit

    /// Whether the cancellation request latched anything.
    ///
    /// True at every point with a running attempt, including the prior-terminal point: the
    /// request *is* recorded there, it simply stops nothing because the session was already
    /// ending through its own path.
    let requestLatches: Bool

    /// Whether the request's commit took the slot.
    let requestCommits: Bool

    /// The evidence-producing calls that must precede the request.
    let evidenceCallsBeforeTheRequest: [PortCallKind]

    static func model(
        shape: CancellationCaseShape,
        priorTerminal: SessionTerminalOutcome?
    ) -> CancellationExpectation {
        let point = shape.point
        let standing: SessionTerminalOutcome = priorTerminal ?? .cancelled
        let admission: FrameworkResultAdmission
        let refusal: TerminalCommit
        if point.hasARunningAttemptAtTheRequest {
            admission = .discardedTerminalCommitted(standing)
            refusal = .refusedAlreadyTerminal(standing)
        } else {
            // The session ended before the callbacks could be delivered, so there is no
            // attempt for them to belong to at all.
            admission = .discardedNoActiveSession
            refusal = .refusedNoActiveSession
        }
        return CancellationExpectation(
            standingOutcome: standing,
            finalOutcome: standing,
            admission: admission,
            refusal: refusal,
            requestLatches: point.hasARunningAttemptAtTheRequest,
            requestCommits: point.hasARunningAttemptAtTheRequest
                && !point.aTerminalAlreadyStands,
            evidenceCallsBeforeTheRequest: point.expectedEvidenceCallsBeforeTheRequest
        )
    }
}

// MARK: - One executed case

/// One generated cancellation point and callback schedule, delivered to a live session, plus
/// its positive control.
///
/// Every field is a recording. The assertions below read only recordings, so no arm can
/// depend on the order the actor happened to run in.
private struct CancellationRun {
    let shape: CancellationCaseShape
    let point: CancellationPoint
    let expectation: CancellationExpectation

    /// The subject attempt, or `nil` before the session started.
    let identity: AnalysisSessionIdentity?

    /// The identity the callbacks named. The ended session's identity before the start
    /// point, where no running attempt exists at the request.
    let callbackTarget: AnalysisSessionIdentity

    /// The evidence-producing calls recorded when the request was delivered.
    let evidenceCallsBeforeTheRequest: [PortCallKind]

    /// Whether the armed rendezvous stage was actually entered.
    let armedStageWasReached: Bool

    /// Stages the rendezvous saw entered at all.
    let reachedStages: Set<GatedStage>

    /// Waits that gave up. Zero, or this file is miswired.
    let exhaustedWaits: Int

    /// The outcome standing immediately *before* the cancellation was delivered.
    let standingBeforeTheRequest: SessionTerminalOutcome?

    /// The outcome standing immediately *after* it, still mid-flight.
    let standingWhileStillSuspended: SessionTerminalOutcome?

    /// What the cancellation request did, or `nil` before the session started.
    let requestResult: CancellationRequestResult?

    /// The terminal committed before the request, at the prior-terminal point.
    let priorCommit: TerminalCommit?

    /// The delivered callbacks, in order.
    let ledger: [DeliveredCallback]

    /// Callback values that existed before the request was delivered.
    let pendingCallbackIndices: [Int]

    /// The bounded sampling loop, when the case generated that point.
    let boundedLoop: BoundedLoopObservation?

    /// The subject session, after the pipeline resumed and ended.
    let subject: CompletedAnalysisSession

    /// The subject session's own call log, in order.
    let subjectCallKinds: [PortCallKind]

    /// The subject's evidence-producing calls recorded at or after the request.
    let evidenceCallsAfterTheRequest: [PortCallKind]

    /// Whether the subject's material was gone from the store afterwards.
    let ephemeralStoreWasEmpty: Bool

    /// The positive control: one clean session through the identical wiring.
    let control: CompletedAnalysisSession

    /// The control's own call log, taken before the subject's log began.
    let controlCallKinds: [PortCallKind]

    /// The three port calls whose absence is what "no evidence" means here.
    ///
    /// `calibrate` is the only way Pixel Evidence exists, `provenanceAnalyze` the only way a
    /// provenance result exists, and `fuse` the only way a Combined Summary exists.
    static let evidenceProducingKinds: [PortCallKind] = [
        .calibrate, .provenanceAnalyze, .fuse,
    ]

    /// The metrics the bounded sampling loop is asked to sample.
    ///
    /// Two, so the loop has a second boundary to stop at. Both are defined in the release's
    /// own main-application budget; no limit is invented here.
    static let boundedLoopMetrics: [ResourceMetric] = [.decodedPixelCount, .temporaryStorage]

    // MARK: Execution

    static func execute(
        shape: CancellationCaseShape,
        witness: CancellationWitness
    ) async -> CancellationRun? {
        let release: CoordinatorRelease
        do {
            // Provenance and fusion are bound so the control provably produces a provenance
            // result and a Combined Summary. Without them, "the cancelled session has
            // neither" would hold in a composition that never produces either.
            release = try await CoordinatorRelease.build(provenance: true, fusion: true)
        } catch {
            Issue.record("the synthetic release must pass its own startup gate: \(error)")
            witness.recordUnbuildableInput()
            return nil
        }

        let rendezvous = StageRendezvous()
        let recorder = release.recorder
        let sessionID = PortValue.sessionID("session-0001")
        let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
        let provider = ProvenanceLaneProvider.resolve(
            analyzer: RendezvousProvenanceAnalyzer(
                state: .absent,
                recorder: recorder,
                rendezvous: rendezvous
            ),
            policy: release.admission.configuration.provenancePolicy,
            manifest: release.admission.configuration.capabilityManifest
        )
        guard provider.isEnabled else {
            Issue.record("the provenance lane must be enabled for the control [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        let coordinator = AnalysisCoordinator(
            binder: release.binder(),
            validator: RendezvousInputValidator(
                value: PortValue.validatedImage(
                    sessionID: sessionID,
                    preprocessingContractID: contractID
                ),
                recorder: recorder,
                rendezvous: rendezvous
            ),
            preprocessor: RendezvousImagePreprocessor(
                value: PortValue.modelInput(
                    sessionID: sessionID,
                    preprocessingContractID: contractID
                ),
                recorder: recorder,
                rendezvous: rendezvous
            ),
            modelLoader: RendezvousModelLoader(
                value: CoordinatorSample.loadedModel(bundle: release.bundle),
                recorder: recorder,
                rendezvous: rendezvous
            ),
            analyzer: RendezvousPixelAnalyzer(
                value: PortValue.logit(1.5),
                recorder: recorder,
                rendezvous: rendezvous
            ),
            calibrator: StubPixelCalibrator(
                outcome: StubOutcome(always: .signalsConsistentWithAIGeneration),
                recorder: recorder
            ),
            provenance: provider,
            fuser: StubEvidenceFuser(recorder: recorder),
            inconsistencyClassifier: nil,
            cleanup: SessionTerminalCleanup(
                deleter: release.deleter,
                policy: release.lifecyclePolicy
            ),
            branchExecution: .serial(
                validationPlan: CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
            )
        )

        // 1. The positive control, first, with nothing armed so it runs the whole pipeline.
        //    Its real Evidence Report and real Combined Summary are the values the late
        //    callbacks below offer, so "the completed report the pipeline was about to
        //    commit" is a report this release actually produced.
        await rendezvous.arm(nil)
        let controlAsset: ImportedEncodedAsset
        do {
            controlAsset = try await release.acceptedIngest(byteSeed: shape.controlByteSeed)
        } catch {
            Issue.record("the control ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        guard let control = await coordinator.analyze(controlAsset).completed,
              let controlReport = control.evidenceReport,
              let controlSummary = controlReport.combinedSummary
        else {
            Issue.record(
                "the positive control must complete with a report and a summary [\(shape)]"
            )
            witness.recordUnbuildableInput()
            return nil
        }
        let controlCallKinds = recorder.callKinds
        recorder.reset()

        // 2. The subject session, held open at the generated cancellation point.
        let point = shape.point
        await rendezvous.arm(point.armedStage)
        let asset: ImportedEncodedAsset
        do {
            asset = try await release.acceptedIngest(byteSeed: shape.subjectByteSeed)
        } catch {
            Issue.record("the subject ingest must be writable: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        let handle: Task<AnalysisSessionOutcome, Never>
        if point == .beforeSessionStart {
            // The rendezvous makes the ordering the test's: the task is cancelled while it
            // waits at the pre-entry seam, so `analyze` is entered already cancelled rather
            // than racing a cancel against the first stage.
            let started = Task { () -> AnalysisSessionOutcome in
                await rendezvous.reach(.sessionEntry)
                return await coordinator.analyze(asset)
            }
            started.cancel()
            handle = started
        } else if shape.coordinatorOwnsTask {
            guard let started = await coordinator.startAnalysis(of: asset) else {
                Issue.record("an idle coordinator must start the subject session [\(shape)]")
                witness.recordUnbuildableInput()
                await rendezvous.release()
                return nil
            }
            handle = started
        } else {
            handle = Task { await coordinator.analyze(asset) }
        }

        await rendezvous.waitUntilTheArmedStageIsReached()
        let armedStageWasReached = await rendezvous.wasReached(point.armedStage)

        let identity: AnalysisSessionIdentity?
        if point.hasARunningAttemptAtTheRequest {
            guard let live = await coordinator.activeIdentity() else {
                Issue.record("the held session must be the running attempt [\(shape)]")
                witness.recordUnbuildableInput()
                await rendezvous.release()
                _ = await handle.value
                return nil
            }
            identity = live
        } else {
            identity = nil
        }

        // 3. The terminal that already stands, at the point that generates one.
        var priorCommit: TerminalCommit?
        var priorTerminal: SessionTerminalOutcome?
        if point.aTerminalAlreadyStands {
            guard let live = identity,
                  let snapshot = AnalysisFailureSnapshot(
                      sessionID: live.sessionID,
                      error: shape.priorError,
                      stage: shape.priorStage,
                      bytePreservationStatus: asset.preservationStatus,
                      inputQuality: nil
                  )
            else {
                Issue.record("the prior failure snapshot must be representable [\(shape)]")
                witness.recordUnbuildableInput()
                await rendezvous.release()
                _ = await handle.value
                return nil
            }
            let outcome = SessionTerminalOutcome.failed(snapshot)
            priorCommit = await coordinator.commitTerminal(outcome, for: live)
            priorTerminal = outcome
        }

        // 4. The bounded sampling loop, at the point that generates one. The hook is the
        //    production seam through which an adapter's own cancellation handle is reached,
        //    so the loop is stopped by the request itself rather than by the test.
        var loopTask: Task<AnalysisFault?, Never>?
        var loopGate: FirstCallGate?
        var loopGovernor: RendezvousResourceGovernor?
        var loopController: ResourceController?
        if point == .insideABoundedSamplingLoop {
            let gate = FirstCallGate()
            let governor = RendezvousResourceGovernor(target: .mainApplication, gate: gate)
            guard let live = identity,
                  let controller = ResourceController(
                      target: .mainApplication,
                      budgets: release.admission.configuration.resourceBudgets,
                      governor: governor
                  )
            else {
                Issue.record("the bounded-loop controller must be constructible [\(shape)]")
                witness.recordUnbuildableInput()
                await rendezvous.release()
                _ = await handle.value
                return nil
            }
            let sampling = Task<AnalysisFault?, Never> {
                await faultFromBoundedSampling(
                    controller,
                    first: Self.boundedLoopMetrics[0],
                    second: Self.boundedLoopMetrics[1]
                )
            }
            // Suspended inside the first observation, so the loop is provably mid-loop.
            await gate.waitUntilEntered()
            await coordinator.registerCancellationHook(for: live) { sampling.cancel() }
            loopTask = sampling
            loopGate = gate
            loopGovernor = governor
            loopController = controller
        }

        let expectation = CancellationExpectation.model(
            shape: shape,
            priorTerminal: priorTerminal
        )
        let evidenceCallsBeforeTheRequest = Self.evidenceCalls(in: recorder.callKinds)
        let standingBeforeTheRequest = await coordinator.committedTerminal()
        let callCountAtTheRequest = recorder.calls.count

        // 5. Arm the pending callback values, before the request, so a pending callback's
        //    value provably existed while the session was still admitting results.
        let callbacks = shape.callbacks
        var pendingCallbackIndices: [Int] = []
        var armedValues: [Int: PixelEvidence] = [:]
        for (index, callback) in callbacks.enumerated()
        where callback.wasArmedBeforeTheRequest {
            pendingCallbackIndices.append(index)
            armedValues[index] = callback.pixel
        }

        // 6. The visible cancel control, or — before the session starts — the enclosing
        //    task's cancellation, which is the only mechanism available there.
        var requestResult: CancellationRequestResult?
        if let live = identity {
            requestResult = await coordinator.requestCancellation(for: live)
        }
        let standingWhileStillSuspended = await coordinator.committedTerminal()

        // 7. The bounded loop's next metric boundary, reached only after the hook fired.
        var boundedLoop: BoundedLoopObservation?
        if let sampling = loopTask, let gate = loopGate, let governor = loopGovernor,
           let controller = loopController {
            let enteredMidLoop = await gate.entered()
            await gate.release()
            let fault = await sampling.value
            boundedLoop = BoundedLoopObservation(
                wasEnteredMidLoop: enteredMidLoop,
                fault: fault,
                observedMetrics: governor.observed,
                requestedMetrics: Self.boundedLoopMetrics,
                reserveCallCount: governor.reserveCallCount,
                latchedBreach: await controller.currentBreach(),
                permitsEvidenceCommit: await controller.permits(.evidenceReport),
                invokedHookCount: requestResult?.invokedHookCount ?? 0
            )
        }

        // 8. Deliver the callback schedule. Every callback is late by construction: the port
        //    is still held, the cancellation has already been delivered, and the pipeline has
        //    not resumed. Before the start point there is no running attempt to deliver to,
        //    so the schedule is delivered after the session ended instead — still after the
        //    cancellation, and refused because no attempt exists rather than by the slot.
        var ledger: [DeliveredCallback] = []
        var subjectOutcome: AnalysisSessionOutcome
        if let live = identity {
            ledger = await Self.deliver(
                callbacks,
                armedValues: armedValues,
                to: coordinator,
                naming: live,
                report: controlReport,
                summary: controlSummary,
                shape: shape,
                asset: asset,
                witness: witness
            )
            await rendezvous.release()
            subjectOutcome = await handle.value
        } else {
            await rendezvous.release()
            subjectOutcome = await handle.value
        }
        let subjectCallKinds = recorder.callKinds

        guard let subject = subjectOutcome.completed else {
            Issue.record("the subject session must reach a terminal [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        if identity == nil {
            ledger = await Self.deliver(
                callbacks,
                armedValues: armedValues,
                to: coordinator,
                naming: subject.identity,
                report: controlReport,
                summary: controlSummary,
                shape: shape,
                asset: asset,
                witness: witness
            )
        }
        let callbackTarget = identity ?? subject.identity
        let evidenceCallsAfterTheRequest = Self.evidenceCalls(
            in: Array(subjectCallKinds.dropFirst(callCountAtTheRequest))
        )
        let ephemeralStoreWasEmpty = await release.ephemeral.occupiedScopes().isEmpty

        let run = CancellationRun(
            shape: shape,
            point: point,
            expectation: expectation,
            identity: identity,
            callbackTarget: callbackTarget,
            evidenceCallsBeforeTheRequest: evidenceCallsBeforeTheRequest,
            armedStageWasReached: armedStageWasReached,
            reachedStages: await rendezvous.reachedStages(),
            exhaustedWaits: await totalExhaustedWaits(
                rendezvous: rendezvous,
                loopGate: loopGate
            ),
            standingBeforeTheRequest: standingBeforeTheRequest,
            standingWhileStillSuspended: standingWhileStillSuspended,
            requestResult: requestResult,
            priorCommit: priorCommit,
            ledger: ledger,
            pendingCallbackIndices: pendingCallbackIndices,
            boundedLoop: boundedLoop,
            subject: subject,
            subjectCallKinds: subjectCallKinds,
            evidenceCallsAfterTheRequest: evidenceCallsAfterTheRequest,
            ephemeralStoreWasEmpty: ephemeralStoreWasEmpty,
            control: control,
            controlCallKinds: controlCallKinds
        )
        witness.recordExecutedCase(run)
        return run
    }

    /// Delivers one callback schedule and reads the coordinator's answer to each.
    private static func deliver(
        _ callbacks: [LateCallback],
        armedValues: [Int: PixelEvidence],
        to coordinator: AnalysisCoordinator,
        naming identity: AnalysisSessionIdentity,
        report: EvidenceReport,
        summary: CombinedSummary,
        shape: CancellationCaseShape,
        asset: ImportedEncodedAsset,
        witness: CancellationWitness
    ) async -> [DeliveredCallback] {
        var ledger: [DeliveredCallback] = []
        for (index, callback) in callbacks.enumerated() {
            let response: CallbackResponse
            switch callback.kind {
            case .pixelLaneResult:
                // A calibrated label. Either armed before the request or arising after it;
                // Requirement 15.6 refuses both.
                let value = armedValues[index] ?? callback.pixel
                let admitted = await coordinator.admit(value, for: identity)
                response = .pixelAdmission(
                    await coordinator.admitFrameworkResult(for: identity),
                    landed: admitted.value
                )

            case .provenanceLaneResult:
                let admitted = await coordinator.admit(
                    Self.lane(at: callback.laneIndex),
                    for: identity
                )
                response = .laneAdmission(
                    await coordinator.admitFrameworkResult(for: identity),
                    landed: admitted.value
                )

            case .fusionResult:
                // The real Combined Summary this release produced for the control.
                let admitted = await coordinator.admit(summary, for: identity)
                response = .summaryAdmission(
                    await coordinator.admitFrameworkResult(for: identity),
                    landed: admitted.value
                )

            case .completedReportOffer:
                let offered = SessionTerminalOutcome.completed(report)
                response = .offer(
                    await coordinator.commitTerminal(offered, for: identity),
                    offered: offered
                )

            case .failureOffer:
                guard let snapshot = AnalysisFailureSnapshot(
                    sessionID: identity.sessionID,
                    error: shape.priorError,
                    stage: shape.priorStage,
                    bytePreservationStatus: asset.preservationStatus,
                    inputQuality: nil
                ) else {
                    Issue.record("the offered failure snapshot must be representable [\(shape)]")
                    witness.recordUnbuildableInput()
                    continue
                }
                let offered = SessionTerminalOutcome.failed(snapshot)
                response = .offer(
                    await coordinator.commitTerminal(offered, for: identity),
                    offered: offered
                )

            case .repeatedCancellationRequest:
                response = .repeatedRequest(
                    await coordinator.requestCancellation(for: identity)
                )
            }

            ledger.append(
                DeliveredCallback(
                    index: index,
                    callback: callback,
                    response: response,
                    // Read back from the actor after every callback, so one that never
                    // reached it cannot be entered in the ledger as though it had.
                    standingAfter: await coordinator.committedTerminal()
                )
            )
            witness.recordDeliveredCallback(callback)
        }
        return ledger
    }

    /// **Synthetic.** One of three provenance lanes a late callback may carry.
    ///
    /// A stand-in for the lane a validator would return, not an approved provenance result.
    /// The *real* lane is the one the positive control produces.
    private static func lane(at index: Int) -> ProvenanceLane {
        switch index {
        case 0: .available(.absent)
        case 1: .unavailable(.validatorNotCompiledIntoRelease)
        default: .unavailable(.capabilityNotEnabledByReleaseCapabilityManifest)
        }
    }

    /// The evidence-producing calls in `kinds`, in order.
    private static func evidenceCalls(in kinds: [PortCallKind]) -> [PortCallKind] {
        kinds.filter { PortCall.evidenceProducingCalls.contains($0) }
    }

    // MARK: Arms

    /// The selector arithmetic really is uniform over the vocabularies it reduces.
    ///
    /// Every modulus below divides the selector range, so each field is uniform and
    /// independent of the others. A vocabulary that gained a case would silently skew the
    /// draw, so the counts are asserted rather than assumed.
    func checkTheSelectorArithmeticIsUniform() {
        let pointRange = CancellationCaseShape.pointSelectorBound + 1
        #expect(
            CancellationPoint.allCases.count == 9,
            "the point selector is reduced by 9, found \(CancellationPoint.allCases.count) points"
        )
        #expect(pointRange % CancellationPoint.allCases.count == 0, "point draw is skewed")
        #expect(pointRange % 18 == 0, "task-ownership draw is skewed")
        #expect(
            pointRange % (18 * AnalysisError.allCases.count) == 0,
            "prior-category draw is skewed"
        )
        #expect(
            pointRange % (180 * AnalysisStage.allCases.count) == 0,
            "prior-stage draw is skewed"
        )

        let callbackRange = CancellationCaseShape.callbackSelectorBound + 1
        #expect(
            LateCallbackKind.allCases.count == 6,
            "the callback selector is reduced by 6, found \(LateCallbackKind.allCases.count)"
        )
        #expect(callbackRange % LateCallbackKind.allCases.count == 0, "kind draw is skewed")
        #expect(callbackRange % 18 == 0, "pixel-label draw is skewed")
        #expect(callbackRange % 54 == 0, "provenance-lane draw is skewed")
        #expect(callbackRange % 108 == 0, "pending/late draw is skewed")
    }

    /// The generated cancellation point was actually reached.
    ///
    /// Not "a cancellation happened somewhere". The armed rendezvous stage must have been
    /// entered; the evidence-producing calls recorded when the request landed must be
    /// *exactly* the ones this point predicts, in order; and the outcome standing before the
    /// request must be the one the point predicts — `nil` at every point except the
    /// prior-terminal one. A point that degenerated into "cancelled before anything ran"
    /// fails here instead of satisfying every absence below for free.
    func checkTheGeneratedPointWasActuallyReached() {
        #expect(
            armedStageWasReached,
            "the \(point.rawValue) point never reached its \(point.armedStage.rawValue) seam [\(shape)]"
        )
        #expect(
            reachedStages.contains(point.armedStage),
            "the rendezvous did not record \(point.armedStage.rawValue) [\(shape)]"
        )
        #expect(
            exhaustedWaits == 0,
            "\(exhaustedWaits) bounded waits gave up, so this case was not deterministic [\(shape)]"
        )
        #expect(
            evidenceCallsBeforeTheRequest == expectation.evidenceCallsBeforeTheRequest,
            """
            at the \(point.rawValue) point the request landed after \
            \(evidenceCallsBeforeTheRequest.map(\.rawValue)) but the point predicts \
            \(expectation.evidenceCallsBeforeTheRequest.map(\.rawValue)) [\(shape)]
            """
        )
        if point.aTerminalAlreadyStands {
            #expect(
                standingBeforeTheRequest == expectation.standingOutcome,
                "the prior terminal was not standing when the request arrived [\(shape)]"
            )
        } else {
            #expect(
                standingBeforeTheRequest == nil,
                """
                the session had already committed \
                \(String(describing: standingBeforeTheRequest)) before the cancellation was \
                delivered, so this point was degenerate [\(shape)]
                """
            )
        }
        if let identity {
            #expect(
                identity == callbackTarget,
                "the callbacks named an attempt that was not the running one [\(shape)]"
            )
            #expect(
                identity.sessionID == subject.identity.sessionID,
                "the held attempt is not the session that ended [\(shape)]"
            )
            #expect(
                identity.generation == subject.identity.generation,
                "the held attempt's generation is not the ended session's [\(shape)]"
            )
        } else {
            // Before the start point: no stage ran at all, which is the strongest form of
            // "pending decode, preprocessing, provenance validation, and inference stopped".
            #expect(
                subjectCallKinds.contains(.validate) == false,
                "a session cancelled before it started read a byte [\(shape)]"
            )
        }
    }

    /// Evidence commits were disabled at the instant of the request, not at the next stage.
    ///
    /// Read *while* the pipeline is still suspended inside its port. The slot has to be
    /// occupied already, which is what makes the guarantee structural rather than a check a
    /// later stage might skip.
    func checkEvidenceCommitsWereDisabledAtTheInstantOfTheRequest() {
        guard let result = requestResult else {
            // Before the start point there is no running attempt for the control to name;
            // the cancellation arrives as the enclosing task's, and the entry boundary
            // commits it before the first port call.
            #expect(
                standingWhileStillSuspended == nil,
                "no session was running, so nothing could stand [\(shape)]"
            )
            #expect(
                subject.outcome == .cancelled,
                "a session entered already cancelled must commit the cancelled terminal [\(shape)]"
            )
            return
        }

        #expect(
            standingWhileStillSuspended == expectation.standingOutcome,
            """
            while the pipeline was still suspended at \(point.armedStage.rawValue) the slot \
            held \(String(describing: standingWhileStillSuspended)) but must already hold \
            \(expectation.standingOutcome) [\(shape)]
            """
        )
        #expect(
            result.latchedRequest == expectation.requestLatches,
            "the request reported latchedRequest \(result.latchedRequest) [\(shape)]"
        )
        #expect(
            result.commit.didCommit == expectation.requestCommits,
            "the request's commit reported didCommit \(result.commit.didCommit) [\(shape)]"
        )
        #expect(
            result.standingOutcome == expectation.standingOutcome,
            "the request reported \(String(describing: result.standingOutcome)) standing [\(shape)]"
        )
        #expect(
            result.isCancelled == !point.aTerminalAlreadyStands,
            "the request reported isCancelled \(result.isCancelled) [\(shape)]"
        )
        #expect(
            result.cancelledStructuredTask == (shape.coordinatorOwnsTask
                && !point.aTerminalAlreadyStands),
            """
            the request reported cancelledStructuredTask \(result.cancelledStructuredTask) \
            for a session whose task the coordinator \
            \(shape.coordinatorOwnsTask ? "owns" : "does not own") [\(shape)]
            """
        )
    }

    /// The accepted terminal is the session's only one.
    ///
    /// Exactly one commit may be accepted across the request and every later offer, the
    /// standing outcome is the one the point predicts, every later offer is refused with
    /// that outcome reported unchanged, and the ended session reports it.
    func checkTheAcceptedTerminalIsTheOnlyOne() {
        var accepted = 0
        if let priorCommit, priorCommit.didCommit { accepted += 1 }
        if let requestResult, requestResult.commit.didCommit { accepted += 1 }
        accepted += ledger.filter { $0.response.terminalCommit?.didCommit == true }.count

        #expect(
            accepted == (point.hasARunningAttemptAtTheRequest ? 1 : 0),
            """
            \(accepted) offers were accepted for the \(point.rawValue) point; the slot is \
            written once [\(shape)]
            """
        )
        #expect(
            subject.outcome == expectation.finalOutcome,
            """
            the ended session reports \(subject.outcome) rather than \
            \(expectation.finalOutcome) [\(shape)]
            """
        )
        for entry in ledger {
            guard let commit = entry.response.terminalCommit else { continue }
            #expect(
                commit.didCommit == false,
                "the callback at \(entry.index) overwrote a standing terminal [\(shape)]"
            )
            #expect(
                commit == expectation.refusal,
                """
                the callback at \(entry.index) (\(entry.callback)) was answered \(commit) \
                rather than \(expectation.refusal) [\(shape)]
                """
            )
            #expect(
                commit.standingOutcome == expectation.refusal.standingOutcome,
                "a refusal must report the standing outcome unchanged [\(shape)]"
            )
        }
        // Every read-back after a callback agrees, so no callback moved the slot even
        // momentarily.
        for entry in ledger {
            #expect(
                entry.standingAfter == (point.hasARunningAttemptAtTheRequest
                    ? expectation.standingOutcome
                    : nil),
                """
                after the callback at \(entry.index) the slot held \
                \(String(describing: entry.standingAfter)) [\(shape)]
                """
            )
        }
    }

    /// Every pending or late lane or fusion callback was ignored.
    ///
    /// Each value-carrying callback must be discarded by session and generation, must carry
    /// **no** value — the discarded case has no `value` to unwrap — and must report the
    /// reason the point predicts. A repeated activation of the cancel control latches
    /// nothing and changes nothing.
    func checkEveryPendingOrLateCallbackWasIgnored() {
        #expect(
            ledger.count == shape.callbacks.count,
            """
            \(shape.callbacks.count) callbacks were scheduled but \(ledger.count) were \
            delivered [\(shape)]
            """
        )
        #expect(
            ledger.map(\.callback) == shape.callbacks,
            "the delivered callbacks must be the scheduled ones [\(shape)]"
        )
        #expect(
            ledger.map(\.index) == Array(shape.callbacks.indices),
            "the ledger positions must be the schedule's, found \(ledger.map(\.index)) [\(shape)]"
        )

        for entry in ledger {
            // The response's shape must match the callback's kind, so one callback cannot be
            // recorded as delivered on the strength of another's answer.
            switch (entry.callback.kind, entry.response) {
            case (.pixelLaneResult, .pixelAdmission),
                 (.provenanceLaneResult, .laneAdmission),
                 (.fusionResult, .summaryAdmission),
                 (.completedReportOffer, .offer),
                 (.failureOffer, .offer),
                 (.repeatedCancellationRequest, .repeatedRequest):
                break
            default:
                Issue.record(
                    "\(entry.callback) got a response of the wrong kind [\(shape)]"
                )
            }

            if let admission = entry.response.admission {
                #expect(
                    admission == expectation.admission,
                    """
                    the \(entry.callback) callback was answered \(admission) rather than \
                    \(expectation.admission) [\(shape)]
                    """
                )
                #expect(
                    admission.isAdmitted == false,
                    "a callback delivered after the cancellation was admitted [\(shape)]"
                )
                #expect(
                    entry.response.carriedAValue == false,
                    "a discarded \(entry.callback.kind.rawValue) carried a value [\(shape)]"
                )
                if point.hasARunningAttemptAtTheRequest, !point.aTerminalAlreadyStands {
                    #expect(
                        admission.wasDiscardedByCancellation,
                        "the callback was not discarded by the cancelled terminal [\(shape)]"
                    )
                }
            }

            if case let .repeatedRequest(result) = entry.response {
                #expect(
                    result.latchedRequest == false,
                    "a repeated cancellation request latched again [\(shape)]"
                )
                #expect(
                    result.invokedHookCount == 0,
                    "a repeated cancellation request re-invoked \(result.invokedHookCount) hooks [\(shape)]"
                )
                #expect(
                    result.cancelledStructuredTask == false,
                    "a repeated cancellation request cancelled a task again [\(shape)]"
                )
            }
        }

        // A pending callback's value existed while the session was still admitting results
        // and was still refused, which is the half of Requirement 15.6 that a purely late
        // callback does not exercise.
        for index in pendingCallbackIndices {
            guard let entry = ledger.first(where: { $0.index == index }) else { continue }
            #expect(
                entry.callback.wasArmedBeforeTheRequest,
                "the pending index \(index) does not name a pending callback [\(shape)]"
            )
            if entry.response.admission != nil {
                #expect(
                    entry.response.carriedAValue == false,
                    "a pending callback's value became usable after cancellation [\(shape)]"
                )
            }
        }
    }

    /// No evidence work ran after the cancellation.
    ///
    /// Measured against the call log's suffix from the instant of the request rather than
    /// against the absent result: `calibrate` is the only way Pixel Evidence exists,
    /// `provenanceAnalyze` the only way a provenance result exists, and `fuse` the only way a
    /// Combined Summary exists. `fuse` is additionally required to be absent from the whole
    /// subject log, because the join runs after every generated point.
    func checkNoEvidenceWorkRanAfterTheRequest() {
        for kind in Self.evidenceProducingKinds {
            let count = evidenceCallsAfterTheRequest.filter { $0 == kind }.count
            #expect(
                count == 0,
                """
                \(count) \(kind.rawValue) calls happened after the cancellation at the \
                \(point.rawValue) point [\(shape)]
                """
            )
        }
        #expect(
            subjectCallKinds.contains(.fuse) == false,
            "fusion ran for a cancelled session [\(shape)]"
        )
        // The whole log after the request holds no evidence-producing call at all, so the
        // three zeros above are not an artifact of which kinds were selected.
        #expect(
            evidenceCallsAfterTheRequest.isEmpty,
            """
            \(evidenceCallsAfterTheRequest.map(\.rawValue)) ran after the cancellation at the \
            \(point.rawValue) point [\(shape)]
            """
        )
        // Cleanup is the one thing that must still happen, so this is not the vacuous claim
        // that nothing at all ran afterwards.
        #expect(
            subjectCallKinds.contains(.deleteSession),
            "the cancelled session's material was never removed [\(shape)]"
        )
    }

    /// No partial evidence survived.
    ///
    /// The ended session carries no Evidence Report, no Combined Summary, and no fusion
    /// fault — a fusion fault would mean a rule was consulted — and its material is gone.
    func checkNoPartialEvidenceSurvived() {
        #expect(
            subject.evidenceReport == nil,
            "a session cancelled at the \(point.rawValue) point carries a report [\(shape)]"
        )
        #expect(
            subject.outcome.evidenceReport?.combinedSummary == nil,
            "a cancelled session carries a Combined Summary [\(shape)]"
        )
        #expect(
            subject.fusionFault == nil,
            "fusion was attempted for a cancelled session [\(shape)]"
        )
        #expect(
            subject.outcome.isCompleted == false,
            "a cancelled session reports a completed terminal [\(shape)]"
        )
        #expect(
            ephemeralStoreWasEmpty,
            "the session's ephemeral material outlived its terminal [\(shape)]"
        )
        if !point.aTerminalAlreadyStands {
            // Requirement 11.15 names this deadline specifically, and a cancelled session is
            // not an error-terminated one. Property 25 owns cleanup completeness; what is
            // asserted here is only that the reason a cancellation selects is the cancelled
            // one, because a receipt under another reason would mean a different deadline
            // governed the removal.
            #expect(
                subject.cleanup.receipt?.reason == .cancelled,
                """
                the removal was audited against \
                \(String(describing: subject.cleanup.receipt?.reason)) [\(shape)]
                """
            )
        }
        // Nothing of the attempt survives, so a retry inherits no cancellation request.
        #expect(
            subject.identity.generation > control.identity.generation,
            "the subject attempt did not take a fresh generation [\(shape)]"
        )
    }

    /// Cancellation acquires no Analysis Error category on any path.
    ///
    /// Requirement 11.17 keeps the cancelled terminal out of the ten categories, so the
    /// whole vocabulary is checked rather than one representative value, and the fault is
    /// checked as well as the terminal: a fault that gained a category or a stage would give
    /// the cancelled terminal a failure location.
    func checkCancellationCarriesNoAnalysisErrorCategory() {
        #expect(AnalysisFault.cancelled.analysisError == nil, "cancellation gained a category")
        #expect(AnalysisFault.cancelled.stage == nil, "cancellation gained a stage")
        #expect(AnalysisFault.cancelled.isCancelled, "cancellation must report itself")
        #expect(
            SessionTerminalOutcome.cancelled.error == nil,
            "the cancelled terminal reports a category"
        )
        #expect(
            SessionTerminalOutcome.cancelled.failure == nil,
            "the cancelled terminal reports a snapshot"
        )
        for category in AnalysisError.allCases {
            #expect(
                SessionTerminalOutcome.cancelled.error != category,
                "the cancelled terminal reported \(category.rawValue)"
            )
        }

        guard !point.aTerminalAlreadyStands else {
            // The standing terminal here is a generated failure, which of course carries a
            // category. What matters is that the *cancellation* did not add one, which the
            // prior-terminal arm asserts by requiring the outcome unchanged.
            return
        }
        #expect(
            subject.outcome.isCancelled,
            "the ended session is not the cancelled terminal [\(shape)]"
        )
        #expect(subject.error == nil, "the cancelled session reported a category [\(shape)]")
        #expect(
            subject.outcome.failure == nil,
            "the cancelled session reported a failure snapshot [\(shape)]"
        )
        #expect(
            subject.outcome.isFailed == false,
            "the cancelled session reports a failed terminal [\(shape)]"
        )
        if let requestResult, let standing = requestResult.standingOutcome {
            #expect(
                standing.error == nil,
                "a cancellation request produced a categorised terminal [\(shape)]"
            )
        }
    }

    /// A bounded sampling loop stopped at its next metric boundary and sampled nothing more.
    ///
    /// The request fires the registered framework hook, which is the production seam an
    /// adapter's own cancellation handle is reached through. The loop was suspended inside
    /// its first observation when that happened, so exactly one metric was sampled: a loop
    /// that had already finished would sample both and prove nothing. Cancellation latches
    /// no breach, so a later within-limit reading is still answered honestly.
    func checkTheBoundedLoopStoppedAtItsNextMetricBoundary() {
        guard let loop = boundedLoop else {
            #expect(
                point != .insideABoundedSamplingLoop,
                "the bounded-loop point recorded no loop [\(shape)]"
            )
            return
        }
        #expect(loop.wasEnteredMidLoop, "the loop was not mid-loop at the request [\(shape)]")
        #expect(
            loop.invokedHookCount >= 1,
            "the request invoked \(loop.invokedHookCount) hooks, so nothing cancelled the loop [\(shape)]"
        )
        #expect(loop.fault == .cancelled, "the loop reported \(String(describing: loop.fault)) [\(shape)]")
        #expect(
            loop.fault?.analysisError == nil,
            "the cancelled loop reported an Analysis Error category [\(shape)]"
        )
        #expect(loop.fault?.stage == nil, "the cancelled loop reported a stage [\(shape)]")
        #expect(
            loop.observedMetrics == [Self.boundedLoopMetrics[0]],
            """
            the loop sampled \(loop.observedMetrics.map(\.rawValue)) of \
            \(loop.requestedMetrics.map(\.rawValue)); it must stop at the boundary after the \
            first [\(shape)]
            """
        )
        #expect(loop.reserveCallCount == 0, "a sampling loop reserved headroom [\(shape)]")
        #expect(
            loop.latchedBreach == nil,
            "cancellation latched a resource breach [\(shape)]"
        )
        #expect(
            loop.permitsEvidenceCommit,
            "cancellation withdrew the controller's commit permission [\(shape)]"
        )
    }

    /// A request that found a terminal already standing changed nothing.
    ///
    /// The three terminals cannot transition into one another, so the request is refused at
    /// the slot with the standing outcome reported unchanged, stops no task, and invokes no
    /// hook — while still being recorded, because the user did activate the control.
    func checkARequestAfterAStandingTerminalChangedNothing() {
        guard point.aTerminalAlreadyStands else {
            #expect(priorCommit == nil, "a terminal was committed at the wrong point [\(shape)]")
            return
        }
        guard let priorCommit, let standing = priorCommit.standingOutcome else {
            Issue.record("the prior terminal must have been committed [\(shape)]")
            return
        }
        guard let result = requestResult else {
            Issue.record("the prior-terminal point must deliver a request [\(shape)]")
            return
        }
        #expect(priorCommit.didCommit, "the prior terminal was refused [\(shape)]")
        #expect(
            result.commit == .refusedAlreadyTerminal(standing),
            "the request was answered \(result.commit) [\(shape)]"
        )
        #expect(result.isCancelled == false, "the request cancelled a decided session [\(shape)]")
        // Still recorded: the control was activated. It simply stopped nothing, because the
        // session was already ending through its own path.
        #expect(result.latchedRequest, "the request was not recorded [\(shape)]")
        #expect(
            result.cancelledStructuredTask == false,
            "the request cancelled the task of a session that had already committed [\(shape)]"
        )
        #expect(result.invokedHookCount == 0, "the request invoked a hook [\(shape)]")
        #expect(
            subject.outcome == standing,
            "the ended session reports \(subject.outcome) rather than the standing \(standing) [\(shape)]"
        )
        #expect(
            subject.error == shape.priorError,
            "the standing failure's category changed [\(shape)]"
        )
        #expect(
            subject.outcome.failure?.stage == shape.priorStage,
            "the standing failure's stage changed [\(shape)]"
        )
    }

    /// The positive control produced, through identical wiring, everything the arms above
    /// required to be absent.
    ///
    /// This is what turns three zeros into a measurement. Same coordinator, same ports, same
    /// release, same call log — only the cancellation is missing.
    func checkThePositiveControlProducedEvidence() {
        #expect(
            control.outcome.isCompleted,
            "the positive control must complete, got \(control.outcome) [\(shape)]"
        )
        guard let report = control.evidenceReport else {
            Issue.record("the positive control must produce an Evidence Report [\(shape)]")
            return
        }
        #expect(control.error == nil, "the control reported a category [\(shape)]")
        #expect(
            report.provenance.isAvailable,
            "the control's provenance lane must be available [\(shape)]"
        )
        #expect(
            report.combinedSummary != nil,
            "the control must produce a Combined Summary [\(shape)]"
        )
        #expect(control.fusionFault == nil, "the control's fusion rule did not apply [\(shape)]")
        #expect(
            control.cleanup.receipt?.reason == .completed,
            "the control's removal was audited against the wrong reason [\(shape)]"
        )

        for kind in Self.evidenceProducingKinds {
            let count = controlCallKinds.filter { $0 == kind }.count
            #expect(
                count == 1,
                "the control made \(count) \(kind.rawValue) calls, expected one [\(shape)]"
            )
        }
        // The control ran the whole pipeline, so the subject's shorter prefix is a stopped
        // session rather than a composition that never reaches these stages.
        #expect(
            Self.evidenceCalls(in: controlCallKinds)
                == [.validate, .preprocess, .loadModel, .infer, .calibrate,
                    .provenanceAnalyze, .fuse],
            "the control visited \(Self.evidenceCalls(in: controlCallKinds).map(\.rawValue)) [\(shape)]"
        )
    }
}

// MARK: - Non-vacuity witness

/// Counts what the run generated, reached, delivered, and produced — outside the property
/// body.
///
/// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
/// failed on its first statement would report a passing test in milliseconds with every arm
/// skipped. `completedBodies == cases` alone does not catch that: it passes vacuously as
/// `0 == 0`. The case floor, the per-case counts, and the produced sets are what close the
/// gap, and they live here because an issue recorded outside the body is not suppressed.
///
/// The produced sets are the substantive half. Every cancellation point must have been
/// **reached**, every callback kind delivered, both the pending and the late arming
/// observed, both task-ownership answers observed, and one Evidence Report with a Combined
/// Summary produced by the positive control in **every** case — which is what turns "a
/// cancelled session has no evidence" from a claim about an unreached branch into a measured
/// zero beside a measured one.
///
/// The thresholds sit far below what the requested number of uniform draws produces, so they
/// witness variation rather than pinning a distribution.
private final class CancellationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var executedCases = 0
    private var unbuildableInputs = 0

    // Delivery.
    private var deliveredCallbacks = 0
    private var pendingCallbacks = 0
    private var lateCallbacks = 0
    private var refusedOffers = 0
    private var discardedAdmissions = 0
    private var admittedAfterCancellation = 0
    private var boundedLoopCases = 0
    private var invokedHooks = 0
    private var controlReports = 0
    private var measuredZeroCases = 0
    private var measuredOneCases = 0
    private var cancelledTerminals = 0
    private var standingUnchangedCases = 0

    // Produced outputs.
    private var reachedPoints: Set<CancellationPoint> = []
    private var observedCallbackKinds: Set<LateCallbackKind> = []
    private var observedArmings: Set<String> = []
    private var observedOwnershipAnswers: Set<Bool> = []
    private var observedPriorCategories: Set<AnalysisError> = []
    private var observedPriorStages: Set<AnalysisStage> = []
    private var observedAdmissionAnswers: Set<String> = []
    private var observedProvenanceLaneShapes: Set<Int> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var scheduleLengths: Set<Int> = []
    private var generatedPoints: Set<CancellationPoint> = []

    func record(_ shape: CancellationCaseShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        scheduleLengths.insert(shape.callbackSelectors.count)
        generatedPoints.insert(shape.point)
        observedOwnershipAnswers.insert(shape.coordinatorOwnsTask)
        for callback in shape.callbacks {
            observedProvenanceLaneShapes.insert(callback.laneIndex)
        }
    }

    func recordDeliveredCallback(_ callback: LateCallback) {
        lock.lock()
        defer { lock.unlock() }
        deliveredCallbacks += 1
        observedCallbackKinds.insert(callback.kind)
        if callback.wasArmedBeforeTheRequest {
            pendingCallbacks += 1
            observedArmings.insert("pending")
        } else {
            lateCallbacks += 1
            observedArmings.insert("late")
        }
    }

    /// Records the outcomes one fully executed case produced.
    func recordExecutedCase(_ run: CancellationRun) {
        lock.lock()
        defer { lock.unlock() }
        executedCases += 1
        reachedPoints.insert(run.point)

        for entry in run.ledger {
            if let commit = entry.response.terminalCommit, !commit.didCommit {
                refusedOffers += 1
            }
            guard let admission = entry.response.admission else { continue }
            if admission.isAdmitted {
                admittedAfterCancellation += 1
            } else {
                discardedAdmissions += 1
            }
            switch admission {
            case .admitted: observedAdmissionAnswers.insert("admitted")
            case .discardedTerminalCommitted: observedAdmissionAnswers.insert("terminalCommitted")
            case .discardedStaleIdentity: observedAdmissionAnswers.insert("staleIdentity")
            case .discardedNoActiveSession: observedAdmissionAnswers.insert("noActiveSession")
            }
        }

        if run.subject.outcome.isCancelled { cancelledTerminals += 1 }
        if run.point.aTerminalAlreadyStands {
            observedPriorCategories.insert(run.shape.priorError)
            observedPriorStages.insert(run.shape.priorStage)
            if run.subject.outcome == run.expectation.standingOutcome {
                standingUnchangedCases += 1
            }
        }
        if let loop = run.boundedLoop {
            boundedLoopCases += 1
            invokedHooks += loop.invokedHookCount
        }
        if run.control.evidenceReport?.combinedSummary != nil { controlReports += 1 }
        if CancellationRun.evidenceProducingKinds.allSatisfy({ run.controlCallKinds.contains($0) }) {
            measuredOneCases += 1
        }
        if run.evidenceCallsAfterTheRequest.isEmpty { measuredZeroCases += 1 }
    }

    /// Records an input this file described but could not build.
    ///
    /// Never a finding about the coordinator: every input here is built from generated
    /// integers inside validated ranges, so a refusal is a defect in this file. It is counted
    /// so a run whose inputs quietly stopped being buildable fails outside the body rather
    /// than shrinking its own coverage.
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

        let readOut = """
            cases \(cases)/\(requestedCases), completed bodies \(completedBodies), \
            executed \(executedCases), unbuildable \(unbuildableInputs); \
            delivered callbacks \(deliveredCallbacks) \
            (pending \(pendingCallbacks), late \(lateCallbacks)), \
            refused offers \(refusedOffers), discarded admissions \(discardedAdmissions), \
            admitted after cancellation \(admittedAfterCancellation); \
            bounded-loop cases \(boundedLoopCases) (hooks invoked \(invokedHooks)), \
            prior-terminal cases unchanged \(standingUnchangedCases); \
            cancelled terminals \(cancelledTerminals), control reports \(controlReports), \
            measured ones \(measuredOneCases), measured zeros \(measuredZeroCases); \
            points reached \(reachedPoints.count)/\(CancellationPoint.allCases.count) \
            \(reachedPoints.map(\.rawValue).sorted()), \
            callback kinds \(observedCallbackKinds.map(\.rawValue).sorted()), \
            armings \(observedArmings.sorted()), \
            task ownership \(observedOwnershipAnswers.sorted { !$0 && $1 }), \
            prior categories \(observedPriorCategories.count)/\(AnalysisError.allCases.count), \
            prior stages \(observedPriorStages.count)/\(AnalysisStage.allCases.count), \
            admission answers \(observedAdmissionAnswers.sorted()), \
            provenance lane shapes \(observedProvenanceLaneShapes.sorted()); \
            seeds \(seeds.count), schedule lengths \(scheduleLengths.sorted()), \
            generated points \(generatedPoints.count)
            """

        #expect(
            cases == requestedCases && completedBodies == cases && executedCases == cases,
            "read-out: \(readOut)"
        )
        #expect(
            cases >= requestedCases,
            "the run must generate \(requestedCases) cases; ran \(cases)"
        )
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            executedCases == cases,
            "\(cases - executedCases) of \(cases) cases did not execute a cancellation point"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Schedules hold two to five callbacks, so the floors sit far below
        // what the requested count produces and far enough above zero that a run which built
        // only fixtures fails here rather than passing.
        #expect(deliveredCallbacks >= 2 * cases, "delivered callbacks: \(deliveredCallbacks)")
        #expect(pendingCallbacks >= 100, "callbacks armed before the request: \(pendingCallbacks)")
        #expect(lateCallbacks >= 100, "callbacks arising after the request: \(lateCallbacks)")
        #expect(refusedOffers >= 100, "terminal offers refused after the request: \(refusedOffers)")
        #expect(
            discardedAdmissions >= 100,
            "lane and fusion callbacks discarded after the request: \(discardedAdmissions)"
        )
        #expect(
            admittedAfterCancellation == 0,
            "\(admittedAfterCancellation) callbacks were admitted after the cancellation"
        )
        #expect(boundedLoopCases >= 10, "bounded sampling loops exercised: \(boundedLoopCases)")
        #expect(invokedHooks >= boundedLoopCases, "framework hooks invoked: \(invokedHooks)")
        #expect(
            cancelledTerminals >= cases / 2,
            "sessions that ended cancelled: \(cancelledTerminals)"
        )

        // Every absence was measured beside a presence, on every case.
        #expect(
            controlReports == cases,
            "\(cases - controlReports) cases produced no positive-control report with a summary"
        )
        #expect(
            measuredOneCases == cases,
            "\(cases - measuredOneCases) positive controls did not call every evidence port"
        )
        #expect(
            measuredZeroCases == cases,
            "\(cases - measuredZeroCases) cases ran evidence work after the cancellation"
        )

        // The substantive half: every point was reached, not merely described.
        #expect(
            reachedPoints == Set(CancellationPoint.allCases),
            "points never reached: \(Set(CancellationPoint.allCases).subtracting(reachedPoints).map(\.rawValue).sorted())"
        )
        #expect(
            generatedPoints == Set(CancellationPoint.allCases),
            "points never generated: \(Set(CancellationPoint.allCases).subtracting(generatedPoints).map(\.rawValue).sorted())"
        )
        #expect(
            observedCallbackKinds == Set(LateCallbackKind.allCases),
            "callback kinds never delivered: \(Set(LateCallbackKind.allCases).subtracting(observedCallbackKinds).map(\.rawValue).sorted())"
        )
        #expect(
            observedArmings == ["late", "pending"],
            "callbacks were only ever \(observedArmings.sorted())"
        )
        #expect(
            observedOwnershipAnswers == [false, true],
            "the coordinator's task ownership never varied: \(observedOwnershipAnswers.sorted { !$0 && $1 })"
        )
        #expect(
            observedAdmissionAnswers == ["noActiveSession", "terminalCommitted"],
            "admission answers observed: \(observedAdmissionAnswers.sorted())"
        )
        #expect(
            observedProvenanceLaneShapes == [0, 1, 2],
            "provenance lane shapes offered: \(observedProvenanceLaneShapes.sorted())"
        )
        // The prior-terminal fields vary on one point in nine, so the floor is a coverage
        // requirement rather than a distribution: a run that drew one category for every
        // prior terminal fails, while requiring all ten would be a coin flip.
        #expect(
            observedPriorCategories.count >= 6,
            "prior terminal categories: \(observedPriorCategories.map(\.rawValue).sorted())"
        )
        #expect(
            observedPriorStages.count >= 6,
            "prior terminal stages: \(observedPriorStages.map(\.rawValue).sorted())"
        )
        #expect(
            standingUnchangedCases >= 10,
            "prior-terminal cases whose outcome stayed unchanged: \(standingUnchangedCases)"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            scheduleLengths == [2, 3, 4, 5],
            "generated schedule lengths: \(scheduleLengths.sorted())"
        )
    }
}

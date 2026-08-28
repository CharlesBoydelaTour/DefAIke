import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 10.13: the actor, fault-schedule, cleanup, and interruption integration matrix.
//
// These are **example-based integration tests**, exhaustive over the axes the task
// enumerates rather than randomized. Property coverage over the same requirements already
// exists in tasks 10.6, 10.7, 10.9, 10.10, 10.11, and 10.12; what a generator cannot state
// is "every cell of the enumerated matrix actually ran", because sampling a space is not
// covering it. Each suite below drives one axis to exhaustion over a closed vocabulary and
// asserts that coverage, so a vocabulary that grows a case fails a completeness test here
// rather than silently losing coverage.
//
// The eight axes the task names, and the suite that owns each:
//
//   * **error stage** — `IntegrationMatrixErrorStageTests`: every `AnalysisError` category
//     at the stage the coordinator reaches it, with the downstream nonoccurrences.
//   * **branch ordering** — `IntegrationMatrixBranchOrderingTests`: serial and concurrent
//     execution crossed with a resolving and a faulting pixel branch, plus causal
//     arbitration over every ordered pair of distinct stages.
//   * **retry** — `IntegrationMatrixRetryTests`: a clean session after each terminal kind
//     and after every error stage, under the same session identifier.
//   * **termination boundary** — `IntegrationMatrixTerminationBoundaryTests`: the next
//     application *and* extension start sweeping what an interrupted process left behind,
//     before ingest is reachable, and failing closed when the sweep refuses.
//   * **cleanup reason** — `IntegrationMatrixCleanupReasonTests`: all five reasons under a
//     policy whose five deadlines are *distinct*.
//   * **resource breach** — `IntegrationMatrixResourceBreachTests`: a breach at each stage
//     the Resource Controller governs, every required metric, and the controller's refusal
//     to permit a gated commit afterwards.
//   * **cancellation point** — `IntegrationMatrixCancellationPointTests`: a request landing
//     at each suspension the pipeline actually has.
//   * **late callback** — `IntegrationMatrixLateCallbackTests`: the whole admission
//     vocabulary and every (standing terminal x offered terminal) pair.
//
// A ninth suite, `IntegrationMatrixProgressAndProtectionTests`, covers the progress and
// data-protection halves of the requirement range (15.1 through 15.11, and 9.6) that the
// eight axes do not reach on their own.
//
// **What these tests deliberately do not claim.**
//
//   * **Requirement 9.6 is covered structurally only.** The enforcing platform adapter is
//     not in this test target's module closure, and off iOS its enforcement flag is false,
//     so *no* host result here is evidence that iOS data protection was applied to a real
//     file. The store double holds bytes in memory and creates no file at all. What is
//     shown is that a requested level travels with the write receipt and that a refused
//     level fails closed. Physical-device verification of 9.6 remains outstanding.
//   * **No approved release value appears here.** The five deadlines below are distinct only
//     so that a deadline assertion can fail; they are synthetic placeholders and no test
//     asserts that any of them is correct.
//   * **Two known production behaviours are pinned as they are, not as they should be**,
//     each at the assertion that records it: there is no cancellation checkpoint between
//     building the joined report and committing it, and the derived work percentage is
//     inexact both near ordinary fractions and above 2^53.

// MARK: - A lifecycle policy whose five deadlines differ

/// A Data Lifecycle Policy with a different deadline for every cleanup reason.
///
/// `CoordinatorSample.lifecyclePolicy()` gives all five reasons the same duration, which
/// makes "the receipt carries *this* reason's deadline" true of every reason and therefore
/// vacuous. Every deadline assertion in this file runs against this policy instead, so a
/// mapping that selected the wrong reason's number fails.
///
/// **No number here is an approved release value.** The five deadlines are an unresolved
/// external decision; these are distinct placeholders chosen only to make the assertions
/// non-vacuous.
enum IntegrationLifecycle {

    /// The placeholder deadline for one reason, in milliseconds. All five differ.
    static func milliseconds(for reason: SessionCleanupReason) -> UInt64 {
        switch reason {
        case .completed: 1_000
        case .cancelled: 2_000
        case .errorTerminated: 3_000
        case .interrupted: 4_000
        case .abandoned: 5_000
        }
    }

    /// A schema-valid policy covering the closed reason set with five distinct deadlines.
    ///
    /// It carries the same artifact identifier the synthetic release registers, so it can be
    /// substituted into that release's artifact store and be read by the real startup gate
    /// rather than only by a hand-built cleanup.
    static func distinctPolicy(
        id: ArtifactID = CoordinatorSample.artifact(CoordinatorSample.lifecyclePolicyID)
    ) -> DataLifecyclePolicy {
        do {
            return try DataLifecyclePolicy(
                id: id,
                schemaVersion: .v1,
                deadlines: try SessionCleanupReason.allCases.map { reason in
                    DataLifecyclePolicy.Deadline(
                        reason: reason,
                        deadline: try ValidatedDuration(validating: milliseconds(for: reason))
                    )
                },
                approval: CoordinatorSample.approval()
            )
        } catch {
            preconditionFailure(
                "the distinct-deadline lifecycle fixture must be schema-valid: \(error)"
            )
        }
    }

    /// The deadline this policy assigns to `reason`.
    static func deadline(for reason: SessionCleanupReason) -> ValidatedDuration {
        distinctPolicy().deadline(for: reason)
    }
}

// MARK: - Gated port doubles

/// Where in the pipeline a ``BranchGate`` suspends a port call.
///
/// One case per suspension a cancellation request can land inside. `calibration` is absent
/// on purpose: `PixelCalibrating.classify` is synchronous, so there is no suspension there
/// to hold open, and the boundary *after* calibration is reached instead by gating the
/// serial provenance branch.
enum PipelineGatePoint: String, Sendable, CaseIterable {
    case inputValidation
    case preprocessing
    case modelLoad
    case inference
    case provenanceValidation
}

/// Counts calls so a gate can be armed for one specific invocation.
///
/// A gate that fires on every call cannot express "hold the *second* session open while the
/// first one's identity is offered", which is what the stale-generation case needs.
final class GateArming: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: BranchGate?
    private let callNumber: Int
    private var calls = 0

    init(gate: BranchGate?, callNumber: Int) {
        self.gate = gate
        self.callNumber = callNumber
    }

    /// Suspends when this is the armed call, and returns immediately otherwise.
    func waitIfArmed() async {
        let current = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        guard let gate, current == callNumber else { return }
        await gate.enter()
    }
}

/// An ``InputValidating`` double that can be held open inside validation.
final class GatedInputValidator: InputValidating, Sendable {
    private let outcome: StubOutcome<ValidatedImage>
    private let recorder: PortCallRecorder
    private let arming: GateArming

    init(
        outcome: StubOutcome<ValidatedImage>,
        recorder: PortCallRecorder,
        gate: BranchGate? = nil,
        gateCallNumber: Int = 1
    ) {
        self.outcome = outcome
        self.recorder = recorder
        self.arming = GateArming(gate: gate, callNumber: gateCallNumber)
    }

    func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage {
        recorder.record(.validate(asset.sessionID))
        await arming.waitIfArmed()
        return try outcome.resolve()
    }
}

/// An ``ImagePreprocessing`` double that can be held open inside preprocessing.
final class GatedImagePreprocessor: ImagePreprocessing, Sendable {
    private let outcome: StubOutcome<ModelImageInput>
    private let recorder: PortCallRecorder
    private let arming: GateArming

    init(
        outcome: StubOutcome<ModelImageInput>,
        recorder: PortCallRecorder,
        gate: BranchGate? = nil,
        gateCallNumber: Int = 1
    ) {
        self.outcome = outcome
        self.recorder = recorder
        self.arming = GateArming(gate: gate, callNumber: gateCallNumber)
    }

    func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        recorder.record(.preprocess(image.sessionID))
        await arming.waitIfArmed()
        return try outcome.resolve()
    }
}

/// A ``PixelModelLoading`` double that can be held open inside the model load.
final class GatedPixelModelLoader: PixelModelLoading, Sendable {
    private let outcome: StubOutcome<BoundCoreMLModel>
    private let recorder: PortCallRecorder
    private let arming: GateArming

    init(
        outcome: StubOutcome<BoundCoreMLModel>,
        recorder: PortCallRecorder,
        gate: BranchGate? = nil,
        gateCallNumber: Int = 1
    ) {
        self.outcome = outcome
        self.recorder = recorder
        self.arming = GateArming(gate: gate, callNumber: gateCallNumber)
    }

    func loadModel(
        from bundle: BoundModelBundle
    ) async throws(AnalysisFault) -> BoundCoreMLModel {
        recorder.record(.loadModel(bundle.bundleID))
        await arming.waitIfArmed()
        return try outcome.resolve()
    }
}

/// A ``ProvenanceAnalyzing`` double that can be held open inside validator work.
///
/// Non-throwing, matching the port: every validator condition is an enabled state chosen by
/// the approved mapping, so this double has no fault to program.
final class GatedProvenanceAnalyzer: ProvenanceAnalyzing, Sendable {
    private let state: ProvenanceEvidence
    private let recorder: PortCallRecorder
    private let arming: GateArming

    init(
        always state: ProvenanceEvidence,
        recorder: PortCallRecorder,
        gate: BranchGate? = nil,
        gateCallNumber: Int = 1
    ) {
        self.state = state
        self.recorder = recorder
        self.arming = GateArming(gate: gate, callNumber: gateCallNumber)
    }

    func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence {
        recorder.record(.provenanceAnalyze(asset.sessionID))
        await arming.waitIfArmed()
        return state
    }
}

// MARK: - The matrix harness

/// A coordinator wired to one release, with a distinct-deadline cleanup policy and an
/// optional gate at any one pipeline suspension.
///
/// Deliberately separate from `CoordinatorHarness`, which hard-wires the release's own
/// lifecycle policy and can gate only the inference call. Two things this file needs are not
/// reachable through it: five distinguishable cleanup deadlines, and a suspension at each of
/// the five gate points above.
struct MatrixHarness {
    let coordinator: AnalysisCoordinator
    let release: CoordinatorRelease
    let recorder: PortCallRecorder
    let binder: AnalysisSessionBinder

    /// The policy whose deadlines this harness's cleanup is audited against.
    let policy: DataLifecyclePolicy

    /// The gate armed at ``gatePoint``, or an unused gate when none was requested.
    let gate: BranchGate

    /// Where the gate suspends, or `nil` when the pipeline runs straight through.
    let gatePoint: PipelineGatePoint?

    static func make(
        release: CoordinatorRelease,
        policy: DataLifecyclePolicy = IntegrationLifecycle.distinctPolicy(),
        validated: StubOutcome<ValidatedImage>? = nil,
        prepared: StubOutcome<ModelImageInput>? = nil,
        model: StubOutcome<BoundCoreMLModel>? = nil,
        logit: StubOutcome<RawLogit>? = nil,
        evidence: StubOutcome<PixelEvidence>? = nil,
        provenanceState: ProvenanceEvidence = .absent,
        gateAt gatePoint: PipelineGatePoint? = nil,
        gateCallNumber: Int = 1,
        execution: EvidenceBranchExecution = .serial,
        validationPlan: ArtifactID = CoordinatorSample.artifact(
            CoordinatorSample.validationPlanID
        ),
        sessionID: String = "session-0001"
    ) -> MatrixHarness {
        let recorder = release.recorder
        let gate = BranchGate()
        let session = PortValue.sessionID(sessionID)
        let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
        func gateFor(_ point: PipelineGatePoint) -> BranchGate? {
            gatePoint == point ? gate : nil
        }

        let analyzer: (any ProvenanceAnalyzing)? = release.provenanceEnabled
            ? GatedProvenanceAnalyzer(
                always: provenanceState,
                recorder: recorder,
                gate: gateFor(.provenanceValidation),
                gateCallNumber: gateCallNumber
            )
            : nil
        let binder = release.binder()
        let coordinator = AnalysisCoordinator(
            binder: binder,
            validator: GatedInputValidator(
                outcome: validated
                    ?? StubOutcome(
                        always: PortValue.validatedImage(
                            sessionID: session,
                            preprocessingContractID: contractID
                        )
                    ),
                recorder: recorder,
                gate: gateFor(.inputValidation),
                gateCallNumber: gateCallNumber
            ),
            preprocessor: GatedImagePreprocessor(
                outcome: prepared
                    ?? StubOutcome(
                        always: PortValue.modelInput(
                            sessionID: session,
                            preprocessingContractID: contractID
                        )
                    ),
                recorder: recorder,
                gate: gateFor(.preprocessing),
                gateCallNumber: gateCallNumber
            ),
            modelLoader: GatedPixelModelLoader(
                outcome: model
                    ?? StubOutcome(always: CoordinatorSample.loadedModel(bundle: release.bundle)),
                recorder: recorder,
                gate: gateFor(.modelLoad),
                gateCallNumber: gateCallNumber
            ),
            // Reused from the shared coordinator fixtures. It gates every inference call
            // rather than one, so `.inference` is only ever armed for the first session in a
            // test; a later session finds the gate already open and runs straight through.
            analyzer: GatedPixelAnalyzer(
                outcome: logit ?? StubOutcome(always: PortValue.logit(1.5)),
                recorder: recorder,
                gate: gateFor(.inference)
            ),
            calibrator: StubPixelCalibrator(
                outcome: evidence ?? StubOutcome(always: .signalsConsistentWithAIGeneration),
                recorder: recorder
            ),
            provenance: ProvenanceLaneProvider.resolve(
                linksValidator: true,
                analyzer: analyzer,
                policy: release.admission.configuration.provenancePolicy,
                manifest: release.admission.configuration.capabilityManifest
            ),
            fuser: release.fusionEnabled ? StubEvidenceFuser(recorder: recorder) : nil,
            inconsistencyClassifier: nil,
            cleanup: SessionTerminalCleanup(deleter: release.deleter, policy: policy),
            branchExecution: ApprovedEvidenceBranchExecution(
                execution: execution,
                validationPlan: validationPlan
            )
        )
        return MatrixHarness(
            coordinator: coordinator,
            release: release,
            recorder: recorder,
            binder: binder,
            policy: policy,
            gate: gate,
            gatePoint: gatePoint
        )
    }

    /// A provenance-and-fusion-enabled release, so every downstream nonoccurrence claim in
    /// this file — no provenance analysis, no fusion — is about a call that could otherwise
    /// have happened.
    static func fullComposition(
        policy: DataLifecyclePolicy = IntegrationLifecycle.distinctPolicy(),
        validated: StubOutcome<ValidatedImage>? = nil,
        prepared: StubOutcome<ModelImageInput>? = nil,
        model: StubOutcome<BoundCoreMLModel>? = nil,
        logit: StubOutcome<RawLogit>? = nil,
        evidence: StubOutcome<PixelEvidence>? = nil,
        gateAt gatePoint: PipelineGatePoint? = nil,
        gateCallNumber: Int = 1,
        execution: EvidenceBranchExecution = .serial,
        sessionID: String = "session-0001"
    ) async throws -> MatrixHarness {
        make(
            release: try await CoordinatorRelease.build(provenance: true, fusion: true),
            policy: policy,
            validated: validated,
            prepared: prepared,
            model: model,
            logit: logit,
            evidence: evidence,
            gateAt: gatePoint,
            gateCallNumber: gateCallNumber,
            execution: execution,
            sessionID: sessionID
        )
    }
}

/// Failures this file's own helpers report, so a helper never force-unwraps.
enum IntegrationMatrixSetupFailure: Error {
    case donorReportUnavailable
    case failureSnapshotUnrepresentable
}

/// One real Evidence Report, for the tests that need a `completed` terminal *value* without
/// letting the session under test reach its own completion.
///
/// Produced by running a throwaway session to completion on its own release, so it is a
/// genuine report rather than a hand-assembled one. Its content is immaterial to the tests
/// that use it: the terminal slot refuses a second offer without inspecting the payload, and
/// the cleanup mapping reads only the outcome's case.
enum IntegrationReport {
    static func make(sessionID: String = "session-0001") async throws -> EvidenceReport {
        let donor = try await MatrixHarness.fullComposition(sessionID: sessionID)
        let asset = try await donor.release.acceptedIngest(sessionID: sessionID)
        guard let report = await donor.coordinator.analyze(asset).completed?.evidenceReport
        else {
            throw IntegrationMatrixSetupFailure.donorReportUnavailable
        }
        return report
    }
}

/// A terminal outcome of the requested kind for `sessionID`.
///
/// `report` is supplied by the caller so that two offers of the *same* completed outcome are
/// the same value, which is what the monotonicity matrix means by offering it twice.
func integrationTerminal(
    _ reason: SessionEndReason,
    sessionID: AnalysisSessionID,
    report: EvidenceReport
) throws -> SessionTerminalOutcome {
    switch reason {
    case .cancelled:
        return .cancelled
    case .completed:
        return .completed(report)
    default:
        guard let snapshot = AnalysisFailureSnapshot(
            sessionID: sessionID,
            error: .resourceLimit,
            stage: .inference,
            bytePreservationStatus: .unknown,
            inputQuality: nil
        ) else {
            throw IntegrationMatrixSetupFailure.failureSnapshotUnrepresentable
        }
        return .failed(snapshot)
    }
}

// MARK: - Axis: error stage

/// Which port raises a row's fault.
enum FaultingPort: String, Sendable, CaseIterable {
    case validator
    case preprocessor
    case modelLoader
    case analyzer
    case calibrator
}

/// One (category, stage, raising port) cell of the error-stage axis.
struct ErrorStageCell: Sendable, CustomStringConvertible {
    let error: AnalysisError
    let stage: AnalysisStage
    let port: FaultingPort

    /// Calls that must not happen once this cell's fault is raised.
    let forbidden: [PortCallKind]

    var description: String { "\(error.rawValue)@\(stage.rawValue) from \(port.rawValue)" }
}

/// Every stage a fault can be raised at, and what must not run afterwards.
///
/// The table is the axis. `everyCategoryIsCovered` asserts it reaches every member of the
/// closed `AnalysisError` vocabulary, so a category added to the requirements fails a test
/// here rather than going unexercised.
enum ErrorStageMatrix {
    static let afterValidation: [PortCallKind] = [
        .preprocess, .loadModel, .infer, .calibrate, .provenanceAnalyze, .fuse,
    ]
    static let afterPreprocessing: [PortCallKind] = [
        .loadModel, .infer, .calibrate, .provenanceAnalyze, .fuse,
    ]
    static let afterModelLoad: [PortCallKind] = [.infer, .calibrate, .provenanceAnalyze, .fuse]
    static let afterInference: [PortCallKind] = [.calibrate, .provenanceAnalyze, .fuse]
    static let afterCalibration: [PortCallKind] = [.provenanceAnalyze, .fuse]

    static let cells: [ErrorStageCell] = [
        // Handoff verification is the causally first stage: a Share transfer whose bytes or
        // status did not survive the handoff fails before validation, provenance, or
        // inference (Requirements 2.19 and 11.13).
        ErrorStageCell(
            error: .handoffError,
            stage: .handoffVerification,
            port: .validator,
            forbidden: afterValidation
        ),
        ErrorStageCell(
            error: .unsupportedMedia,
            stage: .mediaClassification,
            port: .validator,
            forbidden: afterValidation
        ),
        ErrorStageCell(
            error: .unsupportedStaticFormat,
            stage: .mediaClassification,
            port: .validator,
            forbidden: afterValidation
        ),
        ErrorStageCell(
            error: .decodingError,
            stage: .inputValidation,
            port: .validator,
            forbidden: afterValidation
        ),
        // The same category at three different stages, which is why a snapshot records the
        // stage as well as the category (Requirements 3.4 and 11.6).
        ErrorStageCell(
            error: .resourceLimit,
            stage: .inputValidation,
            port: .validator,
            forbidden: afterValidation
        ),
        ErrorStageCell(
            error: .preprocessingError,
            stage: .preprocessing,
            port: .preprocessor,
            forbidden: afterPreprocessing
        ),
        ErrorStageCell(
            error: .resourceLimit,
            stage: .preprocessing,
            port: .preprocessor,
            forbidden: afterPreprocessing
        ),
        ErrorStageCell(
            error: .modelLoadError,
            stage: .modelLoad,
            port: .modelLoader,
            forbidden: afterModelLoad
        ),
        ErrorStageCell(
            error: .inferenceError,
            stage: .inference,
            port: .analyzer,
            forbidden: afterInference
        ),
        // A missing or non-finite logit is refused at output validation and never mapped to
        // a label (Requirement 4.16).
        ErrorStageCell(
            error: .invalidOutputError,
            stage: .outputValidation,
            port: .analyzer,
            forbidden: afterInference
        ),
        ErrorStageCell(
            error: .resourceLimit,
            stage: .inference,
            port: .analyzer,
            forbidden: afterInference
        ),
        ErrorStageCell(
            error: .calibrationInputError,
            stage: .calibration,
            port: .calibrator,
            forbidden: afterCalibration
        ),
    ]

    /// A harness whose `cell.port` raises `cell`'s fault and whose every other port succeeds.
    static func harness(for cell: ErrorStageCell) async throws -> MatrixHarness {
        let fault = AnalysisFault.analysis(cell.error, stage: cell.stage)
        return try await MatrixHarness.fullComposition(
            validated: cell.port == .validator ? StubOutcome(alwaysFailing: fault) : nil,
            prepared: cell.port == .preprocessor ? StubOutcome(alwaysFailing: fault) : nil,
            model: cell.port == .modelLoader ? StubOutcome(alwaysFailing: fault) : nil,
            logit: cell.port == .analyzer ? StubOutcome(alwaysFailing: fault) : nil,
            evidence: cell.port == .calibrator ? StubOutcome(alwaysFailing: fault) : nil
        )
    }
}

@Suite("Integration matrix: every error stage ends one session with one error")
struct IntegrationMatrixErrorStageTests {

    @Test("The error-stage table reaches every Analysis Error category")
    func everyCategoryIsCovered() {
        // The axis is exhaustive only if the table is.
        #expect(Set(ErrorStageMatrix.cells.map(\.error)) == Set(AnalysisError.allCases))
    }

    @Test("Every stage in the table is ranked by causal arbitration")
    func everyTableStageIsRanked() {
        // Arbitration has to be able to order every stage this axis can fail at; an
        // unranked stage would be a silent tie.
        for stage in Set(ErrorStageMatrix.cells.map(\.stage)) {
            #expect(CausalFaultArbitration.causalStageOrder.contains(stage))
        }
    }

    @Test(
        "A fault at one stage commits that stage's error, no evidence, and no later work",
        arguments: ErrorStageMatrix.cells
    )
    func stageFaultCommitsOneErrorAndStopsThere(cell: ErrorStageCell) async throws {
        let harness = try await ErrorStageMatrix.harness(for: cell)
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        let failure = try #require(session.outcome.failure)
        // Exactly one category, at the stage the port named, never rewritten
        // (Requirements 3.12 and 11.18).
        #expect(failure.error == cell.error)
        #expect(failure.stage == cell.stage)
        #expect(failure.sessionID == asset.sessionID)
        #expect(session.evidenceReport == nil)
        #expect(session.outcome.isCompleted == false)
        #expect(session.outcome.isCancelled == false)
        // No Pixel Evidence, no provenance state, and no Combined Summary for a failed
        // session, asserted against the call log rather than inferred from the result.
        for forbidden in cell.forbidden {
            #expect(harness.recorder.didCall(forbidden) == false)
        }
    }

    @Test(
        "Every stage failure is cleaned up under the error-terminated deadline",
        arguments: ErrorStageMatrix.cells
    )
    func stageFailureCleansUpUnderTheErrorDeadline(cell: ErrorStageCell) async throws {
        let harness = try await ErrorStageMatrix.harness(for: cell)
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.reason == .errorTerminated)
        // Non-vacuous: the five deadlines in this policy differ, so selecting the completed
        // or cancelled number would fail here (Requirements 9.8 and 9.17).
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: .errorTerminated))
        #expect(receipt.lifecyclePolicyID == harness.policy.id)
        #expect(receipt.removedObjectCount == 1)
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
        // The attempt is fully discarded, so nothing of it survives into the next session
        // (Requirement 3.15).
        #expect(await harness.coordinator.activeIdentity() == nil)
        #expect(await harness.coordinator.committedTerminal() == nil)
        #expect(await harness.binder.boundSessionCount == 0)
    }

    @Test(
        "A failure at or after validation preserves the dimensions recorded before it",
        arguments: ErrorStageMatrix.cells.filter { $0.port != .validator }
    )
    func aLaterFailurePreservesWhatWasAlreadyMeasured(cell: ErrorStageCell) async throws {
        let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
        let sessionID = PortValue.sessionID("session-0001")
        let fault = AnalysisFault.analysis(cell.error, stage: cell.stage)
        let harness = try await MatrixHarness.fullComposition(
            validated: StubOutcome(
                always: PortValue.validatedImage(
                    sessionID: sessionID,
                    width: 1_024,
                    height: 768,
                    preprocessingContractID: contractID
                )
            ),
            prepared: cell.port == .preprocessor ? StubOutcome(alwaysFailing: fault) : nil,
            model: cell.port == .modelLoader ? StubOutcome(alwaysFailing: fault) : nil,
            logit: cell.port == .analyzer ? StubOutcome(alwaysFailing: fault) : nil,
            evidence: cell.port == .calibrator ? StubOutcome(alwaysFailing: fault) : nil
        )
        let asset = try await harness.release.acceptedIngest()

        let completed = try #require(await harness.coordinator.analyze(asset).completed)

        let failure = try #require(completed.outcome.failure)
        // Requirement 3.14: the byte status and every pre-orientation dimension recorded
        // before the failure survive into the snapshot.
        #expect(failure.bytePreservationStatus == asset.preservationStatus)
        let quality = try #require(failure.inputQuality)
        #expect(quality.decodedWidthBeforeOrientation == 1_024)
        #expect(quality.decodedHeightBeforeOrientation == 768)
        #expect(quality.shortEdgeBeforeOrientation == 768)
    }

    @Test("A failure before validation preserves the byte status with no dimensions")
    func anEarlyFailurePreservesOnlyTheByteStatus() async throws {
        let harness = try await MatrixHarness.fullComposition(
            validated: StubOutcome(
                alwaysFailing: .analysis(.unsupportedMedia, stage: .mediaClassification)
            )
        )
        let asset = try await harness.release.acceptedIngest()

        let completed = try #require(await harness.coordinator.analyze(asset).completed)

        let failure = try #require(completed.outcome.failure)
        #expect(failure.bytePreservationStatus == asset.preservationStatus)
        // Nothing was measured, so nothing is reconstructed or defaulted.
        #expect(failure.inputQuality == nil)
    }
}

// MARK: - Axis: branch ordering

/// One (execution policy, pixel-branch outcome) cell of the branch-ordering axis.
struct BranchOrderingCell: Sendable, CustomStringConvertible {
    let execution: EvidenceBranchExecution
    let pixelFaults: Bool

    var description: String {
        let order = execution == .concurrent ? "concurrent" : "serial"
        let branch = pixelFaults ? "pixel-faults" : "pixel-resolves"
        return "\(order)/\(branch)"
    }
}

@Suite("Integration matrix: branch ordering and causal arbitration")
struct IntegrationMatrixBranchOrderingTests {

    static let cells: [BranchOrderingCell] = [
        BranchOrderingCell(execution: .serial, pixelFaults: false),
        BranchOrderingCell(execution: .serial, pixelFaults: true),
        BranchOrderingCell(execution: .concurrent, pixelFaults: false),
        BranchOrderingCell(execution: .concurrent, pixelFaults: true),
    ]

    @Test(
        "Both executions reach the same terminal, and only serial withholds the sibling",
        arguments: cells
    )
    func executionDecidesOnlyWhetherTheSiblingStarts(cell: BranchOrderingCell) async throws {
        let harness = try await MatrixHarness.fullComposition(
            logit: cell.pixelFaults
                ? StubOutcome(alwaysFailing: .analysis(.inferenceError, stage: .inference))
                : nil,
            execution: cell.execution
        )
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        // The recorded execution is the one the approved policy authorized for the bound
        // session, which is a fact a device-validation record needs.
        #expect(session.branchExecution == cell.execution)
        if cell.pixelFaults {
            #expect(session.error == .inferenceError)
            #expect(session.evidenceReport == nil)
            // Serially the sibling has not started when the pixel branch fails, which is
            // the ordered equivalent of cancelling it (Requirement 3.12). Concurrently it
            // was already launched, so the call happens and its lane is dropped at the join.
            #expect(
                harness.recorder.didCall(PortCallKind.provenanceAnalyze)
                    == (cell.execution == .concurrent)
            )
            // Either way no summary is fused for a failed session.
            #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
        } else {
            let report = try #require(session.evidenceReport)
            #expect(report.pixel == .signalsConsistentWithAIGeneration)
            #expect(report.provenance == .available(.absent))
            #expect(harness.recorder.callCount(of: .provenanceAnalyze) == 1)
            #expect(harness.recorder.callCount(of: .fuse) == 1)
        }
    }

    @Test("A concurrent answer recorded against another plan version degrades to serial")
    func aPolicyFromAnotherPlanDegradesToSerial() async throws {
        // Concurrency requires the *active* plan to approve it for the exact configuration.
        // An answer recorded against a different plan version has not done that, so serial
        // is the design's own rule rather than a lenient fallback.
        let release = try await CoordinatorRelease.build(provenance: true, fusion: true)
        let degraded = MatrixHarness.make(
            release: release,
            execution: .concurrent,
            validationPlan: CoordinatorSample.artifact("plan.device-validation.other")
        )
        let asset = try await release.acceptedIngest()

        let session = try #require(await degraded.coordinator.analyze(asset).completed)

        #expect(session.branchExecution == .serial)
        #expect(session.evidenceReport != nil)
    }

    @Test(
        "A serial pixel failure never opens the provenance branch, at any pixel stage",
        arguments: [
            AnalysisStage.modelLoad, .inference, .outputValidation, .calibration,
        ]
    )
    func aSerialPixelFailureNeverOpensTheSibling(stage: AnalysisStage) async throws {
        let fault = AnalysisFault.analysis(
            stage == .calibration ? .calibrationInputError : .inferenceError,
            stage: stage
        )
        let harness = try await MatrixHarness.fullComposition(
            model: stage == .modelLoad ? StubOutcome(alwaysFailing: fault) : nil,
            logit: stage == .inference || stage == .outputValidation
                ? StubOutcome(alwaysFailing: fault)
                : nil,
            evidence: stage == .calibration ? StubOutcome(alwaysFailing: fault) : nil,
            execution: .serial
        )
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.outcome.failure?.stage == stage)
        #expect(harness.recorder.didCall(PortCallKind.provenanceAnalyze) == false)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
    }

    @Test("Arbitration is invariant over every ordered pair of distinct stages")
    func arbitrationIsPermutationInvariantOverDistinctStages() {
        let stages = CausalFaultArbitration.causalStageOrder
        for left in stages {
            for right in stages where left != right {
                let a = AnalysisFault.analysis(.resourceLimit, stage: left)
                let b = AnalysisFault.analysis(.inferenceError, stage: right)
                let forward = CausalFaultArbitration.earliest(of: [a, b])
                #expect(forward == CausalFaultArbitration.earliest(of: [b, a]))
                let leftIsEarlier = CausalFaultArbitration.causalRank(of: left)
                    < CausalFaultArbitration.causalRank(of: right)
                #expect(forward == (leftIsEarlier ? a : b))
            }
        }
    }

    @Test("Two faults sharing the causally earliest stage keep the first offered")
    func aStageTieKeepsTheFirstAndIsNotPermutationInvariant() {
        // Recorded as designed behaviour, not as a defect: an adapter returns one normalized
        // error per stage, so a same-stage pair is outside the case arbitration has to
        // order, and keeping the first is still deterministic for a caller offering a
        // deterministically ordered list. Permutation invariance is therefore *not* claimed
        // for this case, and this test pins that.
        let first = AnalysisFault.analysis(.resourceLimit, stage: .inference)
        let second = AnalysisFault.analysis(.inferenceError, stage: .inference)
        #expect(CausalFaultArbitration.earliest(of: [first, second]) == first)
        #expect(CausalFaultArbitration.earliest(of: [second, first]) == second)
    }

    @Test("Cancellation outranks an analysis fault at every stage, in either position")
    func cancellationOutranksEveryStage() {
        for stage in CausalFaultArbitration.causalStageOrder {
            let analysis = AnalysisFault.analysis(.resourceLimit, stage: stage)
            #expect(CausalFaultArbitration.earliest(of: [.cancelled, analysis]) == .cancelled)
            #expect(CausalFaultArbitration.earliest(of: [analysis, .cancelled]) == .cancelled)
        }
    }

    @Test("An empty fault list is not a failure, and one fault arbitrates to itself")
    func arbitrationIsTotalOverSmallLists() {
        #expect(CausalFaultArbitration.earliest(of: []) == nil)
        for stage in CausalFaultArbitration.causalStageOrder {
            let only = AnalysisFault.analysis(.decodingError, stage: stage)
            #expect(CausalFaultArbitration.earliest(of: [only]) == only)
        }
    }

    @Test("Under concurrent execution the sibling never changes the reported category")
    func aConcurrentSiblingCannotChangeTheReportedCategory() async throws {
        // The join holds both outcomes and then arbitrates, so the category is the pixel
        // branch's earliest stage whatever the sibling did or how long it took.
        let harness = try await MatrixHarness.fullComposition(
            model: StubOutcome(alwaysFailing: .analysis(.modelLoadError, stage: .modelLoad)),
            execution: .concurrent
        )
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .modelLoadError)
        #expect(session.outcome.failure?.stage == .modelLoad)
        #expect(session.evidenceReport == nil)
    }
}

// MARK: - Axis: retry

@Suite("Integration matrix: a session after any terminal inherits nothing")
struct IntegrationMatrixRetryTests {

    @Test(
        "A retry under the same identifier succeeds after a failure at any stage",
        arguments: ErrorStageMatrix.cells
    )
    func aRetrySucceedsAfterEveryErrorStage(cell: ErrorStageCell) async throws {
        // "Fail, then succeed" on the raising port. Requirement 3.13: a failed session is
        // followed by a new one with no application restart.
        let release = try await CoordinatorRelease.build(provenance: true, fusion: true)
        let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
        let sessionID = PortValue.sessionID("session-0001")
        let fault = AnalysisFault.analysis(cell.error, stage: cell.stage)
        let harness = MatrixHarness.make(
            release: release,
            validated: cell.port == .validator
                ? StubOutcome(
                    [
                        .fault(fault),
                        .success(
                            PortValue.validatedImage(
                                sessionID: sessionID,
                                preprocessingContractID: contractID
                            )
                        ),
                    ]
                )
                : nil,
            prepared: cell.port == .preprocessor
                ? StubOutcome(
                    [
                        .fault(fault),
                        .success(
                            PortValue.modelInput(
                                sessionID: sessionID,
                                preprocessingContractID: contractID
                            )
                        ),
                    ]
                )
                : nil,
            model: cell.port == .modelLoader
                ? StubOutcome(
                    [
                        .fault(fault),
                        .success(CoordinatorSample.loadedModel(bundle: release.bundle)),
                    ]
                )
                : nil,
            logit: cell.port == .analyzer
                ? StubOutcome([.fault(fault), .success(PortValue.logit(1.5))])
                : nil,
            evidence: cell.port == .calibrator
                ? StubOutcome(
                    [.fault(fault), .success(.signalsConsistentWithAIGeneration)]
                )
                : nil
        )

        let first = try #require(
            await harness.coordinator.analyze(
                try await release.acceptedIngest(byteSeed: 1)
            ).completed
        )
        let second = try #require(
            await harness.coordinator.analyze(
                try await release.acceptedIngest(byteSeed: 2)
            ).completed
        )

        #expect(first.error == cell.error)
        #expect(first.identity.generation == 1)
        // A brand-new attempt: a fresh generation, no inherited error, and a report.
        #expect(second.identity.generation == 2)
        #expect(second.error == nil)
        #expect(second.outcome.isFailed == false)
        #expect(second.evidenceReport != nil)
        #expect(second.cleanup.receipt?.reason == .completed)
        #expect(second.cleanup.receipt?.deadline == IntegrationLifecycle.deadline(for: .completed))
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test(
        "A retry succeeds after each of the three terminal kinds",
        arguments: [SessionEndReason.completed, .cancelled, .error]
    )
    func aRetrySucceedsAfterEveryTerminalKind(reason: SessionEndReason) async throws {
        let harness = try await MatrixHarness.fullComposition(
            logit: reason == .error
                ? StubOutcome(
                    [
                        .fault(.analysis(.inferenceError, stage: .inference)),
                        .success(PortValue.logit(1.5)),
                    ]
                )
                : nil,
            gateAt: reason == .cancelled ? .inference : nil
        )
        let first = try await harness.release.acceptedIngest(byteSeed: 1)

        let firstSession: CompletedAnalysisSession
        if reason == .cancelled {
            async let running = harness.coordinator.analyze(first)
            await harness.gate.waitUntilReached()
            let identity = try #require(await harness.coordinator.activeIdentity())
            await harness.coordinator.requestCancellation(for: identity)
            await harness.gate.openGate()
            firstSession = try #require(await running.completed)
        } else {
            firstSession = try #require(await harness.coordinator.analyze(first).completed)
        }

        #expect(firstSession.outcome.endReason == reason)
        #expect(await harness.coordinator.activeIdentity() == nil)

        // The gate is already open once a cancelled first attempt released it, so the second
        // attempt runs straight through the same analyzer.
        let second = try #require(
            await harness.coordinator.analyze(
                try await harness.release.acceptedIngest(byteSeed: 2)
            ).completed
        )

        #expect(second.identity.generation == 2)
        #expect(second.outcome.isCompleted)
        #expect(second.error == nil)
        #expect(second.cleanup.receipt?.deadline == IntegrationLifecycle.deadline(for: .completed))
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("Three attempts in a row each carry their own generation and terminal")
    func generationsAreNeverReused() async throws {
        let harness = try await MatrixHarness.fullComposition(
            logit: StubOutcome(
                [
                    .fault(.analysis(.inferenceError, stage: .inference)),
                    .success(PortValue.logit(1.5)),
                    .fault(.analysis(.invalidOutputError, stage: .outputValidation)),
                ]
            )
        )

        var generations: [UInt64] = []
        var reasons: [SessionEndReason] = []
        for seed in UInt8(1)...3 {
            let session = try #require(
                await harness.coordinator.analyze(
                    try await harness.release.acceptedIngest(byteSeed: seed)
                ).completed
            )
            generations.append(session.identity.generation)
            reasons.append(session.outcome.endReason)
        }

        #expect(generations == [1, 2, 3])
        #expect(reasons == [.error, .completed, .error])
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("A second session cannot start while one is running, and starts cleanly after")
    func aSecondSessionIsRefusedWhileOneRuns() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let first = try await harness.release.acceptedIngest(sessionID: "session-0001", byteSeed: 1)
        let second = try await harness.release.acceptedIngest(sessionID: "session-0002", byteSeed: 2)

        async let running = harness.coordinator.analyze(first)
        await harness.gate.waitUntilReached()
        let refused = await harness.coordinator.analyze(second)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        // No session was created for the refusal, no byte was read, and the running session
        // is untouched. It is not an Analysis Error and not a terminal outcome.
        let refusedIdentity = try #require(refused.refusedIdentity)
        #expect(refusedIdentity == session.identity)
        #expect(refused.completed == nil)
        #expect(session.outcome.isCompleted)
        // The refused ingest's own material is still in the store, because it never became a
        // session and therefore never reached a terminal cleanup path.
        #expect(await harness.release.ephemeral.keys(in: .session(second.sessionID)).count == 1)
    }
}

// MARK: - Axis: app and extension termination boundary

@Suite("Integration matrix: the next start sweeps what an interruption left behind")
struct IntegrationMatrixTerminationBoundaryTests {

    /// A startup gate for `target` over one release's ports.
    ///
    /// The same seven-step gate `CoordinatorRelease` runs, re-run against a store that now
    /// holds material from a process that did not finish. Running it for both targets is what
    /// makes this the *app and extension* boundary rather than the app's alone (Requirements
    /// 9.9 and 11.16).
    static func preflight(target: ExecutionTarget) -> StartupPreflight {
        StartupPreflight(
            device: CoordinatorSample.deviceContext(),
            composition: CoordinatorSample.composition(provenance: false, fusion: false),
            capabilityManifest: CoordinatorSample.artifact(CoordinatorSample.capabilityManifestID),
            verdictCopyCatalog: CoordinatorSample.artifact(CoordinatorSample.copyCatalogID),
            embeddedBundle: Fixture.bundleID(CoordinatorSample.bundleID),
            target: target
        )
    }

    /// A release whose artifact store carries the distinct-deadline lifecycle policy, so a
    /// startup receipt's deadline assertion is non-vacuous.
    static func releaseWithDistinctDeadlines() async throws -> CoordinatorRelease {
        let release = try await CoordinatorRelease.build()
        await release.policies.register(IntegrationLifecycle.distinctPolicy())
        return release
    }

    @Test(
        "An interrupted session's material is swept at the next start of either process",
        arguments: [ExecutionTarget.mainApplication, .shareExtension]
    )
    func interruptedMaterialIsSweptAtTheNextStart(target: ExecutionTarget) async throws {
        let release = try await Self.releaseWithDistinctDeadlines()
        // A session that was live and then went away with no terminal deletion receipt: the
        // process was interrupted or terminated mid-analysis.
        let orphan = PortValue.sessionID("session-interrupted")
        _ = try await release.ephemeral.writeComplete(
            PortValue.bytes(count: 192, seed: 7),
            in: .session(orphan),
            // This store holds bytes in memory and creates no file, so no host
            // data-protection condition is reachable here.
            protection: .completeUntilFirstUserAuthentication
        )
        await release.deleter.registerLiveSession(orphan)
        await release.deleter.forgetLiveSession(orphan)
        #expect(await release.ephemeral.occupiedScopes().isEmpty == false)

        let admission = try await Self.preflight(target: target)
            .run(policies: release.policies, bundles: release.bundles, cleanup: release.deleter)

        #expect(admission.target == target)
        let receipt = try #require(admission.startupCleanup.first { $0.sessionID == orphan })
        #expect(receipt.reason == .abandoned)
        // Non-vacuous under the distinct-deadline policy: the abandoned number is not the
        // interrupted, cancelled, completed, or error number.
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: .abandoned))
        #expect(receipt.lifecyclePolicyID == IntegrationLifecycle.distinctPolicy().id)
        #expect(receipt.removedObjectCount == 1)
        // The admission is the only value that permits ingest, and the sweep already ran
        // before it existed, so no new session can be accepted with material still present.
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("A transfer slot an interrupted extension left behind is swept too")
    func anInterruptedTransferSlotIsSwept() async throws {
        let release = try await Self.releaseWithDistinctDeadlines()
        let transfer = PortValue.transferID("transfer-interrupted")
        for state in TransferSlotState.allCases {
            _ = try await release.ephemeral.writeComplete(
                PortValue.bytes(count: 64, seed: 3),
                in: .transfer(transfer, state),
                protection: .completeUntilFirstUserAuthentication
            )
        }

        let admission = try await Self.preflight(target: .shareExtension)
            .run(policies: release.policies, bundles: release.bundles, cleanup: release.deleter)

        // Transfer slots carry no session identity, so they are swept without a session
        // receipt. What matters is that nothing analyzable survives the boundary.
        #expect(admission.startupCleanup.isEmpty)
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("The session a start is about to accept work for is never swept")
    func aLiveSessionSurvivesTheStartupSweep() async throws {
        let release = try await Self.releaseWithDistinctDeadlines()
        let live = PortValue.sessionID("session-live")
        _ = try await release.ephemeral.writeComplete(
            PortValue.bytes(count: 128, seed: 5),
            in: .session(live),
            protection: .completeUntilFirstUserAuthentication
        )
        await release.deleter.registerLiveSession(live)

        let admission = try await Self.preflight(target: .mainApplication)
            .run(policies: release.policies, bundles: release.bundles, cleanup: release.deleter)

        #expect(admission.startupCleanup.isEmpty)
        #expect(await release.ephemeral.keys(in: .session(live)).count == 1)
    }

    @Test("A refused sweep blocks the admission rather than warning about it")
    func aFailedStartupSweepKeepsIngestClosed() async throws {
        let release = try await Self.releaseWithDistinctDeadlines()
        _ = try await release.ephemeral.writeComplete(
            PortValue.bytes(count: 96, seed: 9),
            in: .session(PortValue.sessionID("session-unremovable")),
            protection: .completeUntilFirstUserAuthentication
        )
        // Queued after the seeding writes, so the refusal lands on the sweep's deletion.
        await release.ephemeral.failNextOperation(with: .storeUnavailable)

        do {
            _ = try await Self.preflight(target: .mainApplication)
                .run(
                    policies: release.policies,
                    bundles: release.bundles,
                    cleanup: release.deleter
                )
            Issue.record("a refused startup sweep must not produce a release admission")
        } catch {
            guard case .startupCleanupFailed = error else {
                Issue.record("a refused store must fail startup cleanup, found \(error)")
                return
            }
        }
        // Unremoved bytes are still there, and there is no admission with which to accept new
        // work, which is the fail-closed posture the requirement asks for.
        #expect(await release.ephemeral.occupiedScopes().isEmpty == false)
    }

    @Test("A session that reached a terminal leaves nothing for the next start to find")
    func aTerminatedSessionLeavesNothingAbandoned() async throws {
        let release = try await Self.releaseWithDistinctDeadlines()
        let harness = MatrixHarness.make(release: release)
        let asset = try await release.acceptedIngest()
        _ = await harness.coordinator.analyze(asset)

        let admission = try await Self.preflight(target: .mainApplication)
            .run(policies: release.policies, bundles: release.bundles, cleanup: release.deleter)

        // Terminal cleanup already removed the material under its own deadline, so the
        // abandoned sweep has nothing to report.
        #expect(admission.startupCleanup.isEmpty)
        #expect(await release.ephemeral.occupiedScopes().isEmpty)
    }
}

// MARK: - Axis: cleanup reason

@Suite("Integration matrix: five cleanup reasons select five distinct deadlines")
struct IntegrationMatrixCleanupReasonTests {

    @Test("The five deadlines are pairwise distinct, so every deadline claim can fail")
    func theFiveDeadlinesAreDistinct() {
        let policy = IntegrationLifecycle.distinctPolicy()
        let deadlines = SessionCleanupReason.allCases.map { policy.deadline(for: $0).milliseconds }
        #expect(Set(deadlines).count == SessionCleanupReason.allCases.count)
    }

    @Test("Every end reason maps to exactly one cleanup reason, and back")
    func theReasonMappingIsABijection() {
        #expect(
            Set(SessionEndReason.allCases.map(\.cleanupReason))
                == Set(SessionCleanupReason.allCases)
        )
        for reason in SessionCleanupReason.allCases {
            #expect(reason.endReason.cleanupReason == reason)
        }
        for reason in SessionEndReason.allCases {
            #expect(reason.cleanupReason.endReason == reason)
        }
    }

    @Test(
        "Each terminal outcome selects its own deadline before any deletion happens",
        arguments: [SessionEndReason.completed, .cancelled, .error]
    )
    func aTerminalOutcomeSelectsItsOwnDeadline(reason: SessionEndReason) async throws {
        let policy = IntegrationLifecycle.distinctPolicy()
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let cleanup = SessionTerminalCleanup(deleter: deleter, policy: policy)
        let sessionID = PortValue.sessionID("session-cleanup")
        _ = try await store.writeComplete(
            PortValue.bytes(count: 128),
            in: .session(sessionID),
            protection: .completeUntilFirstUserAuthentication
        )
        let outcome = try integrationTerminal(
            reason,
            sessionID: sessionID,
            report: try await IntegrationReport.make()
        )

        let selected = cleanup.deadline(for: outcome)
        let result = await cleanup.removeMaterial(for: sessionID, after: outcome)

        #expect(selected == policy.deadline(for: reason.cleanupReason))
        let receipt = try #require(result.receipt)
        #expect(receipt.reason == reason.cleanupReason)
        #expect(receipt.deadline == selected)
        #expect(receipt.removedObjectCount == 1)
        // The other four numbers are not this one.
        for other in SessionCleanupReason.allCases where other != reason.cleanupReason {
            #expect(receipt.deadline != policy.deadline(for: other))
        }
        #expect(await store.keys(in: .session(sessionID)).isEmpty)
    }

    @Test(
        "The interrupted and abandoned deadlines are selected by their own reasons",
        arguments: [SessionEndReason.interrupted, .abandoned]
    )
    func theNonTerminalReasonsSelectTheirOwnDeadlines(reason: SessionEndReason) async throws {
        // Neither reason is a terminal outcome, so neither is reachable through
        // `SessionTerminalCleanup`. Both are reached through the deletion port, which is
        // where a start-time sweep reaches them.
        let policy = IntegrationLifecycle.distinctPolicy()
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let sessionID = PortValue.sessionID("session-interrupted")
        _ = try await store.writeComplete(
            PortValue.bytes(count: 64),
            in: .session(sessionID),
            protection: .completeUntilFirstUserAuthentication
        )

        let receipt: SessionDeletionReceipt
        if reason == .abandoned {
            receipt = try #require(await deleter.deleteAbandonedData(policy: policy).first)
        } else {
            receipt = try await deleter.deleteSession(sessionID, reason: reason, policy: policy)
        }

        #expect(receipt.reason == reason.cleanupReason)
        #expect(receipt.deadline == policy.deadline(for: reason.cleanupReason))
        for other in SessionCleanupReason.allCases where other != reason.cleanupReason {
            #expect(receipt.deadline != policy.deadline(for: other))
        }
        #expect(await store.occupiedScopes().isEmpty)
    }

    @Test("Repeating a cleanup succeeds under the same deadline and removes nothing")
    func repeatedCleanupIsIdempotent() async throws {
        let policy = IntegrationLifecycle.distinctPolicy()
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let cleanup = SessionTerminalCleanup(deleter: deleter, policy: policy)
        let sessionID = PortValue.sessionID("session-repeat")
        _ = try await store.writeComplete(
            PortValue.bytes(count: 128),
            in: .session(sessionID),
            protection: .completeUntilFirstUserAuthentication
        )

        let first = await cleanup.removeMaterial(for: sessionID, after: .cancelled)
        let second = await cleanup.removeMaterial(for: sessionID, after: .cancelled)

        #expect(first.receipt?.removedObjectCount == 1)
        #expect(second.receipt?.removedObjectCount == 0)
        #expect(second.receipt?.deadline == policy.deadline(for: .cancelled))
    }

    @Test("A store refusal is a cleanup fault and never an Analysis Error")
    func aCleanupFailureIsNotAnAnalysisOutcome() async throws {
        let policy = IntegrationLifecycle.distinctPolicy()
        let clock = VirtualSessionClock()
        let store = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(store: store, clock: clock)
        let cleanup = SessionTerminalCleanup(deleter: deleter, policy: policy)
        let sessionID = PortValue.sessionID("session-refused")
        _ = try await store.writeComplete(
            PortValue.bytes(count: 32),
            in: .session(sessionID),
            protection: .completeUntilFirstUserAuthentication
        )
        await store.failNextOperation(with: .storeUnavailable)

        let result = await cleanup.removeMaterial(for: sessionID, after: .cancelled)

        #expect(result.isRemoved == false)
        #expect(result.storeFault == .storeUnavailable)
        // Material with no terminal deletion receipt is exactly what the next start removes
        // as abandoned.
        #expect(await store.occupiedScopes().isEmpty == false)
    }

    @Test(
        "The coordinator's own end path audits each terminal against its own deadline",
        arguments: [SessionEndReason.completed, .cancelled, .error]
    )
    func theCoordinatorSelectsTheCommittedOutcomesDeadline(
        reason: SessionEndReason
    ) async throws {
        let harness = try await MatrixHarness.fullComposition(
            logit: reason == .error
                ? StubOutcome(alwaysFailing: .analysis(.inferenceError, stage: .inference))
                : nil,
            gateAt: reason == .cancelled ? .inference : nil
        )
        let asset = try await harness.release.acceptedIngest()

        let session: CompletedAnalysisSession
        if reason == .cancelled {
            async let running = harness.coordinator.analyze(asset)
            await harness.gate.waitUntilReached()
            let identity = try #require(await harness.coordinator.activeIdentity())
            await harness.coordinator.requestCancellation(for: identity)
            await harness.gate.openGate()
            session = try #require(await running.completed)
        } else {
            session = try #require(await harness.coordinator.analyze(asset).completed)
        }

        let receipt = try #require(session.cleanup.receipt)
        #expect(session.outcome.endReason == reason)
        #expect(receipt.reason == reason.cleanupReason)
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: reason.cleanupReason))
        for other in SessionCleanupReason.allCases where other != reason.cleanupReason {
            #expect(receipt.deadline != IntegrationLifecycle.deadline(for: other))
        }
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }
}

// MARK: - Axis: resource breach

/// One stage at which a resource breach can end a session.
struct ResourceBreachCell: Sendable, CustomStringConvertible {
    let stage: AnalysisStage
    let port: FaultingPort

    var description: String { "resource-limit@\(stage.rawValue)" }
}

@Suite("Integration matrix: a resource breach ends the session with no evidence")
struct IntegrationMatrixResourceBreachTests {

    /// The stages a runtime resource check fires at inside the coordinator's pipeline.
    static let cells: [ResourceBreachCell] = [
        ResourceBreachCell(stage: .inputValidation, port: .validator),
        ResourceBreachCell(stage: .preprocessing, port: .preprocessor),
        ResourceBreachCell(stage: .modelLoad, port: .modelLoader),
        ResourceBreachCell(stage: .inference, port: .analyzer),
    ]

    @Test(
        "A breach at any governed stage commits resource-limit and no evidence",
        arguments: cells
    )
    func aBreachCommitsResourceLimitOnly(cell: ResourceBreachCell) async throws {
        let fault = AnalysisFault.analysis(.resourceLimit, stage: cell.stage)
        let harness = try await MatrixHarness.fullComposition(
            validated: cell.port == .validator ? StubOutcome(alwaysFailing: fault) : nil,
            prepared: cell.port == .preprocessor ? StubOutcome(alwaysFailing: fault) : nil,
            model: cell.port == .modelLoader ? StubOutcome(alwaysFailing: fault) : nil,
            logit: cell.port == .analyzer ? StubOutcome(alwaysFailing: fault) : nil
        )
        let asset = try await harness.release.acceptedIngest()

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.error == .resourceLimit)
        #expect(session.outcome.failure?.stage == cell.stage)
        #expect(session.evidenceReport == nil)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
        // Cleanup still starts: a breach ends the session and removes its material under the
        // error deadline (Requirements 11.6 and 9.8).
        #expect(session.cleanup.receipt?.reason == .errorTerminated)
        #expect(
            session.cleanup.receipt?.deadline
                == IntegrationLifecycle.deadline(for: .errorTerminated)
        )
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test(
        "Every required main-application metric breaches as exactly resource-limit",
        arguments: ResourceMetric.requiredMetrics(for: .mainApplication)
            .sorted { $0.rawValue < $1.rawValue }
    )
    func everyMeasuredBreachIsResourceLimit(metric: ResourceMetric) async throws {
        // One controller per required metric, driven over its limit. The controller has one
        // Analysis Error to emit, so no metric can widen the closed vocabulary.
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )
        if metric.isCategorical {
            await governor.setThermalState(.critical)
        } else {
            await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: metric)
        }

        await #expect(throws: AnalysisFault.analysis(.resourceLimit, stage: .inference)) {
            try await controller.checkpoint(metric, at: .inference)
        }
        let breach = try #require(await controller.currentBreach())
        #expect(breach.metric == metric)
        #expect(breach.stage == .inference)
        #expect(breach.target == .mainApplication)
        #expect(breach.fault == .analysis(.resourceLimit, stage: .inference))
    }

    @Test("A main-application breach forbids every gated commit afterwards")
    func aBreachForbidsTheEvidenceCommit() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )
        #expect(await controller.permits(.evidenceReport))
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .peakResidentMemory)

        _ = try? await controller.checkpoint(.peakResidentMemory, at: .inference)

        // The two halves of Requirements 11.6 and 11.8: the affected work stopped, and no
        // gated commit is permitted afterwards, for either target's commit.
        #expect(await controller.permits(.evidenceReport) == false)
        #expect(await controller.permits(.readyTransferTicket) == false)
        // A later within-limit reading cannot revive a session the controller stopped.
        await governor.setReading(0, for: .peakResidentMemory)
        #expect(await controller.permits(.evidenceReport) == false)
    }

    @Test("A breach cancels registered sibling work and returns outstanding headroom")
    func aBreachStopsSiblingWorkAndReleasesHeadroom() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )
        let cancellations = LockedList<Int>()
        _ = await controller.registerSiblingWork { cancellations.append(1) }
        _ = await controller.registerSiblingWork { cancellations.append(2) }
        _ = try await controller.reserve(
            .temporaryStorage,
            amount: Fixture.positive(10),
            unit: .bytes,
            at: .inputValidation
        )
        await governor.setReading(ResourceFixture.defaultLimitValue + 1, for: .energyImpact)

        _ = try? await controller.checkpoint(.energyImpact, at: .inference)

        // Registration order, once each, and every reservation handed back.
        #expect(cancellations.values == [1, 2])
        #expect(await controller.outstandingReservations().isEmpty)
        #expect(await governor.heldReservations().isEmpty)
    }

    @Test("Cancellation from the resource port stays cancellation and latches no breach")
    func aCancelledReservationIsNotABreach() async throws {
        let governor = RecordingResourceGovernor(target: .mainApplication)
        let controller = try #require(
            ResourceController(
                target: .mainApplication,
                budgets: ResourceFixture.budgetSet(),
                governor: governor
            )
        )
        await governor.setReserveOutcome(.cancelled)

        await #expect(throws: AnalysisFault.cancelled) {
            _ = try await controller.reserve(
                .temporaryStorage,
                amount: Fixture.positive(1),
                unit: .bytes,
                at: .preprocessing
            )
        }
        // Cancellation is a separate terminal outcome with no Analysis Error category, so it
        // must not latch a breach that would outlive it.
        #expect(await controller.currentBreach() == nil)
        #expect(await controller.permits(.evidenceReport))
    }

    @Test("A controller governs one target and refuses the other target's governor")
    func aControllerCannotBeBuiltAcrossTargets() {
        // A substituted budget is unrepresentable rather than a runtime check that could be
        // skipped (Requirement 11.1).
        for target in ExecutionTarget.allCases {
            for governed in ExecutionTarget.allCases {
                let controller = ResourceController(
                    target: target,
                    budgets: ResourceFixture.budgetSet(),
                    governor: FakeResourceGovernor(target: governed)
                )
                #expect((controller != nil) == (target == governed))
            }
        }
    }
}

// MARK: - Axis: cancellation point

@Suite("Integration matrix: a cancellation request at every suspension")
struct IntegrationMatrixCancellationPointTests {

    /// Calls that must not follow a cancellation landing at each gate point.
    static let forbiddenAfter: [PipelineGatePoint: [PortCallKind]] = [
        .inputValidation: [
            .preprocess, .loadModel, .infer, .calibrate, .provenanceAnalyze, .fuse,
        ],
        .preprocessing: [.loadModel, .infer, .calibrate, .provenanceAnalyze, .fuse],
        .modelLoad: [.infer, .calibrate, .provenanceAnalyze, .fuse],
        .inference: [.calibrate, .provenanceAnalyze, .fuse],
        .provenanceValidation: [.fuse],
    ]

    @Test(
        "A request landing at any pipeline suspension makes cancelled the only terminal",
        arguments: PipelineGatePoint.allCases
    )
    func everyGatePointCommitsOnlyTheCancelledTerminal(point: PipelineGatePoint) async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: point)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let result = await harness.coordinator.requestCancellation(for: identity)
        // The slot is occupied before the request returns, not after the suspended port
        // resumes: that is what "immediately disables all future evidence commits" means.
        let standingWhileSuspended = await harness.coordinator.committedTerminal()
        let requestedWhileSuspended = await harness.coordinator.isCancellationRequested()
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(result.latchedRequest)
        #expect(result.isCancelled)
        #expect(requestedWhileSuspended)
        #expect(standingWhileSuspended == .cancelled)
        #expect(session.outcome == .cancelled)
        #expect(session.evidenceReport == nil)
        // Cancellation is not an Analysis Error, so it carries no category and no stage.
        #expect(session.error == nil)
        #expect(session.outcome.failure == nil)
        // Cleanup runs under the cancellation deadline, and that number is not any other
        // reason's under this policy.
        let receipt = try #require(session.cleanup.receipt)
        #expect(receipt.reason == .cancelled)
        #expect(receipt.deadline == IntegrationLifecycle.deadline(for: .cancelled))
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test(
        "The stage the request landed in is the last work the session performs",
        arguments: PipelineGatePoint.allCases
    )
    func nothingDownstreamOfTheCancellationPointRuns(point: PipelineGatePoint) async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: point)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        // The suspended port completes anyway, which is the framework call the design says
        // cannot be forcibly preempted once entered. Its result is discarded by identity.
        await harness.gate.openGate()
        _ = try #require(await running.completed)

        let forbidden = try #require(Self.forbiddenAfter[point])
        for kind in forbidden {
            #expect(harness.recorder.didCall(kind) == false)
        }
        #expect(harness.recorder.callCount(of: .validate) == 1)
    }

    @Test("A session started in an already cancelled task reads no byte and loads no model")
    func anAlreadyCancelledTaskPerformsNoWork() async throws {
        let harness = try await MatrixHarness.fullComposition()
        let asset = try await harness.release.acceptedIngest()

        // The rendezvous makes the ordering the test's rather than a race: the task is
        // cancelled while it waits, and only then released into `analyze`.
        let held = BranchGate()
        let handle = Task {
            await held.enter()
            return await harness.coordinator.analyze(asset)
        }
        handle.cancel()
        await held.openGate()
        let session = try #require(await handle.value.completed)

        #expect(session.outcome == .cancelled)
        // Requirement 11.14: no decode, no preprocessing, no model load, no inference, no
        // provenance validation, no fusion.
        #expect(harness.recorder.producedNoEvidenceWork)
        #expect(session.cleanup.receipt?.reason == .cancelled)
        #expect(session.cleanup.receipt?.deadline == IntegrationLifecycle.deadline(for: .cancelled))
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("A cancelled enclosing task can never produce a completed terminal")
    func anExternallyCancelledTaskNeverCompletes() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        // No `requestCancellation` at all: cancellation arrives only from outside, by
        // cancelling the task the session runs in. The pipeline would otherwise reach its
        // completed terminal, which is exactly what Requirement 15.7 forbids here.
        let handle = Task { await harness.coordinator.analyze(asset) }
        await harness.gate.waitUntilReached()
        handle.cancel()
        await harness.gate.openGate()
        let session = try #require(await handle.value.completed)

        #expect(session.outcome == .cancelled)
        #expect(session.evidenceReport == nil)
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
    }

    @Test("Cancelling the coordinator's own task stops the pipeline cooperatively")
    func theCoordinatorCancelsTheTaskItStarted() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        let task = try #require(await harness.coordinator.startAnalysis(of: asset))
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let result = await harness.coordinator.requestCancellation(for: identity)
        await harness.gate.openGate()
        let session = try #require(await task.value.completed)

        #expect(result.cancelledStructuredTask)
        #expect(session.outcome == .cancelled)
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
    }

    @Test("There is no cancellation checkpoint between building the report and committing")
    func aRequestCannotInterleaveTheJoinAndTheCommit() async throws {
        // The real behaviour, recorded rather than wished for. Joining the lanes, resolving
        // fusion, building the report, and claiming the terminal are one synchronous actor
        // step, so a request cannot land between them: it either precedes the join and wins,
        // or follows the commit and is refused. A session that reaches the join therefore
        // completes and publishes, and a cancellation arriving at that instant has no
        // checkpoint to land on. The same shape exists outside this module between manifest
        // finalize and atomic promotion, where a cancelled task commits and publishes; that
        // path is not reachable from this test target's module closure and is reported here
        // rather than fixed.
        let harness = try await MatrixHarness.fullComposition(gateAt: .provenanceValidation)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        // Released first, so the session runs through the join, and only then is the request
        // made. There is no third possibility available to test.
        await harness.gate.openGate()
        let session = try #require(await running.completed)
        let afterCommit = await harness.coordinator.requestCancellation(for: identity)

        #expect(session.outcome.isCompleted)
        #expect(session.evidenceReport != nil)
        // The session already ended, so the request finds nothing and changes nothing.
        #expect(afterCommit.commit == .refusedNoActiveSession)
        #expect(afterCommit.latchedRequest == false)
    }

    @Test("A repeated request latches once and invokes no hook twice")
    func aRepeatedRequestChangesNothing() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let invocations = LockedList<Int>()
        await harness.coordinator.registerCancellationHook(for: identity) {
            invocations.append(1)
        }
        let first = await harness.coordinator.requestCancellation(for: identity)
        let second = await harness.coordinator.requestCancellation(for: identity)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(first.latchedRequest)
        #expect(first.invokedHookCount == 1)
        #expect(second.latchedRequest == false)
        #expect(second.invokedHookCount == 0)
        #expect(second.standingOutcome == .cancelled)
        #expect(invocations.values == [1])
        #expect(session.outcome == .cancelled)
    }

    @Test("A request naming an attempt that is not running is refused by identity")
    func aStaleRequestIsRefused() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let stale = AnalysisSessionIdentity(
            sessionID: identity.sessionID,
            generation: identity.generation + 1
        )
        let refused = await harness.coordinator.requestCancellation(for: stale)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(refused.commit == .refusedStaleIdentity(offered: stale))
        #expect(refused.latchedRequest == false)
        // Nothing was stopped, so the running session completed normally.
        #expect(session.outcome.isCompleted)
    }

    @Test("A request that finds a non-cancelled terminal leaves that terminal standing")
    func aRequestAfterAMidFlightFailureIsRefusedAtTheSlot() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let standing = try integrationTerminal(
            .error,
            sessionID: identity.sessionID,
            report: try await IntegrationReport.make()
        )
        await harness.coordinator.commitTerminal(standing, for: identity)
        // The user activates the cancel control after a breach already ended the session.
        let result = await harness.coordinator.requestCancellation(for: identity)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(result.commit == .refusedAlreadyTerminal(standing))
        #expect(result.isCancelled == false)
        // The request is recorded but stopped nothing: the session was already ending
        // through its own path, and cancelling that would risk aborting its removal.
        #expect(result.latchedRequest)
        #expect(result.cancelledStructuredTask == false)
        #expect(session.outcome == standing)
        #expect(session.cleanup.receipt?.reason == .errorTerminated)
    }
}

// MARK: - Axis: late callback

@Suite("Integration matrix: late results are refused by identity and by the slot")
struct IntegrationMatrixLateCallbackTests {

    @Test("A running attempt with no terminal admits its own results")
    func aRunningAttemptAdmitsResults() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let admission = await harness.coordinator.admitFrameworkResult(for: identity)
        let admitted = await harness.coordinator.admit(1.5, for: identity)
        await harness.gate.openGate()
        _ = await running

        #expect(admission == .admitted)
        #expect(admission.isAdmitted)
        #expect(admitted.value == 1.5)
        #expect(admitted.discardedBecause == nil)
    }

    @Test(
        "A result offered after any terminal is discarded, carrying that terminal",
        arguments: [SessionEndReason.completed, .cancelled, .error]
    )
    func aResultAfterAnyTerminalIsDiscarded(reason: SessionEndReason) async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()
        let donor = try await IntegrationReport.make()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let standing = try integrationTerminal(
            reason,
            sessionID: identity.sessionID,
            report: donor
        )
        await harness.coordinator.commitTerminal(standing, for: identity)
        let admission = await harness.coordinator.admitFrameworkResult(for: identity)
        let admitted = await harness.coordinator.admit(1.5, for: identity)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(admission == .discardedTerminalCommitted(standing))
        #expect(admission.isAdmitted == false)
        #expect(admission.standingOutcome == standing)
        #expect(admission.wasDiscardedByCancellation == (reason == .cancelled))
        // A discarded case carries no value at all, so an ignored refusal still cannot reach
        // the result.
        #expect(admitted.value == nil)
        #expect(session.outcome == standing)
    }

    @Test("A result naming an earlier generation of the same identifier is stale")
    func anEarlierGenerationIsStale() async throws {
        // The gate is armed for the *second* validation call, so the first session completes
        // and the second one is held open while the first attempt's identity is offered.
        let harness = try await MatrixHarness.fullComposition(
            gateAt: .inputValidation,
            gateCallNumber: 2
        )
        let first = try await harness.release.acceptedIngest(byteSeed: 1)
        _ = await harness.coordinator.analyze(first)
        let firstIdentity = AnalysisSessionIdentity(sessionID: first.sessionID, generation: 1)
        let second = try await harness.release.acceptedIngest(byteSeed: 2)

        async let running = harness.coordinator.analyze(second)
        await harness.gate.waitUntilReached()
        let current = try #require(await harness.coordinator.activeIdentity())
        let admission = await harness.coordinator.admitFrameworkResult(for: firstIdentity)
        await harness.gate.openGate()
        _ = await running

        // The identifier matches and the generation does not, which is exactly why the
        // generation exists: a released identifier can be bound again.
        #expect(current.sessionID == firstIdentity.sessionID)
        #expect(current.generation == 2)
        #expect(admission == .discardedStaleIdentity(offered: firstIdentity))
        #expect(admission.standingOutcome == nil)
    }

    @Test("A result offered while the coordinator is idle belongs to nothing")
    func anIdleCoordinatorDiscardsEveryResult() async throws {
        let harness = try await MatrixHarness.fullComposition()
        let asset = try await harness.release.acceptedIngest()
        _ = await harness.coordinator.analyze(asset)

        let admission = await harness.coordinator.admitFrameworkResult(
            for: AnalysisSessionIdentity(sessionID: asset.sessionID, generation: 1)
        )

        #expect(admission == .discardedNoActiveSession)
        #expect(admission.standingOutcome == nil)
    }

    @Test("The whole admission vocabulary is exercised")
    func everyAdmissionCaseIsCovered() {
        // `FrameworkResultAdmission` is not `CaseIterable` because two cases carry payloads,
        // so coverage is asserted by construction: these four are the whole vocabulary, and
        // each has a behavioural test above.
        let cancelled = FrameworkResultAdmission.discardedTerminalCommitted(.cancelled)
        let stale = FrameworkResultAdmission.discardedStaleIdentity(
            offered: AnalysisSessionIdentity(sessionID: PortValue.sessionID(), generation: 1)
        )
        #expect(FrameworkResultAdmission.admitted.isAdmitted)
        #expect(cancelled.wasDiscardedByCancellation)
        #expect(cancelled.standingOutcome == .cancelled)
        #expect(stale.isAdmitted == false)
        #expect(FrameworkResultAdmission.discardedNoActiveSession.standingOutcome == nil)
    }

    @Test(
        "Every offered terminal is refused against every standing terminal",
        arguments: [SessionEndReason.completed, .cancelled, .error],
        [SessionEndReason.completed, .cancelled, .error]
    )
    func aLateCommitIsRefusedAgainstEveryStandingTerminal(
        standingReason: SessionEndReason,
        offeredReason: SessionEndReason
    ) async throws {
        // The nine-cell monotonicity matrix: `completed`, `cancelled`, and `failed` cannot
        // transition into one another, including into themselves.
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()
        let donor = try await IntegrationReport.make()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let standing = try integrationTerminal(
            standingReason,
            sessionID: identity.sessionID,
            report: donor
        )
        await harness.coordinator.commitTerminal(standing, for: identity)
        let offered = try integrationTerminal(
            offeredReason,
            sessionID: identity.sessionID,
            report: donor
        )
        let refusal = await harness.coordinator.commitTerminal(offered, for: identity)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(refusal == .refusedAlreadyTerminal(standing))
        #expect(refusal.didCommit == false)
        // Committing twice cannot change the answer, and the standing outcome is reported
        // unchanged rather than replaced.
        #expect(refusal.standingOutcome == standing)
        #expect(session.outcome == standing)
        #expect(session.cleanup.receipt?.reason == standingReason.cleanupReason)
        #expect(
            session.cleanup.receipt?.deadline
                == IntegrationLifecycle.deadline(for: standingReason.cleanupReason)
        )
    }

    @Test("A commit offered for another attempt is refused before the slot is consulted")
    func aCommitForAnotherAttemptIsRefusedByIdentity() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let stale = AnalysisSessionIdentity(
            sessionID: identity.sessionID,
            generation: identity.generation + 7
        )
        let refusal = await harness.coordinator.commitTerminal(.cancelled, for: stale)
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(refusal == .refusedStaleIdentity(offered: stale))
        #expect(refusal.standingOutcome == nil)
        // The running attempt was untouched by the refused offer.
        #expect(session.outcome.isCompleted)
    }

    @Test("A hook registered after a terminal stands is invoked immediately, not stored")
    func aHookRegisteredTooLateFiresAtOnce() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        let invocations = LockedList<Int>()
        await harness.coordinator.registerCancellationHook(for: identity) {
            invocations.append(1)
        }
        let firedBeforeResume = invocations.values
        await harness.gate.openGate()
        _ = await running

        // Work that starts in the window after a session ended must not keep running, so
        // the hook fires now rather than being queued to be discarded unfired.
        #expect(firedBeforeResume == [1])
        #expect(invocations.values == [1])
    }

    @Test("Hooks fire once each, in registration order, and do not survive the session")
    func hooksFireInOrderAndAreDiscardedWithTheAttempt() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        let invocations = LockedList<Int>()
        for number in 1...3 {
            await harness.coordinator.registerCancellationHook(for: identity) {
                invocations.append(number)
            }
        }
        let withdrawn = await harness.coordinator.registerCancellationHook(for: identity) {
            invocations.append(99)
        }
        await harness.coordinator.withdrawCancellationHook(withdrawn)
        let result = await harness.coordinator.requestCancellation(for: identity)
        await harness.gate.openGate()
        _ = await running
        // The attempt is gone, so a later request finds no stale hook to invoke.
        let afterEnd = await harness.coordinator.requestCancellation(for: identity)

        #expect(invocations.values == [1, 2, 3])
        #expect(result.invokedHookCount == 3)
        #expect(afterEnd.invokedHookCount == 0)
        #expect(afterEnd.commit == .refusedNoActiveSession)
    }

    @Test("An unpreempted prediction that returns after cancellation is never calibrated")
    func anUnpreemptedPredictionIsDiscarded() async throws {
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        let identity = try #require(await harness.coordinator.activeIdentity())
        await harness.coordinator.requestCancellation(for: identity)
        // The gated analyzer returns its logit *after* the request, which is exactly the
        // framework call the design says cannot be forcibly preempted once entered.
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(harness.recorder.callCount(of: .infer) == 1)
        // Nothing downstream of the discarded logit ran, so no Pixel Evidence, no provenance
        // lane, and no summary exist for the cancelled session even to be refused later.
        #expect(harness.recorder.didCall(PortCallKind.calibrate) == false)
        #expect(harness.recorder.didCall(PortCallKind.provenanceAnalyze) == false)
        #expect(harness.recorder.didCall(PortCallKind.fuse) == false)
        #expect(session.outcome == .cancelled)
    }
}

// MARK: - Axis: progress, and the ephemeral protection posture

@Suite("Integration matrix: honest progress and the ephemeral protection posture")
struct IntegrationMatrixProgressAndProtectionTests {

    @Test("Every stage with no measurement reports continuing, indeterminate work")
    func everyStageHasAnHonestIndeterminateState() {
        // Requirements 15.1 and 15.4: active work always has something honest to display, and
        // an unmeasured stage is continuing rather than stalled, completed, or failed.
        for stage in AnalysisStage.allCases {
            let derived = DerivedAnalysisProgress(at: stage)
            #expect(derived.stage == stage)
            #expect(derived.isDeterminate == false)
            #expect(derived.state == .indeterminate(stage: stage))
            #expect(derived.fractionOfWorkCompleted == nil)
            #expect(derived.percentage == nil)
            #expect(derived.indeterminateAssertion == .analysisIsContinuing)
            #expect(derived.unmeasuredCause == .nothingReported)
        }
    }

    /// One reported shape per refusal cause, so every prerequisite is exercised.
    static func report(for cause: UnmeasuredProgressCause) -> ReportedWork? {
        func amount(
            _ value: UInt64,
            _ unit: ProgressUnit = .encodedBytes,
            _ reliability: WorkMeasurementReliability = .reliable
        ) -> WorkAmount {
            WorkAmount(amount: value, unit: unit, reliability: reliability)
        }
        switch cause {
        case .nothingReported:
            return nil
        case .completedAmountMissing:
            return ReportedWork(completed: nil, total: amount(100))
        case .totalAmountMissing:
            return ReportedWork(completed: amount(10), total: nil)
        case .unitMismatch:
            return ReportedWork(
                completed: amount(10, .encodedBytes),
                total: amount(100, .imageRows)
            )
        case .unreliableCompletedAmount:
            return ReportedWork(
                completed: amount(10, .encodedBytes, .unreliable),
                total: amount(100)
            )
        case .unreliableTotalAmount:
            return ReportedWork(
                completed: amount(10),
                total: amount(100, .encodedBytes, .unreliable)
            )
        case .totalIsNotPositive:
            return ReportedWork(completed: amount(0), total: amount(0))
        case .completedExceedsTotal:
            return ReportedWork(completed: amount(101), total: amount(100))
        }
    }

    @Test(
        "Each missing prerequisite refuses a fraction and names its own cause",
        arguments: [
            UnmeasuredProgressCause.nothingReported,
            .completedAmountMissing,
            .totalAmountMissing,
            .unitMismatch(completed: .encodedBytes, total: .imageRows),
            .unreliableCompletedAmount,
            .unreliableTotalAmount,
            .totalIsNotPositive,
            .completedExceedsTotal,
        ]
    )
    func eachRefusalCauseIsReachedExactly(cause: UnmeasuredProgressCause) {
        let derived = DerivedAnalysisProgress(
            reported: Self.report(for: cause),
            at: .inputValidation
        )

        #expect(derived.isDeterminate == false)
        #expect(derived.unmeasuredCause == cause)
        // Nothing is repaired, clamped, or substituted: a refused fraction is absent rather
        // than shown as zero (Requirement 15.3).
        #expect(derived.fractionOfWorkCompleted == nil)
        #expect(derived.percentage == nil)
        #expect(derived.indeterminateAssertion == .analysisIsContinuing)
    }

    @Test("A reliable, comparable, in-range report yields analysis work progress")
    func aMeasuredReportYieldsWorkProgress() throws {
        let derived = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: WorkAmount(amount: 50, unit: .encodedBytes, reliability: .reliable),
                total: WorkAmount(amount: 200, unit: .encodedBytes, reliability: .reliable)
            ),
            at: .inputValidation
        )

        #expect(derived.isDeterminate)
        #expect(derived.unmeasuredCause == nil)
        #expect(derived.fractionOfWorkCompleted == 0.25)
        let percentage = try #require(derived.percentage)
        #expect(percentage.percent == 25)
        #expect(percentage.unit == .encodedBytes)
        #expect(percentage.stage == .inputValidation)
        // Labeled by its type, so a percentage can never be read as a result probability or
        // confidence (Requirement 15.11).
        #expect(AnalysisWorkPercentage.semantics == .analysisWorkProgress)
        #expect(ProgressQuantitySemantics.allCases == [.analysisWorkProgress])
        #expect(IndeterminateProgressAssertion.allCases == [.analysisIsContinuing])
    }

    @Test("The derived percentage is inexact, and this records the real arithmetic")
    func theDerivedPercentageIsInexact() throws {
        // A defect, reported and not fixed. `29/100` is not representable in binary floating
        // point, so the percentage is 28.999999999999996 and truncating it yields 28. The
        // assertion states what the code does rather than what a reader would assume.
        let derived = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: WorkAmount(amount: 29, unit: .encodedBytes, reliability: .reliable),
                total: WorkAmount(amount: 100, unit: .encodedBytes, reliability: .reliable)
            ),
            at: .preprocessing
        )
        let percentage = try #require(derived.percentage)

        #expect(percentage.percent != 29)
        #expect(Int(percentage.percent) == 28)
        #expect(abs(percentage.percent - 29) < 1e-12)
    }

    @Test("Above 2^53 the fraction reads complete while work remains")
    func aHugeTotalReadsCompleteWithWorkRemaining() throws {
        // The second half of the same defect, reported and not fixed. `Double(completed)` and
        // `Double(total)` collapse onto one value above 2^53, so a report with work genuinely
        // left reads exactly 100 percent.
        let completed: UInt64 = 1 << 53
        let total: UInt64 = (1 << 53) + 1
        let derived = DerivedAnalysisProgress(
            reported: ReportedWork(
                completed: WorkAmount(
                    amount: completed,
                    unit: .encodedBytes,
                    reliability: .reliable
                ),
                total: WorkAmount(amount: total, unit: .encodedBytes, reliability: .reliable)
            ),
            at: .inputValidation
        )
        let percentage = try #require(derived.percentage)

        #expect(completed < total)
        #expect(derived.fractionOfWorkCompleted == 1.0)
        #expect(percentage.percent == 100.0)
    }

    @Test("Progress carries no clock, so no terminal decision can be derived from time")
    func progressStaysActiveHoweverMuchTimePasses() async throws {
        // Requirement 15.10 and the design's "no unmeasured analysis timeout": the clock is
        // advanced far past every deadline in the policy while a session is suspended inside
        // inference, and the session stays active with honest progress.
        let harness = try await MatrixHarness.fullComposition(gateAt: .inference)
        let asset = try await harness.release.acceptedIngest()

        async let running = harness.coordinator.analyze(asset)
        await harness.gate.waitUntilReached()
        for reason in SessionCleanupReason.allCases {
            harness.release.clock.advancePast(IntegrationLifecycle.deadline(for: reason))
        }
        harness.release.clock.advance(by: .seconds(86_400))
        let identity = await harness.coordinator.activeIdentity()
        let terminal = await harness.coordinator.committedTerminal()
        let stage = await harness.coordinator.currentStage()
        await harness.gate.openGate()
        let session = try #require(await running.completed)

        #expect(identity != nil)
        #expect(terminal == nil)
        #expect(stage == .inference)
        #expect(
            DerivedAnalysisProgress(at: .inference).indeterminateAssertion
                == .analysisIsContinuing
        )
        // The session ends because its work finished, never because time passed.
        #expect(session.outcome.isCompleted)
    }

    @Test(
        "A write receipt records the protection level it was asked for",
        arguments: FileProtectionLevel.allCases
    )
    func aReceiptCarriesTheRequestedProtectionLevel(level: FileProtectionLevel) async throws {
        // Structural coverage of Requirement 9.6 only. This store holds bytes in memory and
        // creates no file, so nothing here shows that iOS applied the level; what it shows is
        // that the requested level travels with the receipt rather than being dropped.
        let store = InMemoryEphemeralStore(clock: VirtualSessionClock())
        let sessionID = PortValue.sessionID("session-protection")

        let receipt = try await store.writeComplete(
            PortValue.bytes(count: 64),
            in: .session(sessionID),
            protection: level
        )

        #expect(receipt.protection == level)
        #expect(receipt.scope == .session(sessionID))
    }

    @Test(
        "A protection level the platform refuses fails closed rather than downgrading",
        arguments: FileProtectionLevel.allCases
    )
    func aRefusedProtectionLevelFailsClosed(level: FileProtectionLevel) async throws {
        // Unprotected bytes are not an acceptable fallback, so a refused level is an error
        // and never a quieter level applied silently.
        let store = InMemoryEphemeralStore(clock: VirtualSessionClock())
        await store.failAllProtectionRequests(level)

        await #expect(throws: EphemeralStoreError.protectionUnavailable(level)) {
            _ = try await store.create(
                in: .session(PortValue.sessionID("session-refused")),
                protection: level
            )
        }
        #expect(await store.occupiedScopes().isEmpty)
    }

    @Test("A session's ephemeral material is gone once its terminal cleanup ran")
    func noSessionMaterialSurvivesItsTerminal() async throws {
        // Requirement 9.17: once the cleanup for a session has run, no data from that
        // session remains in application-controlled storage. Asserted over the store's own
        // ownership set rather than over a receipt count.
        let harness = try await MatrixHarness.fullComposition()
        let asset = try await harness.release.acceptedIngest()
        #expect(await harness.release.ephemeral.keys(in: .session(asset.sessionID)).count == 1)

        let session = try #require(await harness.coordinator.analyze(asset).completed)

        #expect(session.cleanup.isRemoved)
        #expect(await harness.release.ephemeral.keys(in: .session(asset.sessionID)).isEmpty)
        #expect(await harness.release.ephemeral.occupiedScopes().isEmpty)
        #expect(await harness.release.ephemeral.usedByteCount == 0)
    }
}

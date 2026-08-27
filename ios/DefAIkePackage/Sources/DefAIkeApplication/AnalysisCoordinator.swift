import DefAIkeDomain
import DefAIkeProvenanceAPI

// The Analysis Coordinator: the sole mutable owner of Analysis Session state.
//
// Everything the session path needs already exists as a value or a port. What did not
// exist until this file is the *order* those pieces run in, the single point at which a
// terminal outcome becomes final, and the guarantee that a second one cannot. Those three
// are what an actor is for here, and each is structural rather than conventional:
//
//   * **Ordered prerequisites are serial and unskippable.** Bundle binding produces the
//     ``BoundAnalysisSession`` every later stage reads its artifacts from; validation
//     produces the ``ValidatedImage`` preprocessing needs; preprocessing produces the
//     ``ModelImageInput`` inference needs. Each stage's input is the previous stage's
//     return value, so "complete validation precedes inference" is a data dependency and
//     not a check that could be reordered.
//   * **One terminal, written once.** ``TerminalCommitSlot`` compares and sets in one
//     synchronous step, and this actor holds the only slot per session. An actor does not
//     hold its executor across an `await`, so every stage re-reads the slot after every
//     suspension before doing more work — the same lesson bundle activation and session
//     binding already learned. A branch never commits: it returns an outcome, and the join
//     commits once.
//   * **Nothing is retained across sessions.** The whole of a session lives in one
//     optional field. Starting a session replaces that field with a freshly built value
//     and ending one clears it, so a retry cannot inherit bytes, dimensions, a stage, an
//     error, a lane, or a report — there is nowhere to keep them (Requirement 3.15).
//
// What this file deliberately does not do:
//
//   * **It does not verify a handoff or create a session.** `ShareHandoffIngestCoordinator`
//     peeks, claims, reverifies the bytes and status, and terminates a pending session with
//     `handoff-error` before anything here is reachable; `PhotosIngestCoordinator` decides
//     whether a session exists at all. Both hand over one ``ImportedEncodedAsset``, and by
//     Requirement 2.14 the two routes are indistinguishable downstream except for the
//     recorded route. So this actor takes an accepted ingest and cannot express "the
//     handoff failed": there is no member for it and no port to reach.
//
//     One recorded consequence, which is *not* fixable here: `ShareTransferClaiming`'s claim
//     carries no session identity on failure, so the Share route peeks first to learn the
//     pending session and attributes a claim failure to what the peek reported. If the ready
//     slot changes between those two calls, the attributed identifier could be the earlier
//     one. That window opens and closes before an accepted ingest exists, and on the success
//     path the identifier this actor receives comes from the verified claim itself, so there
//     is nothing here to compare against and nothing to correct. Closing it needs either a
//     session identifier on the port's fault or an atomic peek-and-claim, both of which are
//     changes to the domain port rather than to its consumers.
//   * **It does not check a resource metric.** Which metrics gate which stage at runtime is
//     a bound plan decision, and `ResourceController` says so about itself. The validator
//     and the preprocessor already receive the bound ``ResourceBudget``, so a
//     `resource-limit` arrives here as an ordinary port fault at the stage that raised it.
//   * **It does not decide when to cancel.** A cancellation request arrives from the user's
//     visible control through ``AnalysisCoordinator/requestCancellation(for:)``; nothing
//     here derives one from elapsed time, a deadline, or a stalled stage, because there is
//     no clock to derive it from (Requirement 15.10). What the coordinator owns is what
//     happens once a request arrives: the terminal slot is claimed with `cancelled` in the
//     same synchronous step, so evidence commits are disabled from that instant; the
//     session's structured task and every registered framework hook are cancelled; each
//     stage boundary re-checks and stops; and a result that arrives anyway is refused by
//     ``AnalysisSessionIdentity``. ``SessionCancellation.swift`` carries that vocabulary.
//   * **It does not delete anything.** A cancelled session's material is removed on the one
//     end path, under the deadline the committed outcome selects, which is
//     ``SessionTerminalCleanup``'s mapping.
//   * **It does not derive progress or select copy.** ``DerivedAnalysisProgress`` is a pure
//     function of reported work and ``currentStage()``; what a user is shown for any
//     outcome belongs to the Result Presenter.

// MARK: - Branch outcomes

/// What one evidence branch produced: its lane's value, or one fault.
///
/// Deliberately not `Result`, and deliberately not a `throws` call the join catches. A
/// branch that threw into the join would be arbitrated in the order the `await`s were
/// written, which is the wall-clock ordering the design excludes. Returning a value means
/// the join holds *both* branches' outcomes before it decides anything, so
/// ``CausalFaultArbitration`` sees a complete list.
enum BranchOutcome<Value: Sendable>: Sendable {
    case resolved(Value)
    case faulted(AnalysisFault)

    var value: Value? {
        guard case .resolved(let value) = self else { return nil }
        return value
    }

    var fault: AnalysisFault? {
        guard case .faulted(let fault) = self else { return nil }
        return fault
    }
}

// MARK: - What one session produced

/// One Analysis Session that reached a terminal outcome, and what happened around it.
///
/// The terminal outcome is the answer; the rest is what an audit needs and cannot recover
/// afterwards. `cleanup` is here rather than thrown because a cleanup failure is not an
/// analysis outcome: the session already committed its terminal and ``AnalysisError`` has
/// no category for a store that refused a deletion. Unremoved material has no terminal
/// deletion receipt, which is exactly what the next start removes as abandoned before
/// accepting new work (Requirement 11.16).
public struct CompletedAnalysisSession: Hashable, Sendable {
    /// The session attempt this describes.
    public let identity: AnalysisSessionIdentity

    /// The single terminal outcome (Requirement 11.17).
    public let outcome: SessionTerminalOutcome

    /// What removing this session's material did, under the deadline `outcome` selects.
    public let cleanup: SessionCleanupResult

    /// The execution the evidence branches actually ran under.
    ///
    /// Recorded because it is a release-approved policy rather than an implementation
    /// choice, and because a session that ran serially under a plan that approves
    /// concurrency is a fact a device-validation record needs.
    public let branchExecution: EvidenceBranchExecution

    /// A fusion rule that could not be applied, when one was offered.
    ///
    /// Present only alongside a completed outcome with no Combined Summary. The fusion port
    /// is explicit that a rule mismatch is a release-configuration fault and not an
    /// ``AnalysisError``: a session with no summary is a complete, valid session, so the
    /// fault is recorded and the summary omitted rather than the analysis failed
    /// (Requirement 7.16).
    public let fusionFault: FusionFault?

    /// The session identifier.
    public var sessionID: AnalysisSessionID { identity.sessionID }

    /// The Evidence Report, or `nil` for every non-completed outcome.
    public var evidenceReport: EvidenceReport? { outcome.evidenceReport }

    /// The single Analysis Error, or `nil` when the session did not fail.
    public var error: AnalysisError? { outcome.error }
}

/// What one call to analyze an accepted ingest did.
///
/// Two cases, because a coordinator that is already running a session has not started a
/// second one and must not report a terminal outcome for it. Version 1 analyzes exactly one
/// image per session, and one coordinator owns one session at a time.
public enum AnalysisSessionOutcome: Hashable, Sendable {
    /// The session ran and reached its single terminal outcome.
    case ended(CompletedAnalysisSession)

    /// Nothing started: the identified session attempt is still running.
    ///
    /// Not an ``AnalysisError`` and not a terminal outcome. No session was created, no byte
    /// was read, and the running session is untouched.
    case refusedWhileSessionActive(AnalysisSessionIdentity)

    /// The completed session, or `nil` when none ran.
    public var completed: CompletedAnalysisSession? {
        guard case .ended(let session) = self else { return nil }
        return session
    }

    /// The running session that refused this one, or `nil` when a session ran.
    public var refusedIdentity: AnalysisSessionIdentity? {
        guard case .refusedWhileSessionActive(let identity) = self else { return nil }
        return identity
    }

    /// The single terminal outcome, or `nil` when no session ran.
    public var terminalOutcome: SessionTerminalOutcome? { completed?.outcome }
}

// MARK: - The coordinator

/// Runs one Analysis Session at a time and commits exactly one terminal outcome for it.
///
/// An actor because the session's stage, its lane join, and its terminal slot are shared
/// mutable state that two concurrent evidence branches both observe. Every port it drives
/// is `Sendable` and every value that crosses the boundary is a value type, so no framework
/// object escapes its adapter's lifetime.
public actor AnalysisCoordinator {

    // MARK: Collaborators

    /// Binds each accepted input to the active verified Model Bundle exactly once.
    ///
    /// Owned here rather than by the caller so that releasing the snapshot is on the same
    /// path as committing the terminal. A session that ends always releases, which is what
    /// lets the identifier be bound again for a clean retry (Requirement 3.15).
    private let binder: AnalysisSessionBinder

    private let validator: any InputValidating
    private let preprocessor: any ImagePreprocessing
    private let modelLoader: any PixelModelLoading
    private let analyzer: any PixelAnalyzing
    private let calibrator: any PixelCalibrating

    /// The provenance source lane of this composition.
    ///
    /// A pixel-only build's provider holds no analyzer, so the lane resolves to
    /// `.unavailable` without awaiting or invoking anything, and no provenance code is
    /// linked to invoke (Requirements 6.3, 6.4, 6.19, and 6.20).
    private let provenance: ProvenanceLaneProvider

    /// The validated fusion rule, or `nil` when this release shows no Combined Summary.
    ///
    /// `ApprovedFusionRule` is itself the port, so what is injected here is a rule that
    /// passed every fusion criterion rather than a resolver that could be handed an
    /// unvalidated one. A composition root with no approved rule passes `nil`, matching
    /// `OptionalFusion.approvedRule`.
    private let fuser: (any EvidenceFusing)?

    /// The release's apparent-inconsistency classifier, or `nil` when none was declared.
    private let inconsistencyClassifier: ApparentInconsistencyClassifier?

    /// Removes the session's material under the deadline its terminal outcome selects.
    private let cleanup: SessionTerminalCleanup

    /// The release-approved evidence-branch execution policy.
    private let approvedBranchExecution: ApprovedEvidenceBranchExecution

    // MARK: Session state

    /// Everything one session attempt holds, and the only place any of it is kept.
    ///
    /// A single value rather than a set of parallel fields, so ending a session is one
    /// assignment and cannot leave a field behind. Its `let`s are the facts fixed when the
    /// attempt began; its `var`s are the ones the stages fill in.
    private struct ActiveSession {
        let identity: AnalysisSessionIdentity

        /// The accepted ingest. The single source of the analyzed bytes, the recorded
        /// route, and the Byte Preservation Status a failure snapshot preserves.
        let asset: ImportedEncodedAsset

        /// The snapshot this session is bound to, once binding succeeded.
        var bound: BoundAnalysisSession?

        /// The report builder, derived from ``bound`` so its binding and scope come from
        /// one source and cannot describe different releases.
        var evidence: EvidenceCoordinator?

        /// The stage now running, for progress reporting only.
        ///
        /// Never used to locate a failure: every fault carries the stage it was detected
        /// in, and a snapshot records that one rather than wherever the session happened
        /// to be.
        var stage: AnalysisStage

        /// Measurements taken before any failure, once validation recorded them
        /// (Requirement 3.14).
        var inputQuality: InputQualityRecord?

        /// The two source lanes as they resolve.
        var lanes: EvidenceLaneJoin

        /// The write-once terminal slot.
        var terminal: TerminalCommitSlot

        /// Whether cancellation has been requested for this attempt. Write-once.
        var cancellation: SessionCancellationLatch

        /// The task running this attempt, when the coordinator started it.
        ///
        /// `nil` for a session started by awaiting ``analyze(_:)`` directly, in which case
        /// the enclosing task belongs to the caller. Present it is the coordinator's own
        /// structured tree, so cancelling it delivers ``Task/isCancelled`` into every
        /// adapter the session is suspended inside.
        var structuredTask: Task<AnalysisSessionOutcome, Never>?

        /// Framework cancellation hooks registered for this attempt, in registration order
        /// so cancellation is deterministic rather than dictionary-ordered.
        var cancellationHooks: [(token: CancellationHookToken, cancel: @Sendable () -> Void)]

        /// The execution the branches ran under.
        var branchExecution: EvidenceBranchExecution

        /// A fusion rule that did not apply to this session.
        var fusionFault: FusionFault?
    }

    private var active: ActiveSession?

    /// The next attempt number. Monotonic and never reused, including across sessions.
    private var nextGeneration: UInt64 = 1

    /// The next hook discriminator. Monotonic across sessions, so a withdrawn token from an
    /// earlier attempt can never name a later attempt's hook.
    private var nextCancellationHookNumber: UInt64 = 1

    /// The task ``startAnalysis(of:)`` created, until the session it runs adopts it.
    ///
    /// Non-`nil` only in the window between that member returning and the created task's
    /// first actor step. Both ends of that window are actor steps, and the member is
    /// synchronous, so the handle is always stored before the task can begin — which is
    /// what lets a session own the task that runs it without a lock or a second await.
    ///
    /// The reserved generation is carried with it so the handle can only be adopted by the
    /// attempt it was created for. Without it, a session that started between those two
    /// steps would be handed another session's task to cancel.
    private var pendingStructuredTask:
        (generation: UInt64, task: Task<AnalysisSessionOutcome, Never>)?

    // MARK: Initialization

    /// Creates a coordinator for one capability composition.
    ///
    /// Every collaborator is required. There is no optional port whose absence would be
    /// silently skipped: an absent capability is expressed by the *value* of a
    /// collaborator — a pixel-only ``ProvenanceLaneProvider``, a `nil` fuser, a `nil`
    /// classifier — so a composition cannot be assembled by leaving something out.
    ///
    /// - Parameters:
    ///   - binder: Binds each accepted input to the active verified Model Bundle once.
    ///   - validator: Classifies the actual container and completes the bound decode.
    ///   - preprocessor: Applies the bound Preprocessing Contract exactly, or fails.
    ///   - modelLoader: Loads the bound model with Apple Neural Engine execution permitted.
    ///   - analyzer: Runs one prediction and validates the runtime feature result.
    ///   - calibrator: Maps one finite logit and the quality record to one pixel label.
    ///   - provenance: This composition's provenance source lane.
    ///   - fuser: The validated Evidence Fusion Rule, or `nil` for no Combined Summary.
    ///   - inconsistencyClassifier: The release's declared classifier, or `nil` for none.
    ///   - cleanup: Removes session material under the approved deadline.
    ///   - branchExecution: The approved evidence-branch execution policy, with the Device
    ///     Validation Plan version it was read from. Concurrency is authorized only when
    ///     that plan is the one the bound Resource Budget cites.
    public init(
        binder: AnalysisSessionBinder,
        validator: any InputValidating,
        preprocessor: any ImagePreprocessing,
        modelLoader: any PixelModelLoading,
        analyzer: any PixelAnalyzing,
        calibrator: any PixelCalibrating,
        provenance: ProvenanceLaneProvider,
        fuser: (any EvidenceFusing)?,
        inconsistencyClassifier: ApparentInconsistencyClassifier?,
        cleanup: SessionTerminalCleanup,
        branchExecution: ApprovedEvidenceBranchExecution
    ) {
        self.binder = binder
        self.validator = validator
        self.preprocessor = preprocessor
        self.modelLoader = modelLoader
        self.analyzer = analyzer
        self.calibrator = calibrator
        self.provenance = provenance
        self.fuser = fuser
        self.inconsistencyClassifier = inconsistencyClassifier
        self.cleanup = cleanup
        self.approvedBranchExecution = branchExecution
    }

    // MARK: Observation

    /// The running session attempt, or `nil` when the coordinator is idle.
    public func activeIdentity() -> AnalysisSessionIdentity? { active?.identity }

    /// The stage now running, or `nil` when the coordinator is idle.
    ///
    /// For progress derivation. It is not where a failure happened: a snapshot records the
    /// stage its own fault carried.
    ///
    /// Under the concurrent execution policy two stages are genuinely in flight, and this
    /// reports the pixel branch's. That is the required Version 1 evidence capability and
    /// the session's ordered prerequisite chain, so it is the stage a progress surface
    /// should name; the provenance branch does not move it, which keeps the value
    /// meaningful rather than whichever branch last suspended.
    public func currentStage() -> AnalysisStage? { active?.stage }

    /// The terminal outcome already committed for the running session, or `nil`.
    ///
    /// Non-`nil` only in the window between the commit and the end of cleanup. Once the
    /// session ends, the coordinator holds nothing, which is what keeps a retry clean.
    public func committedTerminal() -> SessionTerminalOutcome? { active?.terminal.committed }

    /// Whether cancellation has been requested for the running session.
    ///
    /// `false` while the coordinator is idle. Monotonic within one attempt and never
    /// inherited by the next one, because a new attempt gets a new latch.
    public func isCancellationRequested() -> Bool {
        active?.cancellation.isRequested ?? false
    }

    /// Whether `identity` names the running session and it has not yet committed.
    ///
    /// The check every stage boundary performs after a suspension, and the one a late
    /// framework result is discarded by. Expressed in terms of
    /// ``admitFrameworkResult(for:)`` so both read the same recorded state rather than two
    /// copies of the same condition.
    func isRunning(_ identity: AnalysisSessionIdentity) -> Bool {
        admitFrameworkResult(for: identity).isAdmitted
    }

    // MARK: - Discarding late framework results

    /// Whether a result produced for `identity` may still be used.
    ///
    /// Deliberately **not** `async`: with no suspension point the identity comparison and
    /// the slot read happen in one indivisible actor step, so the answer is a function of
    /// recorded state alone. That is what makes "late results are discarded" independent of
    /// timing — a Core ML prediction or an Image I/O decode that could not be preempted and
    /// returns after the cancelled terminal is refused because its attempt no longer
    /// admits results, not because it happened to be slow.
    ///
    /// The generation is what makes the refusal exact. A released session identifier can be
    /// bound again, so an identifier match alone would let a call still running from the
    /// first attempt look like a current one.
    func admitFrameworkResult(for identity: AnalysisSessionIdentity) -> FrameworkResultAdmission {
        guard let active else { return .discardedNoActiveSession }
        guard active.identity == identity else {
            return .discardedStaleIdentity(offered: identity)
        }
        if let committed = active.terminal.committed {
            return .discardedTerminalCommitted(committed)
        }
        return .admitted
    }

    /// Pairs `result` with the decision about whether it may be used.
    ///
    /// For a caller holding a value a framework produced asynchronously: the discarded case
    /// carries no value, so there is nothing to reach for after a refusal.
    func admit<Value: Sendable>(
        _ result: Value,
        for identity: AnalysisSessionIdentity
    ) -> AdmittedFrameworkResult<Value> {
        let admission = admitFrameworkResult(for: identity)
        return admission.isAdmitted ? .admitted(result) : .discarded(admission)
    }

    // MARK: - Cancellation

    /// Requests cancellation of `identity` and reports what that did.
    ///
    /// The whole of the design's cancellation sequence, in one synchronous actor step and
    /// therefore in one indivisible move:
    ///
    /// 1. **Latch the request.** Write-once, so a second activation of the cancel control
    ///    changes nothing and re-invokes no hook.
    /// 2. **Claim the terminal with `cancelled`.** This is what disables every future
    ///    evidence commit *now* rather than when the current stage returns: the slot is
    ///    occupied from this instant, so a completed report the pipeline is already
    ///    building is refused when it is offered, and the cancelled terminal is the
    ///    session's only one (Requirements 11.14, 11.17, and 15.7).
    /// 3. **Cancel the structured task**, when the coordinator started the session. Every
    ///    adapter in this graph fails closed on ``Task/isCancelled`` and throws
    ///    ``AnalysisFault/cancelled``, so this is what stops an in-flight decode,
    ///    preprocessing pass, provenance validation, or prediction at its next chunk or
    ///    stage boundary (Requirement 11.14).
    /// 4. **Invoke every registered framework hook**, in registration order and exactly
    ///    once, then forget them. This is where an available `Progress` or an adapter
    ///    cancellation handle is cancelled.
    ///
    /// Steps 3 and 4 are best effort by nature: a framework call that has already entered
    /// may not be interruptible, and the design does not promise preemption it cannot
    /// deliver. Nothing about the *outcome* depends on them — the terminal is already
    /// cancelled and any result that arrives anyway is discarded by identity.
    ///
    /// Deleting the session's material is not done here. While a framework call is still in
    /// flight it owns the handles, so removal runs where every other terminal's removal
    /// runs — the coordinator's single end path, which selects the cancelled reason's
    /// approved deadline from the committed outcome (Requirements 9.8 and 11.15).
    ///
    /// Refused, with nothing latched and no hook invoked, when no session is running or the
    /// request names an attempt that is not the running one. Refused at the slot, with the
    /// standing outcome reported unchanged, when the session already committed a terminal:
    /// a session that completed before the request stays completed.
    @discardableResult
    public func requestCancellation(
        for identity: AnalysisSessionIdentity
    ) -> CancellationRequestResult {
        guard var session = active else { return .refused(.refusedNoActiveSession) }
        guard session.identity == identity else {
            return .refused(.refusedStaleIdentity(offered: identity))
        }

        let latched = session.cancellation.request()
        let commit = session.terminal.claim(.cancelled)
        // The stopping effects run only for the request that actually claimed the terminal.
        // A session that already committed one is already ending through its own path, and
        // cancelling the task it is releasing handles and deleting material in could abort a
        // removal Requirement 9.8 requires.
        let stopsWork = latched && commit.didCommit
        let structuredTask = stopsWork ? session.structuredTask : nil
        let hooks = stopsWork ? session.cancellationHooks : []
        if stopsWork { session.cancellationHooks.removeAll() }
        active = session

        structuredTask?.cancel()
        for hook in hooks {
            hook.cancel()
        }
        return CancellationRequestResult(
            latchedRequest: latched,
            commit: commit,
            cancelledStructuredTask: structuredTask != nil,
            invokedHookCount: hooks.count
        )
    }

    /// Registers a framework cancellation hook for `identity`.
    ///
    /// The seam through which "any available `Progress`" and an adapter's own cancellation
    /// handle are reached. The word *available* is doing work: a build whose frameworks
    /// expose no cancellation handle registers nothing, and cooperation then reaches the
    /// adapters through structured-task cancellation and their own boundary checks.
    ///
    /// Invoked immediately, and stored nowhere, when the named attempt no longer admits
    /// results — it is not the running one, or a terminal already stands, cancelled or
    /// otherwise. Work that starts in the window after a session ended must not keep
    /// running, and storing a hook for an attempt that is over would only queue it to be
    /// discarded unfired.
    ///
    /// The returned token is always a fresh one, so a caller can withdraw unconditionally.
    @discardableResult
    public func registerCancellationHook(
        for identity: AnalysisSessionIdentity,
        _ cancel: @escaping @Sendable () -> Void
    ) -> CancellationHookToken {
        let token = CancellationHookToken(number: nextCancellationHookNumber)
        nextCancellationHookNumber += 1
        // A cancellation request always claims the terminal in the same step that latches
        // it, so "already cancellation-requested" is one of the cases this single condition
        // covers rather than a second check that could drift from it.
        guard admitFrameworkResult(for: identity).isAdmitted, var session = active else {
            cancel()
            return token
        }
        session.cancellationHooks.append((token: token, cancel: cancel))
        active = session
        return token
    }

    /// Withdraws a hook whose work finished on its own, so a completed framework call is
    /// not cancelled later. Idempotent.
    public func withdrawCancellationHook(_ token: CancellationHookToken) {
        guard var session = active else { return }
        session.cancellationHooks.removeAll { $0.token == token }
        active = session
    }

    /// Whether this attempt may keep working, honoring both the session and the task.
    ///
    /// The stage-boundary check. Two conditions, and they are different failures:
    ///
    ///   * The enclosing task was cancelled. That is cancellation arriving from outside the
    ///     coordinator — a caller cancelling its own tree, or a parent scope going away —
    ///     and it is turned into a request here rather than ignored. Without this, a
    ///     cancelled task would run the pipeline to the end and offer a *completed*
    ///     terminal with an Evidence Report, which is exactly what Requirement 15.7
    ///     forbids.
    ///   * The attempt no longer admits results, because a terminal already stands or it is
    ///     no longer the running one.
    ///
    /// Synchronous, so the check and the request it may raise are one actor step.
    private func continuesAfterBoundary(_ identity: AnalysisSessionIdentity) -> Bool {
        if Task.isCancelled {
            requestCancellation(for: identity)
            return false
        }
        return admitFrameworkResult(for: identity).isAdmitted
    }

    // MARK: The single write path

    /// Offers `outcome` as the session's terminal, and reports what stands afterwards.
    ///
    /// The only member that writes a terminal outcome, and deliberately **not** `async`:
    /// with no suspension point, the identity check and the slot's compare-and-set run in
    /// one indivisible actor step, so two overlapping offers cannot both find the slot
    /// empty. A caller cannot introduce a window either, because there is no separate
    /// "check" member to call first.
    ///
    /// Refused rather than applied in three cases: no session is running, the offer names
    /// a session attempt that is not the running one, or a terminal already stands. The
    /// third is Requirement 11.17's monotonicity — `completed`, `cancelled`, and `failed`
    /// cannot transition into one another, so the first outcome is returned unchanged.
    @discardableResult
    func commitTerminal(
        _ outcome: SessionTerminalOutcome,
        for identity: AnalysisSessionIdentity
    ) -> TerminalCommit {
        guard var session = active else { return .refusedNoActiveSession }
        guard session.identity == identity else {
            return .refusedStaleIdentity(offered: identity)
        }
        let commit = session.terminal.claim(outcome)
        active = session
        return commit
    }

    // MARK: - Analyzing one accepted ingest

    /// Starts one Analysis Session in a task this coordinator can cancel.
    ///
    /// The same session ``analyze(_:)`` runs, with one difference that matters for
    /// cancellation: the task is the coordinator's, so ``requestCancellation(for:)`` can
    /// cancel it. Every adapter in this graph fails closed on ``Task/isCancelled``, so that
    /// is what turns a cancel action into a decode, preprocessing pass, provenance
    /// validation, or prediction that actually stops rather than one that runs to
    /// completion and has its result discarded (Requirement 11.14).
    ///
    /// Await the returned task's value for the terminal outcome. Dropping the handle does
    /// not cancel the session, so a caller that only needs cleanup to happen may discard it.
    ///
    /// `nil` when a session is already running or already starting: no task is created and
    /// nothing is touched, which is the same refusal ``analyze(_:)`` makes. ``analyze(_:)``
    /// remains available for a caller that owns its own task and wants the refused
    /// identity — this member reports refusal without it because the running attempt is
    /// already readable through ``activeIdentity()``.
    ///
    /// Synchronous on purpose. The whole body is one actor step, so the created task cannot
    /// begin before ``pendingStructuredTask`` holds its handle, and the session that task
    /// creates therefore always adopts the task that runs it — with no lock and no second
    /// suspension to race against.
    @discardableResult
    public func startAnalysis(
        of asset: ImportedEncodedAsset
    ) -> Task<AnalysisSessionOutcome, Never>? {
        guard active == nil, pendingStructuredTask == nil else { return nil }
        let task = Task { await self.analyze(asset) }
        // `nextGeneration` is the generation the session this task starts will take, so the
        // reservation names one attempt rather than "whichever runs next".
        pendingStructuredTask = (generation: nextGeneration, task: task)
        return task
    }

    /// Runs one Analysis Session over `asset` and commits exactly one terminal outcome.
    ///
    /// The stages run in the design's fixed order, and every one of them is reached only
    /// through the previous one's return value:
    ///
    /// 1. **Bind.** The active verified Model Bundle is re-read and snapshotted for this
    ///    session, together with the Preprocessing Contract, Calibration Policy, Resource
    ///    Budget, and conditional artifacts *as values*. Nothing downstream consults the
    ///    active pointer again, so a later activation or rollback cannot change a running
    ///    session (Requirements 10.14 and 10.15).
    /// 2. **Prepare to report.** The report builder is derived from that one snapshot, so
    ///    its session binding and its evidence scope come from the same value and cannot
    ///    describe two releases.
    /// 3. **Validate.** The actual container is classified and the bound decode completed,
    ///    and the pre-orientation measurements are recorded before anything can fail with
    ///    them unknown (Requirements 3.5 and 3.14).
    /// 4. **Preprocess.** The bound contract is applied exactly, or the session fails.
    /// 5. **Resolve both lanes**, serially or concurrently as the approved plan authorizes.
    /// 6. **Join and commit once.** Fusion is resolved, the report is built, and the
    ///    terminal is claimed in one synchronous step, so no report can exist that is not
    ///    already this session's committed terminal.
    ///
    /// Every suspension is followed by a re-check that this attempt is still the running
    /// one and has not committed. A stage that finds otherwise stops and the standing
    /// outcome is what the session ends with, so work already in flight cannot add to or
    /// overwrite a decided session.
    ///
    /// The session always ends through one path: release the bound snapshot, remove the
    /// session's material under the deadline the terminal selects, then discard every trace
    /// of the attempt.
    public func analyze(_ asset: ImportedEncodedAsset) async -> AnalysisSessionOutcome {
        // Take whatever `startAnalysis(of:)` reserved and clear the slot before anything
        // else, including before the refusal below. A refused call that left the handle in
        // place would make every later start refuse too, and clearing it here means the
        // slot is occupied for exactly the one window it describes.
        let reservedTask = pendingStructuredTask
        pendingStructuredTask = nil

        // No suspension between reading `active` and writing it, so two concurrent calls
        // cannot both start a session.
        if let active { return .refusedWhileSessionActive(active.identity) }

        let identity = AnalysisSessionIdentity(
            sessionID: asset.sessionID,
            generation: nextGeneration
        )
        nextGeneration += 1
        // A brand-new value: no field carries anything from a previous attempt, because
        // there is no previous value to copy from (Requirement 3.15). The one thing taken
        // from outside is the task `startAnalysis(of:)` created to run this session, and
        // only when the reservation names *this* generation.
        let ownedTask = reservedTask?.generation == identity.generation
            ? reservedTask?.task
            : nil
        active = ActiveSession(
            identity: identity,
            asset: asset,
            bound: nil,
            evidence: nil,
            stage: .inputValidation,
            inputQuality: nil,
            lanes: .unresolved,
            terminal: TerminalCommitSlot(),
            cancellation: SessionCancellationLatch(),
            structuredTask: ownedTask,
            cancellationHooks: [],
            branchExecution: .serial,
            fusionFault: nil
        )
        // Entering already cancelled is cancellation, not a stage that failed. Checked
        // before the first port call so a session started in a cancelled task loads no
        // model and reads no byte, and still commits the cancelled terminal and removes
        // its material under the cancellation deadline (Requirements 11.14 and 11.15).
        guard continuesAfterBoundary(identity) else {
            return await endWithStandingOutcome(identity)
        }

        // 1. Bind the complete active verified bundle to this session.
        let bound: BoundAnalysisSession
        do {
            bound = try await binder.bind(accepting: asset)
        } catch {
            // The refusal's own fault, not a rewritten one: every bundle refusal is
            // `model-load-error` at model load, and a cancelled bind stays cancelled
            // rather than being reported as a model error (Requirement 10.16).
            return await endSession(faulting: error.analysisFault, for: identity)
        }
        guard continuesAfterBoundary(identity) else {
            return await endWithStandingOutcome(identity)
        }
        guard bound.sessionID == identity.sessionID else {
            // A snapshot taken for another session cannot govern this one. Unreachable
            // through the binder, which derives the identifier from the accepted ingest;
            // kept as a refusal because analyzing under another session's bound artifacts
            // is exactly what Requirement 10.14 forbids.
            return await endSession(
                faulting: .analysis(.modelLoadError, stage: .modelLoad),
                for: identity
            )
        }

        // 2. Derive the report builder from that one snapshot.
        guard let evidence = EvidenceCoordinator(
            binding: bound.binding,
            scope: bound.scope,
            inconsistencyClassifier: inconsistencyClassifier
        ) else {
            // The only refusal is a classifier drawn from a copy catalogue this session's
            // Model Bundle and capability set are not compatible with. That is a failed
            // compatibility between two independently signed statements about one release,
            // which the design's error table assigns `model-load-error`, and it is caught
            // here so no analysis work runs for a session that could never report.
            return await endSession(
                faulting: .analysis(.modelLoadError, stage: .modelLoad),
                for: identity
            )
        }
        record(bound: bound, evidence: evidence, for: identity)

        // 3. Classify the container and complete the bound decode.
        let validated: ValidatedImage
        do {
            validated = try await validator.validate(
                asset,
                contract: bound.preprocessingContract,
                budget: bound.resourceBudget
            )
        } catch {
            return await endSession(faulting: error, for: identity)
        }
        guard continuesAfterBoundary(identity) else {
            return await endWithStandingOutcome(identity)
        }
        guard validated.sessionID == identity.sessionID,
              validated.preprocessingContractID == bound.preprocessingContract.id
        else {
            // A decode belonging to another session, or governed by a contract version
            // this session was not bound to, is not a complete decode of *this* image
            // under *its* bound contract (Requirement 3.1). Reported in the stage's own
            // category so a failure snapshot names where the check ran.
            return await endSession(
                faulting: .analysis(.decodingError, stage: .inputValidation),
                for: identity
            )
        }
        // Recorded before anything downstream can fail, so a later failure still preserves
        // the pre-orientation dimensions and the byte status (Requirement 3.14).
        record(inputQuality: validated.quality, for: identity)

        // 4. Apply the bound contract exactly. There is no best-effort path.
        setStage(.preprocessing, for: identity)
        let prepared: ModelImageInput
        do {
            prepared = try await preprocessor.prepare(
                validated,
                contract: bound.preprocessingContract,
                budget: bound.resourceBudget
            )
        } catch {
            return await endSession(faulting: error, for: identity)
        }
        guard continuesAfterBoundary(identity) else {
            return await endWithStandingOutcome(identity)
        }
        guard prepared.sessionID == identity.sessionID,
              prepared.preprocessingContractID == bound.preprocessingContract.id
        else {
            return await endSession(
                faulting: .analysis(.preprocessingError, stage: .preprocessing),
                for: identity
            )
        }

        // 5. Resolve both source lanes under the approved execution policy.
        let execution = approvedBranchExecution.execution(for: bound)
        record(branchExecution: execution, for: identity)
        setStage(.modelLoad, for: identity)

        let pixelOutcome: BranchOutcome<PixelEvidence>
        let provenanceOutcome: BranchOutcome<ProvenanceLane>
        switch execution {
        case .serial:
            pixelOutcome = await resolvePixelLane(
                bound: bound,
                prepared: prepared,
                quality: validated.quality,
                identity: identity
            )
            if let fault = pixelOutcome.fault {
                // Serially the sibling has not started, which is the ordered equivalent of
                // cancelling it: a session that already failed produces no Provenance
                // Evidence (Requirement 3.12).
                return await endSession(faulting: fault, for: identity)
            }
            // Re-checked here as well as inside the branch. The branch's last check precedes
            // its final stage transition, so a terminal committed in that window would
            // otherwise let a decided session start provenance work it can never report.
            guard continuesAfterBoundary(identity) else {
                return await endWithStandingOutcome(identity)
            }
            if provenance.isEnabled { setStage(.provenanceValidation, for: identity) }
            provenanceOutcome = await resolveProvenanceLane(asset: asset, identity: identity)
        case .concurrent:
            // Both branches are launched before either is awaited, so the join holds two
            // outcomes and arbitrates them by causal stage order rather than by whichever
            // returned first.
            async let pixel = resolvePixelLane(
                bound: bound,
                prepared: prepared,
                quality: validated.quality,
                identity: identity
            )
            async let lane = resolveProvenanceLane(asset: asset, identity: identity)
            pixelOutcome = await pixel
            provenanceOutcome = await lane
        }
        // The last boundary before any evidence can be built. A cancellation that landed
        // while either branch was in flight stops here, so a resolved lane or a calibrated
        // label produced by a call that could not be preempted is dropped with the locals
        // holding it and never reaches the join (Requirements 11.14 and 15.7).
        guard continuesAfterBoundary(identity) else {
            return await endWithStandingOutcome(identity)
        }

        if let fault = CausalFaultArbitration.earliest(
            of: [pixelOutcome.fault, provenanceOutcome.fault].compactMap { $0 }
        ) {
            return await endSession(faulting: fault, for: identity)
        }
        guard let pixelEvidence = pixelOutcome.value, let lane = provenanceOutcome.value else {
            // Unreachable: a branch that reported no fault resolved its lane. Kept as a
            // refusal rather than a force-unwrap, because the alternative to a lane is
            // never an invented one.
            return await endSession(faulting: Self.evidenceJoinFault, for: identity)
        }

        // 6. Join the two lanes and commit exactly once. Everything from building the
        // summary to claiming the slot is synchronous, so the actor holds its executor
        // across all of it.
        setStage(.evidenceJoining, for: identity)
        let commit = commitJoinedEvidence(pixel: pixelEvidence, provenance: lane, for: identity)
        return await end(after: commit, for: identity)
    }

    // MARK: - The pixel branch

    /// Loads the bound model, runs one prediction, and calibrates the logit.
    ///
    /// `nonisolated` so the concurrent policy genuinely overlaps this branch with the
    /// provenance branch instead of interleaving two actor-bound runs. It touches no
    /// session state directly: it reads the immutable snapshot it was handed and asks the
    /// actor whether the attempt is still running between stages.
    ///
    /// A branch never commits a terminal. It reports one fault or one lane value, and the
    /// join decides — which is what keeps arbitration causal rather than temporal.
    private nonisolated func resolvePixelLane(
        bound: BoundAnalysisSession,
        prepared: ModelImageInput,
        quality: InputQualityRecord,
        identity: AnalysisSessionIdentity
    ) async -> BranchOutcome<PixelEvidence> {
        // Before the model load rather than after it, so a branch launched into an already
        // cancelled attempt performs no framework work at all.
        guard await continuesAfterBoundary(identity) else { return .faulted(.cancelled) }
        let model: BoundCoreMLModel
        do {
            // The bundle *value* this session snapshotted, so inference executes the model
            // from the version bound to the session rather than whatever is active when the
            // load happens (Requirement 4.1).
            model = try await modelLoader.loadModel(from: bound.bundle)
        } catch {
            return .faulted(error)
        }
        // A loaded model that arrives after cancellation is a late framework result: it is
        // refused by identity, and the fault is cancellation rather than a model error.
        guard await continuesAfterBoundary(identity) else { return .faulted(.cancelled) }
        do {
            // The checked half of Requirement 4.1: a model loaded from any other bundle
            // version is refused rather than run.
            try bound.requireBoundModel(model)
        } catch {
            return .faulted(error.analysisFault)
        }
        guard model.accepts(prepared) else {
            // The prepared buffer does not match the shape the model was loaded against.
            // A failed compatibility, which the design's error table assigns
            // `model-load-error`, and never an approximated input that reaches inference and
            // is measured as parity.
            //
            // Structurally satisfied today: `ModelInputContract` pins 384x384 unsigned 8-bit,
            // `ModelImageInput` refuses any other edge or element type, and
            // `ModelChannelOrder` has one member, so a representable pair always matches.
            // Written out anyway, for the same reason the session binder writes out its
            // integrity check — it is the condition Requirement 4.6 rests on, and a later
            // vocabulary that gains a second channel order should refuse here rather than
            // infer on a buffer the model was not loaded for.
            return .faulted(.analysis(.modelLoadError, stage: .modelLoad))
        }

        await setStage(.inference, for: identity)
        let logit: RawLogit
        do {
            logit = try await analyzer.infer(prepared, model: model)
        } catch {
            // Execution failure and an unusable runtime result are distinct categories the
            // adapter already separated; neither is rewritten here and neither produces
            // Pixel Evidence.
            return .faulted(error)
        }
        // The prediction may not have been interruptible once entered, so this is where a
        // logit produced after cancellation is discarded — by identity and generation, not
        // by how long the call took. Nothing calibrates it, so no Pixel Evidence exists for
        // a cancelled session even to be refused later (Requirement 15.7).
        guard await continuesAfterBoundary(identity) else { return .faulted(.cancelled) }

        await setStage(.calibration, for: identity)
        do {
            // Synchronous and total: there is no suspension point at which a late result
            // could change a label, and the policy is the value this session bound.
            return .resolved(
                try calibrator.classify(logit, quality: quality, policy: bound.calibrationPolicy)
            )
        } catch {
            return .faulted(error)
        }
    }

    // MARK: - The provenance branch

    /// Resolves the provenance source lane for this composition.
    ///
    /// Non-faulting, and that is the port's contract rather than an omission here: every
    /// validator condition — a parser fault, an inconclusive result, a missing offline
    /// revocation answer — maps through the signed Provenance Policy into one of the five
    /// enabled states, so a validator problem is an evidence state chosen by an approved
    /// mapping and never an error that ends the session (Requirements 6.9 through 6.18).
    ///
    /// In a pixel-only composition the provider holds no analyzer, so this resolves
    /// `.unavailable` without awaiting or invoking anything. The lane always comes from the
    /// provider rather than from the session's binding, because the provider is the fact
    /// about the linked module graph and the signed manifest; the startup gate already
    /// required the two to agree, and report construction refuses a lane that is not the
    /// bound composition's.
    ///
    /// The outcome is still a ``BranchOutcome`` so that the join arbitrates a list rather
    /// than a special case. Runtime resource control can end a session from either branch,
    /// and when those checkpoints are wired to their bound plan this is where the second
    /// fault would arrive; ``CausalFaultArbitration`` already ranks it.
    ///
    /// The one fault it does report is cancellation, checked before the validator is
    /// invoked. Requirement 11.14 names provenance validation among the work a cancelled
    /// session stops, and under the concurrent policy this branch is launched alongside the
    /// pixel branch rather than after a boundary check of its own.
    private nonisolated func resolveProvenanceLane(
        asset: ImportedEncodedAsset,
        identity: AnalysisSessionIdentity
    ) async -> BranchOutcome<ProvenanceLane> {
        guard await continuesAfterBoundary(identity) else { return .faulted(.cancelled) }
        // The identical retained byte sequence the validator received, inspected before any
        // byte-changing transformation (Requirements 2.13 and 6.6).
        return .resolved(await provenance.lane(for: asset))
    }

    // MARK: - Committing the completed terminal

    /// The fault a session that cannot join its lanes ends with.
    ///
    /// An ``EvidenceJoinFault`` is a release-configuration fault — a lane or a summary
    /// attributed to an artifact version the session was not bound to — so it takes the
    /// category the design's error table gives a failed compatibility, recorded at the
    /// stage where it was caught. Refusing is the only safe answer: the alternative is a
    /// report that misattributes evidence.
    private static let evidenceJoinFault: AnalysisFault = .analysis(
        .modelLoadError,
        stage: .evidenceJoining
    )

    /// Joins both lanes, builds the Evidence Report, and claims the terminal.
    ///
    /// Synchronous from end to end, which is the point. Held inside the actor, the whole
    /// sequence — resolve the summary, build the report, compare and set the slot — runs
    /// without a suspension, so there is no instant at which a constructed report is not
    /// already this session's committed terminal, and no second offer can interleave.
    private func commitJoinedEvidence(
        pixel: PixelEvidence,
        provenance lane: ProvenanceLane,
        for identity: AnalysisSessionIdentity
    ) -> TerminalCommit {
        guard var session = active,
              session.identity == identity,
              let bound = session.bound,
              let evidence = session.evidence,
              let quality = session.inputQuality
        else {
            return commitTerminal(
                failure(Self.evidenceJoinFault, for: identity),
                for: identity
            )
        }

        // Each lane resolves exactly once. A refused write means the join already held that
        // lane, which is a duplicate result rather than a new one, and applying it would
        // let one branch change an answer the join already carries.
        guard let withPixel = session.lanes.resolving(pixel: pixel),
              let joined = withPixel.resolving(provenance: lane),
              let lanes = joined.resolvedLanes
        else {
            return commitTerminal(
                failure(Self.evidenceJoinFault, for: identity),
                for: identity
            )
        }
        session.lanes = joined

        let summary: CombinedSummary?
        switch resolveSummary(pixel: pixel, provenance: lane, bound: bound) {
        case .resolved(let value):
            summary = value
        case .unavailable(let fault):
            // A rule that does not apply costs the summary and nothing else: both source
            // lanes still appear in full (Requirements 7.9 and 7.16).
            summary = nil
            session.fusionFault = fault
        }
        active = session

        let report: EvidenceReport
        do {
            report = try evidence.report(
                lanes: lanes,
                combinedSummary: summary,
                bytePreservationStatus: session.asset.preservationStatus,
                inputQuality: quality,
                // Every port in the shipping graph runs on the user's device: there is no
                // network dependency to reach, which the module-boundary and release
                // archive audits enforce rather than this line asserting it
                // (Requirement 4.10).
                onDeviceProcessing: true
            )
        } catch {
            return commitTerminal(
                failure(Self.evidenceJoinFault, for: identity),
                for: identity
            )
        }
        return commitTerminal(.completed(report), for: identity)
    }

    /// What resolving the optional Combined Summary produced.
    private enum SummaryResolution {
        /// The summary to show beside both lanes, or `nil` for an approved omission.
        case resolved(CombinedSummary?)
        /// No summary, because the offered rule does not apply to this session.
        case unavailable(FusionFault)
    }

    /// Resolves the Combined Summary, or reports why the offered rule did not apply.
    ///
    /// Three ways to reach no summary without a fault, and none of them is a failure: this
    /// release binds no rule, this composition compiled no fuser, or the provenance lane is
    /// unavailable so no combination applies. The unavailable lane is structural rather
    /// than checked — the port takes ``ProvenanceEvidence``, so an unavailable lane cannot
    /// be passed at all (Requirement 7.10).
    private func resolveSummary(
        pixel: PixelEvidence,
        provenance lane: ProvenanceLane,
        bound: BoundAnalysisSession
    ) -> SummaryResolution {
        guard let fuser, let rule = bound.fusionRule, let evidence = lane.fusionInput else {
            return .resolved(nil)
        }
        do {
            return .resolved(
                try fuser.resolve(
                    pixel: pixel,
                    provenance: evidence,
                    rule: rule,
                    binding: bound.binding
                )
            )
        } catch {
            return .unavailable(error)
        }
    }

    // MARK: - Committing a non-evidence terminal

    /// The terminal outcome one fault produces.
    ///
    /// Cancellation and failure are different terminals, so the fault's two cases map to
    /// different outcomes rather than to one category: a cancelled session is never
    /// presented as a failure (Requirement 11.17). A failure carries exactly one Analysis
    /// Error and has no evidence field at all (Requirement 11.18), and preserves the byte
    /// status and whatever pre-orientation measurements had been recorded before the
    /// failure (Requirement 3.14).
    private func failure(
        _ fault: AnalysisFault,
        for identity: AnalysisSessionIdentity
    ) -> SessionTerminalOutcome {
        switch fault {
        case .cancelled:
            return .cancelled
        case let .analysis(error, stage):
            // Read only from the attempt this failure belongs to. A snapshot must never
            // borrow another session's byte status or dimensions, so a mismatched identity
            // preserves nothing rather than preserving the wrong thing.
            let session = active?.identity == identity ? active : nil
            guard let snapshot = AnalysisFailureSnapshot(
                sessionID: identity.sessionID,
                error: error,
                stage: stage,
                bytePreservationStatus: session?.asset.preservationStatus,
                inputQuality: session?.inputQuality
            ) else {
                // Unreachable: the schema version defaults to the only one this build
                // produces, which is the sole rejection condition.
                preconditionFailure(
                    "a failure snapshot at the current schema version must be representable"
                )
            }
            return .failed(snapshot)
        }
    }

    // MARK: - Ending

    /// Commits the terminal `fault` produces and ends the session.
    private func endSession(
        faulting fault: AnalysisFault,
        for identity: AnalysisSessionIdentity
    ) async -> AnalysisSessionOutcome {
        let commit = commitTerminal(failure(fault, for: identity), for: identity)
        return await end(after: commit, for: identity)
    }

    /// Ends the session with whatever outcome stands after `commit`.
    ///
    /// A refused offer still ends the session: refusal means a terminal was already
    /// committed, and that one is what the session ends with. Release, cleanup, and
    /// discarding the attempt happen exactly once either way.
    private func end(
        after commit: TerminalCommit,
        for identity: AnalysisSessionIdentity
    ) async -> AnalysisSessionOutcome {
        guard let standing = commit.standingOutcome else {
            // The attempt is no longer the running one, so it has already ended and its
            // cleanup has already run. Nothing to release and nothing to remove.
            return .refusedWhileSessionActive(identity)
        }
        return await finish(standing, for: identity)
    }

    /// Ends a session whose terminal was committed by something other than this stage.
    private func endWithStandingOutcome(
        _ identity: AnalysisSessionIdentity
    ) async -> AnalysisSessionOutcome {
        guard let session = active,
              session.identity == identity,
              let standing = session.terminal.committed
        else {
            return .refusedWhileSessionActive(identity)
        }
        return await finish(standing, for: identity)
    }

    /// Releases the bound snapshot, removes the session's material, and discards the
    /// attempt.
    ///
    /// The order matters. The snapshot is released first so nothing holds the bound bundle;
    /// the material is then removed under the deadline the committed outcome selects, which
    /// is ``SessionTerminalCleanup``'s mapping and not this file's; and only then is the
    /// attempt discarded.
    ///
    /// The state stays in place across both suspensions on purpose. A result that arrives
    /// while cleanup is running still finds the standing terminal and is refused by it,
    /// rather than finding no session and being ambiguous. And because the field is only
    /// cleared at the end, a new session cannot start before the previous one's material is
    /// gone — which is what makes a retry structurally clean rather than merely tidy
    /// (Requirement 3.15).
    private func finish(
        _ outcome: SessionTerminalOutcome,
        for identity: AnalysisSessionIdentity
    ) async -> AnalysisSessionOutcome {
        await binder.release(identity.sessionID)
        let cleanupResult = await cleanup.removeMaterial(
            for: identity.sessionID,
            after: outcome
        )
        // Read from this attempt only, for the same reason a failure snapshot does: a record
        // must not describe another session's execution or fusion outcome.
        let session = active?.identity == identity ? active : nil
        let branchExecution = session?.branchExecution ?? .serial
        let fusionFault = session?.fusionFault
        // One assignment discards the bytes handle, the dimensions, the bound snapshot, the
        // lane join, the stage, the terminal slot, the cancellation latch, the task handle,
        // every registered cancellation hook, and the recorded fault together. There is no
        // field-by-field reset that could miss one, which is also why a later request naming
        // this attempt finds nothing to cancel rather than a stale hook to invoke.
        active = nil
        return .ended(
            CompletedAnalysisSession(
                identity: identity,
                outcome: outcome,
                cleanup: cleanupResult,
                branchExecution: branchExecution,
                fusionFault: fusionFault
            )
        )
    }

    // MARK: - Recording

    /// Records the bound snapshot and the report builder for the running attempt.
    ///
    /// Every recorder checks the identity first, so a value produced by a stage of an
    /// attempt that has since ended cannot be written into a later one.
    private func record(
        bound: BoundAnalysisSession,
        evidence: EvidenceCoordinator,
        for identity: AnalysisSessionIdentity
    ) {
        guard var session = active, session.identity == identity else { return }
        session.bound = bound
        session.evidence = evidence
        active = session
    }

    private func record(inputQuality: InputQualityRecord, for identity: AnalysisSessionIdentity) {
        guard var session = active, session.identity == identity else { return }
        session.inputQuality = inputQuality
        active = session
    }

    private func record(
        branchExecution: EvidenceBranchExecution,
        for identity: AnalysisSessionIdentity
    ) {
        guard var session = active, session.identity == identity else { return }
        session.branchExecution = branchExecution
        active = session
    }

    /// Advances the reported stage, if this attempt is still the running one.
    ///
    /// Progress only. A stale attempt cannot move a later attempt's stage, and no failure
    /// is located from this value.
    private func setStage(_ stage: AnalysisStage, for identity: AnalysisSessionIdentity) {
        guard var session = active, session.identity == identity else { return }
        session.stage = stage
        active = session
    }
}

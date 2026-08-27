import DefAIkeDomain
import Foundation

// Step 7 of the fixed verification order, and the `ModelBundleManaging` conformance:
//
//   7. Stage an immutable verified receipt and atomically replace the active pointer only
//      after all checks pass. A failed candidate leaves the previous pointer and loaded
//      active bundle unchanged.
//
// Everything before step 7 already exists and is reused unchanged. This file adds no
// verification logic of its own: it owns the ordering, the receipt, and the commit, and
// nothing else. That matters for Requirement 10.17 — rollback has to run the *same*
// verification path — and the cheapest way to guarantee that is to have exactly one path
// and call it from both entry points.
//
// Four properties are structural rather than asserted, and each one is the point of a
// design choice above it:
//
//   * One path. ``activateLocalCandidate(_:context:)`` and ``rollback(to:context:)`` are two
//     names for one call to ``activate(_:context:)``. There is no branch, no flag, and no
//     "already trusted" shortcut for a prior bundle, because there is nowhere to put one
//     (Requirement 10.17).
//   * Atomic commit. The active bundle is one immutable ``BoundModelBundle`` value replaced
//     by a single assignment inside an actor, after the durable pointer has been atomically
//     replaced. Nothing between the durable replacement and that assignment can fail, so an
//     observer sees the complete old tuple or the complete new one (Requirement 10.13).
//   * No fallback. A finding at any step returns a finding and leaves ``activeBundle()``
//     exactly as it was. Nothing here reaches for an older or unverified asset, and there is
//     no path that returns a bundle whose verification did not complete in this process
//     (Requirements 10.12 and 10.16).
//   * No update channel. Nothing in this file, and nothing in this module's dependency
//     graph, can name a remote bundle: ``activate(_:context:)`` takes a ``ModelBundleID``
//     that a release installed, and the store and content seams have no member that fetches
//     anything (Requirements 10.19 and 10.21).

/// Verifies, activates, reports, and rolls back locally installed Model Bundles.
///
/// An actor because the active pointer is shared mutable state that two callers can race
/// for, and because every observer of it — ``activeBundle()``, ``verifiedActive(for:)`` —
/// reads one immutable value in one isolated step, so no observer can see a mixture.
///
/// Actor isolation alone is not enough for the commit, though, and the difference matters.
/// An actor serializes each contiguous run of synchronous work; it does not hold the
/// executor across a suspension. Step 7 suspends at least four times, so two overlapping
/// activations would interleave freely and could both read the same activation generation
/// before either published — which would leave two published activations an audit cannot
/// order, and the generation exists precisely to make them orderable (Requirement 10.13).
/// So the commit takes an explicit turn: see ``beginCommit()``.
public actor ModelBundleActivator: ModelBundleManaging {
    private let integrity: ModelBundleIntegrityVerifier
    private let compatibility: ModelBundleCompatibilityVerifier
    private let selfTests: ReleaseSelfTestRunner
    private let store: any ActivationRecordStoring
    private let clock: any SessionClock

    /// The complete active tuple, or `nil` when no verification run has completed.
    ///
    /// Set only by ``commit(_:context:)``, and only after every check passed and the durable
    /// pointer was replaced. Deliberately not seeded from a persisted receipt: see
    /// ``verifiedActive(for:)``.
    private var active: BoundModelBundle?

    /// Whether an activation currently holds the commit turn.
    private var isCommitting = false

    /// Activations waiting for the turn, oldest first.
    private var waitingCommits: [CheckedContinuation<Void, Never>] = []

    /// Creates an activator over the existing verification path and one record store.
    ///
    /// Every argument is required with no default. In particular the three verifiers are
    /// supplied rather than constructed here, so this file cannot quietly build a verifier
    /// with a policy, key set, layout, or budget of its own choosing — those are already
    /// unconstructible without their approved inputs, and that guarantee is inherited rather
    /// than restated.
    public init(
        integrity: ModelBundleIntegrityVerifier,
        compatibility: ModelBundleCompatibilityVerifier,
        selfTests: ReleaseSelfTestRunner,
        store: any ActivationRecordStoring,
        clock: any SessionClock
    ) {
        self.integrity = integrity
        self.compatibility = compatibility
        self.selfTests = selfTests
        self.store = store
        self.clock = clock
    }

    // MARK: - Inspection

    /// The complete currently active tuple, or `nil` when nothing is active.
    ///
    /// The atomicity oracle: it is either one complete ``BoundModelBundle`` or nothing, and
    /// never a mixture, because there is no representation of a mixture.
    public func activeBundle() -> BoundModelBundle? { active }

    // MARK: - The one path

    /// Verifies one locally installed candidate and atomically makes it active.
    ///
    /// The whole fixed order, in order: manifest and signature and artifact digests, then
    /// model identity and component compatibility and self-test completeness, then the
    /// offline self-test run, then the receipt and the commit. A finding at any step returns
    /// that finding and changes nothing.
    ///
    /// Reports the exact verification finding rather than the user-facing category. The port
    /// members below map every finding to `model-load-error`, which is what a session sees
    /// (Requirement 10.16); a release audit needs to know which step refused the candidate,
    /// so the finding is available here and is never presented to a user
    /// (Requirement 11.17).
    public func activate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) async throws(ModelBundleVerificationError) -> BoundModelBundle {
        let tree = try integrity.verify(id)
        let candidate = try compatibility.resolve(tree, for: context)
        let tested = try await selfTests.run(candidate)
        return try await commit(tested, context: context)
    }

    /// The active bundle, reverified as compatible with `context`.
    ///
    /// Compatibility is rechecked on every call because the running context can change
    /// between activations — an operating-system upgrade moves `osVersion` without touching
    /// a single bundle byte — and a bundle that was compatible at activation is not
    /// automatically compatible now.
    ///
    /// What this deliberately does **not** do is reconstruct a bundle from a persisted
    /// receipt. A receipt records that a verification run happened; it is not a certificate
    /// that lets a later launch skip one. Treating it as one would be exactly the
    /// cached-verification bypass Requirement 10.17 rules out for rollback, arrived at from
    /// the other direction. So on a cold start nothing is active until the startup preflight
    /// runs the full path over the installed bundle (design, startup preflight step 3), and
    /// until then this reports ``ModelBundleVerificationError/noActiveModelBundle`` and
    /// pixel inference is prevented (Requirement 10.16).
    public func verifiedActive(
        for context: ReleaseContext
    ) throws(ModelBundleVerificationError) -> BoundModelBundle {
        guard let active else {
            throw ModelBundleVerificationError.noActiveModelBundle
        }
        guard active.isCompatible(with: context) else {
            throw ModelBundleVerificationError.activeModelBundleNotCompatible(active.bundleID)
        }
        return active
    }

    // MARK: - ModelBundleManaging

    public func verifiedActiveBundle(
        for context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        do {
            return try verifiedActive(for: context)
        } catch {
            throw error.analysisFault
        }
    }

    public func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        do {
            return try await activate(id, context: context)
        } catch {
            throw error.analysisFault
        }
    }

    public func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        // The identical path, deliberately spelled as the same call rather than as a
        // rollback-shaped variant of it. "Prior" does not imply trusted: a retained bundle
        // whose bytes changed on disk, whose signing key has since been revoked, or whose
        // component versions no longer match this build is refused here exactly as a new
        // candidate would be (Requirement 10.17).
        do {
            return try await activate(id, context: context)
        } catch {
            throw error.analysisFault
        }
    }

    // MARK: - Step 7

    /// Writes the receipt, replaces the durable pointer, then commits in memory.
    ///
    /// The ordering is the whole content of this function, and each step is placed where it
    /// is for one reason:
    ///
    ///   0. The turn is taken first, so the read-derive-write sequence below is one activation
    ///      at a time even though it suspends. Released on every exit path.
    ///   1. The generation is read from the published pointer, so it counts activations that
    ///      actually happened rather than attempts.
    ///   2. The receipt is built and checked for bindability *before* anything is written,
    ///      so a receipt that could not authorize a session is never persisted.
    ///   3. The receipt is persisted before the pointer that names it, so a published pointer
    ///      never references a record that has not reached stable storage.
    ///   4. The pointer is staged, synchronized, and atomically published — three steps,
    ///      because an interruption between any two of them has to leave the published
    ///      pointer alone, and a single write-and-hope member could not offer that.
    ///   5. The in-memory tuple is replaced last, by one assignment that cannot fail. Every
    ///      earlier step can fail, and each failure leaves both the durable pointer and the
    ///      in-memory tuple exactly as they were.
    ///
    /// Internal rather than private, and reachable only from inside the module. Requirement
    /// 10.4 pins the weight-blob digest to one specific value, so no assembled candidate can
    /// reach step 7 through ``activate(_:context:)``; the only way to exercise the ordering
    /// above without weakening that check is to hand it a ``SelfTestedBundleCandidate`` built
    /// through the module-internal initializers. Nothing outside the module can call this, so
    /// it is not a way to activate a bundle that skipped a step.
    func commit(
        _ tested: SelfTestedBundleCandidate,
        context: ReleaseContext
    ) async throws(ModelBundleVerificationError) -> BoundModelBundle {
        await beginCommit()
        defer { endCommit() }

        let generation = try await nextGeneration()
        let receipt = try activationReceipt(for: tested, context: context, generation: generation)
        guard let bound = BoundModelBundle(
            manifest: tested.candidate.manifest,
            receipt: receipt
        ) else {
            // Unreachable for a candidate that reached this point, because the receipt
            // records outcomes taken from values that could not exist otherwise. Kept as a
            // refusal rather than a precondition: if the two ever disagree, the correct
            // answer is to leave the active bundle alone, not to trap.
            throw ModelBundleVerificationError.activationReceiptNotBindable(tested.bundleID)
        }

        do {
            try await store.persistReceipt(receipt)
        } catch {
            throw error == .receiptConflict
                ? ModelBundleVerificationError.activationReceiptConflict(receipt.id)
                : ModelBundleVerificationError.activationReceiptNotPersisted(receipt.id)
        }

        let staged: StagedActivationToken
        do {
            staged = try await store.stage(ActiveBundlePointer(receipt: receipt))
        } catch {
            throw ModelBundleVerificationError.activationPointerNotStaged(tested.bundleID)
        }

        do {
            try await store.synchronize(staged)
        } catch {
            await store.discard(staged)
            throw ModelBundleVerificationError.activationStateNotSynchronized(tested.bundleID)
        }

        do {
            try await store.publish(staged)
        } catch {
            await store.discard(staged)
            throw ModelBundleVerificationError.activationPointerNotReplaced(tested.bundleID)
        }

        // The commit. One assignment of one complete immutable value, with no failable
        // operation between it and the durable replacement that just succeeded.
        active = bound
        return bound
    }

    // MARK: - Taking a turn

    /// Waits until no other activation is inside step 7.
    ///
    /// Mutual exclusion over the read-derive-write sequence in ``commit(_:context:)``, which
    /// spans suspensions and therefore is not protected by actor isolation. Without it two
    /// overlapping activations read the same published pointer and derive the same generation,
    /// and the pointer stops distinguishing them.
    ///
    /// Non-cancelling on purpose. A waiter that abandoned its turn would either have to drop
    /// the turn — deadlocking the next waiter — or publish out of order, and an activation is
    /// short and entirely local. Every exit path from ``commit(_:context:)`` releases the turn
    /// through `defer`, including a thrown finding, so a refused activation never holds it.
    private func beginCommit() async {
        while isCommitting {
            await withCheckedContinuation { waitingCommits.append($0) }
        }
        isCommitting = true
    }

    /// Releases the turn and wakes the next waiter, if any.
    ///
    /// A woken waiter rechecks the flag rather than assuming the turn, so a caller that
    /// arrives in the gap between the release and the wake cannot cause two holders: the
    /// waiter simply queues again.
    private func endCommit() {
        isCommitting = false
        guard !waitingCommits.isEmpty else { return }
        waitingCommits.removeFirst().resume()
    }

    /// The generation this activation would publish.
    ///
    /// Read from the published pointer rather than counted in memory, so it survives a
    /// process restart and so a generation is never reused by a later launch. The in-memory
    /// tuple is taken into account as well, which matters in exactly one case: a store whose
    /// published pointer is somehow behind what this process already committed must not hand
    /// back a generation an observer has already seen.
    private func nextGeneration() async throws(ModelBundleVerificationError) -> PositiveCount {
        let published: ActiveBundlePointer?
        do {
            published = try await store.activePointer()
        } catch {
            throw ModelBundleVerificationError.activationRecordStoreUnavailable
        }
        let previous = max(
            published?.activationGeneration.value ?? 0,
            active?.activationGeneration.value ?? 0
        )
        let (next, overflow) = previous.addingReportingOverflow(1)
        guard !overflow, let generation = try? PositiveCount(validating: next) else {
            throw ModelBundleVerificationError.activationGenerationExhausted
        }
        return generation
    }

    /// Builds the immutable receipt this activation writes.
    ///
    /// Every field is a measurement or an identity carried by a value that could not exist
    /// if the corresponding check had not passed:
    ///
    ///   * the manifest digest and the complete artifact digest inventory come from the
    ///     verified tree, so they are what streaming measured rather than what the manifest
    ///     claimed (Requirement 10.5);
    ///   * `signatureOutcome` is `passed` because a ``VerifiedBundleArtifactTree`` exists
    ///     only for a candidate whose detached signature verified under a trusted key the
    ///     active policy admitted (Requirement 10.6); and
    ///   * `selfTestOutcome` is read from the ``SelfTestedBundleCandidate``, which exists
    ///     only for a run in which every declared expectation was compared and agreed
    ///     (Requirement 10.11).
    ///
    /// Nothing about a user's image reaches it. The receipt carries identifiers, digests of
    /// *bundle artifacts*, the device and build context, a generation, and an instant — no
    /// pixels, no fixture bytes, no logit, and no session identity (Requirement 9.11).
    private func activationReceipt(
        for tested: SelfTestedBundleCandidate,
        context: ReleaseContext,
        generation: PositiveCount
    ) throws(ModelBundleVerificationError) -> ActivationReceipt {
        let candidate = tested.candidate
        let activatedAt = clock.wallClockNow
        guard let id = Self.receiptIdentity(
            bundle: candidate.bundleID,
            generation: generation,
            at: activatedAt
        ) else {
            throw ModelBundleVerificationError.activationReceiptIdentityNotCanonical(
                candidate.bundleID
            )
        }
        do {
            return try ActivationReceipt(
                id: id,
                schemaVersion: .v1,
                bundleID: candidate.bundleID,
                verificationPolicy: candidate.tree.verificationPolicyID,
                verifiedManifestDigest: candidate.tree.manifestDigest,
                verifiedArtifactDigests: candidate.tree.verifiedArtifacts,
                signatureOutcome: .passed,
                selfTestOutcome: tested.selfTestOutcome,
                deviceContext: context.device,
                activationGeneration: generation,
                activatedAt: activatedAt
            )
        } catch let error as ArtifactSchemaError {
            throw ModelBundleVerificationError.activationReceiptRejectedBySchema(error)
        } catch {
            // `ActivationReceipt.init` validates only its digest inventory and throws
            // `ArtifactSchemaError`, so this is unreachable. Refusing rather than trapping
            // keeps the fail-closed direction: an unbuildable receipt leaves the active
            // bundle alone.
            throw ModelBundleVerificationError.activationReceiptNotBindable(candidate.bundleID)
        }
    }

    /// The identifier for one activation attempt's receipt.
    ///
    /// Derived rather than minted, so an audit can read which bundle, which generation, and
    /// which attempt a receipt belongs to without a lookup, and so two runs of the same
    /// attempt derive the same identity. The instant is part of it on purpose: an attempt
    /// whose publish was interrupted leaves a persisted receipt behind, and the retry is a
    /// separate attempt with a separate record rather than a rewrite of that one. Immutable
    /// means "these bytes never change", which is only achievable if a retry writes
    /// somewhere new.
    ///
    /// Returns `nil` when the derived text is not a canonical identifier — an overlong bundle
    /// identifier, or an instant outside the representable millisecond range. Fail closed:
    /// no receipt, no activation.
    static func receiptIdentity(
        bundle: ModelBundleID,
        generation: PositiveCount,
        at instant: Date
    ) -> ArtifactID? {
        let scaled = (instant.timeIntervalSince1970 * 1000).rounded()
        guard scaled.isFinite, abs(scaled) <= 9_000_000_000_000_000 else { return nil }
        let milliseconds = Int64(scaled)
        return ArtifactID("receipt.\(bundle.rawValue).\(generation.value).\(milliseconds)")
    }
}

import DefAIkeDomain

// The Share route's main-app ingest coordinator: the one place that decides what a pending
// handoff becomes.
//
// The Photos route's coordinator decides *whether a session exists*. This one does not have
// that freedom, and the difference is the whole reason it is a separate file. By the time
// the main app is involved, the extension's atomic publication has already created exactly
// one Analysis Session in `AwaitingMainApp` — a session the user consented to. So there are
// only two places a pending handoff can go:
//
//   * verified, and resumed under **the same** identifier with the active Model Bundle
//     bound (Requirements 2.3 and 11.12); or
//   * terminated, under that same identifier, with exactly one Analysis Error and no
//     evidence (Requirements 2.19 and 11.13).
//
// The ordering requirement is the thing this file makes structural. "Bind the Model Bundle
// only after successful verification" is not a comment here: ``bundles`` is unreachable
// until ``claiming`` has returned an accepted ingest, so a claim that throws cannot have
// touched the bundle manager, and a test can assert that as a nonoccurrence rather than
// review it by eye. The same holds downstream — nothing here validates, preprocesses,
// analyzes provenance, or infers, and it has no dependency that could.
//
// Deliberately absent: any retry of a failed claim, any way to resume a handoff under a new
// identifier, any way to bind a bundle before the claim, any evidence construction, and any
// presentation decision. What a user is shown for a `handoff-error` is the Result
// Presenter's, and the error is never an evidence verdict.

/// Why no Share session was resumed, when none had to fail either.
///
/// Both cases mean the app simply carries on: there is nothing pending and nothing to
/// report. They stay separate because a launch with no handoff and a handoff the user
/// discarded are different facts, and neither is an ``AnalysisError``.
public enum ShareHandoffRefusal: Hashable, Sendable {
    /// No published transfer is awaiting this app.
    ///
    /// The ordinary case: the user opened DefAIke without sharing anything, or a previous
    /// launch already claimed the handoff. Also covers material that named no session —
    /// an expired pending handoff, an ambiguous slot, or a publication that never
    /// committed — because none of those created a session to resume or to terminate.
    case nothingPending

    /// The store could not say whether anything is pending.
    ///
    /// Fail-closed and deliberately not an error terminal: with no readable ticket there is
    /// no session identifier, and attributing a failure to a session that may not exist
    /// would be worse than reporting nothing. The material is removed by the next startup
    /// cleanup.
    case pendingHandoffUnreadable
}

/// One resumed Share session: the verified bytes and the bundle bound to them.
///
/// Both, and in that order. The asset was verified before the bundle was requested, and the
/// bundle is the complete verified snapshot the session is bound to for its whole life —
/// a later activation or rollback cannot change it, because this value already holds it
/// (Requirements 10.14 and 10.15).
public struct ResumedShareSession: Hashable, Sendable {
    /// The accepted ingest, under the identifier the extension allocated.
    public let asset: ImportedEncodedAsset

    /// The verified active Model Bundle, bound after verification and not before.
    public let bundle: BoundModelBundle

    public init(asset: ImportedEncodedAsset, bundle: BoundModelBundle) {
        self.asset = asset
        self.bundle = bundle
    }

    /// The session that resumed, unchanged since staging (Requirement 2.3).
    public var sessionID: AnalysisSessionID { asset.sessionID }

    /// The single recorded route, always the Share route (Requirement 2.8).
    public var route: InputRoute { asset.route }
}

/// A pending session ending with exactly one Analysis Error and no evidence.
///
/// Carries the session identifier because the requirement is about *that* session: the
/// handoff failure terminates the already-pending session rather than refusing a new one
/// (Requirements 2.19 and 11.13). It carries no evidence field at all, so a failed handoff
/// cannot be represented as carrying a partial result.
public struct ShareHandoffTermination: Hashable, Sendable {
    /// The session that ends here.
    public let sessionID: AnalysisSessionID

    /// The single error category (Requirement 11.18).
    public let error: AnalysisError

    /// The stage it was detected in.
    public let stage: AnalysisStage

    public init(sessionID: AnalysisSessionID, error: AnalysisError, stage: AnalysisStage) {
        self.sessionID = sessionID
        self.error = error
        self.stage = stage
    }
}

/// Where one attempt to resume a pending handoff ended.
///
/// Four disjoint cases mirroring the state machine's edges out of `AwaitingMainApp`, plus
/// the case where there was no pending session at all. Exactly one of them carries evidence
/// bytes, exactly one carries an error, and neither can be read as the other.
public enum ShareHandoffIngestOutcome: Hashable, Sendable {
    /// The handoff verified and the session resumed with its bundle bound.
    case sessionResumed(ResumedShareSession)

    /// The pending session terminated with one error, before any validation, provenance,
    /// or inference work.
    case sessionFailed(ShareHandoffTermination)

    /// The pending session was cancelled or interrupted. No error, no evidence.
    ///
    /// The state machine's `AwaitingMainApp → Cancelled` edge. Cancellation is its own
    /// terminal outcome and must never be presented as a failure category
    /// (Requirement 11.17).
    case sessionCancelled(AnalysisSessionID)

    /// No session was resumed and none had to fail.
    case noSession(ShareHandoffRefusal)

    /// The resumed session, or `nil` in every other outcome.
    public var resumedSession: ResumedShareSession? {
        guard case .sessionResumed(let session) = self else { return nil }
        return session
    }

    /// The termination, or `nil` in every other outcome.
    public var termination: ShareHandoffTermination? {
        guard case .sessionFailed(let termination) = self else { return nil }
        return termination
    }

    /// The single error category, or `nil` when no session failed.
    public var error: AnalysisError? { termination?.error }
}

/// Resumes at most one pending Share handoff per activation.
///
/// Stateless and reusable: each call is a complete attempt that shares nothing with the
/// last one, so a failed handoff leaves behind no bytes, dimensions, error, or session
/// identity for the next one to inherit (Requirement 3.15).
public struct ShareHandoffIngestCoordinator: Sendable {
    private let claiming: any ShareTransferClaiming
    private let bundles: any ModelBundleManaging

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - claiming: The Share claim port. The coordinator reaches the App Group container
    ///     only through it, so it imports no `Foundation` file API and never sees a path.
    ///   - bundles: The Model Bundle port. Reached strictly after a successful claim and
    ///     never before, which is what makes the ordering requirement a property of this
    ///     type rather than of a call site.
    public init(claiming: any ShareTransferClaiming, bundles: any ModelBundleManaging) {
        self.claiming = claiming
        self.bundles = bundles
    }

    /// Claims the pending handoff, if there is one, and resumes or terminates its session.
    ///
    /// Ordered so that each step happens only after the one that could make it pointless:
    ///
    /// 1. Peek. An empty slot ends the attempt with no session and nothing claimed, so an
    ///    ordinary launch neither takes ownership of anything nor touches the bundle
    ///    manager.
    /// 2. Record the pending session identifier the peek reported. A claim failure has to
    ///    terminate *that* session, and the port's fault carries no identifier, so the
    ///    coordinator has to know it before it asks.
    /// 3. Claim. The adapter takes ownership atomically, recopies into app-private
    ///    protected storage, recomputes the byte count and digest, and compares them and
    ///    the ticket's schema, route, status, and staging build against what it measured.
    ///    Any mismatch throws, and the transfer is already deleted by then.
    /// 4. Only now bind the Model Bundle. Not before: an unverified handoff must not reach
    ///    bundle binding, image validation, provenance, or inference (Requirement 2.19).
    ///
    /// - Parameter context: The exact running build, device, and capability set. Its
    ///   `appBuild` is the claiming build identity the ticket's staging build is compared
    ///   against, so a ticket from another installed composition is refused before a byte
    ///   is read, and the same context is what the bundle is reverified as compatible with.
    public func resumePendingHandoff(
        context: ReleaseContext
    ) async -> ShareHandoffIngestOutcome {
        let pending: ReadyTransfer?
        do {
            pending = try await claiming.peekReadyTransfer()
        } catch {
            return .noSession(.pendingHandoffUnreadable)
        }
        guard let pending else { return .noSession(.nothingPending) }

        // The session the app observed as pending. If the claim fails, this is the session
        // that has to end, because it is the only one the app was ever told about. A slot
        // that changed between the peek and the claim is the same failure from the user's
        // side — one pending handoff did not verify — and the claim has already removed
        // whatever it took ownership of either way.
        let pendingSession = pending.ticket.sessionID

        let asset: ImportedEncodedAsset?
        do {
            asset = try await claiming.claimReadyTransfer(
                claimingBuildID: context.device.appBuild
            )
        } catch {
            switch error {
            case .cancelled:
                return .sessionCancelled(pendingSession)
            case .analysis(let category, let stage):
                return .sessionFailed(
                    ShareHandoffTermination(
                        sessionID: pendingSession,
                        error: category,
                        stage: stage
                    )
                )
            }
        }
        guard let asset else {
            // The slot emptied between the peek and the claim: another claimer won it, or
            // it expired and was discarded under the lifecycle policy. Nothing is pending
            // now, and nothing failed.
            return .noSession(.nothingPending)
        }

        guard asset.route == .shareExtension else {
            // A claim that returned an ingest attributed to another route is not this
            // route's session. Unreachable through the shipping adapter, which carries the
            // ticket's route; kept as a fail-closed branch because binding a session to
            // bytes recorded under a different route is exactly what Requirement 2.8
            // forbids.
            return .sessionFailed(
                ShareHandoffTermination(
                    sessionID: pendingSession,
                    error: .handoffError,
                    stage: .handoffVerification
                )
            )
        }

        // Verification passed. Only now is the bundle bound.
        do {
            let bundle = try await bundles.verifiedActiveBundle(for: context)
            return .sessionResumed(
                ResumedShareSession(asset: asset, bundle: bundle)
            )
        } catch {
            switch error {
            case .cancelled:
                return .sessionCancelled(asset.sessionID)
            case .analysis(let category, let stage):
                // The handoff verified; the bundle did not. The category is the bundle
                // port's and is deliberately not rewritten as a handoff failure — an
                // unverifiable active bundle is not a corrupted transfer.
                return .sessionFailed(
                    ShareHandoffTermination(
                        sessionID: asset.sessionID,
                        error: category,
                        stage: stage
                    )
                )
            }
        }
    }
}

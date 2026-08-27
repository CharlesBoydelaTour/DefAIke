import DefAIkeDomain

// Terminal cleanup: the one place a session's end selects its cleanup deadline.
//
// Requirement 9.8 removes a session's material on completion, cancellation, or an Analysis
// Error, and Requirement 11.15 names the cancellation deadline specifically. Each of those
// is a *different* approved number, so the interesting question is not whether deletion
// happens but which deadline it is audited against. This type answers it by deriving both
// the reason and the deadline, so neither is a parameter:
//
//   * The reason comes from ``SessionTerminalOutcome``, which is the value the coordinator
//     already committed. A caller cannot ask for the completed deadline for a cancelled
//     session, because there is nowhere to say so.
//   * The deadline comes from the bound ``DataLifecyclePolicy`` keyed by that reason. There
//     is no compiled-in duration here and no argument that overrides one: the five numbers
//     are an unresolved approved release input (Requirement 9.7).
//
// Startup cleanup is deliberately absent. ``StartupPreflight`` already runs it as step 5
// through the same ``SessionDataDeleting`` port and refuses to produce a ``ReleaseAdmission``
// when it fails, which is what keeps both ingest routes closed after a failed startup
// cleanup. Adding a second entry point for it here would be a second cleanup path with its
// own idea of when ingest is allowed.

/// What one terminal cleanup did.
///
/// A result rather than a thrown error, because a cleanup failure is not an analysis
/// outcome. The session has already committed its terminal state, the user has already been
/// shown it, and ``AnalysisError`` has no category for "the file system refused a
/// deletion" — presenting one would invent a failure the analysis did not have. The
/// material that could not be removed is material with no terminal deletion receipt, which
/// is exactly what the next start removes as abandoned before accepting new work
/// (Requirement 11.16).
public enum SessionCleanupResult: Hashable, Sendable {
    /// The session's material is gone, with the receipt that proves it.
    case removed(SessionDeletionReceipt)

    /// The store refused. Nothing here is presentable to a user.
    case failed(EphemeralStoreError)

    /// The receipt, or `nil` when cleanup failed.
    public var receipt: SessionDeletionReceipt? {
        guard case .removed(let receipt) = self else { return nil }
        return receipt
    }

    /// The store fault, or `nil` when cleanup succeeded.
    public var storeFault: EphemeralStoreError? {
        guard case .failed(let fault) = self else { return nil }
        return fault
    }

    /// Whether the session's material was removed.
    public var isRemoved: Bool { receipt != nil }
}

/// Removes one session's material as soon as it reaches a terminal outcome.
///
/// Stateless and reusable. It holds the policy this build is bound to, so every session it
/// cleans up is audited against the same approved artifact version.
public struct SessionTerminalCleanup: Sendable {
    private let deleter: any SessionDataDeleting

    /// The bound Data Lifecycle Policy, and the only source of every deadline used here.
    public let policy: DataLifecyclePolicy

    /// Creates the cleanup.
    ///
    /// - Parameters:
    ///   - deleter: The Privacy Controller's deletion port. It owns every session directory,
    ///     so this type never names a path and never touches the file system.
    ///   - policy: The versioned policy whose five deadlines the receipts are audited
    ///     against. Bind the one the startup gate validated, reachable as
    ///     ``ReleaseAdmission``'s configuration, so runtime cleanup and the startup gate
    ///     cannot be governed by two different policy versions.
    public init(deleter: any SessionDataDeleting, policy: DataLifecyclePolicy) {
        self.deleter = deleter
        self.policy = policy
    }

    /// Removes everything `sessionID` owns, under the deadline `outcome` selects.
    ///
    /// The three terminal outcomes map onto three different approved deadlines, and the
    /// mapping is ``SessionTerminalOutcome/endReason``'s rather than this type's, so a
    /// completed session and a cancelled one cannot be audited against the same number by
    /// accident.
    ///
    /// Safe to call more than once for the same session: the port's deletion is idempotent,
    /// so a repeat removes nothing and still returns a receipt, reporting a zero count.
    @discardableResult
    public func removeMaterial(
        for sessionID: AnalysisSessionID,
        after outcome: SessionTerminalOutcome
    ) async -> SessionCleanupResult {
        await removeMaterial(for: sessionID, reason: outcome.endReason)
    }

    /// The deadline a terminal outcome selects, before any deletion happens.
    ///
    /// Exposed so a caller can record which approved number governs a cleanup it is about to
    /// start without reimplementing the reason mapping.
    public func deadline(for outcome: SessionTerminalOutcome) -> ValidatedDuration {
        policy.deadline(for: outcome.endReason.cleanupReason)
    }

    private func removeMaterial(
        for sessionID: AnalysisSessionID,
        reason: SessionEndReason
    ) async -> SessionCleanupResult {
        do {
            return .removed(
                try await deleter.deleteSession(sessionID, reason: reason, policy: policy)
            )
        } catch {
            return .failed(error)
        }
    }
}

import DefAIkeDomain
import Foundation

// The Privacy Controller's deletion adapter.
//
// This is the real ``SessionDataDeleting``: the one path by which an Analysis Session's
// retained bytes leave the device's file system. The design gives the Privacy Controller
// two jobs — it "owns session directories and deletion receipts" — and this type is the
// second half of that sentence sitting on top of ``ProtectedEphemeralFileStore``, which is
// the first.
//
// Four rules shape it, and each one rules out a shorter implementation:
//
//   * **Every app-controlled namespace, not the convenient one.** The design defines
//     deletion as "removal from all app-controlled file-system namespaces", so the deleter
//     holds a list of namespaces rather than one store. A session that was resumed from a
//     claimed handoff can own material in the App Group container *and* in app-private
//     storage, and removing one of the two would satisfy no requirement.
//   * **Deletion is verified, not assumed.** Requirement 9.17 is about what is left, not
//     about what was attempted, so after clearing a session the deleter asks its
//     namespaces again and fails closed if anything still names that session. A store that
//     silently kept a directory would otherwise be reported as a successful cleanup.
//   * **Failure blocks, it does not warn.** ``deleteAbandonedData(policy:)`` throws when a
//     namespace refused, and ``StartupPreflight`` turns that into
//     ``PreflightFailure/startupCleanupFailed(_:)``. Since ``ReleaseAdmission`` is the only
//     value that permits ingest and it cannot be produced without that call returning,
//     failing startup cleanup keeps both ingest routes closed rather than logging a
//     warning and continuing (Requirements 9.9 and 11.16).
//   * **The deadline is read, never chosen.** Every receipt's deadline comes from the
//     injected ``DataLifecyclePolicy`` keyed by the reason the caller's terminal outcome
//     selected. There is no compiled-in duration and no parameter that overrides one: the
//     five numbers are an unresolved approved release input (Requirement 9.7).
//
// Deletion itself is immediate in every case. A cleanup reason selects which approved
// deadline the receipt is audited against; it never delays the removal.
//
// The transfer namespace is handled by delegation rather than by deleting transfer scopes
// here. ``SharedTransferStore/runStartupCleanup()`` already knows the one thing a blind
// sweep would destroy: a published handoff the user consented to survives a restart until
// its lifecycle deadline passes, and staging and claimed residue never does. Reaching that
// through the transfer store keeps a single cleanup path for the App Group's `transfers`
// subtree and still lets a transfer-store failure block ingest.

/// One app-controlled file-system namespace that can hold session material.
///
/// An adapter-local seam, in the same sense as ``DataProtectionApplying``: it exists so the
/// fail-closed path can be exercised without a file system that refuses a removal, and so
/// the deleter can hold several namespaces without knowing how any of them is laid out.
/// ``ProtectedEphemeralFileStore`` is the shipping conformance.
public protocol SessionStorageNamespace: Sendable {
    /// Every session this namespace still holds anything for, including a scope directory
    /// whose objects are already gone.
    func sessionsWithStoredMaterial() async -> Set<AnalysisSessionID>

    /// Removes everything this namespace holds for one session.
    ///
    /// Idempotent by contract: a session with nothing left removes nothing and still
    /// succeeds, so repeated cleanup, cleanup after an interruption, and cleanup after a
    /// previous removal of the same session all behave identically.
    func clearSessionMaterial(
        for sessionID: AnalysisSessionID,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt
}

extension ProtectedEphemeralFileStore: SessionStorageNamespace {
    public func sessionsWithStoredMaterial() -> Set<AnalysisSessionID> {
        var sessions: Set<AnalysisSessionID> = []
        for scope in knownScopes() {
            // Transfer scopes are the handoff lifecycle's, even when they share this root.
            // Sweeping them here would delete a consented pending handoff.
            guard case .session(let sessionID) = scope else { continue }
            sessions.insert(sessionID)
        }
        return sessions
    }

    public func clearSessionMaterial(
        for sessionID: AnalysisSessionID,
        reason: SessionCleanupReason
    ) throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        try deleteAll(in: .session(sessionID), reason: reason)
    }
}

/// Everything the Privacy Controller still holds once a cleanup has run.
///
/// This is the design's retention allowlist made checkable. Both members are receipts, and
/// a receipt records a reason, an artifact identifier, a deadline, a count, and an instant —
/// no bytes, no decoded pixels, no dimensions, no digest of user content, and no evidence.
/// Nothing image-derived is representable here, which is what makes "only non-image records
/// survive" a fact about the type rather than a claim about the code.
///
/// The records live in memory for as long as the process does. They are not written to disk:
/// a persisted receipt would itself be application-controlled storage that outlived its
/// session, and Requirement 11.16 already defines the fallback for a process that died
/// holding them — material found with no live session at the next start is abandoned and
/// removed before any new session is accepted.
public struct RetainedCleanupRecords: Hashable, Sendable {
    /// One receipt per session this deleter removed material for, in issue order.
    public let sessionReceipts: [SessionDeletionReceipt]

    /// Receipts from the transfer namespace's own startup cleanup.
    ///
    /// A transfer slot has no session identity of its own, so it produces a scope receipt
    /// rather than a ``SessionDeletionReceipt``.
    public let transferReceipts: [EphemeralDeletionReceipt]

    public init(
        sessionReceipts: [SessionDeletionReceipt],
        transferReceipts: [EphemeralDeletionReceipt]
    ) {
        self.sessionReceipts = sessionReceipts
        self.transferReceipts = transferReceipts
    }

    /// Total objects removed across every receipt.
    public var removedObjectCount: Int {
        sessionReceipts.reduce(0) { $0 + $1.removedObjectCount }
            + transferReceipts.reduce(0) { $0 + $1.removedObjectCount }
    }
}

/// Removes Analysis Session material from every app-controlled namespace.
///
/// An actor because cleanup is read-then-act — list what a namespace holds, remove it, then
/// confirm nothing remains — and a concurrent terminal deletion arriving between those
/// steps would let one call report a completeness it did not establish.
public actor ProtectedSessionDataDeleter: SessionDataDeleting {

    private let namespaces: [any SessionStorageNamespace]
    private let transfers: SharedTransferStore?
    private let clock: any SessionClock

    private var sessionReceipts: [SessionDeletionReceipt] = []
    private var transferReceipts: [EphemeralDeletionReceipt] = []

    /// Creates the deleter.
    ///
    /// - Parameters:
    ///   - namespaces: Every app-controlled namespace that can hold session material,
    ///     usually the app-private store and the App Group store. An empty list is
    ///     accepted and owns nothing: it is the honest configuration for a process with no
    ///     session storage, and it deletes nothing rather than pretending to.
    ///   - transfers: The App Group handoff store, when this process has one. Present, its
    ///     startup cleanup runs as part of ``deleteAbandonedData(policy:)``, so the
    ///     `transfers` subtree is covered by the same fail-closed startup gate as the
    ///     `sessions` subtree. Absent — a unit test, or a process with no registered App
    ///     Group — nothing about the transfer subtree is claimed.
    ///   - clock: Wall-clock readings for receipt timestamps. Deadline evaluation is the
    ///     policy's; nothing here compares an elapsed duration.
    public init(
        namespaces: [any SessionStorageNamespace],
        transfers: SharedTransferStore? = nil,
        clock: any SessionClock = SystemSessionClock()
    ) {
        self.namespaces = namespaces
        self.transfers = transfers
        self.clock = clock
    }

    // MARK: - Inspection

    /// The records this deleter kept, which are the only records that survive cleanup.
    public func retainedRecords() -> RetainedCleanupRecords {
        RetainedCleanupRecords(
            sessionReceipts: sessionReceipts,
            transferReceipts: transferReceipts
        )
    }

    // MARK: - SessionDataDeleting

    /// Removes everything one session owns, under the deadline its terminal reason selects.
    ///
    /// One call covers the whole session: retained encoded bytes, decoded image data, model
    /// inputs, raw logits, provenance lane data, Pixel Evidence, report data, and error data
    /// all live in objects owned by ``EphemeralStorageScope/session(_:)``, so removing the
    /// scope removes the set Requirement 9.8 names rather than a list this type has to keep
    /// in step with later stages.
    ///
    /// Idempotent: a second call finds nothing, removes nothing, and still returns a receipt
    /// — with a zero count, which is how an audit tells a repeated deletion from the first
    /// one (Requirements 11.15 and 11.16).
    public func deleteSession(
        _ id: AnalysisSessionID,
        reason: SessionEndReason,
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> SessionDeletionReceipt {
        let cleanupReason = reason.cleanupReason
        var removed = 0
        var failure: EphemeralStoreError?
        for namespace in namespaces {
            do {
                removed += try await namespace
                    .clearSessionMaterial(for: id, reason: cleanupReason)
                    .removedObjectCount
            } catch {
                // Keep going. A namespace that refused must not stop the others from being
                // emptied: partial removal leaves strictly less on disk than stopping does,
                // and the call still fails so nothing treats this as a completed cleanup.
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        try await requireNothingRemains(forAnyOf: [id])

        let receipt = SessionDeletionReceipt(
            sessionID: id,
            reason: cleanupReason,
            lifecyclePolicyID: policy.id,
            deadline: policy.deadline(for: cleanupReason),
            removedObjectCount: removed,
            completedAt: clock.wallClockNow
        )
        sessionReceipts.append(receipt)
        return receipt
    }

    /// Removes material found with no live session and no terminal deletion receipt.
    ///
    /// A restart is the evidence: a process that was interrupted or terminated left whatever
    /// it was holding, and this runs before either ingest route is exposed, so every session
    /// scope it can see belongs to a session that is already over. The receipts are
    /// ``SessionCleanupReason/abandoned`` because that is the deadline Requirement 9.9 names
    /// for material found at startup, and ``StartupPreflight`` checks the reason and the
    /// deadline on every receipt against the bound policy.
    ///
    /// The transfer namespace is swept through ``SharedTransferStore/runStartupCleanup()``,
    /// which removes interrupted staging and claimed residue and keeps exactly one
    /// unexpired published handoff. Those removals carry their own reasons and produce scope
    /// receipts, not session receipts: a transfer slot names no session until its ticket is
    /// resolved.
    ///
    /// Idempotent: a second run finds no session scope and no transfer material, returns an
    /// empty array, and succeeds. Empty never means "cleanup was skipped" — reaching a
    /// return at all required every namespace to answer.
    public func deleteAbandonedData(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt] {
        var removedBySession: [AnalysisSessionID: Int] = [:]
        var failure: EphemeralStoreError?

        for namespace in namespaces {
            for sessionID in await namespace.sessionsWithStoredMaterial() {
                do {
                    let receipt = try await namespace.clearSessionMaterial(
                        for: sessionID,
                        reason: .abandoned
                    )
                    removedBySession[sessionID, default: 0] += receipt.removedObjectCount
                } catch {
                    failure = failure ?? error
                }
            }
        }

        if let transfers {
            do {
                transferReceipts.append(
                    contentsOf: try await transfers.runStartupCleanup().receipts
                )
            } catch {
                failure = failure ?? Self.storeError(from: error)
            }
        }

        if let failure { throw failure }
        try await requireNothingRemains(forAnyOf: Set(removedBySession.keys))

        // Deterministic order, so a receipt list is comparable across runs and across the
        // two namespaces' unordered set answers.
        let issued = removedBySession.keys
            .sorted { $0.rawValue < $1.rawValue }
            .map { sessionID in
                SessionDeletionReceipt(
                    sessionID: sessionID,
                    reason: .abandoned,
                    lifecyclePolicyID: policy.id,
                    deadline: policy.deadline(for: .abandoned),
                    removedObjectCount: removedBySession[sessionID] ?? 0,
                    completedAt: clock.wallClockNow
                )
            }
        sessionReceipts.append(contentsOf: issued)
        return issued
    }

    // MARK: - Completeness

    /// Fails unless no namespace holds anything for any of `sessions` any more.
    ///
    /// Requirement 9.17 is a statement about what is left once a deadline passes, so a
    /// cleanup that removed some of a session's material and reported success would satisfy
    /// the call and not the requirement. Asking again is cheap — one directory listing per
    /// namespace — and it turns an incomplete removal into a failure, which blocks ingest
    /// when it happens at startup and is retried at the next start when it does not.
    private func requireNothingRemains(
        forAnyOf sessions: Set<AnalysisSessionID>
    ) async throws(EphemeralStoreError) {
        guard !sessions.isEmpty else { return }
        for namespace in namespaces {
            guard await namespace.sessionsWithStoredMaterial().isDisjoint(with: sessions) else {
                throw .storeUnavailable
            }
        }
    }

    /// The store fault behind a transfer-store failure.
    ///
    /// Exhaustive on purpose: a new ``TransferStoreError`` case must stop this compiling
    /// rather than inherit a mapping nobody chose. Only ``TransferStoreError/store(_:)``
    /// carries a store fault; the rest describe publication outcomes that startup cleanup
    /// cannot produce, so they collapse to the unclassified fault rather than being reported
    /// as something more specific than what is known.
    private static func storeError(from error: TransferStoreError) -> EphemeralStoreError {
        switch error {
        case .store(let underlying):
            underlying
        case .pendingHandoffExists, .stagingFailed, .manifestTooLarge, .ticketRejected:
            .storeUnavailable
        }
    }
}

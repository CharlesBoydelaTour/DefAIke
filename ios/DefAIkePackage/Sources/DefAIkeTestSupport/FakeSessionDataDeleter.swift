import DefAIkeDomain

/// A ``SessionDataDeleting`` over ``InMemoryEphemeralStore``.
///
/// Real deletion semantics against a virtual store, which is what the cleanup property
/// needs (Property 25):
///
///   * a deleted session owns nothing afterwards, so the ownership set is empty;
///   * a second deletion succeeds and reports zero removals, so cleanup is idempotent;
///   * abandoned cleanup sweeps every scope with no live session, including transfer
///     slots an interrupted extension left behind; and
///   * a live session is never swept, so startup cleanup cannot delete the session it is
///     about to accept work for.
///
/// The deadline is read from the injected policy for every deletion, never from a constant
/// here. Deletion is immediate: the deadline is what a receipt is audited against, not a
/// delay the double invents.
public actor FakeSessionDataDeleter: SessionDataDeleting {
    private let store: InMemoryEphemeralStore
    private let clock: VirtualSessionClock
    private let recorder: PortCallRecorder?
    private var liveSessions: Set<AnalysisSessionID> = []
    private var receipts: [SessionDeletionReceipt] = []

    public init(
        store: InMemoryEphemeralStore,
        clock: VirtualSessionClock,
        recorder: PortCallRecorder? = nil
    ) {
        self.store = store
        self.clock = clock
        self.recorder = recorder
    }

    // MARK: - Programming

    /// Marks a session live, so abandoned cleanup leaves it alone.
    public func registerLiveSession(_ id: AnalysisSessionID) {
        liveSessions.insert(id)
    }

    /// Marks a session no longer live, without deleting anything.
    ///
    /// This is the "the process was interrupted" setup: material exists, no session is
    /// live, and no terminal deletion receipt was written.
    public func forgetLiveSession(_ id: AnalysisSessionID) {
        liveSessions.remove(id)
    }

    // MARK: - Inspection

    /// Every receipt issued, in order.
    public func issuedReceipts() -> [SessionDeletionReceipt] { receipts }

    // MARK: - SessionDataDeleting

    public func deleteSession(
        _ id: AnalysisSessionID,
        reason: SessionEndReason,
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> SessionDeletionReceipt {
        recorder?.record(.deleteSession(id))
        let cleanupReason = reason.cleanupReason
        let storeReceipt = try await store.deleteAll(
            in: .session(id),
            reason: cleanupReason
        )
        liveSessions.remove(id)
        let receipt = SessionDeletionReceipt(
            sessionID: id,
            reason: cleanupReason,
            lifecyclePolicyID: policy.id,
            deadline: policy.deadline(for: cleanupReason),
            removedObjectCount: storeReceipt.removedObjectCount,
            completedAt: clock.wallClockNow
        )
        receipts.append(receipt)
        return receipt
    }

    public func deleteAbandonedData(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt] {
        recorder?.record(.deleteAbandonedData)
        var issued: [SessionDeletionReceipt] = []
        for scope in await store.occupiedScopes() {
            switch scope {
            case .session(let sessionID):
                guard !liveSessions.contains(sessionID) else { continue }
                let storeReceipt = try await store.deleteAll(in: scope, reason: .abandoned)
                let receipt = SessionDeletionReceipt(
                    sessionID: sessionID,
                    reason: .abandoned,
                    lifecyclePolicyID: policy.id,
                    deadline: policy.deadline(for: .abandoned),
                    removedObjectCount: storeReceipt.removedObjectCount,
                    completedAt: clock.wallClockNow
                )
                receipts.append(receipt)
                issued.append(receipt)
            case .transfer:
                // Transfer slots have no session identity of their own, so they are swept
                // without a session receipt. An unclaimed slot left by an interrupted
                // extension must not survive into the next launch.
                _ = try await store.deleteAll(in: scope, reason: .interrupted)
            }
        }
        return issued
    }
}

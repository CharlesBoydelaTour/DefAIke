import Foundation

// The cleanup port.
//
// The Privacy Controller owns every session directory and every deletion receipt. This
// port is the only way session material is removed, and it takes the Data Lifecycle
// Policy as a parameter rather than reading a deadline from anywhere in code: the five
// numeric deadlines are approved release values (Requirement 9.7).
//
// Both members are idempotent by contract. Requirement 11.16 requires cleanup of
// abandoned material at the next start and before accepting new work, which means the
// same deletion may run after a completed deletion, after an interruption, and again on
// the following launch. A second call succeeds with nothing left to remove (Property 25).

/// Proof that one session's material no longer exists.
///
/// Kept so a later start can distinguish "already deleted under its deadline" from
/// "abandoned with no terminal deletion". The receipt records the reason, the deadline
/// that applied, and when deletion completed; it carries no bytes, no dimensions, no
/// evidence, and no error category.
public struct SessionDeletionReceipt: Hashable, Sendable {
    public let sessionID: AnalysisSessionID
    public let reason: SessionCleanupReason

    /// The policy version whose deadline applied.
    public let lifecyclePolicyID: ArtifactID

    /// The deadline that applied to this reason.
    public let deadline: ValidatedDuration

    /// How many stored objects were removed. Zero on a repeated deletion.
    public let removedObjectCount: Int

    /// Wall-clock instant deletion completed, for deadline auditing.
    public let completedAt: Date

    public init(
        sessionID: AnalysisSessionID,
        reason: SessionCleanupReason,
        lifecyclePolicyID: ArtifactID,
        deadline: ValidatedDuration,
        removedObjectCount: Int,
        completedAt: Date
    ) {
        self.sessionID = sessionID
        self.reason = reason
        self.lifecyclePolicyID = lifecyclePolicyID
        self.deadline = deadline
        self.removedObjectCount = removedObjectCount
        self.completedAt = completedAt
    }
}

/// Removes ephemeral Analysis Session material within the active policy deadlines.
///
/// Fails only because the underlying store failed, which is why the fault type is
/// ``EphemeralStoreError`` and not ``AnalysisError``: a cleanup problem is an internal
/// privacy-controller fault, never a user-facing evidence category, and it must not be
/// reported as an analysis outcome.
public protocol SessionDataDeleting: Sendable {
    /// Removes everything one session owns: retained encoded bytes, decoded image data,
    /// model inputs, raw logits, provenance lane data, Pixel Evidence, report data, and
    /// error data (Requirement 9.8).
    ///
    /// `reason` selects the deadline; the deletion itself is immediate. The reason is a
    /// ``SessionEndReason``, matching the terminal outcome the coordinator committed, and
    /// maps one-to-one onto the policy's ``SessionCleanupReason`` keys.
    func deleteSession(
        _ id: AnalysisSessionID,
        reason: SessionEndReason,
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> SessionDeletionReceipt

    /// Removes material found with no live session and no terminal deletion receipt.
    ///
    /// Runs at every application and extension start, before any new session is accepted,
    /// so an interrupted or terminated process cannot leave analyzable bytes behind
    /// (Requirement 11.16). Returns one receipt per scope it cleaned, and an empty array
    /// when there was nothing to clean.
    func deleteAbandonedData(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt]
}

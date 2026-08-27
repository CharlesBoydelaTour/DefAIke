import DefAIkeDomain
import Foundation

// The lifecycle policy and cleanup-port double the terminal cleanup needs.
//
// **No deadline in this file is an approved release value.** The five numeric cleanup
// deadlines are an unresolved external decision (design decision D7). The fixture gives each
// reason a *different* number so an assertion can name which entry was read; that
// distinctness is the only meaningful property here, and nothing may be copied into a
// shipping artifact.

extension Fixture {
    static func duration(_ milliseconds: UInt64) -> ValidatedDuration {
        do {
            return try ValidatedDuration(validating: milliseconds)
        } catch {
            preconditionFailure("\(milliseconds)ms is not a valid duration: \(error)")
        }
    }

    static func approver(_ raw: String = "role.release-owner") -> ApproverID {
        guard let id = ApproverID(raw) else {
            preconditionFailure("fixture approver identifier is not canonical: \(raw)")
        }
        return id
    }

    static func approval(_ artifact: String) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(artifact),
            decision: .approved,
            approver: approver(),
            decidedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    /// Milliseconds this fixture assigns to each cleanup reason. All different, so reading
    /// the wrong entry is visible.
    static let cleanupDeadlineMilliseconds: [SessionCleanupReason: UInt64] = [
        .completed: 1_000,
        .cancelled: 2_000,
        .errorTerminated: 3_000,
        .interrupted: 4_000,
        .abandoned: 5_000,
    ]

    static func lifecyclePolicy(
        id: String = "data-lifecycle-0001"
    ) -> DataLifecyclePolicy {
        do {
            return try DataLifecyclePolicy(
                id: artifactID(id),
                schemaVersion: .v1,
                deadlines: try SessionCleanupReason.allCases.map { reason in
                    DataLifecyclePolicy.Deadline(
                        reason: reason,
                        // A missing entry fails the fixture rather than defaulting: a
                        // deadline no test declared must not silently become zero-adjacent.
                        deadline: try ValidatedDuration(
                            validating: cleanupDeadlineMilliseconds[reason] ?? 0
                        )
                    )
                },
                approval: approval("data-lifecycle-approval")
            )
        } catch {
            preconditionFailure("the lifecycle policy fixture must be schema-valid: \(error)")
        }
    }

    /// A completed terminal outcome, which selects the completion deadline.
    static func completedOutcome() -> SessionTerminalOutcome {
        guard let report = EvidenceReport(
            binding: SessionSample.binding(),
            pixel: .noStrongSignalDetected,
            provenance: .unavailable(.validatorNotCompiledIntoRelease),
            combinedSummary: nil,
            apparentInconsistency: nil,
            bytePreservationStatus: .unknown,
            inputQuality: SessionSample.inputQuality,
            onDeviceProcessing: true,
            scope: SessionSample.scope
        ) else {
            preconditionFailure("the evidence report fixture must be internally consistent")
        }
        return .completed(report)
    }

    /// A failed terminal outcome, which selects the error-terminated deadline.
    static func failedOutcome(
        sessionID: AnalysisSessionID = Fixture.sessionID(),
        error: AnalysisError = .decodingError
    ) -> SessionTerminalOutcome {
        guard let snapshot = AnalysisFailureSnapshot(
            sessionID: sessionID,
            error: error,
            stage: .inputValidation,
            bytePreservationStatus: nil,
            inputQuality: nil
        ) else {
            preconditionFailure("the failure snapshot fixture must be constructible")
        }
        return .failed(snapshot)
    }
}

// MARK: - Cleanup port double

/// A ``SessionDataDeleting`` that records every call and answers what a test queued.
///
/// It records the *policy* it was handed as well as the reason, because the thing under test
/// is a binding: the reason has to come from the terminal outcome and the deadline from that
/// policy's entry for it. A double that only recorded the session identifier could not tell a
/// correct deadline from a coincidence.
actor RecordingSessionDataDeleter: SessionDataDeleting {

    struct TerminalCall: Hashable, Sendable {
        let sessionID: AnalysisSessionID
        let reason: SessionEndReason
        let policyID: ArtifactID
    }

    private(set) var terminalCalls: [TerminalCall] = []
    private(set) var abandonedCallCount = 0
    private var queuedFaults: [EphemeralStoreError] = []
    private var removedObjectCount: Int

    init(removedObjectCount: Int = 1) {
        self.removedObjectCount = removedObjectCount
    }

    /// Makes the next deletion fail. Queued, so successive calls can differ.
    func failNextDeletion(with fault: EphemeralStoreError) {
        queuedFaults.append(fault)
    }

    /// What the next deletion reports as removed.
    func setRemovedObjectCount(_ count: Int) {
        removedObjectCount = count
    }

    func deleteSession(
        _ id: AnalysisSessionID,
        reason: SessionEndReason,
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> SessionDeletionReceipt {
        terminalCalls.append(
            TerminalCall(sessionID: id, reason: reason, policyID: policy.id)
        )
        if !queuedFaults.isEmpty { throw queuedFaults.removeFirst() }
        let cleanupReason = reason.cleanupReason
        return SessionDeletionReceipt(
            sessionID: id,
            reason: cleanupReason,
            lifecyclePolicyID: policy.id,
            // Read from the policy it was handed, never from a constant here.
            deadline: policy.deadline(for: cleanupReason),
            removedObjectCount: removedObjectCount,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func deleteAbandonedData(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt] {
        abandonedCallCount += 1
        if !queuedFaults.isEmpty { throw queuedFaults.removeFirst() }
        return []
    }
}

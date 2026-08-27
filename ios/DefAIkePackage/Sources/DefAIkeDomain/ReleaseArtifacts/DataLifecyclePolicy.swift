import Foundation

// The signed Data Lifecycle Policy and Extension Execution Policy.
//
// Requirement 9.7 requires versioned numeric cleanup deadlines for completed,
// cancelled, error-terminated, interrupted, and abandoned session data before
// distribution. The numbers are decision D7 and stay unresolved; the schema requires
// all five as positive, bounded, decided values, so a build cannot run with an
// implicit "clean up eventually".

/// Why a session's data is being removed.
///
/// One reason selects one deadline. The set is closed, so cleanup cannot be asked to
/// run for a reason the policy has no deadline for.
public enum SessionCleanupReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// The session completed and its Evidence Report was displayed.
    case completed
    /// The user cancelled the session.
    case cancelled
    /// The session ended with an Analysis Error.
    case errorTerminated = "error-terminated"
    /// iOS interrupted or terminated the process; measured from the next start.
    case interrupted
    /// Session material was found at startup with no terminal deletion receipt.
    case abandoned
}

/// The versioned policy that fixes every cleanup deadline.
public struct DataLifecyclePolicy: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// One deadline per cleanup reason, covering the closed reason set exactly.
    public let deadlines: [Deadline]

    /// The release record that approved these deadlines.
    public let approval: ApprovalRecord

    /// One reason and the deadline that applies to it.
    public struct Deadline: Hashable, Codable, Sendable {
        public let reason: SessionCleanupReason
        public let deadline: ValidatedDuration

        public init(reason: SessionCleanupReason, deadline: ValidatedDuration) {
            self.reason = reason
            self.deadline = deadline
        }
    }

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        deadlines: [Deadline],
        approval: ApprovalRecord
    ) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            deadlines.map(\.reason.rawValue),
            required: Set(SessionCleanupReason.allCases.map(\.rawValue)),
            field: "lifecycleDeadlines"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.deadlines = deadlines
        self.approval = approval
    }

    /// The deadline for one reason. Total by construction.
    public func deadline(for reason: SessionCleanupReason) -> ValidatedDuration {
        // Safe: the initializer proved every reason appears exactly once.
        deadlines.first { $0.reason == reason }!.deadline
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, deadlines, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                deadlines: container.decode([Deadline].self, forKey: .deadlines),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Extension execution

/// iOS data-protection level applied to staged handoff material.
///
/// The design defaults to complete protection unless physical-device validation shows
/// that a supported handoff lifecycle needs a different level, and records that choice
/// here rather than in code.
public enum FileProtectionLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case complete
    case completeUnlessOpen = "complete-unless-open"
    case completeUntilFirstUserAuthentication = "complete-until-first-user-authentication"
}

/// What a later Share invocation does while a ready handoff already exists.
///
/// The single ready-slot rule prevents two pending images from being ambiguous.
/// Silently replacing the pending handoff is representable so the schema can reject
/// it: replacement would discard a handoff the user already consented to.
public enum PendingHandoffPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Offer a recovery instruction to open or discard the pending handoff.
    case instructRecovery = "instruct-recovery"
    /// Replace the pending handoff without asking. Rejected.
    case replaceSilently = "replace-silently"
}

/// The versioned policy bound to every distributed build (Requirement 11.9).
///
/// It fixes the three Share Extension behaviors the requirements make mandatory:
/// visible consent before handoff, no inference in the extension, and protected
/// staging. All three are required fields, and the two unsafe values are rejected by
/// name rather than being unrepresentable, so a review can see what was refused.
public struct ExtensionExecutionPolicy: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// Always true (Requirements 2.2 and 11.10).
    public let requiresVisibleConsent: Bool

    /// Always true (Requirement 11.11).
    public let delegatesInferenceToMainApplication: Bool

    public let stagedFileProtection: FileProtectionLevel
    public let pendingHandoffPolicy: PendingHandoffPolicy

    /// The physical-device evidence behind the protection level choice.
    public let protectionEvidence: EvidenceSource

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        requiresVisibleConsent: Bool,
        delegatesInferenceToMainApplication: Bool,
        stagedFileProtection: FileProtectionLevel,
        pendingHandoffPolicy: PendingHandoffPolicy,
        protectionEvidence: EvidenceSource
    ) throws {
        guard requiresVisibleConsent else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "extensionExecution.requiresVisibleConsent",
                value: "false",
                reason: "every handoff needs a visible user-consent action"
            )
        }
        guard delegatesInferenceToMainApplication else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "extensionExecution.delegatesInferenceToMainApplication",
                value: "false",
                reason: "the Share Extension runs no model inference"
            )
        }
        guard pendingHandoffPolicy == .instructRecovery else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "extensionExecution.pendingHandoffPolicy",
                value: pendingHandoffPolicy.rawValue,
                reason: "a consented pending handoff cannot be replaced silently"
            )
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.requiresVisibleConsent = requiresVisibleConsent
        self.delegatesInferenceToMainApplication = delegatesInferenceToMainApplication
        self.stagedFileProtection = stagedFileProtection
        self.pendingHandoffPolicy = pendingHandoffPolicy
        self.protectionEvidence = protectionEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, requiresVisibleConsent, delegatesInferenceToMainApplication
        case stagedFileProtection, pendingHandoffPolicy, protectionEvidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                requiresVisibleConsent: container.decode(
                    Bool.self,
                    forKey: .requiresVisibleConsent
                ),
                delegatesInferenceToMainApplication: container.decode(
                    Bool.self,
                    forKey: .delegatesInferenceToMainApplication
                ),
                stagedFileProtection: container.decode(
                    FileProtectionLevel.self,
                    forKey: .stagedFileProtection
                ),
                pendingHandoffPolicy: container.decode(
                    PendingHandoffPolicy.self,
                    forKey: .pendingHandoffPolicy
                ),
                protectionEvidence: container.decode(
                    EvidenceSource.self,
                    forKey: .protectionEvidence
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

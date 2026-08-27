// Disjoint terminal outcomes and the evidence-free failure snapshot.

/// Why an Analysis Session's data is being removed.
///
/// The five reasons match the five cleanup deadlines a Data Lifecycle Policy
/// defines. The numeric deadlines are externally approved values the domain does
/// not carry; this vocabulary only says which deadline applies.
public enum SessionEndReason: String, Codable, Sendable, CaseIterable {
    case completed
    case cancelled
    case error
    /// The process was interrupted or terminated; found on a later start.
    case interrupted
    /// Session data outlived its session with no terminal deletion receipt.
    case abandoned
}

/// The diagnostic record of one failed Analysis Session.
///
/// Carries exactly one ``AnalysisError`` (Requirement 11.18) and no evidence: there
/// is no field for Pixel Evidence, a provenance state, or a Combined Summary, so a
/// failure cannot carry a partial verdict. What was already measured before the
/// failure is preserved rather than discarded, which is what lets the presenter
/// still show byte status and recorded pre-orientation dimensions for a failed
/// session (Requirement 3.14).
///
/// Both preserved fields are optional because a session can fail before either was
/// recorded. Neither is ever reconstructed, defaulted, or guessed.
public struct AnalysisFailureSnapshot: Hashable, Sendable {
    /// The only schema version this build produces.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    /// The session that failed. A new session never inherits this identity.
    public let sessionID: AnalysisSessionID

    /// The single committed error category.
    public let error: AnalysisError

    /// Where the failure was detected.
    public let stage: AnalysisStage

    /// Byte status, when it had been recorded before the failure.
    public let bytePreservationStatus: BytePreservationStatus?

    /// Measurements taken before the failure, when any had been taken.
    public let inputQuality: InputQualityRecord?

    /// Creates a snapshot, or `nil` for an unreadable schema version.
    public init?(
        schemaVersion: Int = AnalysisFailureSnapshot.currentSchemaVersion,
        sessionID: AnalysisSessionID,
        error: AnalysisError,
        stage: AnalysisStage,
        bytePreservationStatus: BytePreservationStatus?,
        inputQuality: InputQualityRecord?
    ) {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.error = error
        self.stage = stage
        self.bytePreservationStatus = bytePreservationStatus
        self.inputQuality = inputQuality
    }
}

/// The one terminal outcome of an Analysis Session.
///
/// The three cases are disjoint and cannot transition into one another. Evidence is
/// reachable from ``completed`` alone: ``cancelled`` carries no payload at all, and
/// ``failed`` carries a snapshot with no evidence field. A late framework result
/// that arrives after a terminal commit therefore has nowhere to land, which is what
/// makes "cancellation prevents every evidence commit" a structural property rather
/// than a timing guarantee (Requirements 11.17, 11.18, and 15.7).
///
/// Deliberately not `Codable`: a terminal outcome is held in memory for the active
/// session and then discarded. There is no result persistence or export.
public enum SessionTerminalOutcome: Hashable, Sendable {
    /// One immutable Evidence Report.
    case completed(EvidenceReport)
    /// The user cancelled. No evidence, no error, no partial result.
    case cancelled
    /// Exactly one Analysis Error, with no evidence.
    case failed(AnalysisFailureSnapshot)

    /// The report, or `nil` for every non-completed outcome.
    public var evidenceReport: EvidenceReport? {
        guard case .completed(let report) = self else { return nil }
        return report
    }

    /// The failure snapshot, or `nil` for every non-failed outcome.
    public var failure: AnalysisFailureSnapshot? {
        guard case .failed(let snapshot) = self else { return nil }
        return snapshot
    }

    /// The single error category, or `nil` for every non-failed outcome.
    public var error: AnalysisError? { failure?.error }

    public var isCompleted: Bool { evidenceReport != nil }

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    public var isFailed: Bool { failure != nil }

    /// The cleanup reason this outcome selects.
    public var endReason: SessionEndReason {
        switch self {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .error
        }
    }
}

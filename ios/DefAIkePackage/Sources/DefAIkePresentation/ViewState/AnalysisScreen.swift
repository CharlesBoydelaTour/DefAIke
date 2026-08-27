import DefAIkeDomain

// The six mutually exclusive screen families, and why they are one enum.
//
// The design gives the Result Presenter mutually exclusive screen families, and the
// requirements make several claims that hold only if that exclusivity is real: a progress
// state is replaced by exactly one distinct terminal state (Requirement 15.7); an Analysis
// Error presents its category and a recovery action with no evidence verdict (Requirements
// 4.17 and 11.18); cancelled is a terminal disjoint from completed and failed
// (Requirement 11.17); and every error category is distinguishable from every label,
// provenance state, summary, and the cancelled state (Requirement 11.17).
//
// A set of independent booleans - `isLoading`, `hasError`, `showResult` - can express all
// of those violations at once, and every one of them is a plausible one-line bug. So the
// families are the cases of a single enum. Exactly one is inhabited at any moment because
// an enum value *is* one case, and the compiler refuses a fresh combination rather than
// rendering it:
//
//   * There is no field to hold two families, so "progress plus result" is not a state to
//     get into.
//   * Each family's payload holds only what that family shows. ``ActiveScreen`` has no
//     evidence, error, or summary member; ``CompletedScreen`` has no progress member;
//     ``AnalysisErrorScreen`` has no evidence member; ``CancelledScreen`` has no error
//     member. A percentage therefore cannot sit beside a verdict, and a cancellation cannot
//     acquire an error category, for the same reason a `String` cannot hold an `Int`.
//   * ``ReadyScreen`` has no stored property at all, which is what makes recovery clean:
//     every ready screen is the same value, so no failed session's identity, category,
//     dimensions, byte status, or evidence can survive into the next one
//     (Requirements 3.13 and 3.15).
//
// What no screen here carries, in any family: a probability, a confidence value or level, a
// numeric score, a raw logit, a graphical magnitude, or a free-form user-facing `String`.
// Wording arrives only as a ``ResolvedCopyReference`` addressed through the session's
// version-bound approved copy, so no screen can write its own sentence.

/// Which screen family a view state inhabits.
///
/// A flat, closed, enumerable list, so a test can assert something for every family and a
/// new family cannot be added without the assertion noticing.
public enum AnalysisScreenFamily: String, Hashable, Sendable, CaseIterable {
    case ready
    case importing
    case active
    case completed
    case cancelled
    case error
}

/// The recovery a terminal screen offers.
///
/// One case by construction, and the constraint is the point. A terminal outcome cannot
/// transition into another one (Requirement 11.17), and a new session may inherit no data
/// from a failed one (Requirement 3.15), so "resume", "retry this session", "recompute", and
/// "show the previous result again" are all unrepresentable. Recovery means one thing:
/// select an image and start a new Analysis Session, which the application permits without a
/// restart (Requirement 3.13).
public enum SessionRecovery: String, Hashable, Sendable, CaseIterable {
    /// Selecting another image begins a new Analysis Session.
    case selectAnotherImage
}

/// A user-facing surface this projection needs and the closed Approved Verdict Copy
/// vocabulary does not define.
///
/// Recorded rather than filled in. Approved copy is addressed by surface, the surface
/// vocabulary is closed, and it has entries for labels, explanations, provenance states,
/// summaries, limitations, errors, and error recovery - but none for progress status,
/// the cancel control, the cancelled terminal, the start-a-new-session action, or an import
/// in flight. No approved wording for those exists in the repository.
///
/// So this projection resolves no copy for them and renders no text for them. Inventing a
/// sentence, or rendering a localization key, would put unapproved user-facing language on
/// screen, which is exactly what the approved-copy binding exists to prevent. Listing the
/// gaps as values means a release audit and the later accessibility and view tasks can
/// enumerate what is still missing instead of discovering it at render time.
///
/// Closing a gap is a release-artifact change: extend the approved surface vocabulary,
/// approve the wording, and add the String Catalog value. It is not a change to this file.
public enum UnapprovedViewStateSurface: String, Hashable, Sendable, CaseIterable {
    /// Status text for an active session with a measured readout.
    case measuredProgressStatus
    /// Status text asserting that unmeasured analysis work is continuing.
    case continuingProgressStatus
    /// The cancellation control's own label.
    case cancellationControl
    /// Status text for the cancelled terminal state.
    case cancelledTerminalStatus
    /// The action that starts a new Analysis Session after a terminal outcome.
    case startNewSessionAction
    /// Status text for an ingest attempt in flight.
    case importInProgressStatus
}

// MARK: - Family payloads

/// The ready screen: no ingest attempt, no session, nothing retained.
///
/// Deliberately empty. Every instance is equal to every other instance, so a ready screen
/// reached after a failed, cancelled, or completed session is indistinguishable from the one
/// the application launched with. That is the structural form of "the new session is
/// initialized without any error category or session data from the failed session"
/// (Requirement 3.15): there is no member for a category, an identity, a dimension, a byte
/// status, or a verdict to persist in.
public struct ReadyScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The only ready screen there is.
    public static let awaitingSelection = ReadyScreen()

    init() {}
}

/// The importing screen: one image is being retrieved and no session exists yet.
///
/// Carries the route and nothing else. No progress readout, because a provider retrieval
/// reports no measured completed-work and total-work amounts to this layer and a synthesized
/// one would be an estimate presented as a measurement. No cancellation availability,
/// because Requirement 15.5 scopes the visible, enabled cancel control to active *analysis*
/// work and dismissing a system picker is the picker's own affordance. No error, because a
/// retrieval that produces nothing is a recoverable ingest attempt rather than a session
/// that failed.
public struct ImportingScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The route the image is arriving through.
    public let attempt: ImportAttemptSnapshot

    init(attempt: ImportAttemptSnapshot) {
        self.attempt = attempt
    }
}

/// The active screen: analysis work is in flight for one session attempt.
///
/// Holds progress and the cancel control, and holds no evidence, summary, or error member.
/// Requirement 15.1 keeps this family on screen until the work completes, is cancelled, or
/// returns an Analysis Error, and Requirement 15.5 keeps cancellation available for all of
/// it - which here is not a rule to follow but the only value ``cancellation`` can take.
public struct ActiveScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The attempt whose work is in flight.
    public let identity: SessionAttemptIdentity

    /// What the work reported about itself, projected for display.
    public let progress: ProjectedWorkProgress

    /// The cancel control's availability. Visible and enabled, always.
    public let cancellation: CancellationAvailability

    init(identity: SessionAttemptIdentity, progress: ProjectedWorkProgress) {
        self.identity = identity
        self.progress = progress
        self.cancellation = .visibleAndEnabled
    }
}

/// The completed screen: one Evidence Report, with both source lanes resolved.
///
/// The two lanes are separate members holding separately resolved presentations, so neither
/// can suppress, override, or rank the other (Requirements 7.1 and 7.8). The optional
/// summary and the optional apparent-inconsistency notice sit alongside both lanes rather
/// than in place of either.
///
/// Assembling these into cards, limitations, and technical details is separate work. What
/// this family fixes is that a completed session shows a report, that the report's own lanes
/// are what is shown, and that there is no progress member for a percentage to reappear in
/// beside a verdict.
public struct CompletedScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The attempt that completed.
    public let identity: SessionAttemptIdentity

    /// The immutable report this session produced.
    public let report: EvidenceReport

    /// The pixel source lane, resolved against the session's approved copy.
    public let pixel: PixelLabelPresentation

    /// The provenance source lane, resolved against the session's approved copy. Present
    /// for every completed session, including as the unavailable state.
    public let provenance: ProvenanceLanePresentation

    /// The Combined Summary, when an approved fusion rule produced one.
    public let combinedSummary: CombinedSummaryPresentation?

    /// The apparent-inconsistency notice the report declared, when it declared one.
    public let apparentInconsistency: ResolvedCopyReference?

    /// What this screen offers next. Always a new session from a new selection.
    public let recovery: SessionRecovery

    init(
        identity: SessionAttemptIdentity,
        report: EvidenceReport,
        pixel: PixelLabelPresentation,
        provenance: ProvenanceLanePresentation,
        combinedSummary: CombinedSummaryPresentation?,
        apparentInconsistency: ResolvedCopyReference?
    ) {
        self.identity = identity
        self.report = report
        self.pixel = pixel
        self.provenance = provenance
        self.combinedSummary = combinedSummary
        self.apparentInconsistency = apparentInconsistency
        self.recovery = .selectAnotherImage
    }
}

/// The cancelled screen: the user stopped the work, and there is no result.
///
/// A terminal state in its own right, disjoint from completed and from failed
/// (Requirement 11.17). It carries no evidence and, just as deliberately, no Analysis Error:
/// cancellation is not one of the ten error categories and must never be presented as a
/// failure, so there is no member here for a category to be written into.
///
/// It carries no progress either. Requirement 15.7 replaces the active progress state with
/// the terminal state, so a cancelled screen showing "72%" is not a state this type can
/// hold.
public struct CancelledScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The attempt that was cancelled.
    public let identity: SessionAttemptIdentity

    /// What this screen offers next. Always a new session from a new selection.
    public let recovery: SessionRecovery

    init(identity: SessionAttemptIdentity) {
        self.identity = identity
        self.recovery = .selectAnotherImage
    }
}

/// The error screen: exactly one Analysis Error category and a recovery action.
///
/// Requirements 4.17 and 11.18 give a failed session one category, one recovery, and no
/// evidence verdict. There is no evidence, lane, or summary member here, so "the error plus
/// a partial result" is unrepresentable rather than merely avoided.
///
/// The measurements a failed session had already recorded are preserved rather than
/// discarded (Requirement 3.14). Both are optional because a session can fail before either
/// was recorded, and neither is ever reconstructed or defaulted when it was not.
public struct AnalysisErrorScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The attempt that failed.
    public let identity: SessionAttemptIdentity

    /// The single error category and its approved message and recovery copy.
    public let presentation: AnalysisErrorPresentation

    /// The byte status recorded before the failure, when it had been recorded.
    public let bytePreservationStatus: BytePreservationStatus?

    /// The pre-orientation measurements taken before the failure, when any were taken.
    public let inputQuality: InputQualityRecord?

    /// What this screen offers next. Always a new session from a new selection.
    public let recovery: SessionRecovery

    init(
        identity: SessionAttemptIdentity,
        presentation: AnalysisErrorPresentation,
        bytePreservationStatus: BytePreservationStatus?,
        inputQuality: InputQualityRecord?
    ) {
        self.identity = identity
        self.presentation = presentation
        self.bytePreservationStatus = bytePreservationStatus
        self.inputQuality = inputQuality
        self.recovery = .selectAnotherImage
    }
}

// MARK: - The screen

/// The one screen family the application is showing.
///
/// One value, one case, one family. Two families cannot be shown at once and none can be
/// shown alongside another, because that is what an enum is.
public enum AnalysisScreen: Hashable, Sendable {
    case ready(ReadyScreen)
    case importing(ImportingScreen)
    case active(ActiveScreen)
    case completed(CompletedScreen)
    case cancelled(CancelledScreen)
    case error(AnalysisErrorScreen)

    /// The ready screen, with nothing retained from any session.
    public static let awaitingSelection = AnalysisScreen.ready(.awaitingSelection)

    /// Which family this screen inhabits.
    public var family: AnalysisScreenFamily {
        switch self {
        case .ready: .ready
        case .importing: .importing
        case .active: .active
        case .completed: .completed
        case .cancelled: .cancelled
        case .error: .error
        }
    }

    /// The attempt this screen describes, or `nil` for the ready and importing families.
    ///
    /// `nil` is not an omission: neither family has an attempt. The ready screen holds
    /// nothing, and an ingest attempt is not yet an Analysis Session.
    public var identity: SessionAttemptIdentity? {
        switch self {
        case .ready, .importing: nil
        case let .active(screen): screen.identity
        case let .completed(screen): screen.identity
        case let .cancelled(screen): screen.identity
        case let .error(screen): screen.identity
        }
    }

    /// The session this screen describes, or `nil` when it describes none.
    public var sessionID: AnalysisSessionID? { identity?.sessionID }

    /// Displayed work progress, or `nil` outside the active family.
    ///
    /// Non-`nil` exactly for ``AnalysisScreenFamily/active``. A completed, cancelled, or
    /// failed screen has no progress to read, which is Requirement 15.7 as a type rather
    /// than as a transition rule.
    public var workProgress: ProjectedWorkProgress? {
        guard case let .active(screen) = self else { return nil }
        return screen.progress
    }

    /// The cancel control's availability, or `nil` outside the active family.
    ///
    /// Non-`nil` exactly while analysis work is active, and its only value is visible and
    /// enabled (Requirement 15.5).
    public var cancellation: CancellationAvailability? {
        guard case let .active(screen) = self else { return nil }
        return screen.cancellation
    }

    /// The Evidence Report, or `nil` outside the completed family.
    ///
    /// Non-`nil` exactly for ``AnalysisScreenFamily/completed``. No other family can reach a
    /// report, so no error, cancellation, or progress surface can show one.
    public var evidenceReport: EvidenceReport? {
        guard case let .completed(screen) = self else { return nil }
        return screen.report
    }

    /// The single Analysis Error category, or `nil` outside the error family.
    ///
    /// Non-`nil` exactly for ``AnalysisScreenFamily/error``. In particular it is `nil` for
    /// the cancelled family: cancellation is not an error category (Requirement 11.17).
    public var analysisError: AnalysisError? {
        guard case let .error(screen) = self else { return nil }
        return screen.presentation.error
    }

    /// The recovery this screen offers, or `nil` for a nonterminal family.
    ///
    /// Non-`nil` for exactly the three terminal families, so every terminal outcome offers a
    /// way forward and no in-flight family offers one that would abandon running work.
    public var recovery: SessionRecovery? {
        switch self {
        case .ready, .importing, .active: nil
        case let .completed(screen): screen.recovery
        case let .cancelled(screen): screen.recovery
        case let .error(screen): screen.recovery
        }
    }

    /// Whether this screen shows one of the three terminal outcomes.
    public var isTerminal: Bool {
        switch self {
        case .ready, .importing, .active: false
        case .completed, .cancelled, .error: true
        }
    }

    /// Whether work is in flight that a user must not be interrupted out of.
    ///
    /// True for the active family and for an ingest attempt. Used to refuse a recovery
    /// action that would replace a running session's screen and take its cancel control off
    /// screen with it (Requirement 15.5).
    public var isWorkInFlight: Bool {
        switch self {
        case .importing, .active: true
        case .ready, .completed, .cancelled, .error: false
        }
    }
}

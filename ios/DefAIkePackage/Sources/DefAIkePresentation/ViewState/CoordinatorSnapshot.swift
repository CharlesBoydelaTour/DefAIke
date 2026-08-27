import DefAIkeDomain

// The immutable observation a screen is projected from.
//
// The Result Presenter has to render what the Analysis Coordinator is doing, and it has to
// do so without becoming able to influence it. So the input is a *value*: one immutable
// snapshot per observation, carrying only what a screen needs, with no port, no closure, no
// actor reference, and no mutable handle anywhere in it. Everything a screen shows is a
// projection of one such value, which is what makes the projection a pure function and the
// screen reproducible from the snapshot alone.
//
// The snapshot vocabulary is defined here rather than imported, because this module depends
// on the domain and on nothing else. That boundary is deliberate and worth stating: the
// presentation layer cannot reach the coordinator's own observation members, so it cannot
// poll a running session, cancel one, or read a stage that no snapshot handed it. The
// composition root reads the coordinator and fills in one of these values. Everything in a
// snapshot is a domain type or a small wrapper over one, so filling it in is a copy rather
// than a translation that could disagree with the session.
//
// Three shapes the snapshot cannot take, each because a requirement forbids the state it
// would describe:
//
//   * **A session with both progress and a terminal outcome.** ``SessionWorkPhase`` is an
//     enum, so a snapshot describes work in flight or one committed terminal, never both
//     (Requirement 11.17).
//   * **A failure carrying evidence.** The terminal outcome is the domain's own
//     ``SessionTerminalOutcome``, whose failure case carries an evidence-free snapshot
//     (Requirement 11.18). There is no evidence field to populate alongside an error.
//   * **A cancellation carrying an error category.** The cancelled case has no payload at
//     all, so cancellation cannot be described as, or upgraded into, an Analysis Error.

/// One Analysis Session attempt, named so a screen can tell two attempts apart.
///
/// The identifier alone is not enough. A released identifier can be bound again, so a
/// second attempt can legitimately carry the same ``AnalysisSessionID``; the attempt
/// generation is what distinguishes them. The pair mirrors the identity the coordinator
/// stamps on every asynchronous callback, which is what lets a view state refuse an
/// observation of an attempt that has already been superseded.
///
/// It carries no bytes, dimensions, evidence, error, path, or filename, so holding one
/// cannot leak session content.
public struct SessionAttemptIdentity: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The session this attempt runs under.
    public let sessionID: AnalysisSessionID

    /// Which attempt this is. Minted by the coordinator, monotonic, and never reused.
    public let attemptGeneration: UInt64

    public init(sessionID: AnalysisSessionID, attemptGeneration: UInt64) {
        self.sessionID = sessionID
        self.attemptGeneration = attemptGeneration
    }
}

/// Where one Analysis Session attempt is: still working, or ended.
///
/// Disjoint by construction. An attempt has work in flight *or* exactly one terminal
/// outcome, and a snapshot cannot describe an attempt that is both progressing and
/// finished.
public enum SessionWorkPhase: Hashable, Sendable {
    /// Analysis work is in flight, with the progress state the coordinator derived for it.
    ///
    /// The progress state arrives already derived. Nothing in this module decides whether a
    /// completion fraction exists, and nothing synthesizes one from elapsed time.
    case working(AnalysisProgressState)

    /// The attempt committed exactly one terminal outcome.
    case ended(SessionTerminalOutcome)

    /// The progress state of work in flight, or `nil` once the attempt ended.
    public var progress: AnalysisProgressState? {
        guard case let .working(progress) = self else { return nil }
        return progress
    }

    /// The single committed terminal outcome, or `nil` while work is in flight.
    public var terminalOutcome: SessionTerminalOutcome? {
        guard case let .ended(outcome) = self else { return nil }
        return outcome
    }
}

/// One immutable observation of one Analysis Session attempt.
///
/// `copy` travels with the snapshot rather than being held by the projector, because an
/// Approved Verdict Copy binding belongs to one session: a later bundle activation or
/// rollback cannot change a running session, so copy is bound per session exactly as the
/// bundle is. A projection checks that the binding names this snapshot's session and
/// refuses otherwise, so one session's screen can never be rendered through another
/// session's approved copy.
public struct AnalysisSessionSnapshot: Hashable, Sendable {
    /// The attempt this observation describes.
    public let identity: SessionAttemptIdentity

    /// Whether that attempt is working or has ended.
    public let phase: SessionWorkPhase

    /// The Approved Verdict Copy binding for this session.
    public let copy: ApprovedCopyBinding

    public init(
        identity: SessionAttemptIdentity,
        phase: SessionWorkPhase,
        copy: ApprovedCopyBinding
    ) {
        self.identity = identity
        self.phase = phase
        self.copy = copy
    }

    /// The session this observation belongs to.
    public var sessionID: AnalysisSessionID { identity.sessionID }
}

/// One immutable observation of an ingest attempt.
///
/// An ingest attempt is not an Analysis Session. The system may have to retrieve an iCloud
/// asset and can fail before the application holds any bytes, so retrieval is a recoverable
/// attempt that creates no session, commits no terminal outcome, and produces no Analysis
/// Error to display. That is why this value carries no session identity, no progress
/// measurement, and no error: there is no session to name and nothing measured to report.
public struct ImportAttemptSnapshot: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The route the image is arriving through.
    public let route: InputRoute

    public init(route: InputRoute) {
        self.route = route
    }
}

/// One immutable observation of what the application is doing.
///
/// Total over the three situations a screen can be projected from, and disjoint: there is
/// no observation that is idle *and* importing, or importing *and* running a session.
public enum CoordinatorSnapshot: Hashable, Sendable {
    /// No ingest attempt and no Analysis Session. Nothing to show but the ready screen.
    case idle

    /// One image is being retrieved. No session exists yet.
    case importing(ImportAttemptSnapshot)

    /// One Analysis Session attempt, working or ended.
    case session(AnalysisSessionSnapshot)

    /// The attempt this observation describes, or `nil` when no session exists.
    public var attemptIdentity: SessionAttemptIdentity? {
        guard case let .session(snapshot) = self else { return nil }
        return snapshot.identity
    }
}

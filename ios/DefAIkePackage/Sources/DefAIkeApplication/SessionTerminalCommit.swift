import DefAIkeDomain

// The write-once terminal slot, and the identity every callback carries.
//
// Requirement 11.17 gives a session exactly one of three terminal outcomes and
// Requirement 11.18 gives a failure exactly one Analysis Error and no evidence.
// ``SessionTerminalOutcome`` already makes the *shape* of that unrepresentable otherwise:
// the three cases are disjoint, cancellation carries no payload, and a failure snapshot
// has no evidence field. What is left is the part a type cannot state on its own — that
// the value is written **once** — and that is this file.
//
// The slot is a value type with one mutating member. That is deliberate, and it is what
// makes a second commit impossible rather than merely unlikely:
//
//   * The refusal lives in the value, not in the caller. ``claim(_:)`` compares and then
//     sets in one expression, so there is no call site that could read the slot, decide it
//     is empty, and set it later. A caller that ignores the returned
//     ``TerminalCommit`` still cannot overwrite anything.
//   * There is no `reset`, no setter, and no way to clear a claimed slot. A new session
//     gets a new slot, so "start over" is a new value rather than a mutation of this one —
//     which is also how a retry inherits nothing (Requirement 3.15).
//   * ``claim(_:)`` is synchronous and has no suspension point. Held inside an actor,
//     compare-and-set therefore runs in one indivisible step: an actor does not hold its
//     executor across an `await`, but it does hold it across a contiguous run of
//     synchronous work, so two overlapping commits cannot both find the slot empty.
//
// The identity is the other half. Every asynchronous callback carries the session
// identifier and the operation generation, so a result that arrives after its session
// ended is refused by identity rather than by timing. A generation is never reused, which
// is what lets the same session identifier be analyzed again after a failure without the
// second attempt inheriting the first attempt's late results.

/// One session attempt, named so a late result can be recognized as belonging to it.
///
/// The identifier alone is not enough. A released identifier can be bound again, so a
/// second attempt can legitimately carry the same ``AnalysisSessionID``; without the
/// generation, a framework call still running from the first attempt would look like a
/// current one. The pair is what the design means by carrying the Session ID *and* the
/// operation generation.
///
/// It carries no bytes, dimensions, evidence, path, or error, so passing it into a
/// callback cannot leak session content, and its description spells only the generation.
public struct AnalysisSessionIdentity: Hashable, Sendable, CustomStringConvertible {
    /// The session this attempt runs under.
    public let sessionID: AnalysisSessionID

    /// Which attempt this is, counted by the coordinator and never reused.
    ///
    /// Starts at 1. Monotonic for the life of the coordinator, including across sessions,
    /// so two attempts are distinguishable even when they share an identifier.
    public let generation: UInt64

    public init(sessionID: AnalysisSessionID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }

    /// Omits the session identifier, which is a session-correlatable value
    /// (Requirement 9.11). Diagnostics that legitimately need it read ``sessionID``.
    public var description: String {
        "AnalysisSessionIdentity(generation: \(generation))"
    }
}

/// What one attempt to commit a terminal outcome did.
///
/// Four disjoint answers, and only one of them changed anything. A caller learns which,
/// rather than being told the commit succeeded and quietly losing its result.
public enum TerminalCommit: Hashable, Sendable {
    /// This outcome is now the session's single terminal.
    case committed(SessionTerminalOutcome)

    /// The session already committed a terminal, which stands unchanged.
    ///
    /// The direct enforcement of Requirement 11.17's monotonicity: `completed`,
    /// `cancelled`, and `failed` cannot transition into one another, so a second offer is
    /// refused and the first outcome is handed back rather than replaced.
    case refusedAlreadyTerminal(SessionTerminalOutcome)

    /// The outcome belongs to a session attempt that is no longer running.
    ///
    /// A late framework result recognized by identity. Its temporary output is deleted
    /// with the rest of that attempt's material and can never become evidence.
    case refusedStaleIdentity(offered: AnalysisSessionIdentity)

    /// No session is running, so there is nothing to commit a terminal for.
    case refusedNoActiveSession

    /// The outcome that stands after this attempt, or `nil` when no session was involved.
    ///
    /// Non-`nil` for a successful commit and for a refusal that reported the existing
    /// terminal, and the same value in both cases — which is the observable form of
    /// "committing twice cannot change the answer".
    public var standingOutcome: SessionTerminalOutcome? {
        switch self {
        case .committed(let outcome): outcome
        case .refusedAlreadyTerminal(let outcome): outcome
        case .refusedStaleIdentity, .refusedNoActiveSession: nil
        }
    }

    /// Whether this attempt is the one that set the terminal.
    public var didCommit: Bool {
        if case .committed = self { return true }
        return false
    }
}

/// A terminal outcome slot that can be written exactly once.
///
/// Not `public`: nothing outside this module should be able to hold a slot, because a
/// slot's whole value is that the coordinator owns the only one per session. It is a
/// separate type rather than an optional field so that the compare-and-set is a member of
/// the thing being protected.
struct TerminalCommitSlot: Hashable, Sendable {
    private var outcome: SessionTerminalOutcome?

    /// An unclaimed slot.
    init() {
        self.outcome = nil
    }

    /// The committed outcome, or `nil` while the session is still active.
    var committed: SessionTerminalOutcome? { outcome }

    /// Whether a terminal has been committed.
    var isTerminal: Bool { outcome != nil }

    /// Claims the slot for `candidate`, or refuses and reports what already stands.
    ///
    /// Compare and set in one synchronous step. There is no branch that leaves the slot
    /// occupied by anything other than the first claim, and no branch that returns
    /// ``TerminalCommit/committed(_:)`` without having written it.
    mutating func claim(_ candidate: SessionTerminalOutcome) -> TerminalCommit {
        if let outcome { return .refusedAlreadyTerminal(outcome) }
        outcome = candidate
        return .committed(candidate)
    }
}

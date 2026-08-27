import DefAIkeDomain

// Cooperative cancellation, and the values that make a late framework result stale by
// identity rather than by timing.
//
// The design fixes five steps, and the interesting thing about them is which are
// guarantees and which are best effort:
//
//   1. The visible cancel action immediately marks the session cancellation-requested and
//      **disables all future evidence commits**. A guarantee, and a structural one: the
//      request claims the write-once terminal slot with `cancelled` in the same
//      synchronous actor step that latches it, so from that instant every other offer —
//      including a completed report the pipeline is about to produce — is refused by the
//      slot rather than by a check a later stage might skip.
//   2. Structured tasks, any available framework progress, and adapter cancellation hooks
//      are cancelled. **Best effort**, and deliberately so: a framework call that has
//      already entered cannot be forcibly preempted, and the design "does not promise
//      unsupported preemption". What is guaranteed is that the request reaches every
//      registered hook exactly once, in registration order.
//   3. Stage boundaries and bounded-loop boundaries check cancellation. Cooperative: the
//      adapters in this graph already fail closed on ``Task/isCancelled`` and throw
//      ``AnalysisFault/cancelled``, so cancelling the session's structured task is what
//      makes an in-flight decode, preprocessing pass, or prediction stop at its next
//      chunk or stage boundary.
//   4. A framework call that completes anyway has its result discarded by session
//      identifier and generation. A guarantee, and the reason this file carries an
//      admission vocabulary: staleness is a function of the recorded identity and the
//      terminal slot, both read in one synchronous step, so it never depends on which
//      call returned first.
//   5. Cleanup begins as soon as the owned handles can be released, under the cancelled
//      reason's approved deadline. The coordinator's single end path already selects that
//      deadline from the committed outcome, so cancellation reaches it by committing
//      `cancelled` and nothing else.
//
// What is deliberately absent:
//
//   * **No Analysis Error for cancellation.** ``AnalysisFault/cancelled`` and
//     ``SessionTerminalOutcome/cancelled`` carry no category and no stage, and nothing
//     here invents one. A user who withdrew the input is not told the input failed
//     (Requirement 11.17).
//   * **No clock, deadline, or elapsed-time member.** Cancellation is requested by a
//     user action, never derived from how long work has taken (Requirement 15.10).
//   * **No second cleanup path.** A cancellation request does not delete anything itself.
//     While a framework call is still in flight it still owns the handles, so the removal
//     runs where every other terminal's removal runs — which is also what keeps a repeat
//     request from racing a deletion.
//   * **No cancellation for a session that already committed.** A completed or failed
//     terminal stands; the three outcomes cannot transition into one another.

/// Names one registered framework cancellation hook.
///
/// Opaque and process-local, for the same reason ``SiblingWorkToken`` is: it carries no
/// image-derived value, no path, and no session-correlatable value, and its description
/// omits the discriminator so it cannot become a correlatable log identifier
/// (Requirement 9.11).
public struct CancellationHookToken: Hashable, Sendable, CustomStringConvertible {
    let number: UInt64

    public var description: String { "CancellationHookToken(opaque)" }
}

/// Whether cancellation has been requested for one session attempt.
///
/// Write-once and never cleared, which is what makes "disable *all future* evidence
/// commits" monotonic. A new attempt gets a new latch, so a retry cannot inherit a
/// previous attempt's request — the same reason ``TerminalCommitSlot`` has no reset.
///
/// Not `public`: nothing outside this module should hold a latch, because its whole value
/// is that the coordinator owns the only one per session.
struct SessionCancellationLatch: Hashable, Sendable {
    private var requested: Bool

    /// An unlatched request.
    init() {
        self.requested = false
    }

    /// Whether cancellation has been requested.
    var isRequested: Bool { requested }

    /// Latches the request, reporting whether this call was the one that latched it.
    ///
    /// Synchronous compare-and-set in one expression, so two overlapping requests cannot
    /// both be told they latched it. That is what makes hook invocation happen exactly
    /// once rather than once per request.
    mutating func request() -> Bool {
        if requested { return false }
        requested = true
        return true
    }
}

/// Whether an asynchronously produced framework result may still be used.
///
/// The four answers are what the coordinator can decide *synchronously* from the recorded
/// session identity and the terminal slot. None of them consults a clock, an elapsed
/// duration, or an arrival order, which is what the design means by discarding a late
/// result "by Session ID/generation checks": a Core ML prediction or an Image I/O decode
/// that completes after cancellation is refused because it names an attempt that is no
/// longer admitting results, not because it was slow.
public enum FrameworkResultAdmission: Hashable, Sendable {
    /// The named attempt is running and has committed no terminal, so its result may be
    /// used.
    case admitted

    /// A terminal already stands for the named attempt, which is unchanged.
    ///
    /// The cancelled case of this is Requirement 15.7: the result arrived after the
    /// cancelled terminal and can never become evidence.
    case discardedTerminalCommitted(SessionTerminalOutcome)

    /// The result names a session attempt that is not the running one.
    ///
    /// Reached when a released session identifier has been bound again: the identifier
    /// matches but the generation does not, which is precisely why the generation exists.
    case discardedStaleIdentity(offered: AnalysisSessionIdentity)

    /// No session is running, so there is nothing for the result to belong to.
    case discardedNoActiveSession

    /// Whether the result may be used.
    public var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }

    /// The terminal outcome that discarded the result, or `nil`.
    ///
    /// Non-`nil` only for ``discardedTerminalCommitted(_:)``: the other two refusals name
    /// no attempt whose outcome could be reported.
    public var standingOutcome: SessionTerminalOutcome? {
        guard case .discardedTerminalCommitted(let outcome) = self else { return nil }
        return outcome
    }

    /// Whether the result was discarded because the session was cancelled.
    public var wasDiscardedByCancellation: Bool { standingOutcome?.isCancelled == true }
}

/// One framework result paired with the decision about whether it may be used.
///
/// A value rather than an optional, so a caller that ignores the refusal still cannot
/// reach the result: there is no `value` to unwrap on a discarded case. The reason the
/// result was dropped travels with it, so an audit can distinguish "cancelled" from
/// "belonged to an earlier attempt" without inferring it from timing.
public enum AdmittedFrameworkResult<Value: Sendable>: Sendable {
    /// The result belongs to the running attempt and may be used.
    case admitted(Value)

    /// The result was discarded, and why.
    case discarded(FrameworkResultAdmission)

    /// The usable result, or `nil` when it was discarded.
    public var value: Value? {
        guard case .admitted(let value) = self else { return nil }
        return value
    }

    /// Why the result was discarded, or `nil` when it was admitted.
    public var discardedBecause: FrameworkResultAdmission? {
        guard case .discarded(let admission) = self else { return nil }
        return admission
    }
}

/// What one cancellation request did.
///
/// Three separable facts, because they can disagree and a caller that conflated them
/// would be wrong in both directions:
///
///   * ``latchedRequest`` is `false` for a repeat request, which is not a failure — the
///     session is already cancellation-requested and its hooks have already fired.
///   * ``commit`` is refused when a terminal already stood. A session that completed
///     before the request stays completed (Requirement 11.17), so the request cannot be
///     read as "the session is now cancelled" without checking this.
///   * ``invokedHookCount`` records how many registered framework hooks this call
///     invoked. Zero is the ordinary answer for a build whose frameworks expose no
///     cancellation handle, and it says nothing about whether cancellation took effect.
public struct CancellationRequestResult: Hashable, Sendable {
    /// Whether this call was the one that latched the request.
    public let latchedRequest: Bool

    /// What offering the cancelled terminal did.
    public let commit: TerminalCommit

    /// Whether this call cancelled a structured task the coordinator owns.
    ///
    /// `false` when the session was started by awaiting the coordinator directly, in
    /// which case the enclosing task belongs to the caller and cooperation reaches the
    /// adapters through the caller's own cancellation.
    public let cancelledStructuredTask: Bool

    /// How many registered framework cancellation hooks this call invoked.
    public let invokedHookCount: Int

    /// The outcome that stands after this request, or `nil` when no session was involved.
    public var standingOutcome: SessionTerminalOutcome? { commit.standingOutcome }

    /// Whether the session's single terminal is now the cancelled one.
    public var isCancelled: Bool { standingOutcome?.isCancelled == true }

    /// A request that found nothing to cancel.
    ///
    /// No session was running, or the request named an attempt that is not the running
    /// one. Nothing was latched, committed, or invoked.
    static func refused(_ commit: TerminalCommit) -> CancellationRequestResult {
        CancellationRequestResult(
            latchedRequest: false,
            commit: commit,
            cancelledStructuredTask: false,
            invokedHookCount: 0
        )
    }
}

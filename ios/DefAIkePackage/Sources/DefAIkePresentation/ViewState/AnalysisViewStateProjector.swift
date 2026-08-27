import DefAIkeDomain

// Projecting one immutable snapshot into one screen.
//
// Two things live here, and the split matters:
//
//   * ``AnalysisScreen/projecting(_:)`` is a pure total function from one snapshot to one
//     screen. It reads nothing outside its argument, writes nothing, and cannot be affected
//     by the order snapshots arrived in. Every screen this application can show is the
//     result of applying it to some snapshot, so a screen is always reproducible from a
//     value.
//   * ``AnalysisViewStateProjector`` is the `@MainActor` holder of the current screen. It
//     adds exactly one thing the pure function cannot have: memory of which attempt the
//     screen already advanced past, so an observation of a superseded attempt cannot
//     reappear on screen.
//
// The projector is `@MainActor` and every value it produces is immutable. Both halves are
// requirements rather than style: view state is read during a SwiftUI update, so it has one
// isolation domain; and a screen that could be mutated after projection would let a view
// edit a verdict, a byte status, or a recorded dimension after the session committed it.
// There is no `var` in any screen type and no setter on any of them, so the only way a
// screen changes is by being replaced wholesale with another projection.
//
// Ordering is the whole of the projector's state, and it is deliberately minimal. It keeps
// the highest attempt generation it has projected and whether that attempt already reached a
// terminal. That is enough to refuse three things:
//
//   * an observation of an earlier attempt, which would re-show a session the user has
//     already moved past;
//   * a second, different terminal for the same attempt, since terminal outcomes are
//     monotonic and cannot transition into one another (Requirement 11.17);
//   * an active observation of an attempt that already ended, which would take a terminal
//     screen back to a progress bar.
//
// The same observation arriving twice is not a change and is allowed through, because it
// projects to the screen already standing. That is checked by comparing whole projected
// screens, so "the same terminal again" cannot quietly become "the same category with
// different preserved measurements".
//
// Refusal keeps the standing screen and reports that it did. It is not an error: a late
// observation is expected, and the coordinator suppressing late *work* is a separate
// guarantee in a separate module. This is only about which snapshot the screen shows.
//
// What the projector deliberately cannot do:
//
//   * **Start, cancel, or influence a session.** It holds no port, no coordinator, and no
//     closure. `startNewSelection()` returns the ready screen; it does not begin an ingest.
//   * **Retain a previous session's data.** Applying a snapshot replaces the screen with a
//     fresh projection, and the ready screen has no storage at all, so there is nothing for
//     a failed session to leave behind.
//   * **Approve copy or fill a copy gap.** Copy is resolved through the snapshot's own
//     session-bound binding, and a surface the approved vocabulary does not define is left
//     unrendered rather than invented. See ``UnapprovedViewStateSurface``.

/// Why a snapshot could not be projected into a screen.
///
/// Every case is a disagreement between records that must agree, and none of them is
/// recoverable by relaxing a check. There is no `unknown` case, and no case carries
/// substitute or degraded content: an unprojectable snapshot yields no screen at all rather
/// than a partial one.
public enum ViewStateProjectionError: Error, Hashable, Sendable {
    /// The snapshot's approved copy binding belongs to a different session.
    ///
    /// A binding is bound to one session because the Model Bundle is, so rendering this
    /// session through another session's binding would show copy checked for compatibility
    /// with a bundle this session never ran under.
    case copyBindingSessionMismatch(snapshot: AnalysisSessionID, binding: AnalysisSessionID)

    /// The committed Evidence Report describes a different session than the snapshot it
    /// arrived in.
    ///
    /// Refused rather than displayed. A report is the result of one session's analysis, and
    /// showing it under another session's identity is exactly the leakage between a failed
    /// or finished session and a later one that Requirement 3.15 forbids.
    case reportSessionMismatch(snapshot: AnalysisSessionID, report: AnalysisSessionID)

    /// The failure snapshot describes a different session than the snapshot it arrived in.
    case failureSessionMismatch(snapshot: AnalysisSessionID, failure: AnalysisSessionID)

    /// Approved copy for a reachable surface could not be resolved.
    ///
    /// Wraps the copy layer's own refusal unchanged, so a version-skew or coverage failure
    /// keeps naming the record that disagreed.
    case copy(PresentationCopyError)
}

/// What one attempt to change the screen did.
///
/// Three cases: the observation or action was accepted, or it was refused for one of two
/// stated reasons. All three report the screen that stands afterwards, so a caller never has
/// to guess whether what it supplied is what is displayed.
public enum ScreenProjection: Hashable, Sendable {
    /// The screen is now this.
    case projected(AnalysisScreen)

    /// The observation described an attempt the screen has already advanced past, so the
    /// standing screen is unchanged.
    case refusedSupersededAttempt(standing: AnalysisScreen)

    /// A recovery action was refused because work is still in flight, so the standing screen
    /// is unchanged (Requirement 15.5).
    case refusedWhileWorkInFlight(standing: AnalysisScreen)

    /// The screen that stands after this attempt.
    public var screen: AnalysisScreen {
        switch self {
        case let .projected(screen): screen
        case let .refusedSupersededAttempt(standing): standing
        case let .refusedWhileWorkInFlight(standing): standing
        }
    }

    /// Whether what was supplied is what the screen now shows.
    ///
    /// True for an accepted observation, including one that arrived twice and projected to the
    /// screen already standing. False for either refusal, where the standing screen was
    /// reached by some earlier observation instead.
    public var wasAccepted: Bool {
        guard case .projected = self else { return false }
        return true
    }
}

// MARK: - The pure projection

extension AnalysisScreen {
    /// Projects one immutable snapshot into one screen family.
    ///
    /// Pure and total over the snapshot vocabulary. The mapping is fixed:
    ///
    ///   * an idle observation is the ready screen;
    ///   * an ingest attempt is the importing screen;
    ///   * a session with work in flight is the active screen, whose progress is the state
    ///     the coordinator already derived and whose cancel control is visible and enabled;
    ///   * a committed terminal is the completed, cancelled, or error screen its own case
    ///     selects, with no branch that could produce a different family for it.
    ///
    /// Throws only when records that must agree do not: a copy binding for another session, a
    /// report or failure snapshot for another session, or a copy surface that cannot be
    /// resolved. It never returns a partially populated screen.
    public static func projecting(
        _ snapshot: CoordinatorSnapshot
    ) throws(ViewStateProjectionError) -> AnalysisScreen {
        switch snapshot {
        case .idle:
            return .awaitingSelection
        case let .importing(attempt):
            return .importing(ImportingScreen(attempt: attempt))
        case let .session(session):
            return try projecting(session)
        }
    }

    /// Projects one Analysis Session observation.
    static func projecting(
        _ snapshot: AnalysisSessionSnapshot
    ) throws(ViewStateProjectionError) -> AnalysisScreen {
        // Checked before anything is resolved. Copy is bound per session, so a binding for a
        // different session cannot be used to render this one even if every surface it
        // carries happens to resolve.
        guard snapshot.copy.sessionID == snapshot.sessionID else {
            throw .copyBindingSessionMismatch(
                snapshot: snapshot.sessionID,
                binding: snapshot.copy.sessionID
            )
        }

        switch snapshot.phase {
        case let .working(progress):
            return .active(
                ActiveScreen(
                    identity: snapshot.identity,
                    progress: ProjectedWorkProgress(progress)
                )
            )
        case let .ended(outcome):
            return try projecting(outcome, for: snapshot)
        }
    }

    /// Projects one committed terminal outcome.
    ///
    /// The three cases map to the three terminal families and to nothing else. There is no
    /// shared branch, so no outcome can be rendered as another one's family, and cancellation
    /// in particular cannot fall through into the error family.
    private static func projecting(
        _ outcome: SessionTerminalOutcome,
        for snapshot: AnalysisSessionSnapshot
    ) throws(ViewStateProjectionError) -> AnalysisScreen {
        switch outcome {
        case let .completed(report):
            return .completed(try completedScreen(report, for: snapshot))
        case .cancelled:
            return .cancelled(CancelledScreen(identity: snapshot.identity))
        case let .failed(failure):
            return .error(try errorScreen(failure, for: snapshot))
        }
    }

    private static func completedScreen(
        _ report: EvidenceReport,
        for snapshot: AnalysisSessionSnapshot
    ) throws(ViewStateProjectionError) -> CompletedScreen {
        guard report.binding.sessionID == snapshot.sessionID else {
            throw .reportSessionMismatch(
                snapshot: snapshot.sessionID,
                report: report.binding.sessionID
            )
        }

        let copy = snapshot.copy
        do {
            // Each lane is resolved independently and stored in its own member, so neither
            // resolution can consult, alter, or rank the other.
            let pixel = try copy.presentation(forPixel: report.pixel)
            let provenance = try copy.presentation(forProvenance: report.provenance)
            let summary = try report.combinedSummary.map { summary throws(PresentationCopyError) in
                try copy.presentation(forCombinedSummary: summary)
            }
            let inconsistency = try report.apparentInconsistency.map {
                key throws(PresentationCopyError) in
                try copy.apparentInconsistencyReference(declaredKey: key)
            }
            return CompletedScreen(
                identity: snapshot.identity,
                report: report,
                pixel: pixel,
                provenance: provenance,
                combinedSummary: summary,
                apparentInconsistency: inconsistency
            )
        } catch {
            throw .copy(error)
        }
    }

    private static func errorScreen(
        _ failure: AnalysisFailureSnapshot,
        for snapshot: AnalysisSessionSnapshot
    ) throws(ViewStateProjectionError) -> AnalysisErrorScreen {
        guard failure.sessionID == snapshot.sessionID else {
            throw .failureSessionMismatch(
                snapshot: snapshot.sessionID,
                failure: failure.sessionID
            )
        }

        let presentation: AnalysisErrorPresentation
        do {
            presentation = try snapshot.copy.presentation(forError: failure.error)
        } catch {
            throw .copy(error)
        }
        // Both preserved values come from the failure snapshot unchanged. Neither is
        // defaulted when the session failed before recording it (Requirement 3.14).
        return AnalysisErrorScreen(
            identity: snapshot.identity,
            presentation: presentation,
            bytePreservationStatus: failure.bytePreservationStatus,
            inputQuality: failure.inputQuality
        )
    }
}

// MARK: - The projector

/// Holds the screen the application is showing, on the main actor.
///
/// A reference type because the screen has to survive between observations and one owner has
/// to decide which observation wins. Everything it hands out is an immutable value, and the
/// only mutable state it holds is the current screen and the ordering watermark that keeps a
/// superseded attempt off it.
@MainActor
public final class AnalysisViewStateProjector {

    /// One attempt the screen has already reflected, and how far it got.
    private struct ProjectedAttempt: Hashable {
        let generation: UInt64
        let reachedTerminal: Bool
    }

    /// The screen the application is showing. Replaced wholesale, never edited.
    public private(set) var screen: AnalysisScreen

    /// The furthest attempt the screen has reflected, or `nil` before the first session.
    ///
    /// Monotonic: it never moves to a lower generation, and once an attempt is recorded as
    /// terminal it never goes back to nonterminal. That is what makes a late observation
    /// refusable by identity rather than by timing.
    private var furthestAttempt: ProjectedAttempt?

    /// A projector showing the ready screen and remembering no session.
    public init() {
        self.screen = .awaitingSelection
        self.furthestAttempt = nil
    }

    /// The furthest attempt generation the screen has reflected, or `nil` before the first
    /// session observation.
    public var projectedAttemptGeneration: UInt64? { furthestAttempt?.generation }

    /// Projects `snapshot` onto the screen, or refuses a superseded attempt.
    ///
    /// An observation of an earlier attempt is refused before any copy is resolved, so an
    /// attempt the screen has entirely moved past costs nothing. An observation of the
    /// furthest attempt after it has already finished is projected and then compared against
    /// the standing screen, because "the same terminal again" is only recognizable from the
    /// screen it produces. Either refusal leaves the screen exactly as it was.
    @discardableResult
    public func apply(
        _ snapshot: CoordinatorSnapshot
    ) throws(ViewStateProjectionError) -> ScreenProjection {
        // An earlier attempt is refused before any copy is resolved, so an observation the
        // screen has entirely moved past costs nothing and cannot fail for a copy reason.
        if let identity = snapshot.attemptIdentity,
           let furthest = furthestAttempt,
           identity.attemptGeneration < furthest.generation
        {
            return .refusedSupersededAttempt(standing: screen)
        }

        let projected = try AnalysisScreen.projecting(snapshot)

        // A committed terminal is final (Requirement 11.17). Once the furthest attempt has
        // reached one, the only observation of that attempt the screen may accept is one that
        // projects to the very screen already standing - which is the same observation
        // arriving twice, and changes nothing. A second different terminal, and a return to
        // active work, are both refused.
        //
        // Compared as whole projected screens rather than field by field, so "the same
        // terminal" cannot drift into "the same error category with different preserved
        // measurements".
        if let identity = snapshot.attemptIdentity,
           let furthest = furthestAttempt,
           identity.attemptGeneration == furthest.generation,
           furthest.reachedTerminal,
           projected != screen
        {
            return .refusedSupersededAttempt(standing: screen)
        }

        // Recorded only after the projection succeeded. A snapshot refused for a record
        // disagreement must not advance the watermark, or the correct snapshot for that
        // attempt could not be applied afterwards.
        if let identity = snapshot.attemptIdentity {
            furthestAttempt = ProjectedAttempt(
                generation: identity.attemptGeneration,
                reachedTerminal: projected.isTerminal
            )
        }
        screen = projected
        return .projected(projected)
    }

    /// Returns to the ready screen so the user can select another image.
    ///
    /// The recovery action every terminal screen offers (Requirement 3.13). It carries
    /// nothing forward: the ready screen has no storage, and the projected screen is replaced
    /// rather than edited, so no error category, identity, measurement, byte status, or
    /// verdict from the ended session survives it (Requirement 3.15).
    ///
    /// The watermark is *not* cleared. A finished attempt stays finished, so a late
    /// observation of it cannot re-enter the screen after the user has moved on.
    ///
    /// Refused while work is in flight, because replacing an active screen would take its
    /// visible, enabled cancel control off screen while the work continues
    /// (Requirement 15.5). Stopping active work is a cancellation, which the session commits;
    /// it is not something a view state may do on its own.
    @discardableResult
    public func startNewSelection() -> ScreenProjection {
        guard !screen.isWorkInFlight else {
            return .refusedWhileWorkInFlight(standing: screen)
        }
        screen = .awaitingSelection
        return .projected(screen)
    }
}

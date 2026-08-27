import DefAIkeDomain

// Status announcements and accessibility focus.
//
// Requirement 12.5: when analysis status changes, announce the new status. Requirement 12.6:
// while the focused element remains available, an analysis status change keeps accessibility
// focus on it. The design adds that announcements are "debounced to meaningful state changes
// and do not steal focus from an element that remains present".
//
// Those two requirements pull against each other in the obvious implementation. Announcing
// every observation is how a minute-scale analysis becomes unusable with VoiceOver: a
// determinate progress state arrives many times per second, each arrival is a status change by
// the letter of 12.5, and each announcement interrupts the previous one so nothing is ever
// heard. Meanwhile the usual way to make a change noticeable - moving focus to the new content
// - is exactly what 12.6 forbids.
//
// Both are settled here, and both are settled by shape rather than by a timer:
//
//   * **Debouncing is identity comparison, not elapsed time.** ``AnnouncedStatus`` is derived
//     from a screen and deliberately omits the measured progress amounts, so every
//     observation within one stage has the same identity and only the first of them announces.
//     A stage change, a terminal outcome, and a family change all change the identity and all
//     announce. There is no clock, no interval, and no scheduler, so the debouncer is a pure
//     value a host test can drive deterministically - which also means "meaningful" is a
//     definition a reader can check rather than a tuning constant.
//   * **An announcement cannot move focus.** ``AnnouncementFocus`` has exactly one case. There
//     is no "move focus to" case for a caller to select, so Requirement 12.6 is not a rule the
//     announcement path has to remember; it is the only thing the type can say.
//
// The second half of 12.6 - "while the focused element remains available" - is a question
// about two projections, and ``FocusRetention`` answers it by identity. When the focused
// element is gone the caller has to move focus somewhere, and that is the one case where
// moving it is correct.
//
// What is deliberately absent: any announcement text chosen here. Announcement content is an
// address into approved copy, exactly like a label, and a status whose wording is not approved
// announces nothing and records why.

/// What an announcement says.
///
/// Either an address into approved content, or the recorded gaps that make the status
/// unannounceable. There is no third case carrying a sentence, so an announcement cannot be
/// composed at the call site and cannot describe a status the release has not approved wording
/// for.
public enum AnnouncementContent: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The approved text to announce.
    case approved(AccessibilitySemanticSource)

    /// Nothing is announced, because no approved wording for this status exists. The gaps
    /// are listed in a deterministic order.
    case blocked([BlockedSemanticSurface])

    /// Whether this content can actually be spoken.
    public var isAnnounceable: Bool {
        guard case .approved = self else { return false }
        return true
    }
}

/// What an announcement does to accessibility focus.
///
/// One case by construction (Requirement 12.6). An announcement is spoken alongside whatever
/// the user is reading; it never becomes the new focus, so a user cannot be moved off a
/// control mid-gesture by a status change arriving behind them.
public enum AnnouncementFocus: String, Hashable, Sendable, CaseIterable {
    /// Speak without changing what is focused.
    case preservesExistingFocus = "preserves-existing-focus"
}

/// How urgently an announcement is spoken.
///
/// Two cases and no way to mix them. A terminal outcome interrupts, because it is the answer
/// the user has been waiting minutes for; anything in flight waits, because interrupting an
/// evidence field being read is worse than announcing a stage change late.
public enum AnnouncementUrgency: String, Hashable, Sendable, CaseIterable {
    /// Speak after the current utterance finishes.
    case afterCurrentSpeech = "after-current-speech"

    /// Interrupt the current utterance.
    case interruptsCurrentSpeech = "interrupts-current-speech"
}

/// The status an announcement is about.
///
/// The debounce key, and the reason a determinate progress state does not announce itself many
/// times a second: the measured amounts are not part of this value, so every observation within
/// one stage is the same status. What *is* part of it is everything a user needs to be told
/// about - the route an ingest is using, the stage work has reached, and which terminal was
/// committed.
///
/// A percentage is therefore never announced. That is not a gap: Requirement 12.2 exposes the
/// progress field's value continuously for a user who asks, and an announcement is for a change
/// nobody asked about.
public enum AnnouncedStatus: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Nothing is happening; the application is waiting for a selection.
    case awaitingSelection

    /// An image is being retrieved through one route.
    case importInFlight(InputRoute)

    /// Analysis work has reached one stage.
    case analysisWorking(AnalysisStage)

    /// The session completed, and this is the pixel label it produced.
    ///
    /// Carries the label rather than the whole report, because the label is the one part of a
    /// completed result whose display string is fixed by Requirement 8.2 and therefore the one
    /// part that can be announced today.
    case analysisCompleted(PixelLabelKey)

    /// The session was cancelled.
    case analysisCancelled

    /// The session failed with one category.
    case analysisFailed(AnalysisError)

    /// Stable identifier, for deterministic reporting.
    public var stableKey: String {
        switch self {
        case .awaitingSelection: "awaiting-selection"
        case let .importInFlight(route): "import-in-flight/\(route.rawValue)"
        case let .analysisWorking(stage): "analysis-working/\(stage.rawValue)"
        case let .analysisCompleted(label): "analysis-completed/\(label.rawValue)"
        case .analysisCancelled: "analysis-cancelled"
        case let .analysisFailed(error): "analysis-failed/\(error.rawValue)"
        }
    }

    /// How urgently this status is spoken.
    ///
    /// The three terminals interrupt; everything else waits. Total switch, no `default`.
    public var urgency: AnnouncementUrgency {
        switch self {
        case .analysisCompleted, .analysisCancelled, .analysisFailed: .interruptsCurrentSpeech
        case .awaitingSelection, .importInFlight, .analysisWorking: .afterCurrentSpeech
        }
    }
}

/// One announcement, fully described as data.
public struct StatusAnnouncement: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The status this announcement is about.
    public let status: AnnouncedStatus

    /// What is said, or the recorded reason nothing is.
    public let content: AnnouncementContent

    /// What this does to focus. Always nothing (Requirement 12.6).
    public let focus: AnnouncementFocus

    /// How urgently it is spoken.
    public var urgency: AnnouncementUrgency { status.urgency }

    /// Whether this announcement can actually be spoken.
    public var isAnnounceable: Bool { content.isAnnounceable }

    init(status: AnnouncedStatus, content: AnnouncementContent) {
        self.status = status
        self.content = content
        self.focus = .preservesExistingFocus
    }
}

// MARK: - Deriving the status from a screen

extension AnnouncedStatus {
    /// The status one screen represents.
    ///
    /// Total over the six screen families and derived from the family and its payload alone,
    /// so two observations of the same stage produce the same value and the debouncer sees one
    /// status rather than two.
    public init(_ input: AccessibilityScreenInput) {
        switch input {
        case .ready:
            self = .awaitingSelection
        case let .importing(importing):
            self = .importInFlight(importing.attempt.route)
        case let .active(active):
            self = .analysisWorking(active.progress.stage)
        case let .completed(report):
            self = .analysisCompleted(report.cards.pixel.fixedLabelText.label)
        case .cancelled:
            self = .analysisCancelled
        case let .error(failed):
            self = .analysisFailed(failed.presentation.error)
        }
    }
}

extension StatusAnnouncement {
    /// The announcement for one screen, including whether anything can be said.
    ///
    /// Content comes from the screen's own already-resolved approved copy, from the chrome
    /// vocabulary for the statuses that describe what the application is doing, and is recorded
    /// as blocked where neither exists. Five of the six families announce: an ingest attempt,
    /// active work, and the three terminals. The ready family is the one that does not, because
    /// it is not a change anyone waits for and the only approved wording near it is a control's
    /// name rather than a status.
    public init(_ input: AccessibilityScreenInput) {
        let status = AnnouncedStatus(input)
        switch input {
        case .ready:
            // The one family that still announces nothing, and not for want of wording. The
            // ready screen is not a status *change* anyone waits for: it is the state the
            // application launches in and returns to, and the only approved thing to say about
            // it is the picker control's own label — which is a control name, not a status.
            // Announcing a button's label as a status is exactly the substitution the closed
            // announcement vocabulary exists to prevent, so nothing is announced and the reason
            // is recorded.
            self.init(
                status: status,
                content: .blocked([.viewState(.startNewSessionAction)])
            )
        case .importing:
            self.init(
                status: status,
                content: .approved(
                    .approvedChromeCopy(ChromeCopyReference(.importInProgressStatus))
                )
            )
        case .active:
            // The stage-specific and measured-readout variants stay unbuilt. One approved
            // sentence asserts that work is continuing, which is the whole of what this layer
            // is told, and the debounce key omits the measured amounts anyway — so every
            // observation within one stage announces once and a stage change announces again.
            self.init(
                status: status,
                content: .approved(
                    .approvedChromeCopy(ChromeCopyReference(.analysisInProgressStatus))
                )
            )
        case let .completed(report):
            self.init(
                status: status,
                content: .approved(
                    .requiredPixelLabelText(report.cards.pixel.fixedLabelText)
                )
            )
        case .cancelled:
            self.init(
                status: status,
                content: .approved(.approvedChromeCopy(ChromeCopyReference(.cancelledStatus)))
            )
        case let .error(failed):
            self.init(
                status: status,
                content: .approved(.approvedCopy(failed.presentation.messageCopy))
            )
        }
    }

}

// MARK: - Debouncing

/// Decides which status changes are announced.
///
/// A value type holding one status, and nothing else. It consults no clock, keeps no queue,
/// and cancels no pending work, so its whole behaviour is "announce when the status identity
/// changed" - which is the design's "debounced to meaningful state changes", stated as a rule
/// rather than as an interval.
///
/// Being a value type matters for testing: a test drives a sequence of screens through a
/// `var` and reads back exactly which announcements a user would have heard, with no waiting
/// and no flake.
public struct StatusAnnouncementDebouncer: Hashable, Sendable {
    /// The status last announced, or `nil` before the first screen.
    public private(set) var lastAnnouncedStatus: AnnouncedStatus?

    /// A debouncer that has announced nothing.
    public init() {
        self.lastAnnouncedStatus = nil
    }

    /// The announcement for `input`, or `nil` when its status has not changed.
    ///
    /// Records the status as announced whenever it is new, including when the announcement is
    /// blocked for lack of approved wording. That is deliberate: a blocked status that stayed
    /// unrecorded would be re-derived on every observation, and the moment wording is approved
    /// the same screen would begin announcing many times a second. Recording it keeps the
    /// debounce rule identical before and after the copy decision.
    public mutating func announcement(
        for input: AccessibilityScreenInput
    ) -> StatusAnnouncement? {
        let announcement = StatusAnnouncement(input)
        guard announcement.status != lastAnnouncedStatus else { return nil }
        lastAnnouncedStatus = announcement.status
        return announcement
    }

    /// Whether `input` would announce, without recording anything.
    ///
    /// A probe for a caller deciding whether a change is meaningful at all. It is not a way to
    /// announce twice: speaking still goes through ``announcement(for:)``.
    public func wouldAnnounce(_ input: AccessibilityScreenInput) -> Bool {
        AnnouncedStatus(input) != lastAnnouncedStatus
    }
}

// MARK: - Focus

/// What became of accessibility focus across a screen change.
///
/// Three cases, and the middle one is the only situation in which focus may be moved. That is
/// what Requirement 12.6 permits and no more: focus stays put while the focused element is
/// still there, and is placed somewhere deliberate only when it is not.
public enum FocusRetention: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Nothing was focused, so nothing is preserved.
    case noFocusedElement

    /// The focused element is still present, so focus stays exactly where it was
    /// (Requirement 12.6).
    case retained(AccessibleElementIdentity)

    /// The focused element is gone from the new screen, so focus has to move.
    ///
    /// Carries the element that vanished and where focus should go: the first element of the
    /// new screen's reading order, so a user is placed at the top of the new content rather
    /// than nowhere.
    case movedBecauseElementIsGone(
        vanished: AccessibleElementIdentity,
        suggestedTarget: AccessibleElementIdentity?
    )

    /// Whether focus is unchanged.
    public var preservesFocus: Bool {
        switch self {
        case .retained: true
        case .noFocusedElement, .movedBecauseElementIsGone: false
        }
    }

    /// Where focus should be after this change, or `nil` when it should be left alone or has
    /// nowhere to go.
    public var target: AccessibleElementIdentity? {
        switch self {
        case .noFocusedElement: nil
        case let .retained(identity): identity
        case let .movedBecauseElementIsGone(_, suggested): suggested
        }
    }
}

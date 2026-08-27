#if canImport(SwiftUI)

// `Accessibility` is imported explicitly rather than relied on through SwiftUI. SwiftUI's own
// interface imports it without re-exporting it, so `AccessibilityNotification` and the
// announcement-priority attribute are visible here only by that module being loaded - which is
// not a guarantee. Both are iOS 17.0 and macOS 14.0, matching the package's own minimums exactly,
// so no availability annotation is needed once the module is named.
import Accessibility
import DefAIkeDomain
import SwiftUI

// The screen, as an application of one ``AccessibilitySemanticsSnapshot``.
//
// The view holds no accessibility decision of its own. It reads the snapshot, renders the exposed
// elements in the snapshot's order, applies each element's semantics through
// ``AccessibleElementView``, and does four things a value cannot do for itself:
//
//   1. **Scroll.** Reachability at the largest accessibility sizes depends on it
//      (Requirement 12.8), and ``ContentScrollPolicy`` has no case that says otherwise.
//   2. **Stack vertically.** The layout axis comes from ``AdaptiveLayoutPolicy/axis(at:)`` over
//      the current text size, so overlap and clipping at accessibility sizes are removed by the
//      policy rather than by a breakpoint chosen here.
//   3. **Announce.** A status change is spoken through the debouncer, so a determinate progress
//      state arriving many times a second is announced once per meaningful change
//      (Requirement 12.5), and the announcement never takes focus (Requirement 12.6).
//   4. **Keep focus.** Accessibility focus is tracked by element identity and reassigned only when
//      the focused element is genuinely gone from the new screen (Requirement 12.6).
//
// What the view deliberately cannot do:
//
//   * **Choose wording.** Every string it renders came from the approved catalog through
//     ``AccessibleTextResolver``, and an element whose text will not resolve is not rendered.
//     There is no literal, no interpolation, and no concatenation in any user-facing position.
//   * **Reach a session.** Actions arrive as closures from the composition root. This module
//     depends on the domain and nothing else, so there is no coordinator here to start, cancel,
//     or observe.
//   * **Draw a magnitude.** The only visual that is not text is the in-flight work indicator,
//     which is hidden from assistive technology and carries no value - see
//     ``WorkIndicatorView``.

/// What the composition root supplies for the controls on screen.
///
/// Closures rather than a port, because the presentation layer must not be able to reach a session.
/// Held by a view, so main-actor isolation comes from the view protocol rather than from an
/// annotation here.
public struct AnalysisScreenActions {
    /// Begin selecting an image. Also the recovery every terminal screen offers.
    public var selectImage: () -> Void

    /// Request cancellation of active analysis work.
    public var requestCancellation: () -> Void

    /// Open one of the onward disclosure paths.
    public var openDisclosurePath: (ReportDisclosurePath) -> Void

    public init(
        selectImage: @escaping () -> Void,
        requestCancellation: @escaping () -> Void,
        openDisclosurePath: @escaping (ReportDisclosurePath) -> Void
    ) {
        self.selectImage = selectImage
        self.requestCancellation = requestCancellation
        self.openDisclosurePath = openDisclosurePath
    }

    /// The action for one element, or `nil` when the element is not operable.
    ///
    /// Total over the identity vocabulary, so an operable element cannot be rendered without an
    /// action and a content element cannot acquire one.
    func action(for identity: AccessibleElementIdentity) -> (() -> Void)? {
        switch identity {
        case .imageSelectionControl, .analysisErrorRecovery: selectImage
        case .cancellationControl: requestCancellation
        case .modelInformationPath: { self.openDisclosurePath(.modelInformation) }
        case .privacyPath: { self.openDisclosurePath(.privacyBehavior) }
        case .correctionChannelPath: { self.openDisclosurePath(.correctionChannel) }
        case .importStatus, .workProgress, .cancelledStatus, .analysisErrorMessage,
            .pixelEvidenceLabel, .pixelEvidenceExplanation, .provenanceLaneState,
            .screenshotProvenanceExplanation, .combinedSummary, .apparentInconsistencyNotice,
            .evidenceScopeLimitation, .falseResultLimitation, .bytePreservationLimitation,
            .technicalDetailsDisclosure, .boundComponentVersion, .recordedDimension,
            .onDeviceProcessingStatus, .modelBundleIntegrityStatus:
            nil
        }
    }
}

/// The in-flight work indicator, and the Reduce Motion substitution for it
/// (Requirement 12.10).
///
/// The only non-text visual in this module. Two properties make it safe:
///
///   * it is hidden from assistive technology, so it can never be the channel a status travels on
///     (Requirement 12.7). What a user hears about active work comes from the status field, whose
///     wording is a recorded gap;
///   * it carries no value, no fraction, and no magnitude, so it is not a graphical encoding of a
///     probability or confidence and there is nothing in it to read as one.
///
/// Under Reduce Motion the moving indicator is replaced by a nonmoving one that appears and
/// disappears with the same state, so the same state change is conveyed without motion. The choice
/// comes from ``MotionPolicy`` rather than from an `if` here, so the reduced branch cannot be
/// forgotten.
struct WorkIndicatorView: View {
    /// Whether the user has asked for reduced motion.
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch MotionPolicy.statusChangeStyle(reduceMotion: reduceMotion) {
            case .animatedIndicator:
                ProgressView()
            case .staticStateChange:
                // A plain dot rather than a spinner: it states "work is in flight" by being
                // present and stops stating it by being absent, with nothing moving either way.
                //
                // Deliberately a dot and not a bar. A bar, gauge, or meter reads as a filled
                // magnitude, and Requirement 8.13 bans a graphical encoding equivalent to a
                // probability or confidence value. A dot has no fill fraction to misread.
                Circle().frame(width: 12, height: 12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One screen, rendered from its accessibility semantics.
public struct AnalysisScreenView: View {
    /// The screen to render, with its completed report already assembled.
    public let input: AccessibilityScreenInput

    /// The resolver supplying approved text.
    public let resolver: AccessibleTextResolver

    /// What the controls on screen do.
    public let actions: AnalysisScreenActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Which element accessibility focus is on, tracked by identity so it survives a reprojection
    /// that changes an element's position (Requirement 12.6).
    @AccessibilityFocusState private var focusedElement: AccessibleElementIdentity?

    /// The debouncer deciding which status changes are spoken.
    @State private var debouncer = StatusAnnouncementDebouncer()

    public init(
        input: AccessibilityScreenInput,
        resolver: AccessibleTextResolver,
        actions: AnalysisScreenActions
    ) {
        self.input = input
        self.resolver = resolver
        self.actions = actions
    }

    /// The semantics this view is an application of.
    private var snapshot: AccessibilitySemanticsSnapshot {
        AccessibilitySemanticsSnapshot.projecting(input)
    }

    /// The supported text size the environment is at.
    private var textSize: SupportedTextSize { SupportedTextSize(dynamicTypeSize) }

    public var body: some View {
        let snapshot = self.snapshot

        // Always scrollable, at every text size. `ContentScrollPolicy` has one case, so there is
        // no condition under which this becomes a fixed-height container that could clip.
        ScrollView(.vertical) {
            content(for: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .accessibilityElement(children: .contain)
        .onChange(of: input) { _, newInput in
            announce(for: newInput)
            preserveFocus(across: AccessibilitySemanticsSnapshot.projecting(newInput))
        }
        .onAppear { announce(for: input) }
    }

    /// The exposed elements, in reading order, plus the in-flight indicator where one applies.
    ///
    /// A single vertical list at every text size: the fields themselves always stack, and the axis
    /// the policy chooses applies *within* a field that shows both a name and a state. That is
    /// where a side-by-side layout would clip first, so that is where the size is consulted.
    @ViewBuilder
    private func content(for snapshot: AccessibilitySemanticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.family == .active || snapshot.family == .importing {
                WorkIndicatorView(reduceMotion: reduceMotion)
            }
            ForEach(Array(snapshot.elements.enumerated()), id: \.element.identity) {
                index, element in
                AccessibleElementView(
                    element: element,
                    resolver: resolver,
                    elementCount: snapshot.elements.count,
                    readingIndex: index,
                    axis: snapshot.layout.axis(at: textSize),
                    action: element.isOperable ? actions.action(for: element.identity) : nil
                )
                .accessibilityFocused($focusedElement, equals: element.identity)
            }
        }
    }

    // MARK: - Announcements and focus

    /// Speaks the new status, if it changed and if approved wording for it exists.
    ///
    /// The debouncer decides whether anything is said. A blocked announcement is not spoken and not
    /// substituted, so a status with no approved wording is silent rather than described in words
    /// chosen here.
    private func announce(for input: AccessibilityScreenInput) {
        guard let announcement = debouncer.announcement(for: input),
            case let .approved(source) = announcement.content,
            let text = resolver.resolvedText(for: source)
        else {
            return
        }
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority =
            switch announcement.urgency {
            case .interruptsCurrentSpeech: .high
            case .afterCurrentSpeech: .default
            }
        AccessibilityNotification.Announcement(spoken).post()
    }

    /// Keeps accessibility focus where it was, or moves it when the focused element is gone.
    ///
    /// The decision is ``AccessibilitySemanticsSnapshot/focusRetention(movingFrom:)``'s, not this
    /// method's: focus is written only in the one case that answers "the focused element is no
    /// longer available", which is exactly the case Requirement 12.6 leaves open.
    private func preserveFocus(across snapshot: AccessibilitySemanticsSnapshot) {
        switch snapshot.focusRetention(movingFrom: focusedElement) {
        case .noFocusedElement, .retained:
            return
        case let .movedBecauseElementIsGone(_, suggestedTarget):
            focusedElement = suggestedTarget
        }
    }
}

#endif

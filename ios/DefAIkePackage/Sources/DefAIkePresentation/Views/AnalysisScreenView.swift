#if canImport(SwiftUI)

// `Accessibility` is imported explicitly rather than relied on through SwiftUI. SwiftUI's own
// interface imports it without re-exporting it, so `AccessibilityNotification` and the
// announcement-priority attribute are visible here only by that module being loaded - which is
// not a guarantee. Both are iOS 17.0 and macOS 14.0, matching the package's own minimums exactly,
// so no availability annotation is needed once the module is named.
import Accessibility
import DefAIkeDomain
import SwiftUI

// The screen, as an application of one ``AccessibilitySemanticsSnapshot`` grouped into regions.
//
// The view holds no accessibility decision and no wording decision of its own. It reads the
// snapshot, groups the exposed elements into contiguous regions through ``ScreenComposition``,
// renders them in the snapshot's order, and does five things a value cannot do for itself:
//
//   1. **Scroll.** Reachability at the largest accessibility sizes depends on it
//      (Requirement 12.8), and ``ContentScrollPolicy`` has no case that says otherwise.
//   2. **Stack vertically.** The layout axis comes from ``AdaptiveLayoutPolicy/axis(at:)`` over the
//      current text size, so overlap and clipping at accessibility sizes are removed by the policy
//      rather than by a breakpoint chosen here.
//   3. **Announce.** A status change is spoken through the debouncer, so a determinate progress
//      state arriving many times a second is announced once per meaningful change
//      (Requirement 12.5), and the announcement never takes focus (Requirement 12.6).
//   4. **Keep focus.** Accessibility focus is tracked by element identity and reassigned only when
//      the focused element is genuinely gone from the new screen (Requirement 12.6).
//   5. **Draw.** Which is new, and is the design layer's whole contribution: a region gets a
//      container, an element gets a weight, and both come from tokens rather than from a literal
//      written here.
//
// What the view deliberately still cannot do:
//
//   * **Choose wording.** Every string it renders came from the approved catalog through
//     ``AccessibleTextResolver``, and an element whose text will not resolve is not rendered. There
//     is no literal, no interpolation, and no concatenation in any user-facing position. This file
//     builds no `Text` at all - it delegates every one to ``AccessibleElementView``.
//   * **Reach a session.** Actions arrive as closures from the composition root. This module depends
//     on the domain and nothing else, so there is no coordinator here to start, cancel, or observe.
//   * **Draw a magnitude.** No view reachable from here has a fill fraction, a bar length, or a
//     gauge, because Requirement 8.13 bans a graphical encoding equivalent to a probability.
//   * **Colour an outcome.** Appearance is resolved from ``VisualEmphasis`` and ``ScreenRegion``,
//     and neither is ever shown a verdict. See ``VisualEmphasis`` for the full argument.

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

    /// Open the information screen, which carries every limitation and disclosure statement.
    ///
    /// This replaced a `(ReportDisclosurePath) -> Void`. The report used to expose one control per
    /// path, so the closure had to say *which* path; there is one control now, and the destination
    /// carries all four statements, so the parameter had nothing left to select.
    public var openInformation: () -> Void

    public init(
        selectImage: @escaping () -> Void,
        requestCancellation: @escaping () -> Void,
        openInformation: @escaping () -> Void
    ) {
        self.selectImage = selectImage
        self.requestCancellation = requestCancellation
        self.openInformation = openInformation
    }

    /// The action for one element, or `nil` when the composition root supplies none.
    ///
    /// Total over the identity vocabulary, so an operable element cannot be rendered without an
    /// action and a content element cannot acquire one.
    ///
    /// ``AccessibleElementIdentity/limitationsDisclosure`` is the one operable element that answers
    /// `nil` here, and deliberately: whether a group is expanded is view state, and a composition
    /// root that could toggle it would be reaching into layout. The view supplies that action
    /// itself - see `AnalysisScreenView.elementView(_:...)`.
    func action(for identity: AccessibleElementIdentity) -> (() -> Void)? {
        switch identity {
        case .imageSelectionControl, .analysisErrorRecovery: selectImage
        case .cancellationControl: requestCancellation
        case .informationPath: openInformation
        case .limitationsDisclosure: nil
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
    @Environment(\.colorScheme) private var colorScheme

    /// Which element accessibility focus is on, tracked by identity so it survives a reprojection
    /// that changes an element's position (Requirement 12.6).
    @AccessibilityFocusState private var focusedElement: AccessibleElementIdentity?

    /// The debouncer deciding which status changes are spoken.
    @State private var debouncer = StatusAnnouncementDebouncer()

    /// Whether the limitation statements are revealed.
    ///
    /// Starts closed. The limitations are three paragraphs and they are the reason the action that
    /// starts a new session used to sit below the fold; a user who wants them can ask for them.
    /// Reset whenever the screen family changes, so a new report does not inherit the last one's
    /// disclosure state.
    @State private var limitationsExpanded = false

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

    /// The measured palette for the current appearance.
    private var palette: Palette { .resolved(for: Appearance(colorScheme)) }

    /// Whether the action region is pinned below the scroll view rather than scrolled with it.
    ///
    /// Pinned at the ordinary text sizes, where it costs about fifty points and puts the control that
    /// starts a new session on the first screenful.
    ///
    /// *Not* pinned at the accessibility sizes, and a screenshot is why. At accessibility5 the
    /// button's label wraps to three lines and the bar grows past four hundred points - so a pinned
    /// bar took roughly half of what was left of the viewport and squeezed the report down to about a
    /// line and a half of visible text. A bar that always shows the action by hiding the evidence is a
    /// worse trade than one the user scrolls to, especially now the limitations are collapsed and the
    /// report is short.
    ///
    /// The condition is ``AdaptiveLayoutPolicy``'s own signal, not a new breakpoint: the policy
    /// answers `.vertical` for exactly the accessibility sizes, and the decorative glyphs already drop
    /// out on the same boundary. One definition of "large text", used in three places.
    private var pinsAction: Bool { snapshot.layout.axis(at: textSize) == .horizontal }

    public var body: some View {
        let snapshot = self.snapshot

        // Always scrollable, at every text size. `ContentScrollPolicy` has one case, so there is no
        // condition under which this becomes a fixed-height container that could clip.
        // The scrolling report, and the action pinned beneath it. Splitting them is what puts the
        // control that starts a new session on the first screenful: it used to be the last element
        // inside the scroll view, below three paragraphs of limitations, so re-running an analysis
        // meant scrolling to the bottom of a report the user had already read.
        //
        // It stays *last* in the reading order, because it is last in the snapshot and the sort
        // priority is derived from that position. Visually bottom and semantically last agree.
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                // The spacer establishes a floor of one viewport, so a sparse screen centres in the
                // window instead of clinging to the top edge with a screenful of nothing beneath it,
                // and a full report is unaffected because it is already taller. See
                // ``ViewportHeightSpacer`` for why this is a `ZStack` and not a measured height.
                ZStack {
                    ViewportHeightSpacer()
                    content(for: snapshot)
                        // A readable-measure ceiling, then a full-width frame to centre that column.
                        // Not a breakpoint: no size class is read anywhere, and nothing changes on a
                        // phone, where the ceiling is never reached.
                        .frame(maxWidth: Layout.readableWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Space.pageMargin)
                        .padding(.vertical, Space.section)
                }
            }
            pinnedAction(for: snapshot)
        }
        .background(Color(palette.background))
        // The one animated surface, and it is a screen-family change. `MotionPolicy` decides whether
        // it moves; passing `nil` under Reduce Motion performs no animation rather than a fast one.
        .animation(Motion.familyTransition(reduceMotion: reduceMotion), value: snapshot.family)
        .accessibilityElement(children: .contain)
        .onChange(of: input) { _, newInput in
            announce(for: newInput)
            preserveFocus(across: AccessibilitySemanticsSnapshot.projecting(newInput))
            // A new screen starts with its limitations closed. Without this, expanding them on one
            // report would leave them expanded on the next.
            limitationsExpanded = false
        }
        .onAppear { announce(for: input) }
    }

    /// The action region, pinned below the scroll view rather than inside it.
    ///
    /// Only the action region moves out. Everything else stays in the scroll view, so nothing that
    /// carries evidence is pinned over content a user is reading.
    ///
    /// Drawn on the page background with a hairline above it, so it reads as a bar rather than as a
    /// floating card, and inside the bottom safe area so it clears the home indicator.
    @ViewBuilder
    private func pinnedAction(for snapshot: AccessibilitySemanticsSnapshot) -> some View {
        let regions = ScreenComposition.regions(of: snapshot)
        if pinsAction, let index = regions.firstIndex(where: { $0.region == .action }) {
            VStack(spacing: 0) {
                RowDivider(palette: palette)
                elements(
                    of: regions[index],
                    snapshot: snapshot,
                    startingAt: readingOffset(of: index, in: regions),
                    spacing: Space.inner
                )
                .frame(maxWidth: Layout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.pageMargin)
                .padding(.top, Space.padding)
            }
            .background(Color(palette.background))
        }
    }

    /// The regions, in reading order, plus the decorative mark on a screen with no content.
    ///
    /// The elements' order is the snapshot's order: ``ScreenComposition/regions(of:)`` only ever
    /// groups contiguous runs, so concatenating what is rendered here reproduces `snapshot.elements`
    /// exactly. `ScreenCompositionOrderTests` asserts that for every family.
    @ViewBuilder
    private func content(for snapshot: AccessibilitySemanticsSnapshot) -> some View {
        let regions = ScreenComposition.regions(of: snapshot)

        VStack(alignment: .leading, spacing: Space.section) {
            // The ready screen exposes one control and nothing else. Without a mark it reads as a
            // screen that failed to load; the mark says nothing the control does not, which is why
            // it is hidden from assistive technology.
            if snapshot.family == .ready {
                // No top padding: the composition is centred in the viewport now, so padding here
                // would push it off centre rather than move it down the screen.
                DecorativeMark(palette: palette)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Space.tight)
            }

            // The action region is drawn by `pinnedAction(for:)` below the scroll view when it is
            // pinned, so it is skipped here rather than rendered twice. At the accessibility sizes it
            // is not pinned, and it scrolls with everything else - see ``pinsAction``.
            ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                if region.region != .action || !pinsAction {
                    regionView(
                        region,
                        snapshot: snapshot,
                        startingAt: readingOffset(of: index, in: regions)
                    )
                }
            }
        }
    }

    /// Where one region's first element sits in the whole screen's reading order.
    ///
    /// Needed because the sort priority is derived from a position in the *screen*, not in a region.
    /// Summing the preceding regions' counts is exact for the same reason the grouping is safe: the
    /// regions partition the element array in order, with no overlap and no omission.
    private func readingOffset(of index: Int, in regions: [ComposedRegion]) -> Int {
        regions.prefix(index).reduce(0) { $0 + $1.elements.count }
    }

    /// One region, in its own container.
    @ViewBuilder
    private func regionView(
        _ composed: ComposedRegion,
        snapshot: AccessibilitySemanticsSnapshot,
        startingAt offset: Int
    ) -> some View {
        Group {
            switch composed.surface {
            case .centeredStatus:
                centeredStatus(composed, snapshot: snapshot, startingAt: offset)
            case .rowGroup:
                rowGroup(composed, snapshot: snapshot, startingAt: offset)
            case .recessiveBlock where composed.region == .limitations:
                collapsibleLimitations(composed, snapshot: snapshot, startingAt: offset)
            case .card, .inset, .recessiveBlock, .controlStack:
                elements(
                    of: composed,
                    snapshot: snapshot,
                    startingAt: offset,
                    spacing: composed.region == .action ? Space.inner : Space.tight
                )
            }
        }
        .regionContainer(composed.region, palette: palette)
    }

    /// A status region: the in-flight indicator above its own sentence, centred.
    ///
    /// The indicator is present only while work is in flight. A cancelled screen is a status region
    /// too, and it has nothing in flight to indicate.
    @ViewBuilder
    private func centeredStatus(
        _ composed: ComposedRegion,
        snapshot: AccessibilitySemanticsSnapshot,
        startingAt offset: Int
    ) -> some View {
        VStack(spacing: Space.padding) {
            if snapshot.family == .active || snapshot.family == .importing {
                WorkIndicatorView(reduceMotion: reduceMotion, palette: palette)
            }
            elements(of: composed, snapshot: snapshot, startingAt: offset, spacing: Space.tight)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, Space.generous)
    }

    /// The limitations, behind their disclosure control.
    ///
    /// A real disclosure, not a visual one: while collapsed the statements are not built at all, so
    /// they are absent from the accessibility tree rather than present and hidden. That is what makes
    /// the control worth having - a screen reader hears one control instead of three paragraphs it
    /// cannot skip.
    ///
    /// The first element of the region is the control, which the composition put there. Everything
    /// after it is what the control reveals.
    @ViewBuilder
    private func collapsibleLimitations(
        _ composed: ComposedRegion,
        snapshot: AccessibilitySemanticsSnapshot,
        startingAt offset: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ForEach(Array(composed.elements.enumerated()), id: \.element.identity) {
                index, element in
                if element.identity == .limitationsDisclosure || limitationsExpanded {
                    elementView(
                        element,
                        snapshot: snapshot,
                        readingIndex: offset + index,
                        region: composed.region
                    )
                }
            }
        }
    }

    /// A grouped list of rows, separated by hairlines.
    @ViewBuilder
    private func rowGroup(
        _ composed: ComposedRegion,
        snapshot: AccessibilitySemanticsSnapshot,
        startingAt offset: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ForEach(Array(composed.elements.enumerated()), id: \.element.identity) {
                index, element in
                if index > 0 {
                    RowDivider(palette: palette)
                }
                elementView(
                    element,
                    snapshot: snapshot,
                    readingIndex: offset + index,
                    region: composed.region
                )
            }
        }
    }

    /// One region's elements, stacked in reading order.
    @ViewBuilder
    private func elements(
        of composed: ComposedRegion,
        snapshot: AccessibilitySemanticsSnapshot,
        startingAt offset: Int,
        spacing: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(composed.elements.enumerated()), id: \.element.identity) {
                index, element in
                elementView(
                    element,
                    snapshot: snapshot,
                    readingIndex: offset + index,
                    region: composed.region
                )
            }
        }
    }

    /// One element, with its semantics and its weight.
    @ViewBuilder
    private func elementView(
        _ element: AccessibleElement,
        snapshot: AccessibilitySemanticsSnapshot,
        readingIndex: Int,
        region: ScreenRegion
    ) -> some View {
        AccessibleElementView(
            element: element,
            resolver: resolver,
            elementCount: snapshot.elements.count,
            readingIndex: readingIndex,
            axis: snapshot.layout.axis(at: textSize),
            region: region,
            palette: palette,
            isExpanded: element.identity == .limitationsDisclosure ? limitationsExpanded : nil,
            action: element.isOperable ? action(for: element) : nil
        )
        .accessibilityFocused($focusedElement, equals: element.identity)
    }

    /// What activating one element does.
    ///
    /// The disclosure control is the view's own: expansion is view state, so
    /// ``AnalysisScreenActions/action(for:)`` answers `nil` for it and the toggle is supplied here.
    /// Every other action comes from the composition root.
    private func action(for element: AccessibleElement) -> (() -> Void)? {
        guard element.identity == .limitationsDisclosure else {
            return actions.action(for: element.identity)
        }
        return { limitationsExpanded.toggle() }
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

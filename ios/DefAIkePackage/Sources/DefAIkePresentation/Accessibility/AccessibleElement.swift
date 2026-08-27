import DefAIkeDomain

// One accessible element, as data rather than as a view modifier.
//
// Requirement 12 asks for six things about every control and evidence field: a nonempty
// label that identifies its purpose (12.1), a value that matches its displayed state
// (12.2), traits that match its interaction role (12.3), a place in the displayed reading
// and action order (12.4), text in addition to any colour, shape, animation, or icon
// (12.7), and an activation area of at least 44 by 44 points (12.9).
//
// None of those is checkable inside a SwiftUI `body`. A modifier chain is not a value, so a
// test can only observe it by rendering a hierarchy, driving an assistive technology, and
// reading back what it heard - which needs a device, and which is exactly the evidence the
// release gates collect separately. So the semantics are computed *first*, as plain values,
// and the view's only job is to apply them. Everything Requirement 12 asserts about a
// control is then a property of a value a host test can construct and inspect.
//
// Four of the six are settled by shape rather than by care:
//
//   * **A label cannot be empty.** ``label`` is a non-optional
//     ``AccessibilitySemanticSource``, and every case of that type addresses approved
//     content that release validation has already refused to leave blank. There is no
//     `String` field for `""` to arrive in, and no initializer that omits the label.
//   * **Traits cannot disagree with the role.** ``traits`` is computed from ``role`` by a
//     total switch, so it is not a field a caller can populate incorrectly.
//   * **An operable element cannot be smaller than the minimum.** ``activationArea`` is
//     computed from ``role`` too, and its only value is the 44-point minimum.
//   * **Colour, shape, and iconography cannot be the only channel.** There is no colour,
//     symbol, or animation field on this type at all. Decoration is declared through
//     ``AccessoryPresentation``, whose single case states that any accompanying visual is
//     hidden from assistive technology, so meaning always travels as text.
//
// The other two - reading order and displayed-state value - are properties of the
// collection rather than of one element, and live in ``AccessibilitySemanticsSnapshot``.
//
// What this type deliberately cannot hold: a user-facing sentence. Text arrives only as an
// address into approved content, so an accessibility label cannot be assembled by
// concatenation and cannot contain wording chosen here. That is what makes the semantics
// independent of the displayed English, which is what Requirements 12.15 and 12.16 need
// when the Localization Readiness Suite swaps the catalog underneath them.

/// Where one piece of accessible text comes from.
///
/// Two cases, both addresses rather than sentences. There is no case carrying a `String`, so
/// no label, value, or announcement in this module can be built by interpolation, joined
/// from fragments, or written inline.
public enum AccessibilitySemanticSource: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Approved Verdict Copy, addressed by the surface it was approved for.
    case approvedCopy(ResolvedCopyReference)

    /// Approved application-chrome copy, addressed by the surface it was approved for.
    ///
    /// A separate case because chrome copy is not session-bound. A verdict address carries the
    /// catalogue version and the Model Bundle compatibility identifier that approved it, and
    /// resolving one needs a session's `ApprovedCopyBinding`; a control label and a status
    /// sentence have no outcome to be compatible with, and the ready and importing screens have
    /// no binding to resolve one through. See ``ChromeCopySurface`` for the full argument.
    ///
    /// Still an address rather than a sentence, so nothing changes about what this type can
    /// hold: there is no case here carrying a `String`.
    case approvedChromeCopy(ChromeCopyReference)

    /// One of the three display strings Requirement 8.2 fixes character for character.
    ///
    /// A separate case because these three are a requirement rather than an approval
    /// decision, and because ``FixedPixelLabelText`` is already the single authority on
    /// them. Resolving one needs no catalog lookup, which is why the pixel label is the one
    /// evidence field that is fully renderable today.
    case requiredPixelLabelText(FixedPixelLabelText)

    /// The approved verdict-copy address, or `nil` for the fixed pixel labels and for chrome.
    public var copyReference: ResolvedCopyReference? {
        guard case let .approvedCopy(reference) = self else { return nil }
        return reference
    }

    /// The approved chrome-copy address, or `nil` for every other source.
    public var chromeReference: ChromeCopyReference? {
        guard case let .approvedChromeCopy(reference) = self else { return nil }
        return reference
    }

    /// Whether this source addresses content that cannot be blank (Requirement 12.1).
    ///
    /// A real check rather than a restatement of the type. An approved copy address is a
    /// canonical identifier, which the domain refuses to build empty, and a fixed pixel label
    /// is one of three required strings. Both are asserted here so the audit runs over real
    /// projections instead of trusting that the only constructors were used.
    public var addressesNonemptyContent: Bool {
        switch self {
        case let .approvedCopy(reference): !reference.localizationKey.rawValue.isEmpty
        case let .approvedChromeCopy(reference): !reference.localizationKey.rawValue.isEmpty
        case let .requiredPixelLabelText(text): !text.value.isEmpty
        }
    }
}

/// A user-facing surface an accessible element needs and the closed Approved Verdict Copy
/// vocabulary does not define.
///
/// The same rule the view-state and report layers already follow: the gap is recorded, not
/// filled. What is new here is the *kind* of gap. Tasks 11.2 and 11.3 recorded missing
/// labels and headings; an accessible element additionally needs a value that names its
/// current state in words (Requirement 12.2), and a status name is not the same surface as
/// the field label that introduces it.
///
/// Every case below is a value, never a label. The corresponding labels are already
/// recorded in ``UnapprovedViewStateSurface`` and ``UnapprovedReportSurface``, and nothing
/// here duplicates one.
///
/// Closing a gap is a release-artifact change: extend the approved surface vocabulary,
/// approve the wording, add the String Catalog value. It is not a change to this file.
public enum UnapprovedAccessibilitySurface: String, Hashable, Sendable, CaseIterable {
    /// Wording naming the recorded Byte Preservation Status as a state.
    ///
    /// The status's *limitation* is approved and is rendered. Its own name - what a user
    /// hears as the field's value - is not.
    case bytePreservationStatusValue = "byte-preservation-status-value"

    /// Wording naming the on-device-processing status as a state.
    case onDeviceProcessingStatusValue = "on-device-processing-status-value"

    /// Wording naming the Model Bundle integrity status as a state.
    case modelBundleIntegrityStatusValue = "model-bundle-integrity-status-value"

    /// Wording distinguishing an enabled-validator inconclusive result from a release that
    /// cannot validate at all (Requirement 6.21).
    ///
    /// The two are already different values of ``ProvenanceLaneDistinction`` and already
    /// resolve to different approved state copy. What is missing is a separate spoken value
    /// that states the distinction as such.
    case provenanceLaneDistinctionValue = "provenance-lane-distinction-value"

    /// Wording naming a recorded pre-orientation dimension's unit.
    case recordedDimensionValueUnit = "recorded-dimension-value-unit"

    /// Wording naming the stage an active session is working through.
    case analysisStageValue = "analysis-stage-value"

    /// The requirement this gap gates, as a stable reference.
    public var gates: String {
        switch self {
        case .provenanceLaneDistinctionValue: "6.21, 12.2"
        case .bytePreservationStatusValue, .onDeviceProcessingStatusValue,
            .modelBundleIntegrityStatusValue, .recordedDimensionValueUnit, .analysisStageValue:
            "12.2"
        }
    }
}

/// One recorded copy gap, wherever it was recorded.
///
/// A single closed type over the three gap vocabularies, so an audit can enumerate every
/// unmet accessibility semantic in one pass instead of joining three lists. It adds no new
/// gaps of its own.
public enum BlockedSemanticSurface: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// A gap the view-state projection recorded (task 11.2).
    case viewState(UnapprovedViewStateSurface)

    /// A gap the report assembly recorded (task 11.3).
    case report(UnapprovedReportSurface)

    /// A gap only an accessible element needs.
    case accessibility(UnapprovedAccessibilitySurface)

    /// Stable identifier, for deterministic reporting and ordering.
    public var stableKey: String {
        switch self {
        case let .viewState(surface): "view-state/\(surface.rawValue)"
        case let .report(surface): "report/\(surface.rawValue)"
        case let .accessibility(surface): "accessibility/\(surface.rawValue)"
        }
    }

    /// The requirements this gap gates.
    public var gates: String {
        switch self {
        case .viewState: "12.1"
        case let .report(surface): surface.gates
        case let .accessibility(surface): surface.gates
        }
    }
}

/// One semantic an element still needs and cannot yet be given.
///
/// Recorded on the element rather than in a separate list, so a caller that reads an element
/// cannot read its label without also seeing what is missing beside it.
public enum UnmetSemanticRequirement: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// No approved wording identifies this element's purpose, so its label falls back to
    /// the content it displays (Requirement 12.1).
    case purposeLabel(BlockedSemanticSurface)

    /// No approved wording names this element's current state, so it exposes no value
    /// beyond its label (Requirement 12.2).
    case stateValue(BlockedSemanticSurface)

    /// The gap behind this unmet semantic.
    public var surface: BlockedSemanticSurface {
        switch self {
        case let .purposeLabel(surface): surface
        case let .stateValue(surface): surface
        }
    }

    /// Stable identifier, for deterministic reporting.
    public var stableKey: String {
        switch self {
        case let .purposeLabel(surface): "purpose-label/\(surface.stableKey)"
        case let .stateValue(surface): "state-value/\(surface.stableKey)"
        }
    }
}

// MARK: - Role, traits, and activation

/// What one element is, in interaction terms.
///
/// Closed and small. The role is the single input to traits and to the activation-area
/// requirement, so "the traits match the interaction role and state" (Requirement 12.3) and
/// "every interactive control has a 44 by 44 point activation area" (Requirement 12.9) are
/// derived facts rather than things a caller supplies and could get wrong.
public enum AccessibilityRole: String, Hashable, Sendable, CaseIterable {
    /// Static evidence text: a label, an explanation, a limitation, a summary, a notice.
    case evidenceField = "evidence-field"

    /// A heading introducing a group of evidence fields.
    case sectionHeader = "section-header"

    /// Text stating what the application is doing, which changes as the session advances.
    case statusField = "status-field"

    /// A field carrying measured analysis-work progress.
    case progressField = "progress-field"

    /// A control that performs an action in place: cancel, start a new session, retry.
    case activatingControl = "activating-control"

    /// A control that opens another screen.
    case navigatingControl = "navigating-control"

    /// A control that expands or collapses a group in place.
    case disclosureControl = "disclosure-control"

    /// Whether activating this element does something.
    ///
    /// The three control roles are operable and the four content roles are not. Total
    /// switch, no `default`, so a new role has to decide.
    public var isOperable: Bool {
        switch self {
        case .activatingControl, .navigatingControl, .disclosureControl: true
        case .evidenceField, .sectionHeader, .statusField, .progressField: false
        }
    }

    /// The traits this role requires (Requirement 12.3).
    ///
    /// Derived, never stored. A control is a button, a heading is a header, and text that
    /// changes as work advances announces that it updates frequently so an assistive
    /// technology can poll it rather than treating it as fixed.
    public var traits: Set<AccessibilityTrait> {
        switch self {
        case .evidenceField: [.staticText]
        case .sectionHeader: [.staticText, .header]
        case .statusField: [.staticText, .updatesFrequently]
        case .progressField: [.staticText, .updatesFrequently]
        case .activatingControl, .navigatingControl, .disclosureControl: [.button]
        }
    }

    /// The activation area this role requires, or `nil` for content that is not operable.
    ///
    /// Non-`nil` for exactly the operable roles, and its only value is the minimum
    /// Requirement 12.9 fixes. A smaller area is not representable.
    public var activationArea: MinimumActivationArea? {
        isOperable ? .requiredMinimum : nil
    }
}

/// One accessibility trait this application assigns.
///
/// A closed vocabulary rather than the platform's open option set, so the model stays
/// framework-free and a test can enumerate what a role must carry. The view maps these onto
/// the platform's own traits.
public enum AccessibilityTrait: String, Hashable, Sendable, CaseIterable {
    /// Activating this element performs its action.
    case button

    /// This element introduces the group that follows it.
    case header

    /// This element is text rather than a control.
    case staticText = "static-text"

    /// This element's text changes while the screen is on display.
    case updatesFrequently = "updates-frequently"
}

/// The activation area every interactive control provides (Requirement 12.9).
///
/// Counted in points as whole numbers, because the requirement is stated in whole points and
/// because a fractional measurement here would be a magnitude this module has no business
/// carrying. The view converts to the framework's own unit at the boundary.
///
/// There is one constructible value outside this file: ``requiredMinimum``. The memberwise
/// initializer is internal, so a caller cannot declare a 32-point control.
public struct MinimumActivationArea: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The minimum Requirement 12.9 fixes, in points.
    public static let requiredEdgeLength = 44

    /// The one activation area an interactive control may have.
    public static let requiredMinimum = MinimumActivationArea(
        widthPoints: requiredEdgeLength,
        heightPoints: requiredEdgeLength
    )

    /// Minimum width of the activation area, in points.
    public let widthPoints: Int

    /// Minimum height of the activation area, in points.
    public let heightPoints: Int

    init(widthPoints: Int, heightPoints: Int) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }

    /// Whether this area meets the requirement.
    ///
    /// Always true for a constructible value. Exposed so a release audit can assert it over
    /// a real element rather than trusting that the only constructor was used.
    public var meetsRequirement: Bool {
        widthPoints >= Self.requiredEdgeLength && heightPoints >= Self.requiredEdgeLength
    }
}

/// What any colour, shape, icon, or animation accompanying an element may be.
///
/// One case by construction (Requirement 12.7). A decoration can accompany text; it cannot
/// replace text, and it cannot be the thing an assistive technology reads, because the only
/// value this field can take says it is hidden from assistive technology.
///
/// This is why no element in this module has a colour, symbol, or animation member. There is
/// nothing for a colour-only status to be encoded in, so "convey every label, lane state,
/// insufficient-evidence outcome, warning, progress state, and error through text in
/// addition to colour, shape, animation, or iconography" is a property of the type.
public enum AccessoryPresentation: String, Hashable, Sendable, CaseIterable {
    /// Any accompanying visual is decorative and hidden from assistive technology; the
    /// element's text carries the whole meaning.
    case decorativeAndAccessibilityHidden = "decorative-and-accessibility-hidden"
}

// MARK: - The element

/// One element in the accessibility hierarchy, fully described as data.
public struct AccessibleElement: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Which element this is. Stable across projections, so focus can be tracked by it.
    public let identity: AccessibleElementIdentity

    /// What this element is, in interaction terms.
    public let role: AccessibilityRole

    /// The nonempty programmatic label (Requirement 12.1).
    ///
    /// Non-optional, and every case of the source type addresses approved content that
    /// release validation refuses to leave blank, so an empty label is unrepresentable
    /// rather than merely unlikely.
    public let label: AccessibilitySemanticSource

    /// The programmatic value matching the displayed state (Requirement 12.2), or `nil` when
    /// the element's label already is its state.
    ///
    /// `nil` is the correct answer for static text: the displayed content and the spoken
    /// label are the same words, and a value repeating them would be read twice. It is also
    /// what an unmet ``UnmetSemanticRequirement/stateValue`` leaves behind.
    public let value: AccessibilitySemanticSource?

    /// Semantics this element needs and the approved vocabulary does not define, in a
    /// deterministic order.
    public let unmetSemantics: [UnmetSemanticRequirement]

    /// What an accompanying visual may be. Always decorative and hidden.
    public let accessory: AccessoryPresentation

    /// The traits this element carries (Requirement 12.3). Derived from ``role``.
    public var traits: Set<AccessibilityTrait> { role.traits }

    /// The activation area this element provides, or `nil` when it is not operable
    /// (Requirement 12.9). Derived from ``role``.
    public var activationArea: MinimumActivationArea? { role.activationArea }

    /// Whether activating this element does something.
    public var isOperable: Bool { role.isOperable }

    /// Whether every semantic Requirement 12 asks of this element is met.
    public var hasCompleteSemantics: Bool { unmetSemantics.isEmpty }

    init(
        identity: AccessibleElementIdentity,
        role: AccessibilityRole,
        label: AccessibilitySemanticSource,
        value: AccessibilitySemanticSource? = nil,
        unmetSemantics: [UnmetSemanticRequirement] = []
    ) {
        self.identity = identity
        self.role = role
        self.label = label
        self.value = value
        self.unmetSemantics = unmetSemantics
        self.accessory = .decorativeAndAccessibilityHidden
    }
}

/// An element the screen needs and cannot expose at all, because no approved wording for it
/// exists.
///
/// Distinct from an ``AccessibleElement`` carrying an ``UnmetSemanticRequirement``: that one
/// is exposed and imperfect, this one has no text of any kind and is therefore not rendered.
/// The distinction matters for a release audit, because the second kind is the set of
/// controls and status fields Requirement 12 cannot be satisfied for until the approved copy
/// decision is made.
///
/// Recording them as values is what lets the accessibility tests enumerate the blockage
/// instead of reporting a screen that silently lacks a cancel button.
public struct BlockedAccessibleElement: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Which element is missing.
    public let identity: AccessibleElementIdentity

    /// The role it would carry once wording exists.
    public let role: AccessibilityRole

    /// Every recorded gap blocking it, in a deterministic order.
    public let blocking: [BlockedSemanticSurface]

    init(
        identity: AccessibleElementIdentity,
        role: AccessibilityRole,
        blocking: [BlockedSemanticSurface]
    ) {
        self.identity = identity
        self.role = role
        self.blocking = blocking
    }
}

import DefAIkeDomain

// The whole accessibility hierarchy of one screen, as one immutable value.
//
// This is the seam the accessibility tests need. Requirement 12.4 asks that controls and
// content be exposed "in the displayed reading and action order for each required workflow",
// and an order is a property of a collection rather than of an element - so the collection is
// the value, and the order is the array's own order. Nothing sorts it, nothing derives it from
// text, and nothing reorders it by comparing labels, so the order survives a copy edit, a
// translation, and a Localization Readiness Suite substitution unchanged.
//
// Everything here is computed from view state, without a view. That is deliberate:
//
//   * a host test can construct a screen, project it, and assert labels, values, traits,
//     order, activation areas, and the exact set of blocked elements, with no simulator, no
//     rendering, and no assistive technology driving it;
//   * the SwiftUI layer becomes a mechanical application of this value, so a semantics bug is
//     a wrong value rather than a missing modifier nobody can see; and
//   * the semantics are catalog-independent. Labels are addresses, not sentences, so swapping
//     the English catalog for an expansion, long-word, bidirectional, or pseudolocalized one
//     cannot change a single value in this snapshot - which is Requirement 12.16 as an
//     identity rather than as a test outcome.
//
// Two element lists, not one. ``elements`` is what the screen exposes; ``blockedElements`` is
// what it cannot expose at all, because no approved wording of any kind exists for it. Keeping
// them apart is the honest shape: a release audit reading this can see that the cancel control,
// the progress readout, the cancelled status, and the technical-details rows are absent for one
// stated reason and not through oversight. Merging them into one list with an "is rendered" flag
// would let a caller iterate everything and render a control with no label.
//
// What no snapshot carries: a `String`, a colour, a symbol name, an animation, a coordinate, a
// size, a probability, a percentage, or a score. Every field is an address or a closed
// vocabulary value.

/// The accessibility semantics of one screen.
public struct AccessibilitySemanticsSnapshot: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Which screen family this describes.
    public let family: AnalysisScreenFamily

    /// Every element the screen exposes, in displayed reading order (Requirement 12.4).
    ///
    /// The array order *is* the reading order. There is no sort priority field, no weight, and
    /// no comparator, so the order cannot be changed by anything but changing this array.
    public let elements: [AccessibleElement]

    /// Every element the screen needs and cannot expose, in a deterministic order.
    public let blockedElements: [BlockedAccessibleElement]

    /// The layout rules this screen follows.
    public let layout: AdaptiveLayoutPolicy

    /// The announcement for this screen's status, before debouncing.
    ///
    /// Held on the snapshot so a test can assert what *would* be announced for a screen
    /// independently of the sequence it arrived in. Whether it is actually spoken is
    /// ``StatusAnnouncementDebouncer``'s decision.
    public let announcement: StatusAnnouncement

    init(
        family: AnalysisScreenFamily,
        elements: [AccessibleElement],
        blockedElements: [BlockedAccessibleElement],
        announcement: StatusAnnouncement
    ) {
        self.family = family
        self.elements = elements
        self.blockedElements = blockedElements
        self.layout = .standard
        self.announcement = announcement
    }

    // MARK: - Order

    /// The reading order, as identities (Requirement 12.4).
    public var readingOrder: [AccessibleElementIdentity] { elements.map(\.identity) }

    /// The action order: the operable elements, in reading order (Requirement 12.4).
    ///
    /// A filter of ``elements``, never a separate list, so the action order can never disagree
    /// with the reading order about which control comes first.
    public var actionOrder: [AccessibleElementIdentity] {
        elements.filter(\.isOperable).map(\.identity)
    }

    /// The position of one element in the reading order, or `nil` when it is not exposed.
    ///
    /// The view turns this into the framework's own ordering value; the model keeps it a
    /// position so it stays a whole number a test can compare.
    public func readingIndex(of identity: AccessibleElementIdentity) -> Int? {
        elements.firstIndex { $0.identity == identity }
    }

    // MARK: - Lookup

    /// The exposed element with this identity, or `nil`.
    public func element(_ identity: AccessibleElementIdentity) -> AccessibleElement? {
        elements.first { $0.identity == identity }
    }

    /// The blocked element with this identity, or `nil`.
    public func blockedElement(_ identity: AccessibleElementIdentity) -> BlockedAccessibleElement? {
        blockedElements.first { $0.identity == identity }
    }

    /// Whether this identity is exposed to assistive technology.
    public func exposes(_ identity: AccessibleElementIdentity) -> Bool {
        element(identity) != nil
    }

    /// Every operable element, in reading order.
    public var operableElements: [AccessibleElement] { elements.filter(\.isOperable) }

    // MARK: - Audits

    /// Whether every exposed element has a nonempty label (Requirement 12.1).
    public var everyElementHasANonemptyLabel: Bool {
        elements.allSatisfy(\.label.addressesNonemptyContent)
    }

    /// Whether every exposed value addresses nonempty content (Requirement 12.2).
    ///
    /// An element with no value passes: a static field whose label already is its state has
    /// nothing more to say, and a blank value would be worse than none.
    public var everyExposedValueIsNonempty: Bool {
        elements.allSatisfy { $0.value?.addressesNonemptyContent ?? true }
    }

    /// Whether every exposed operable element provides the required activation area
    /// (Requirement 12.9).
    public var everyControlMeetsTheActivationMinimum: Bool {
        operableElements.allSatisfy { $0.activationArea?.meetsRequirement == true }
    }

    /// Whether every exposed element's traits match its role (Requirement 12.3).
    public var everyElementCarriesItsRoleTraits: Bool {
        elements.allSatisfy { !$0.traits.isEmpty && $0.traits == $0.role.traits }
    }

    /// Every recorded gap this screen is affected by, deduplicated and in stable order.
    ///
    /// The union of what blocked elements are waiting on and what exposed elements are missing.
    /// This is the list a release audit reads to see what the approved-copy decision still owes
    /// Requirement 12.
    public var recordedCopyGaps: [BlockedSemanticSurface] {
        var seen: Set<BlockedSemanticSurface> = []
        var ordered: [BlockedSemanticSurface] = []
        for surface in blockedElements.flatMap(\.blocking)
            + elements.flatMap({ $0.unmetSemantics.map(\.surface) })
        where seen.insert(surface).inserted {
            ordered.append(surface)
        }
        return ordered.sorted { $0.stableKey < $1.stableKey }
    }
}

// MARK: - The projection input

/// One screen, with everything the accessibility projection needs to describe it.
///
/// A separate input type rather than ``AnalysisScreen`` directly, for one reason: a completed
/// session's accessible content is the *assembled* Evidence Report - both cards, the
/// limitations, the transparency fields, and the onward paths - and assembling it needs the
/// session's approved copy binding, which the screen does not carry. Taking the assembled
/// report as the completed case's payload means the projection is pure and total, and cannot
/// be called in a way that silently omits the limitations.
///
/// Total over the six screen families, so a new family cannot be added without this list
/// noticing.
public enum AccessibilityScreenInput: Hashable, Sendable {
    case ready(ReadyScreen)
    case importing(ImportingScreen)
    case active(ActiveScreen)
    case completed(EvidenceReportPresentation)
    case cancelled(CancelledScreen)
    case error(AnalysisErrorScreen)

    /// Which family this input describes.
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

    /// Bridges one projected screen, assembling the report for a completed session.
    ///
    /// `copy` is the same session-bound binding the screen was projected through, and the
    /// assembly checks it against the screen's own session before resolving anything, so a
    /// mismatched binding is refused here exactly as it is in the report layer.
    ///
    /// Throws only for a completed screen, and only for the reasons report assembly already
    /// throws for. The other five families need no copy resolution at all.
    public init(
        screen: AnalysisScreen,
        copy: ApprovedCopyBinding
    ) throws(EvidenceReportAssemblyError) {
        switch screen {
        case let .ready(ready): self = .ready(ready)
        case let .importing(importing): self = .importing(importing)
        case let .active(active): self = .active(active)
        case let .completed(completed):
            self = .completed(try EvidenceReportPresentation.assembling(completed, copy: copy))
        case let .cancelled(cancelled): self = .cancelled(cancelled)
        case let .error(failed): self = .error(failed)
        }
    }
}

import DefAIkeDomain

// Turning one flat, ordered element list into grouped regions, without reordering anything.
//
// ``AccessibilitySemanticsSnapshot`` exposes a flat array whose order *is* the reading order
// (Requirement 12.4). A designed screen needs groups - the two evidence lanes as separate cards,
// the limitations as one recessive block, the onward paths as one row group - and grouping is
// exactly the operation most likely to break that order by accident. A composition that sorted,
// bucketed, or collected by kind would silently rewrite the reading and action order, and the
// accessibility guarantee with it.
//
// So the grouping here is a single forward pass that starts a new region whenever the region of
// the next element differs from the region of the current one. Regions are therefore *contiguous
// runs of the existing order*, never buckets:
//
//   * order is preserved by construction, because nothing is ever moved;
//   * concatenating the regions' elements reproduces `snapshot.elements` exactly, which
//     `ScreenCompositionOrderTests` asserts element by element for every screen family; and
//   * the same identity appearing in two families at different positions - a byte-preservation
//     limitation precedes the message on a failed screen and follows the lanes on a completed one -
//     needs no special case, because the pass reads position from the array rather than from a
//     table.
//
// A region can appear more than once. That is the point of the two evidence lanes: they resolve to
// the same ``ScreenRegion/evidenceLane`` case, so the composition emits two lane regions with
// identical treatment. Neither lane can be drawn more prominently than the other, because there is
// no second case for one of them to use (Requirements 7.1 and 7.8).
//
// This file names no colour, no measurement, and no font. It decides what is grouped with what.

/// One visually grouped region of a screen.
///
/// Closed and flat. Two source lanes share ``evidenceLane`` deliberately; see above.
public enum ScreenRegion: String, Hashable, Sendable, CaseIterable {

    /// Text stating what the application is doing, in a centered composition.
    case status

    /// The Combined Summary an approved fusion rule produced.
    case summary

    /// The notice that the two lanes appear inconsistent.
    case notice

    /// One source lane's headline and supporting sentences.
    ///
    /// One case for both lanes. A screen emits this region twice, and the two are indistinguishable.
    case evidenceLane = "evidence-lane"

    /// The scope, false-result, and byte-preservation statements.
    case limitations

    /// The optional technical-details group.
    case technicalDetails = "technical-details"

    /// The onward disclosure paths.
    case disclosure

    /// The single Analysis Error message.
    case failure

    /// The controls that move a session forward or stop it.
    case action

    /// The container treatment this region is drawn in.
    ///
    /// Derived from the region, so a region cannot be given one surface on one screen and a
    /// different one on another. Total switch, no `default`.
    public var surface: RegionSurface {
        switch self {
        case .status: .centeredStatus
        // Both lanes and the summary sit on the same card treatment. The summary is not ranked
        // above the lanes it joins, and neither lane is ranked above the other.
        case .evidenceLane, .summary: .card
        case .notice, .failure: .inset
        case .limitations: .recessiveBlock
        case .technicalDetails, .disclosure: .rowGroup
        case .action: .controlStack
        }
    }

    /// The region one element belongs to.
    ///
    /// Total over the identity vocabulary, with no `default`, so a new element has to be placed
    /// rather than defaulting into a group.
    ///
    /// An identity and nothing else. The region is not a function of the screen family, of an
    /// outcome, or of a position, so the same element is always grouped with the same neighbours.
    public static func region(for identity: AccessibleElementIdentity) -> ScreenRegion {
        switch identity {
        case .pixelEvidenceLabel, .pixelEvidenceExplanation, .provenanceLaneState,
            .screenshotProvenanceExplanation:
            .evidenceLane

        case .combinedSummary:
            .summary
        case .apparentInconsistencyNotice:
            .notice

        case .limitationsDisclosure, .evidenceScopeLimitation, .falseResultLimitation,
            .bytePreservationLimitation:
            .limitations

        case .technicalDetailsDisclosure, .boundComponentVersion, .recordedDimension,
            .onDeviceProcessingStatus, .modelBundleIntegrityStatus:
            .technicalDetails

        case .informationPath:
            .disclosure

        case .importStatus, .workProgress, .cancelledStatus:
            .status
        case .analysisErrorMessage:
            .failure

        case .imageSelectionControl, .analysisErrorRecovery, .cancellationControl:
            .action
        }
    }

    /// Whether the two evidence lanes are separated within this region.
    ///
    /// True only for ``evidenceLane``: a lane headline begins a new lane, so a run containing both
    /// lanes' elements is split at the second headline. See ``ScreenComposition/regions(of:)``.
    var splitsAtLaneHeadline: Bool { self == .evidenceLane }
}

/// How one region's container is drawn.
///
/// A closed vocabulary rather than a set of modifiers, so a host test can assert which treatment a
/// region gets without rendering. ``Palette`` maps these onto colours and ``RegionContainer`` onto
/// the actual container.
public enum RegionSurface: String, Hashable, Sendable, CaseIterable {

    /// A bordered card on its own background.
    case card

    /// A tinted inset: a notice, a failure message.
    case inset

    /// A quieter block drawn directly on the page, with no fill of its own.
    case recessiveBlock = "recessive-block"

    /// A grouped list of rows sharing one container.
    case rowGroup = "row-group"

    /// A centered composition holding a status and its decorative indicator.
    case centeredStatus = "centered-status"

    /// A stack of controls, drawn on the page.
    case controlStack = "control-stack"
}

// MARK: - The composition

/// One contiguous run of elements sharing a region.
public struct ComposedRegion: Hashable, Sendable {
    /// Which region this is.
    public let region: ScreenRegion

    /// The elements in it, in their original reading order.
    public let elements: [AccessibleElement]

    init(region: ScreenRegion, elements: [AccessibleElement]) {
        self.region = region
        self.elements = elements
    }

    /// The container treatment this run is drawn in.
    public var surface: RegionSurface { region.surface }
}

/// The regions of one screen, in reading order.
public enum ScreenComposition: Sendable {

    /// Groups one snapshot's elements into contiguous regions, preserving order exactly.
    ///
    /// A single forward pass. An element joins the run being built when it has the same region as
    /// the run, and starts a new run otherwise. Nothing is sorted and nothing is moved, so
    /// `regions(of: snapshot).flatMap(\.elements) == snapshot.elements` holds for every input -
    /// asserted per family in `ScreenCompositionOrderTests`.
    ///
    /// The one extra rule is the lane split: two evidence lanes are one region case, so a run of
    /// lane elements is broken before a second ``AccessibleElementIdentity/provenanceLaneState``
    /// or ``AccessibleElementIdentity/pixelEvidenceLabel``. That still only ever *splits* a run,
    /// which cannot reorder anything.
    public static func regions(of snapshot: AccessibilitySemanticsSnapshot) -> [ComposedRegion] {
        var composed: [ComposedRegion] = []
        var currentRegion: ScreenRegion?
        var currentElements: [AccessibleElement] = []

        func closeCurrentRun() {
            guard let region = currentRegion, !currentElements.isEmpty else { return }
            composed.append(ComposedRegion(region: region, elements: currentElements))
            currentElements = []
        }

        for element in snapshot.elements {
            let region = ScreenRegion.region(for: element.identity)
            let startsNewLane = region.splitsAtLaneHeadline && isLaneHeadline(element.identity)

            if region != currentRegion || startsNewLane {
                closeCurrentRun()
                currentRegion = region
            }
            currentElements.append(element)
        }
        closeCurrentRun()

        return composed
    }

    /// Whether this identity begins a source lane.
    ///
    /// The two lane headlines, and nothing else. Named as a function over the closed vocabulary so
    /// it cannot drift from ``VisualEmphasis/laneHeadline``.
    static func isLaneHeadline(_ identity: AccessibleElementIdentity) -> Bool {
        switch identity {
        case .pixelEvidenceLabel, .provenanceLaneState: true
        case .imageSelectionControl, .importStatus, .workProgress, .cancellationControl,
            .cancelledStatus, .analysisErrorMessage, .analysisErrorRecovery,
            .pixelEvidenceExplanation, .screenshotProvenanceExplanation, .combinedSummary,
            .apparentInconsistencyNotice, .evidenceScopeLimitation, .falseResultLimitation,
            .bytePreservationLimitation, .technicalDetailsDisclosure, .boundComponentVersion,
            .recordedDimension, .onDeviceProcessingStatus, .modelBundleIntegrityStatus,
            .informationPath,
            .limitationsDisclosure:
            false
        }
    }
}

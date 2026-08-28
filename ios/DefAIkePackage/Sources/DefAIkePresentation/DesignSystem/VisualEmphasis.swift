import DefAIkeDomain

// How much visual weight one element carries, as a value rather than as a modifier chain.
//
// This is the design layer's counterpart to ``AccessibleElement``: the same argument that put the
// accessibility semantics in a value instead of a `body` puts the visual treatment here. A
// modifier chain is not a value, so a test can only observe it by rendering and reading pixels
// back. An emphasis is a value, so what an element looks like becomes something a host test can
// construct and compare.
//
// # The one thing this type exists to make impossible
//
// A detector's obvious visual language is a red card for "AI" and a green card for "clean". That
// language is forbidden here, and not as a matter of taste. Requirement 8.4 forbids presenting any
// result as proof of authenticity, and a green card states exactly that conclusion - in a channel
// nothing reviews. The approved-copy gate reads sentences, so a claim smuggled in as a fill colour
// passes every check this application has.
//
// So the emphasis of an element is derived from its ``AccessibleElementIdentity`` and from nothing
// else. Look at ``emphasis(for:)``: it takes an identity. It does not take a ``PixelLabelKey``, a
// ``FixedPixelLabelText``, an ``EvidenceReport``, a lane state, or a fusion outcome, and there is
// no overload that does. An outcome-derived colour is therefore not something the views avoid - it
// is not expressible, because the function that decides appearance is never shown an outcome.
//
// `DesignSystemOutcomeBlindnessTests` asserts the consequence directly: all three fixed pixel
// labels project to an identical set of emphases, so the three verdicts are visually
// indistinguishable from each other.
//
// # Why the two evidence lanes share their cases
//
// Requirements 7.1 and 7.8 keep the pixel and provenance lanes independent, and neither may
// suppress, override, or rank the other. ``laneHeadline`` and ``laneBody`` are therefore one case
// each for both lanes rather than two cases per lane. A lane cannot be given a heavier treatment
// than the other, because there is no second case to give it.
//
// # What is deliberately absent
//
// No case here names a colour, and no member of this type stores one. An emphasis says how much
// weight a piece of text carries; ``Palette`` decides what that weight looks like, and it is shown
// an emphasis rather than an outcome for the same reason.

/// How much visual weight one element carries.
///
/// Closed and small. Eleven cases for twenty-four element identities, because most elements are
/// one of a few kinds of thing: a lane's headline, a lane's supporting sentence, a limitation, a
/// status, a control.
public enum VisualEmphasis: String, Hashable, Sendable, CaseIterable {

    /// A source lane's headline: the pixel label, or the provenance lane's state.
    ///
    /// One case for both lanes, so neither can be drawn more prominently than the other.
    case laneHeadline = "lane-headline"

    /// A source lane's supporting sentence: the qualified explanation, the screenshot note.
    ///
    /// One case for both lanes, for the same reason.
    case laneBody = "lane-body"

    /// The Combined Summary an approved fusion rule produced.
    case combinedSummary = "combined-summary"

    /// The notice that the two lanes appear inconsistent.
    case inconsistencyNotice = "inconsistency-notice"

    /// An evidence-scope, false-result, or byte-preservation limitation.
    case limitation

    /// Text stating what the application is doing.
    case status

    /// The single Analysis Error message.
    case failureMessage = "failure-message"

    /// The one action that moves a session forward: choose an image, or recover from a terminal.
    case primaryAction = "primary-action"

    /// The control that stops active analysis work.
    case cancellationAction = "cancellation-action"

    /// A row that opens one of the onward disclosure paths.
    case navigationRow = "navigation-row"

    /// A technical-details row: a bound version, a recorded dimension, a status.
    case transparencyRow = "transparency-row"

    /// The header of a collapsible group, which is also its control.
    case disclosureHeader = "disclosure-header"

    /// The emphasis one element carries.
    ///
    /// Total over the identity vocabulary, with no `default`, so a new element has to be given a
    /// weight rather than inheriting one.
    ///
    /// The parameter is an identity and the return is an emphasis. Neither is an outcome, and no
    /// overload of this function takes one - which is the whole guarantee described at the top of
    /// this file.
    public static func emphasis(for identity: AccessibleElementIdentity) -> VisualEmphasis {
        switch identity {
        // Both lanes reach the same two cases. `pixelEvidenceLabel` and `provenanceLaneState` are
        // different elements saying different things; they are not different weights.
        case .pixelEvidenceLabel, .provenanceLaneState:
            .laneHeadline
        case .pixelEvidenceExplanation, .screenshotProvenanceExplanation:
            .laneBody

        case .combinedSummary:
            .combinedSummary
        case .apparentInconsistencyNotice:
            .inconsistencyNotice

        case .evidenceScopeLimitation, .falseResultLimitation, .bytePreservationLimitation:
            .limitation

        case .importStatus, .workProgress, .cancelledStatus:
            .status
        case .analysisErrorMessage:
            .failureMessage

        // One case for the selection control and for the recovery every terminal offers, because
        // `SessionRecovery` has one case: selecting another image *is* the recovery.
        case .imageSelectionControl, .analysisErrorRecovery:
            .primaryAction
        case .cancellationControl:
            .cancellationAction

        case .informationPath:
            .navigationRow

        // The disclosure that reveals the limitations. Drawn at the same weight as the statements it
        // reveals, so opening it does not feel like leaving the report.
        case .limitationsDisclosure:
            .disclosureHeader

        case .technicalDetailsDisclosure, .boundComponentVersion, .recordedDimension,
            .onDeviceProcessingStatus, .modelBundleIntegrityStatus:
            .transparencyRow
        }
    }

    /// Whether this emphasis is drawn on a filled control rather than on a surface.
    ///
    /// Derived, so a caller cannot declare that a limitation is drawn on the accent fill.
    public var isOnFilledControl: Bool {
        switch self {
        case .primaryAction: true
        case .laneHeadline, .laneBody, .combinedSummary, .inconsistencyNotice, .limitation,
            .status, .failureMessage, .cancellationAction, .navigationRow, .transparencyRow,
            .disclosureHeader:
            false
        }
    }

    /// Every emphasis the two source lanes can resolve to.
    ///
    /// Exposed so a test can assert the lanes share them rather than trusting the switch above.
    public static let laneEmphases: Set<VisualEmphasis> = [.laneHeadline, .laneBody]
}

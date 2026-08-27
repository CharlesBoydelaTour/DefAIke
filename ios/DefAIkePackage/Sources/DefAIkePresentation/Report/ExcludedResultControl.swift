// The result-screen affordances that must not exist.
//
// Requirement 9.15 removes analysis-history, save-result, export-result, copy-result,
// and share-result controls from Version 1. Requirement 8.13 removes probability and
// confidence representations - numeric values, percentages, categorical levels, and
// equivalent graphical encodings - from every user-facing surface. Requirement 8.15
// permits a raw model output inside optional technical details only when the approved
// optional-detail artifact enables it and labels it as uncalibrated raw output.
//
// Those are omissions, and an omission enforced by convention is the easiest thing in
// a UI to lose. A `#if`, a feature flag, a disabled button, a hidden modifier, or a
// commented-out toolbar item all read as "not shipped" and all ship. So the guarantee
// here is absence from the *type*: no card, limitation, technical-detail, or report
// model in this module has a member any of these affordances could hang from, and none
// of them can be reached from a value this module produces.
//
// This file is the written-down list of what is absent, for three reasons:
//
//   * a release audit can enumerate the ban rather than reading prose;
//   * the presentation test target walks every model in this module by reflection and
//     fails when a member appears that could carry one of these (see the forbidden
//     control audit in the test target); and
//   * a future task that needs to add a member has to reckon with a named prohibition
//     instead of an absence it might read as an oversight.
//
// Nothing here is a runtime switch. There is no way to turn one of these on, because
// there is nothing to turn on.

/// One result-screen affordance Version 1 does not have.
///
/// Closed and enumerable. A case is removed only when a requirement stops forbidding
/// the affordance, never when a screen wants it.
public enum ExcludedResultControl: String, Hashable, Sendable, CaseIterable {
    /// A list, log, or browser of earlier Analysis Sessions and their results
    /// (Requirement 9.15).
    ///
    /// There is nothing for one to read. An Evidence Report is exposed only while its
    /// session is active (Requirement 9.14), the domain report is deliberately not
    /// serializable, and no model in this module is either.
    case analysisHistory = "analysis-history"

    /// A control that writes a result to storage for later retrieval
    /// (Requirement 9.15).
    case saveResult = "save-result"

    /// A control that writes a result out of the application as a file, document, or
    /// serialized payload (Requirement 9.15).
    case exportResult = "export-result"

    /// A control that places a result on the system pasteboard (Requirement 9.15).
    case copyResult = "copy-result"

    /// A control that hands a result to another application or to a share sheet
    /// (Requirement 9.15).
    case shareResult = "share-result"

    /// Any probability or confidence representation: a numeric value, a percentage, a
    /// categorical confidence level, or a graphical encoding equivalent to one such as
    /// a gauge, meter, or filled bar (Requirement 8.13).
    ///
    /// Enforced twice over. Nothing in this module carries a floating-point or
    /// percentage field for a magnitude to arrive in, and the three pixel labels are
    /// fixed qualified strings with no numeric companion.
    case probabilityOrConfidenceRepresentation = "probability-or-confidence-representation"

    /// A control that reveals the model's uncalibrated raw output.
    ///
    /// Requirement 8.15 allows one *inside optional technical details*, on two
    /// conditions: the approved optional-detail artifact enables it, and the value is
    /// identified as uncalibrated raw model output rather than a consumer probability,
    /// confidence measure, or percentage. Neither the artifact that would enable it nor
    /// an approved surface that would label it exists, so no model here has a member
    /// for the value and Requirement 8.15 is satisfied by the value being absent rather
    /// than by wording chosen here.
    case uncalibratedRawOutputDisclosure = "uncalibrated-raw-output-disclosure"

    /// The requirement that forbids this affordance, as a stable reference.
    ///
    /// Stated so an audit can report *why* a control is absent without a reader having
    /// to match a case against prose.
    public var forbiddenBy: String {
        switch self {
        case .analysisHistory, .saveResult, .exportResult, .copyResult, .shareResult:
            "9.15"
        case .probabilityOrConfidenceRepresentation:
            "8.13"
        case .uncalibratedRawOutputDisclosure:
            "8.15"
        }
    }
}

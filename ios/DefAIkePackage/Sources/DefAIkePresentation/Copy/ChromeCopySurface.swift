import DefAIkeDomain

// The second closed copy vocabulary: application chrome, not evidence.
//
// `VerdictCopySurface` is closed, and it is closed around one thing — copy that describes an
// *evidence outcome*. Every one of its fifteen cases is a label, an explanation, a lane state,
// a summary, a limitation, an error, or a recovery offered for an error, and Requirement 8.1
// binds all of it to the session's Model Bundle through a compatibility identifier. That
// binding is the reason a verdict's wording cannot be resolved without an
// `ApprovedCopyBinding`: a sentence describing what a model concluded has to be the sentence
// approved for *that* model version, so a later activation or rollback cannot silently restate
// an already-displayed verdict.
//
// The surfaces below are not that. "Choose an image", "Analyzing the image", and "Stop
// analyzing" describe what the *application* is doing. None of them names an outcome, a label,
// a lane, a probability, or a limitation, and none of them changes meaning when the Model
// Bundle changes. So adding them to `VerdictCopySurface` would be wrong in a way that is worth
// stating: it would make the picker button's label a per-session, Model-Bundle-compatible
// artifact, which implies a rollback could change it, and it would require every screen that
// shows chrome to first hold a session binding — which the ready and importing screens, by
// construction, do not have and must not have (`ReadyScreen` has no stored property at all,
// and an ingest attempt is not yet an Analysis Session).
//
// Hence a parallel vocabulary, with the same three-part mechanism and the same fail-closed
// rule:
//
//   1. **A closed surface list.** This enum. A screen can only address a surface that exists,
//      and the compiler refuses a new one that nothing renders.
//   2. **A stable localization key per surface.** Derived by the same convention
//      `EnglishStringCatalog` already uses — `copy.` followed by the surface's stable
//      identifier — so there is one key scheme in the catalog rather than two.
//   3. **An approved English value, validated before anything renders.**
//      `ChromeCopyCoverage.audit(_:)` runs inside `EnglishStringCatalog.loadShippedCatalog()`,
//      so a build whose catalog omits or blanks a chrome value refuses at
//      `AccessibleTextResolver.shipped()` and blocks startup with
//      `approvedCopyUnreadable`. A missing chrome string is a launch refusal, never a
//      button with no name.
//
// What is deliberately *not* replicated: a signed catalogue artifact mapping surface to key.
// `ApprovedVerdictCopyCatalog` exists because a verdict's wording has to be pinned to a model
// version, and pinning needs an artifact the startup gate can compare. Chrome has nothing to
// pin to, so the mapping is a compile-time convention and the approval that matters is the
// content approval recorded against the String Catalog entry itself. That is a smaller claim
// than the verdict path makes, and it is the honest one: a `ChromeCopyReference` asserts that
// the surface exists and that the catalog was validated, and nothing more.
//
// # Wording status
//
// Every value in the String Catalog for these surfaces is **proposed wording awaiting content
// approval**, recorded as unresolved decision D1. The catalog entries say so in their
// `comment` fields. Approving them is a content decision, not a change to this file.

/// One application-chrome surface that needs approved copy.
///
/// Closed and flat. Each case is a control label or a status sentence; none of them names an
/// evidence outcome, so none of them can be used to state a verdict, a probability, or a
/// limitation.
public enum ChromeCopySurface: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The control that opens the image picker.
    ///
    /// Also the recovery every terminal screen offers, because recovery means exactly one
    /// thing here — select an image and start a new session (`SessionRecovery` has one case).
    case imageSelectionAction = "image-selection-action"

    /// Status text for an ingest attempt in flight.
    ///
    /// States that a selected image is being retrieved. It carries no route name: a route is a
    /// developer identifier, and `photos-picker` is not a sentence.
    case importInProgressStatus = "import-in-progress-status"

    /// Status text asserting that analysis work is continuing.
    ///
    /// Deliberately one surface rather than one per stage and one per measured or unmeasured
    /// readout. No stage reports a completed-work and total-work pair for the same measured
    /// unit to this layer (Requirements 15.2 and 15.3), so there is nothing for a
    /// stage-specific or fraction-bearing sentence to say that this one does not. Wording for
    /// the stage itself remains unapproved and stays recorded as
    /// `UnapprovedAccessibilitySurface.analysisStageValue`.
    case analysisInProgressStatus = "analysis-in-progress-status"

    /// The cancellation control's own label (Requirements 12.1 and 15.5).
    case cancellationAction = "cancellation-action"

    /// Status text for the cancelled terminal state.
    ///
    /// Cancellation is a terminal in its own right and never an Analysis Error
    /// (Requirement 11.17), so its wording has to state that no result was produced without
    /// naming a failure.
    case cancelledStatus = "cancelled-status"

    /// The control that expands and collapses the limitation statements.
    ///
    /// Chrome rather than verdict copy, and the distinction is the same one this file already
    /// draws: the limitations *themselves* describe what the evidence does and does not cover, so
    /// they are Model-Bundle-bound `VerdictCopySurface` content. The word on the control that
    /// reveals them describes what the *application* is doing, names no outcome, and does not
    /// change meaning when the Model Bundle changes.
    case limitationsDisclosureAction = "limitations-disclosure-action"

    /// The state a disclosure control announces while its group is revealed.
    ///
    /// Requirement 12.7 forbids a state that travels only as a glyph, and SwiftUI's
    /// `AccessibilityTraits` has no expanded member to lean on - so the state is a word, addressed
    /// like every other word in this application. The view picks which of these two to resolve from
    /// its own expansion state; it does not compose the sentence.
    case disclosureExpandedState = "disclosure-expanded-state"

    /// The state a disclosure control announces while its group is hidden.
    case disclosureCollapsedState = "disclosure-collapsed-state"

    /// The control that opens the information screen.
    case informationAction = "information-action"

    /// The title of the information screen.
    case informationTitle = "information-title"

    /// The control that dismisses the information screen.
    case informationDismissAction = "information-dismiss-action"

    /// The heading introducing the limitation statements on the information screen.
    case informationLimitationsHeading = "information-limitations-heading"

    /// The heading introducing the privacy, model, and correction statements.
    case informationAboutHeading = "information-about-heading"

    /// The notice a development build shows about its own unapproved inputs.
    ///
    /// Present in the shipping vocabulary so its wording is coverage-checked and auditable
    /// like every other string, and rendered only from a `#if DEBUG` seam in the application
    /// target. A Release build resolves it from nowhere because nothing in a Release build
    /// addresses it.
    ///
    /// It exists because a locally provisioned build supplies its own Calibration Policy, and
    /// a label produced through an unapproved boundary must not be shown as a verdict.
    case developmentBuildNotice = "development-build-notice"

    /// Stable key identifying this surface, namespaced so it cannot collide with a
    /// `VerdictCopySurface` key.
    public var description: String { "chrome/\(rawValue)" }

    /// The requirement this surface's wording serves, as a stable reference for an audit.
    public var gates: String {
        switch self {
        case .imageSelectionAction: "2.1, 3.13, 12.1"
        case .importInProgressStatus: "12.1, 12.5"
        case .analysisInProgressStatus: "12.1, 12.5, 15.1"
        case .cancellationAction: "12.1, 15.5"
        case .cancelledStatus: "11.17, 12.1"
        case .limitationsDisclosureAction: "8.10, 8.11, 12.1"
        case .disclosureExpandedState, .disclosureCollapsedState: "12.2, 12.7"
        case .informationAction, .informationTitle, .informationDismissAction: "12.1"
        case .informationLimitationsHeading, .informationAboutHeading: "12.1, 12.3"
        case .developmentBuildNotice: "8.4, 8.13"
        }
    }

    /// The String Catalog key this surface's approved English value lives under.
    ///
    /// The same convention `EnglishStringCatalog` applies to a verdict surface: `copy.`
    /// followed by the stable identifier with the surface separator flattened to a dot. Force
    /// unwrap is sound for the same reason it is there — the identifier is lowercase ASCII
    /// letters, digits, and hyphens, and dots are permitted in a canonical identifier, so no
    /// rejection condition can hold.
    public var localizationKey: ApprovedCopyKey {
        ApprovedCopyKey("copy." + description.replacingOccurrences(of: "/", with: "."))!
    }

    /// Every chrome key a build must carry an approved value for, in stable order.
    public static var requiredLocalizationKeys: [ApprovedCopyKey] {
        allCases.map(\.localizationKey).sorted { $0.rawValue < $1.rawValue }
    }
}

/// One resolved application-chrome copy address.
///
/// The chrome counterpart of `ResolvedCopyReference`, and deliberately smaller. It carries no
/// catalogue identifier and no compatibility identifier, because there is no artifact and no
/// Model Bundle to name: chrome copy is not session-bound, which is the whole reason this
/// vocabulary is separate.
///
/// Its initializer is public, unlike `ResolvedCopyReference`'s, and that is not a relaxation.
/// A `ResolvedCopyReference` is internal-only because a caller could otherwise fabricate one
/// for a surface the signed catalogue never approved. Here there is nothing to fabricate: the
/// surface vocabulary is closed, so a caller can only name a surface that exists, and the key
/// is derived from the surface rather than chosen, so a caller cannot point a surface at
/// someone else's string. Whether the key has an approved value is decided by
/// `ChromeCopyCoverage`, before anything renders.
public struct ChromeCopyReference: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The surface this copy is approved for.
    public let surface: ChromeCopySurface

    /// The stable String Catalog key the approved English value lives under.
    ///
    /// Derived, never stored, so a reference cannot address a key its surface does not own.
    public var localizationKey: ApprovedCopyKey { surface.localizationKey }

    public init(_ surface: ChromeCopySurface) {
        self.surface = surface
    }
}

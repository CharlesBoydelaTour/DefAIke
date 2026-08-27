import DefAIkeDomain

// The closed set of things this application exposes to assistive technology.
//
// An identity is not a label. It never reaches a user, it is never localized, and it carries
// no wording - it is the stable name a test, a focus tracker, and a release audit use to
// talk about one element across projections.
//
// Three jobs need exactly that, and none of them can be done with a `String` chosen at the
// call site:
//
//   * **Focus preservation (Requirement 12.6).** Keeping accessibility focus on the focused
//     element "while the focused element remains available" requires comparing the focused
//     element in the old screen against the elements of the new one. That comparison is an
//     identity comparison, so the identity has to outlive the projection it came from.
//   * **Reading and action order (Requirement 12.4).** The order is a sequence of
//     identities, so it can be asserted without reading any text and therefore without
//     depending on the displayed English.
//   * **Workflow operability (Requirements 12.11 and 12.12).** "Ingest, handoff consent,
//     analysis, cancellation, result review, limitation review, and retry can be completed"
//     is a statement about which elements a workflow needs. Naming them as values lets a
//     test check the set rather than driving a device to discover an omission.
//
// The vocabulary is closed, so a screen cannot invent an element the accessibility tests do
// not know about, and adding one is a visible change to this list.

/// One element this application exposes.
///
/// Two cases carry a parameter because the underlying vocabulary is itself closed and
/// enumerable: a technical-details row exists per bound component and per recorded
/// dimension, and collapsing them into one identity would make a missing row invisible.
public enum AccessibleElementIdentity: Hashable, Sendable, ProbabilityFreePresentationModel {

    // MARK: Ingest and recovery

    /// The control that selects an image, which is also the control every terminal screen
    /// offers to start a new Analysis Session.
    ///
    /// One identity for both, because ``SessionRecovery`` has one case: selecting another
    /// image *is* the recovery, and there is no separate resume, retry, or recompute action
    /// for a second identity to name.
    case imageSelectionControl

    // MARK: In-flight status

    /// Text stating that an ingest attempt is in flight.
    case importStatus

    /// The measured or continuing analysis-work progress field.
    case workProgress

    /// The control that cancels active analysis work.
    case cancellationControl

    // MARK: Terminal status

    /// Text stating that the session was cancelled.
    case cancelledStatus

    /// The Analysis Error message for the single failed category.
    case analysisErrorMessage

    /// The recovery action offered for the failed category.
    case analysisErrorRecovery

    // MARK: Evidence

    /// The pixel source lane's label: one of the three fixed display strings.
    case pixelEvidenceLabel

    /// The qualified explanation accompanying the pixel label.
    case pixelEvidenceExplanation

    /// The provenance source lane's state, including the unavailable state.
    case provenanceLaneState

    /// The explanation that screenshot creation can remove source Content Credentials.
    case screenshotProvenanceExplanation

    /// The Combined Summary, when an approved fusion rule produced one.
    case combinedSummary

    /// The notice that the two lanes appear inconsistent.
    case apparentInconsistencyNotice

    // MARK: Limitations

    /// The evidence-scope and unsupported-scope statement.
    case evidenceScopeLimitation

    /// The statement that false-positive and false-negative results can occur.
    case falseResultLimitation

    /// The limitation attached to the recorded Byte Preservation Status.
    case bytePreservationLimitation

    // MARK: Technical details

    /// The control that expands the optional technical-details group.
    case technicalDetailsDisclosure

    /// One bound component version row.
    case boundComponentVersion(DisclosedComponent)

    /// One recorded pre-orientation dimension row.
    case recordedDimension(PreOrientationDimension)

    /// The on-device-processing status row.
    case onDeviceProcessingStatus

    /// The verified Model Bundle integrity status row.
    case modelBundleIntegrityStatus

    // MARK: Onward paths

    /// The path to model identity, limitations, and release status.
    case modelInformationPath

    /// The path to the in-application privacy explanation.
    case privacyPath

    /// The path to the externally supplied correction channel.
    case correctionChannelPath

    /// Stable identifier, for deterministic ordering and failure reports.
    ///
    /// Derived from the case rather than from any displayed text, so it is unchanged by a
    /// copy edit, a translation, or a Localization Readiness Suite substitution.
    public var stableKey: String {
        switch self {
        case .imageSelectionControl: "image-selection-control"
        case .importStatus: "import-status"
        case .workProgress: "work-progress"
        case .cancellationControl: "cancellation-control"
        case .cancelledStatus: "cancelled-status"
        case .analysisErrorMessage: "analysis-error-message"
        case .analysisErrorRecovery: "analysis-error-recovery"
        case .pixelEvidenceLabel: "pixel-evidence-label"
        case .pixelEvidenceExplanation: "pixel-evidence-explanation"
        case .provenanceLaneState: "provenance-lane-state"
        case .screenshotProvenanceExplanation: "screenshot-provenance-explanation"
        case .combinedSummary: "combined-summary"
        case .apparentInconsistencyNotice: "apparent-inconsistency-notice"
        case .evidenceScopeLimitation: "evidence-scope-limitation"
        case .falseResultLimitation: "false-result-limitation"
        case .bytePreservationLimitation: "byte-preservation-limitation"
        case .technicalDetailsDisclosure: "technical-details-disclosure"
        case let .boundComponentVersion(component): "bound-component-version/\(component.rawValue)"
        case let .recordedDimension(dimension): "recorded-dimension/\(dimension.rawValue)"
        case .onDeviceProcessingStatus: "on-device-processing-status"
        case .modelBundleIntegrityStatus: "model-bundle-integrity-status"
        case .modelInformationPath: "model-information-path"
        case .privacyPath: "privacy-path"
        case .correctionChannelPath: "correction-channel-path"
        }
    }

    /// Every identity this application can expose, in a stable declaration order.
    ///
    /// Enumerated by hand because two cases carry a parameter, and expanded from the closed
    /// parameter vocabularies rather than from a second literal list - so adding a bound
    /// component or a recorded dimension extends this set without an edit here.
    public static var allIdentities: [AccessibleElementIdentity] {
        var identities: [AccessibleElementIdentity] = [
            .imageSelectionControl,
            .importStatus,
            .workProgress,
            .cancellationControl,
            .cancelledStatus,
            .analysisErrorMessage,
            .analysisErrorRecovery,
            .pixelEvidenceLabel,
            .pixelEvidenceExplanation,
            .provenanceLaneState,
            .screenshotProvenanceExplanation,
            .combinedSummary,
            .apparentInconsistencyNotice,
            .evidenceScopeLimitation,
            .falseResultLimitation,
            .bytePreservationLimitation,
            .technicalDetailsDisclosure,
        ]
        identities += DisclosedComponent.allCases.map(AccessibleElementIdentity.boundComponentVersion)
        identities += PreOrientationDimension.allCases.map(AccessibleElementIdentity.recordedDimension)
        identities += [
            .onDeviceProcessingStatus,
            .modelBundleIntegrityStatus,
            .modelInformationPath,
            .privacyPath,
            .correctionChannelPath,
        ]
        return identities
    }
}

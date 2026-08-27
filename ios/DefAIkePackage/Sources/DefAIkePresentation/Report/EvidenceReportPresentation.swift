import DefAIkeDomain

// One completed Evidence Report, assembled for display.
//
// This is the whole result surface as a single immutable value: both evidence cards, the
// apparent-inconsistency answer, the optional Combined Summary, the limitations, the
// transparency fields, and the paths onward to the model, privacy, and correction
// information. Assembling it is a pure function of one completed screen and that
// session's approved copy binding, so a result screen is reproducible from values and
// cannot be influenced by when it was built.
//
// The shape carries the requirements that are easiest to break by accident:
//
//   * ``cards`` is a pair of two non-optional cards, so both lanes are always present
//     and neither is ranked (Requirements 7.2, 7.3, and 7.8).
//   * ``combinedSummary`` is a sibling of ``cards``, never a replacement for it, and it
//     holds no lane value. A summary therefore cannot suppress or override either lane,
//     and every omission reason is written down rather than implied (Requirements 7.9
//     through 7.13, and 7.17).
//   * ``limitations`` and ``technicalDetails`` are non-optional, so no report can be
//     built without the scope, false-result, byte-status, dimension, on-device,
//     component-version, and integrity disclosures (Requirements 6.15, 8.10, 8.11,
//     8.12, and 10.18).
//   * ``disclosurePaths`` is non-optional and total over the six destinations
//     Requirement 8.17 names, so a path onward exists from every report.
//   * There is no member for a probability, confidence value or level, percentage,
//     score, raw model output, benchmark claim, history entry, saved copy, exported
//     document, pasteboard item, or share action (Requirements 8.13, 8.15, 8.16, 9.14,
//     and 9.15). See ``ExcludedResultControl``.
//
// Nothing here is `Codable`, and nothing here can be made `Codable` without adding a
// conformance on purpose. The domain's Evidence Report is deliberately not serializable
// because a report is displayed while its session is active and then discarded
// (Requirement 9.14); this value follows it, which is also why no save, export, or
// history affordance has anything to read.
//
// What this assembly refuses to do: invent a label, a definition, a heading, or a
// sentence for a surface the closed approved-copy vocabulary does not define. Those gaps
// are enumerated in ``UnapprovedReportSurface`` and render nothing.

/// A user-facing surface a completed report needs and the closed Approved Verdict Copy
/// vocabulary does not define.
///
/// Recorded rather than filled in, following the same rule as the view-state layer's
/// ``UnapprovedViewStateSurface``: the approved vocabulary is closed, no wording for
/// these exists anywhere in the repository, and inventing one - or rendering a
/// localization key - would put unapproved user-facing language on screen. So nothing is
/// rendered for them.
///
/// Enumerating the gaps as values means a release audit, and the later view and
/// accessibility tasks, can list what is still missing rather than discovering it at
/// render time. Closing a gap is a release-artifact change: extend the approved surface
/// vocabulary, approve the wording, add the String Catalog value. It is not a change to
/// this file.
public enum UnapprovedReportSurface: String, Hashable, Sendable, CaseIterable {
    /// A heading naming the pixel evidence card as the pixel source lane.
    case pixelCardHeading = "pixel-card-heading"

    /// A heading naming the provenance evidence card as the provenance source lane.
    case provenanceCardHeading = "provenance-card-heading"

    /// A heading identifying a fused output as a Combined Summary.
    case combinedSummaryHeading = "combined-summary-heading"

    /// A label for the Evidence Fusion Rule version shown with a Combined Summary.
    case fusionRuleVersionLabel = "fusion-rule-version-label"

    /// A label for the optional technical-details section itself.
    case technicalDetailsSectionLabel = "technical-details-section-label"

    /// Definitions for the bound component version identifiers.
    case boundComponentVersionDefinition = "bound-component-version-definition"

    /// Labels and definitions for the recorded pre-orientation dimensions.
    case recordedDimensionDefinition = "recorded-dimension-definition"

    /// A field label naming the Byte Preservation Status. The status's *limitation* has
    /// an approved surface; the field label does not.
    case bytePreservationStatusLabel = "byte-preservation-status-label"

    /// A field label naming the on-device-processing status.
    case onDeviceProcessingStatusLabel = "on-device-processing-status-label"

    /// A field label naming the Model Bundle integrity status.
    case modelBundleIntegrityStatusLabel = "model-bundle-integrity-status-label"

    /// The requirement this gap gates, as a stable reference.
    public var gates: String {
        switch self {
        case .pixelCardHeading: "7.2"
        case .provenanceCardHeading: "7.3"
        case .combinedSummaryHeading, .fusionRuleVersionLabel: "7.11"
        case .technicalDetailsSectionLabel, .boundComponentVersionDefinition,
            .recordedDimensionDefinition:
            "8.14"
        case .bytePreservationStatusLabel, .onDeviceProcessingStatusLabel,
            .modelBundleIntegrityStatusLabel:
            "8.12, 8.14"
        }
    }
}

/// A measured input a completed report could narrow a required explanation with, and
/// that nothing in this application records.
///
/// Distinct from ``UnapprovedReportSurface``: the copy for these exists and is used. What
/// is missing is a *fact*, so the requirement is satisfied for a superset of the cases it
/// names rather than for exactly those cases.
public enum UnavailableEvidenceInput: String, Hashable, Sendable, CaseIterable {
    /// Whether the analyzed image is a screenshot.
    ///
    /// Ingest deliberately classifies nothing about an item's origin, the Input Quality
    /// Record has no release-validated feature for it, and the Evidence Report carries no
    /// such field. Requirement 6.16's approved explanation is therefore shown for every
    /// enabled `absent` result rather than only for screenshots. Supplying this input
    /// would narrow the explanation; it is not needed to satisfy the requirement.
    case screenshotOriginDetermination = "screenshot-origin-determination"

    /// The requirement this input would narrow.
    public var narrows: String {
        switch self {
        case .screenshotOriginDetermination: "6.16"
        }
    }
}

/// Why a completed report shows no Combined Summary.
///
/// Written down rather than left as an absent value. Requirement 7.12 requires an
/// approved fusion rule to define exactly one deterministic behaviour, *including
/// explicit omission*, for each of the fifteen lane combinations, so an omission is a
/// decision the release made and this reports which one.
public enum FusionOmissionReason: String, Hashable, Sendable, CaseIterable {
    /// The provenance source lane is unavailable, which is outside the fifteen
    /// combinations entirely and always omits fusion (Requirement 7.10).
    case provenanceLaneUnavailable = "provenance-lane-unavailable"

    /// Both lanes are available and no approved, fixture-tested rule produced a summary
    /// for this combination - either because the release binds no rule at all
    /// (Requirements 7.9 and 7.16) or because the bound rule's entry for this
    /// combination is an explicit omission (Requirement 7.12).
    case noApprovedSummaryForThisCombination = "no-approved-summary-for-this-combination"
}

/// The Combined Summary section of a completed report.
///
/// Two cases, and the shown case holds only the resolved summary. It carries no lane
/// value, no ranking, and no override flag, so a summary sits beside both cards and
/// cannot stand in for either (Requirements 7.11, 7.13, and 7.17). The rule version
/// travels inside the summary presentation, because a displayed summary has to name the
/// rule that produced it.
public enum CombinedSummarySection: Hashable, Sendable {
    /// No summary. The reason is recorded rather than inferred.
    case omitted(FusionOmissionReason)

    /// An approved fusion rule produced this summary.
    case shown(CombinedSummaryPresentation)

    /// The resolved summary, or `nil` when omitted.
    public var summary: CombinedSummaryPresentation? {
        switch self {
        case .omitted: nil
        case let .shown(summary): summary
        }
    }

    /// The Evidence Fusion Rule version behind a shown summary, or `nil` when omitted
    /// (Requirement 7.11).
    public var fusionRuleID: ArtifactID? { summary?.fusionRuleID }
}

/// One onward path a completed report offers (Requirement 8.17).
public enum ReportDisclosurePath: String, Hashable, Sendable, CaseIterable {
    /// Model identity, measured limitations, and release status.
    case modelInformation = "model-information"
    /// The in-application privacy explanation.
    case privacyBehavior = "privacy-behavior"
    /// The externally supplied correction channel.
    case correctionChannel = "correction-channel"
}

/// One destination Requirement 8.17 requires a path to from every Evidence Report.
///
/// Six destinations reached by three paths. Both directions are total: every destination
/// names the path that reaches it through a compiler-checked switch, and every path is a
/// non-optional member of ``ReportDisclosurePaths``. That is what makes "a user-accessible
/// path from every Evidence Report" structural rather than a navigation convention.
///
/// The destination screens themselves are separate work. What is fixed here is that the
/// report offers the way in.
public enum RequiredDisclosureDestination: String, Hashable, Sendable, CaseIterable {
    case selectedModelIdentity = "selected-model-identity"
    case measuredLimitations = "measured-limitations"
    case independentNonPeerReviewedReleaseStatus = "independent-non-peer-reviewed-release-status"
    case invalidInheritedRedTeamStatus = "invalid-inherited-red-team-status"
    case privacyBehavior = "privacy-behavior"
    case correctionChannel = "correction-channel"

    /// The path that reaches this destination.
    public var path: ReportDisclosurePath {
        switch self {
        case .selectedModelIdentity, .measuredLimitations,
            .independentNonPeerReviewedReleaseStatus, .invalidInheritedRedTeamStatus:
            .modelInformation
        case .privacyBehavior: .privacyBehavior
        case .correctionChannel: .correctionChannel
        }
    }
}

/// The onward paths every completed report offers (Requirement 8.17).
///
/// Three non-optional approved references. There is no conditional path, no disabled
/// path, and no path that exists only for some reports.
public struct ReportDisclosurePaths: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let modelInformation: ResolvedCopyReference
    public let privacyBehavior: ResolvedCopyReference
    public let correctionChannel: ResolvedCopyReference

    /// The approved reference for one path. Total, with no `default`.
    public func reference(for path: ReportDisclosurePath) -> ResolvedCopyReference {
        switch path {
        case .modelInformation: modelInformation
        case .privacyBehavior: privacyBehavior
        case .correctionChannel: correctionChannel
        }
    }

    /// The approved reference for the path that reaches one required destination.
    public func reference(
        reaching destination: RequiredDisclosureDestination
    ) -> ResolvedCopyReference {
        reference(for: destination.path)
    }

    init(
        modelInformation: ResolvedCopyReference,
        privacyBehavior: ResolvedCopyReference,
        correctionChannel: ResolvedCopyReference
    ) {
        self.modelInformation = modelInformation
        self.privacyBehavior = privacyBehavior
        self.correctionChannel = correctionChannel
    }

    static func assembling(
        copy: ApprovedCopyBinding
    ) throws(PresentationCopyError) -> ReportDisclosurePaths {
        ReportDisclosurePaths(
            modelInformation: try copy.reference(for: .modelInformation),
            privacyBehavior: try copy.reference(for: .privacyExplanation),
            correctionChannel: try copy.reference(for: .correctionChannel)
        )
    }
}

/// Why a completed screen could not be assembled into a result presentation.
///
/// No `unknown` case and no case that carries substitute content. An unassemblable
/// screen yields no presentation rather than a partial one.
public enum EvidenceReportAssemblyError: Error, Hashable, Sendable {
    /// The supplied approved copy binding belongs to a different session than the
    /// screen.
    ///
    /// Refused rather than used. Copy is bound per session because the Model Bundle is,
    /// so rendering one session's report through another session's binding would show
    /// copy checked against a bundle this session never ran under.
    case copyBindingSessionMismatch(screen: AnalysisSessionID, binding: AnalysisSessionID)

    /// Approved copy for a required surface could not be resolved. Wraps the copy
    /// layer's own refusal unchanged.
    case copy(PresentationCopyError)
}

/// One completed Evidence Report, ready to render.
public struct EvidenceReportPresentation: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Every affordance this surface does not have.
    ///
    /// A declaration for a release audit to enumerate, not a switch. The enforcement is
    /// that no member exists for any of them (Requirements 8.13, 8.15, and 9.15).
    public static let excludedControls = Set(ExcludedResultControl.allCases)

    /// Surfaces this presentation needs and the approved vocabulary does not define.
    /// Nothing is rendered for them.
    public static let unapprovedSurfaces = Set(UnapprovedReportSurface.allCases)

    /// The attempt that produced this report.
    public let identity: SessionAttemptIdentity

    /// Both evidence cards. Always two, never ranked.
    public let cards: EvidenceCardPair

    /// Whether the report declared an apparent inconsistency between the lanes.
    public let apparentInconsistency: ApparentInconsistencyNotice

    /// The Combined Summary, or the recorded reason there is none.
    public let combinedSummary: CombinedSummarySection

    /// The limitations every report states.
    public let limitations: EvidenceLimitations

    /// The transparency fields every report exposes.
    public let technicalDetails: EvidenceTechnicalDetails

    /// The onward paths every report offers.
    public let disclosurePaths: ReportDisclosurePaths

    /// What this screen offers next. Always a new session from a new selection.
    public let recovery: SessionRecovery

    init(
        identity: SessionAttemptIdentity,
        cards: EvidenceCardPair,
        apparentInconsistency: ApparentInconsistencyNotice,
        combinedSummary: CombinedSummarySection,
        limitations: EvidenceLimitations,
        technicalDetails: EvidenceTechnicalDetails,
        disclosurePaths: ReportDisclosurePaths,
        recovery: SessionRecovery
    ) {
        self.identity = identity
        self.cards = cards
        self.apparentInconsistency = apparentInconsistency
        self.combinedSummary = combinedSummary
        self.limitations = limitations
        self.technicalDetails = technicalDetails
        self.disclosurePaths = disclosurePaths
        self.recovery = recovery
    }
}

// MARK: - Assembly

extension EvidenceReportPresentation {
    /// Assembles one completed screen into a result presentation.
    ///
    /// Pure and total over a completed screen: every screen yields either a full
    /// presentation or one stated refusal. There is no branch that produces a
    /// presentation with one card, without limitations, or without transparency fields,
    /// because those members have no absent value to produce.
    ///
    /// `copy` is the same session-bound binding the screen was projected through. It is
    /// supplied rather than read from the screen because the completed screen carries the
    /// resolved lanes rather than the binding, and it is checked against the screen's own
    /// session before anything is resolved.
    public static func assembling(
        _ screen: CompletedScreen,
        copy: ApprovedCopyBinding
    ) throws(EvidenceReportAssemblyError) -> EvidenceReportPresentation {
        guard copy.sessionID == screen.identity.sessionID else {
            throw .copyBindingSessionMismatch(
                screen: screen.identity.sessionID,
                binding: copy.sessionID
            )
        }

        let report = screen.report
        do {
            return EvidenceReportPresentation(
                identity: screen.identity,
                cards: try EvidenceCardPair.assembling(
                    pixel: screen.pixel,
                    provenance: screen.provenance,
                    copy: copy
                ),
                apparentInconsistency: screen.apparentInconsistency
                    .map(ApparentInconsistencyNotice.declared) ?? .none,
                combinedSummary: summarySection(for: screen),
                limitations: try EvidenceLimitations.assembling(
                    scope: report.scope,
                    bytePreservationStatus: report.bytePreservationStatus,
                    copy: copy
                ),
                technicalDetails: EvidenceTechnicalDetails(report: report),
                disclosurePaths: try ReportDisclosurePaths.assembling(copy: copy),
                recovery: screen.recovery
            )
        } catch {
            throw .copy(error)
        }
    }

    /// The summary section for one completed screen.
    ///
    /// Total, and the omission reason comes from the report's own provenance lane rather
    /// than from a guess: an unavailable lane is outside the fifteen combinations and
    /// always omits fusion, and anything else is a rule that produced no summary for
    /// this combination.
    private static func summarySection(for screen: CompletedScreen) -> CombinedSummarySection {
        if let summary = screen.combinedSummary {
            return .shown(summary)
        }
        return .omitted(
            screen.report.provenance.isAvailable
                ? .noApprovedSummaryForThisCombination
                : .provenanceLaneUnavailable
        )
    }
}

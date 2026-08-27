import DefAIkeDomain

// The copy gaps the four disclosure destinations are blocked on.
//
// The rule this file follows is the one tasks 11.2, 11.3, and 11.4 already established: a
// user-facing surface the closed Approved Verdict Copy vocabulary does not define is
// *recorded*, never filled in. The closed vocabulary has exactly three entries for these
// four destinations - the privacy explanation, the model-information statement, and the
// correction channel - plus the evidence-scope statement, the false-result statement, and
// one explanation per pixel label. Those six are resolved and rendered.
//
// Everything else these destinations need is a sentence nobody has approved. Writing one
// here would put unapproved user-facing language on screen under a heading that claims it
// is the project's privacy behaviour, its model's release status, or its correction
// channel, which is worse than an absence a release audit can read back. So the gaps are
// enumerated as values and nothing is rendered for them.
//
// Two of these are not copy at all but externally supplied *content*, and they are the two
// that most obviously must never be invented:
//
//   * ``correctionChannelAddress`` - Requirement 14.14's user-accessible correction
//     channel. The release-readiness record identifies the artifact that carries it; the
//     artifact's contents are outside this repository. A hard-coded address would be a
//     promise the project has not made.
//   * ``cleanupDeadlineDurationUnit`` - the wording that turns Requirement 9.7's supplied
//     numeric deadlines into a sentence. The numbers themselves arrive from the signed
//     Data Lifecycle Policy and are carried through unchanged; what is missing is the unit
//     wording, so a screen cannot say "removed within N minutes" without inventing both
//     the unit and the sentence around it.
//
// Every raw value here is disjoint from the three vocabularies that came before, checked
// by a test rather than by inspection. Where a surface genuinely is one already recorded,
// the existing entry is reused instead of a new one being added - which is why there is no
// entry here for a byte-status label, a dimension unit, or a technical-details heading.
//
// Closing a gap is a release-artifact change: extend the approved surface vocabulary,
// approve the wording, add the String Catalog value. It is not a change to this file.

/// A user-facing surface one of the four disclosure destinations needs and the closed
/// Approved Verdict Copy vocabulary does not define.
public enum UnapprovedDisclosureSurface: String, Hashable, Sendable, CaseIterable {

    // MARK: - Privacy (Requirement 9.16)

    /// A label naming one of the eight topics the privacy explanation covers.
    ///
    /// The explanation itself has one approved surface, which is resolved and shown. What
    /// has no wording is the per-topic label that would let a reader find the local
    /// inference, provenance, permission, retention, telemetry, bundled-model, deadline,
    /// and deletion topics individually.
    case privacyTopicLabel = "privacy-topic-label"

    /// Wording stating whether local Content Credential validation is part of this
    /// release.
    ///
    /// Both answers need wording and neither has any. This is deliberately one surface
    /// rather than two: the requirement is that the explanation cover provenance
    /// validation *conditionally*, so a pixel-only build has to say something true about a
    /// capability it does not have, and a provenance-enabled build has to say something
    /// true about one it does. Neither sentence exists.
    case localProvenanceAvailabilityStatement = "local-provenance-availability-statement"

    /// Wording naming the unit of a supplied cleanup deadline.
    ///
    /// The deadline values come from the signed Data Lifecycle Policy and are carried
    /// unchanged. Rendering one as a sentence needs a unit and a frame the approved
    /// vocabulary does not supply, and neither may be chosen here.
    case cleanupDeadlineDurationUnit = "cleanup-deadline-duration-unit"

    /// Wording naming one data practice this release does not perform.
    ///
    /// Requirement 9.16 requires the explanation to cover the absence of telemetry, and
    /// Requirements 9.10 through 9.13 name five distinct practices. The absences are
    /// facts this module states structurally; their names are wording it does not have.
    case absentDataPracticeLabel = "absent-data-practice-label"

    // MARK: - Funding and access (Requirements 1.6 through 1.9)

    /// Wording identifying the project as nonprofit and free, with analysis that needs no
    /// account, shows no advertising, and sits outside a subscription.
    ///
    /// The single most consequential gap in this task. Requirement 1.9 requires the
    /// application to *identify* the project this way, which is a sentence and nothing
    /// else: the facts are true of the build by construction, but a user learns them only
    /// by reading them. No approved surface addresses them, so the statement is recorded
    /// and Requirement 1.9 stays blocked on approved copy.
    case projectFundingStatement = "project-funding-statement"

    // MARK: - Model information (Requirements 8.17 and 14.9)

    /// A field label for the bound model's checkpoint identifier and required weight
    /// digest.
    ///
    /// Distinct from the report layer's bound-component definition, which covers the six
    /// version identifiers a completed report discloses. This one is the model's own
    /// identity, which Requirement 8.17 names separately.
    case modelIdentityFieldLabel = "model-identity-field-label"

    /// Wording stating that the selected checkpoint is an independent, non-peer-reviewed
    /// fine-tune (Requirement 14.9).
    case independentReleaseStatusStatement = "independent-release-status-statement"

    /// Wording stating that no valid inherited red-team report exists for the selected
    /// checkpoint (Requirement 14.9).
    ///
    /// Recorded separately from the independent-release-status statement because the two
    /// are separate disclosures about separate facts, and because a single merged sentence
    /// is exactly the kind of wording decision this layer must not make.
    case inheritedRedTeamStatusStatement = "inherited-red-team-status-statement"

    /// A label for the versioned active known limitations reference (Requirement 14.14).
    case activeLimitationsReferenceLabel = "active-limitations-reference-label"

    // MARK: - Scope and limitations (Requirements 1.10 and 1.15)

    /// Wording naming one unsupported Version 1 scope individually.
    ///
    /// The approved evidence-scope statement is resolved and shown, and the structured
    /// covered and uncovered scope sets travel beside it. What has no wording is the
    /// per-item label, which is what would let the screen name each unsupported scope as
    /// its own line rather than only inside one approved paragraph.
    case unsupportedScopeItemLabel = "unsupported-scope-item-label"

    /// Wording stating that pixel evidence is probabilistic and establishes none of
    /// authenticity, authorship, intent, editing history, or the absence of localized
    /// editing (Requirement 1.15).
    ///
    /// Partially covered and therefore recorded. The three approved pixel explanations
    /// already carry the probabilistic framing and the "not proof of authenticity" framing
    /// that Requirements 8.3 through 8.5 fix, and the approved scope statement carries the
    /// localized-edit exclusion. Nothing in the closed vocabulary addresses authorship,
    /// intent, or editing history as a statement of what the evidence does not establish,
    /// so the full sentence Requirement 1.15 asks for cannot be assembled from approved
    /// parts - and assembling it from parts would be the concatenation the design forbids
    /// even if the parts existed.
    case pixelEvidenceNonEstablishmentStatement = "pixel-evidence-non-establishment-statement"

    // MARK: - Correction channel (Requirement 14.14)

    /// The correction channel's own user-accessible address.
    ///
    /// Not wording and not a gap this module could close by approving a sentence: it is
    /// external content. The release-readiness record identifies the artifact that
    /// carries the channel, and this module resolves and shows the approved statement that
    /// introduces it, but the address itself lives outside the repository. There is no
    /// placeholder, no example address, and no default.
    case correctionChannelAddress = "correction-channel-address"

    /// The requirements this gap gates, as a stable reference.
    ///
    /// Total switch, no `default`, so a new gap has to say what it blocks.
    public var gates: String {
        switch self {
        case .privacyTopicLabel, .localProvenanceAvailabilityStatement,
            .cleanupDeadlineDurationUnit, .absentDataPracticeLabel:
            "9.16"
        case .projectFundingStatement: "1.6, 1.7, 1.8, 1.9"
        case .modelIdentityFieldLabel: "8.17"
        case .independentReleaseStatusStatement, .inheritedRedTeamStatusStatement: "14.9"
        case .activeLimitationsReferenceLabel, .correctionChannelAddress: "14.14"
        case .unsupportedScopeItemLabel: "1.10"
        case .pixelEvidenceNonEstablishmentStatement: "1.15"
        }
    }

    /// Whether closing this gap needs approved wording rather than external content.
    ///
    /// Both kinds are blocked, and the distinction is who unblocks them: an approved-copy
    /// decision for wording, and the release artifact that carries the channel for the
    /// address. Stated so a release audit can route each gap to its owner.
    public var isApprovedCopyDecision: Bool {
        switch self {
        case .correctionChannelAddress: false
        case .privacyTopicLabel, .localProvenanceAvailabilityStatement,
            .cleanupDeadlineDurationUnit, .absentDataPracticeLabel, .projectFundingStatement,
            .modelIdentityFieldLabel, .independentReleaseStatusStatement,
            .inheritedRedTeamStatusStatement, .activeLimitationsReferenceLabel,
            .unsupportedScopeItemLabel, .pixelEvidenceNonEstablishmentStatement:
            true
        }
    }
}

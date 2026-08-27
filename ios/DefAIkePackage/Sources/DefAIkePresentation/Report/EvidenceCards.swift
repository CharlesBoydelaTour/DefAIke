import DefAIkeDomain

// The two evidence cards, and why there are always exactly two of them.
//
// Requirements 7.2 and 7.3 each require an independently visible card - one for the
// pixel source lane, one for the provenance source lane - in *every* completed
// Evidence Report. Requirement 7.8 adds that an apparent contradiction between them
// preserves both results without suppressing, overriding, or ranking either.
//
// Those three sentences are trivially satisfiable by a correct `if` and trivially
// broken by an incorrect one. `[card]`, `cards.first`, `card ?? other`,
// `if provenanceEnabled { ... }`, and a sort by "strength" are each one line and each
// violates a requirement. So the pair is not a collection and not an optional:
//
//   * ``EvidenceCardPair`` has exactly two non-optional stored properties of two
//     different types. There is no count to be one, no index to be out of range, no
//     `nil` to coalesce, and no order to sort. "Both cards, always" is what the type
//     *is*.
//   * Neither card type can hold the other lane's value. ``PixelEvidenceCard`` has no
//     provenance member and ``ProvenanceEvidenceCard`` has no pixel member, so one
//     lane cannot overwrite, annotate, or qualify the other here any more than it can
//     in the domain.
//   * No card, and no pair, carries a rank, priority, weight, order, primary flag, or
//     confidence. There is no field for "which lane won", so ranking is not a
//     behaviour to avoid.
//   * The apparent-inconsistency notice lives beside the pair rather than inside
//     either card, so identifying a contradiction cannot become a property of one lane
//     (see ``ApparentInconsistencyNotice``).
//
// The unavailable provenance lane is a card like any other. It is not a hidden card, a
// collapsed card, or an absent card: Requirement 6.5 requires the installed release to
// explain that Content Credential validation is unavailable, and Requirement 8.8
// requires that state to be described as unavailable rather than absent, invalid, or
// authentic. Both hold because ``ProvenanceEvidenceCard`` is non-optional and its
// state comes from ``ProvenanceLanePresentation``, whose unavailable case is outside
// the five-state vocabulary entirely.

/// The pixel source lane as one independently visible card (Requirement 7.2).
///
/// Carries the resolved lane presentation and nothing else. In particular it carries
/// no provenance value, no summary, no magnitude, and no raw model output: the label
/// is one of exactly three fixed qualified strings, and its accompanying explanation
/// is approved copy addressed by key.
public struct PixelEvidenceCard: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The pixel lane, resolved against the session's approved copy.
    public let lane: PixelLabelPresentation

    /// The exact required display string for this label (Requirement 8.2).
    ///
    /// Restated on the card because the card is what a view reads. It is the same
    /// value the lane presentation carries, so the two cannot disagree.
    public var fixedLabelText: FixedPixelLabelText { lane.fixedLabelText }

    /// The calibrated outcome this card shows.
    public var evidence: PixelEvidence { lane.evidence }

    init(lane: PixelLabelPresentation) {
        self.lane = lane
    }
}

/// Whether this provenance lane state reports a cryptographically validated claim
/// binding.
///
/// Requirement 6.17 constrains the approved wording for the validated state: it states
/// that cryptographic validation establishes claim binding and does *not* establish
/// the factual truth of every signed assertion. That is a constraint on the wording
/// behind the ``VerdictCopySurface/provenanceState`` surface for `validated`, and the
/// wording is approved outside this code.
///
/// This type exists so the requirement is visible and auditable at the card rather
/// than implicit in a string nobody here can read. It resolves to the same approved
/// reference the card's state copy carries, which is deliberate: two references would
/// be two chances for a binding statement and a state description to disagree, and
/// there is no second approved surface to address anyway.
public enum ClaimBindingDisclosure: Hashable, Sendable {
    /// The lane reports a validated claim, and this is the approved statement about
    /// what that validation does and does not establish (Requirement 6.17).
    case validatedClaimBinding(ResolvedCopyReference)

    /// The lane reports no validated claim, so no binding statement applies. This is
    /// every unavailable lane and every enabled state other than validated.
    case notApplicable
}

/// Whether the screenshot Content Credential explanation applies to this lane state.
///
/// Requirement 6.16 requires the Result Presenter, in a provenance-enabled release, to
/// explain that screenshot creation can remove source Content Credentials when a
/// screenshot carries no Content Credential. The approved surface for that explanation
/// exists (``VerdictCopySurface/screenshotProvenanceExplanation``).
///
/// What does not exist is any input that establishes whether the analyzed image is a
/// screenshot. Ingest deliberately classifies nothing about an item's origin, the
/// Input Quality Record has no release-validated feature for it, and the Evidence
/// Report carries no such fact. See ``UnavailableEvidenceInput``.
///
/// So the explanation is attached to *every* enabled `absent` result rather than to the
/// narrower set the requirement names. That direction is deliberate: the requirement is
/// satisfied for every case it covers, the copy is approved and describes a mechanism
/// that is true regardless of the image, and the alternative - withholding required
/// copy because a narrowing input is missing - would fail Requirement 6.16 outright.
/// Narrowing it later needs the missing input, not new wording.
public enum ScreenshotProvenanceDisclosure: Hashable, Sendable {
    /// An enabled validator found no Content Credential, so the approved explanation
    /// that screenshot creation can remove source Content Credentials is shown
    /// (Requirement 6.16).
    case shownForAbsentCredential(ResolvedCopyReference)

    /// The explanation does not apply: either this release has no validator at all, or
    /// the validator reported a state other than absent.
    case notApplicable
}

/// How this provenance lane state must be told apart from the others.
///
/// Requirement 6.21 requires the indeterminate state to be identified as an
/// enabled-validator processing result *distinct from* the unavailable state, and
/// Requirement 8.8 requires the unavailable state to be described as unavailable
/// rather than absent, invalid, or authentic.
///
/// Both hold structurally: `unavailable` and the five enabled states live in different
/// cases of ``ProvenanceLanePresentationState``, so no code path can reach one while
/// describing the other. This projection names the distinction so a card, an
/// accessibility layer, or a test can assert it directly instead of re-deriving it.
public enum ProvenanceLaneDistinction: String, Hashable, Sendable, CaseIterable {
    /// This installed release cannot validate Content Credentials at all. A fact about
    /// the release, never a finding about the image (Requirements 6.5 and 8.8).
    case releaseCannotValidate = "release-cannot-validate"

    /// An enabled validator produced a conclusive result for the inspected bytes.
    case enabledValidatorResult = "enabled-validator-result"

    /// An enabled validator ran and could not conclude. Distinct from
    /// ``releaseCannotValidate`` (Requirement 6.21).
    case enabledValidatorInconclusive = "enabled-validator-inconclusive"
}

/// The provenance source lane as one independently visible card (Requirement 7.3).
///
/// Present for every completed report, including when the lane is unavailable. Carries
/// no pixel value, so it cannot qualify or be qualified by the pixel lane.
public struct ProvenanceEvidenceCard: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The provenance lane, resolved against the session's approved copy. For a
    /// pixel-only release this is the unavailable state and its approved explanation
    /// (Requirement 6.5).
    public let lane: ProvenanceLanePresentation

    /// Which of the three distinctions this state falls under.
    public let distinction: ProvenanceLaneDistinction

    /// The approved binding statement for a validated claim, or that none applies
    /// (Requirement 6.17).
    public let claimBinding: ClaimBindingDisclosure

    /// The approved screenshot explanation, or that none applies (Requirement 6.16).
    public let screenshotExplanation: ScreenshotProvenanceDisclosure

    /// The lane state this card shows.
    public var state: ProvenanceLanePresentationState { lane.state }

    init(
        lane: ProvenanceLanePresentation,
        distinction: ProvenanceLaneDistinction,
        claimBinding: ClaimBindingDisclosure,
        screenshotExplanation: ScreenshotProvenanceDisclosure
    ) {
        self.lane = lane
        self.distinction = distinction
        self.claimBinding = claimBinding
        self.screenshotExplanation = screenshotExplanation
    }
}

/// Both evidence cards, always.
///
/// Two non-optional members of two different types. Neither can be omitted, neither
/// can be reached through the other, and there is no ordering, ranking, or count for a
/// bug to change (Requirements 7.2, 7.3, and 7.8).
public struct EvidenceCardPair: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The pixel source lane's card.
    public let pixel: PixelEvidenceCard

    /// The provenance source lane's card.
    public let provenance: ProvenanceEvidenceCard

    init(pixel: PixelEvidenceCard, provenance: ProvenanceEvidenceCard) {
        self.pixel = pixel
        self.provenance = provenance
    }
}

// MARK: - Assembly

extension EvidenceCardPair {
    /// Builds both cards from one completed screen's already-resolved lanes.
    ///
    /// The lanes arrive resolved, so this adds no copy decision for either label or
    /// state; what it resolves is the two conditional provenance explanations, and only
    /// from surfaces the binding already covers. It cannot fail for a pixel reason,
    /// because the pixel card is the resolved lane unchanged.
    static func assembling(
        pixel: PixelLabelPresentation,
        provenance: ProvenanceLanePresentation,
        copy: ApprovedCopyBinding
    ) throws(PresentationCopyError) -> EvidenceCardPair {
        EvidenceCardPair(
            pixel: PixelEvidenceCard(lane: pixel),
            provenance: try ProvenanceEvidenceCard.assembling(lane: provenance, copy: copy)
        )
    }
}

extension ProvenanceEvidenceCard {
    /// Builds the provenance card, resolving the two conditional explanations.
    ///
    /// Total over ``ProvenanceLanePresentationState``: every state yields a card, and
    /// each of the two explanations is either an approved reference or an explicit
    /// statement that it does not apply. Neither is an optional a caller could ignore.
    static func assembling(
        lane: ProvenanceLanePresentation,
        copy: ApprovedCopyBinding
    ) throws(PresentationCopyError) -> ProvenanceEvidenceCard {
        switch lane.state {
        case .unavailable:
            // No validator ran, so neither a binding statement nor a screenshot
            // explanation has a subject. The lane's own state copy is the required
            // unavailable explanation (Requirements 6.5 and 8.8).
            return ProvenanceEvidenceCard(
                lane: lane,
                distinction: .releaseCannotValidate,
                claimBinding: .notApplicable,
                screenshotExplanation: .notApplicable
            )

        case let .available(category):
            let binding: ClaimBindingDisclosure =
                switch category {
                case .validated: .validatedClaimBinding(lane.stateCopy)
                case .invalid, .absent, .unsupported, .indeterminate: .notApplicable
                }

            let screenshot: ScreenshotProvenanceDisclosure =
                switch category {
                case .absent:
                    .shownForAbsentCredential(
                        try copy.reference(for: .screenshotProvenanceExplanation)
                    )
                case .validated, .invalid, .unsupported, .indeterminate:
                    .notApplicable
                }

            return ProvenanceEvidenceCard(
                lane: lane,
                distinction: category == .indeterminate
                    ? .enabledValidatorInconclusive
                    : .enabledValidatorResult,
                claimBinding: binding,
                screenshotExplanation: screenshot
            )
        }
    }
}

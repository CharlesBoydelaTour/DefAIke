import DefAIkeDomain

// The copy-addressed presentation models for the two source lanes, the optional
// Combined Summary, and one Analysis Error.
//
// These are the per-state models: exactly one lane state, one summary, or one error,
// each paired with the approved copy that describes it. Composing them into screens
// is separate work - spec task 11.2 projects coordinator snapshots into mutually
// exclusive screen families, and task 11.3 assembles the evidence cards, limitations,
// and technical details.
//
// Every model here is probability-free by shape, not by convention. None carries a
// `Double`, a percentage, a level, a score, or a raw logit, and none carries a
// `String` a component could write a claim into: user-facing wording arrives only as
// a ``ResolvedCopyReference``. See ``ProhibitedPresentationClaim``.
//
// The models also keep the lanes separate. A pixel presentation cannot hold a
// provenance value and a provenance presentation cannot hold a pixel value, so
// neither lane can suppress, override, or rank the other in the presentation layer
// any more than it can in the domain (Requirements 7.1 and 7.8).
//
// Each model's memberwise initializer stays internal on purpose. Outside this module
// the only way to obtain one is to resolve it through ``ApprovedCopyBinding``, so a
// view cannot assemble a result card from values it chose itself and bypass the
// compatibility and coverage checks.

/// The pixel source lane, ready to render.
public struct PixelLabelPresentation: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The calibrated outcome. Exactly one of three, with no fourth state and no
    /// numeric companion.
    public let evidence: PixelEvidence

    /// The exact required display string for this label (Requirement 8.2).
    ///
    /// Held alongside the copy reference rather than instead of it: the reference
    /// addresses the String Catalog entry, and this value is what that entry has to
    /// render as. ``FixedPixelLabelText/validate(rendered:for:)`` is the check.
    public let fixedLabelText: FixedPixelLabelText

    /// Approved copy for the label itself.
    public let labelCopy: ResolvedCopyReference

    /// Approved copy for the qualified explanation that accompanies the label -
    /// probabilistic consistency, no strong signal, or a lack of usable signal
    /// (Requirements 8.3, 8.4, and 8.5).
    public let explanationCopy: ResolvedCopyReference
}

/// Which provenance lane state a presentation describes.
///
/// `unavailable` is a separate case rather than a sixth category, because the
/// unavailable lane is a fact about the installed release and never a finding about
/// the image. Keeping it outside ``ProvenanceCategory`` is what makes "describe the
/// lane as unavailable rather than absent, invalid, or authentic" unrepresentable to
/// get wrong (Requirement 8.8).
public enum ProvenanceLanePresentationState: Hashable, Sendable {
    /// This release cannot validate Content Credentials at all.
    case unavailable(UnavailableReason)
    /// An enabled validator produced one of five results.
    case available(ProvenanceCategory)
}

/// The provenance source lane, ready to render.
public struct ProvenanceLanePresentation: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let state: ProvenanceLanePresentationState

    /// Approved copy for this state. For a validated claim it describes a
    /// cryptographically validated binding rather than factual truth; for an absent
    /// credential it describes no provenance evidence found rather than authenticity
    /// evidence (Requirements 8.6 and 8.7).
    public let stateCopy: ResolvedCopyReference
}

/// An optional fused interpretation of both lanes, ready to render.
///
/// Exists only when an approved deterministic fusion rule produced one. The rule
/// version travels with it because a displayed summary has to name the rule that
/// produced it (Requirement 7.11).
public struct CombinedSummaryPresentation: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let summaryCopy: ResolvedCopyReference

    /// The Evidence Fusion Rule version that produced this summary.
    public let fusionRuleID: ArtifactID
}

/// One Analysis Error, ready to render.
///
/// Carries no evidence field, mirroring the domain's failure snapshot: a failed
/// session has no partial verdict to show (Requirement 11.18). It also carries no
/// framework error, path, or user filename - only the category and its approved copy.
public struct AnalysisErrorPresentation: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let error: AnalysisError

    /// Approved copy describing what happened.
    public let messageCopy: ResolvedCopyReference

    /// Approved copy for the recovery this category offers.
    public let recoveryCopy: ResolvedCopyReference
}

// MARK: - Resolution

extension ApprovedCopyBinding {
    /// Resolves the pixel source lane.
    public func presentation(
        forPixel evidence: PixelEvidence
    ) throws(PresentationCopyError) -> PixelLabelPresentation {
        let label = evidence.labelKey
        return PixelLabelPresentation(
            evidence: evidence,
            fixedLabelText: FixedPixelLabelText(label: label),
            labelCopy: try reference(for: .pixelLabel(label)),
            explanationCopy: try reference(for: .pixelExplanation(label))
        )
    }

    /// Resolves the provenance source lane, including the unavailable state.
    ///
    /// In a pixel-only composition the enabled-state surfaces are unreachable, so a
    /// lane that somehow reported an enabled state there is refused rather than
    /// rendered.
    public func presentation(
        forProvenance lane: ProvenanceLane
    ) throws(PresentationCopyError) -> ProvenanceLanePresentation {
        switch lane {
        case let .unavailable(reason):
            return ProvenanceLanePresentation(
                state: .unavailable(reason),
                stateCopy: try reference(for: .provenanceUnavailable)
            )
        case let .available(evidence):
            let key = evidence.stateKey
            return ProvenanceLanePresentation(
                state: .available(evidence.category),
                stateCopy: try reference(for: .provenanceState(key))
            )
        }
    }

    /// Resolves a Combined Summary.
    ///
    /// The summary's copy key identifies its own surface, so a key the active fusion
    /// rule cannot produce is unreachable and refused. That is the presentation-side
    /// half of "fusion is a pure lookup over an approved table": a summary cannot
    /// appear from a rule this release does not bind.
    public func presentation(
        forCombinedSummary summary: CombinedSummary
    ) throws(PresentationCopyError) -> CombinedSummaryPresentation {
        CombinedSummaryPresentation(
            summaryCopy: try reference(for: .combinedSummary(summary.copyKey)),
            fusionRuleID: summary.fusionRuleID
        )
    }

    /// Resolves one Analysis Error and its recovery.
    public func presentation(
        forError error: AnalysisError
    ) throws(PresentationCopyError) -> AnalysisErrorPresentation {
        let key = error.errorKey
        return AnalysisErrorPresentation(
            error: error,
            messageCopy: try reference(for: .analysisError(key)),
            recoveryCopy: try reference(for: .errorRecovery(key))
        )
    }

    /// Resolves the apparent-inconsistency notice a report declared.
    ///
    /// The notice preserves both cards without suppressing, overriding, or ranking
    /// either (Requirement 7.8), so it resolves to one approved explanatory string and
    /// nothing else. The declared key must be the key the catalogue approved for the
    /// surface.
    public func apparentInconsistencyReference(
        declaredKey: ApprovedCopyKey
    ) throws(PresentationCopyError) -> ResolvedCopyReference {
        try reference(for: .apparentInconsistency, declaredKey: declaredKey)
    }
}

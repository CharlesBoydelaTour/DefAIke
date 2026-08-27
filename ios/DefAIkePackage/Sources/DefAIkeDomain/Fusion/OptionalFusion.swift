// Fusion as an optional capability: how a release that has no usable rule says so.
//
// Requirement 7.16 is an asymmetry, and it is the reason this type exists separately from
// ``ApprovedFusionRule``. Every other release artifact in this domain is required: a
// Calibration Policy that does not activate leaves the bundle unusable, and a Release
// Readiness Record that does not validate blocks the distribution. A fusion rule is the
// one artifact whose failure costs a *sentence*. If no rule passes every fusion criterion
// and every other mandatory gate passes, the release ships — with both source-lane cards
// fully visible and no Combined Summary (Requirements 7.9 and 7.16).
//
// Three structural consequences, and all three are the point:
//
//   * ``resolving(candidate:verdictCopy:fixtures:evidence:)`` does not throw and has no
//     failable form. There is no way to ask this type for a rule and be refused, so no
//     caller can turn a rejected rule into a startup failure or a blocked release by
//     forgetting a `try`.
//   * The rejection is *kept*, not discarded. ``FusionOmission/candidateRejected`` carries
//     the ``ArtifactSchemaError`` that refused the rule, so a release audit can read which
//     entry was unfixtured even though nothing was blocked. Omitting silently would make a
//     broken rule and no rule indistinguishable.
//   * There is no empty table anywhere. `.omitted` is a case, not an
//     ``ApprovedFusionRule`` with zero entries — which is unconstructible anyway, since
//     validation fills all 15 slots or throws. An absent rule stays absent rather than
//     being encoded as a rule that fuses nothing, because those two read the same at a
//     lookup and mean completely different things to an audit.
//
// What this type still refuses to do is show a summary it should not. The unavailable
// provenance lane bypasses the table in ``ApprovedFusionRule`` and bypasses it here too,
// and a session bound to a different rule is a ``FusionFault`` from the port rather than a
// quiet omission: attributing a sentence to the wrong mapping is not the same kind of
// problem as having no mapping.

/// Why a release has no Combined Summary.
///
/// Not an ``AnalysisError`` and not a ``FusionFault``: neither case is a fault at all. Both
/// are ordinary release configurations in which a report carries both lanes and no fused
/// sentence.
///
/// Deliberately not `Hashable`: ``ArtifactSchemaError`` is `Equatable` and not `Hashable`,
/// and reducing the carried refusal to a hashable summary would lose the field name that
/// makes it worth carrying.
public enum FusionOmission: Equatable, Sendable, CustomStringConvertible {
    /// This release binds no Evidence Fusion Rule at all.
    ///
    /// The ordinary state of a release whose fusion gate is not applicable, and of every
    /// pixel-only composition: with no provenance lane there is nothing to fuse.
    case noRuleBound

    /// A candidate rule was refused, and this is the refusal.
    ///
    /// The summary is omitted. Nothing else changes: no gate fails, no session ends, and
    /// both source lanes still appear in full.
    case candidateRejected(ArtifactSchemaError)

    /// The refusal that caused this omission, or `nil` when no rule was offered.
    public var rejection: ArtifactSchemaError? {
        switch self {
        case .noRuleBound: nil
        case let .candidateRejected(error): error
        }
    }

    public var description: String {
        switch self {
        case .noRuleBound:
            "no Evidence Fusion Rule is bound; the Combined Summary is omitted"
        case let .candidateRejected(error):
            "the candidate Evidence Fusion Rule was refused (\(error)); "
                + "the Combined Summary is omitted"
        }
    }
}

/// The fusion capability of one release: an approved rule, or a recorded omission.
///
/// This is what a composition root holds and what a session is bound against. It replaces
/// `ApprovedFusionRule?` so that "no summary" carries its reason, and so the type of the
/// value makes clear that the absent case is expected rather than exceptional.
public enum OptionalFusion: Equatable, Sendable {
    /// A rule that passed every fusion criterion, ready to be looked up.
    case approved(ApprovedFusionRule)

    /// No Combined Summary, for the carried reason.
    case omitted(FusionOmission)

    /// Validates `candidate` and reports the outcome without ever failing.
    ///
    /// Total by construction: a `nil` candidate is ``FusionOmission/noRuleBound``, a
    /// refused candidate is ``FusionOmission/candidateRejected``, and there is no third
    /// outcome and no thrown error. That signature is Requirement 7.16 — a rule that
    /// cannot be used costs the summary and nothing else.
    ///
    /// The catalogue and suite are non-optional because a release that binds a candidate
    /// rule at all has both: the rule names them, and validating against something else
    /// would approve copy and fixtures the rule never claimed. A release with no candidate
    /// passes `nil` and never reaches them.
    public static func resolving(
        candidate: EvidenceFusionRule?,
        verdictCopy catalog: ApprovedVerdictCopyCatalog,
        fixtures suite: ReleaseFixtureSuite,
        evidence index: ReleaseEvidenceIndex
    ) -> OptionalFusion {
        guard let candidate else { return .omitted(.noRuleBound) }
        do {
            return .approved(
                try ApprovedFusionRule(
                    validating: candidate,
                    verdictCopy: catalog,
                    fixtures: suite,
                    evidence: index
                )
            )
        } catch let error as ArtifactSchemaError {
            return .omitted(.candidateRejected(error))
        } catch {
            // `ApprovedFusionRule` throws only `ArtifactSchemaError`, and the compiler
            // cannot yet say so through an untyped `throws`. Anything else is still an
            // omission rather than a block: this file has no path that fails.
            return .omitted(
                .candidateRejected(
                    .forbiddenValue(
                        field: "fusionRule",
                        value: candidate.id.rawValue,
                        reason: "\(error)"
                    )
                )
            )
        }
    }

    // MARK: Accessors

    /// The validated rule, or `nil` when this release has no Combined Summary.
    ///
    /// `nil` is never "a rule exists but was not checked": the only way to reach
    /// ``approved(_:)`` is through validation.
    public var approvedRule: ApprovedFusionRule? {
        switch self {
        case let .approved(rule): rule
        case .omitted: nil
        }
    }

    /// Why there is no summary, or `nil` when an approved rule is bound.
    public var omission: FusionOmission? {
        switch self {
        case .approved: nil
        case let .omitted(reason): reason
        }
    }

    /// The bound rule's artifact identifier, for an ``AnalysisSessionBinding``.
    ///
    /// `nil` when fusion is omitted, which is exactly the value
    /// ``AnalysisSessionBinding/fusionRuleID`` takes in a release with no rule. That
    /// correspondence is why the binding's field is optional: a session records the rule it
    /// was bound to, and there is nothing to record here.
    public var boundRuleID: ArtifactID? { approvedRule?.id }

    /// The rule version a displayed summary is attributed to, or `nil` when none is bound.
    public var ruleVersion: SchemaSemanticVersion? { approvedRule?.ruleVersion }

    // MARK: Lookup

    /// The attributed entry for one pixel label beside a provenance lane, or `nil`.
    ///
    /// Three separate ways to reach `nil`, and none of them is a failure:
    ///
    ///   * no approved rule is bound, so no table is consulted;
    ///   * the provenance lane is unavailable, so no combination applies; or
    ///   * the approved entry for the combination is explicit omission.
    ///
    /// They are collapsed deliberately at this level. A caller deciding whether to show a
    /// summary needs one answer, and the distinctions stay readable through ``omission``
    /// and the returned entry for anyone auditing why.
    public func attributedEntry(
        pixel: PixelEvidence,
        provenance: ProvenanceLane
    ) -> AttributedFusionEntry? {
        approvedRule?.attributedEntry(pixel: pixel, provenance: provenance)
    }

    /// The Combined Summary to show beside both lanes, or `nil` when there is none.
    ///
    /// Total and non-throwing over every representable input: three pixel labels crossed
    /// with five enabled states and two unavailable reasons, against a bound rule or an
    /// omission. No input to this function can refuse an analysis or block a release.
    public func summary(
        pixel: PixelEvidence,
        provenance: ProvenanceLane
    ) -> CombinedSummary? {
        attributedEntry(pixel: pixel, provenance: provenance)?.summary
    }
}

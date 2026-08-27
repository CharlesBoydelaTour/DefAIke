import DefAIkeDomain

// The fail-closed error vocabulary for Approved Verdict Copy resolution.
//
// Requirement 8.1 requires version-controlled copy, compatible with the
// Analysis-Session-bound Model Bundle, for every Pixel Evidence label, provenance
// source-lane state, unavailable state, Combined Summary, warning, and Analysis
// Error. ``ApprovedCopyKey`` already states the consequence of a gap: an
// unresolvable key is a fail-closed presentation error, not a free-form string to
// render.
//
// This is that error. Three absences are deliberate and load-bearing:
//
//   * no `unknown` or `other` case, so every refusal names one cause an audit can
//     read back;
//   * no case carries replacement, placeholder, or degraded text, and no case can
//     be turned into a resolved reference, so "render the raw key" and "render a
//     generated sentence" are both unrepresentable; and
//   * no case is recoverable by relaxing a check. A caller either has a compatible
//     approved entry or it has an error.

/// Which artifact disagreed about the Approved Verdict Copy compatibility
/// identifier.
///
/// Requirement 8.1 binds copy to the session's Model Bundle, so three independent
/// records have to name the same compatibility identifier: the signed Release
/// Capability Manifest, the immutable session binding, and the catalogue itself. A
/// fourth appears once fusion is enabled. Naming the disagreeing record keeps a
/// version-skew failure diagnosable without widening the error.
public enum CopyCompatibilitySource: String, Hashable, Sendable, CaseIterable {
    /// The signed Release Capability Manifest's policy compatibility set.
    case capabilityManifest = "capability-manifest"
    /// The immutable Analysis Session binding.
    case sessionBinding = "session-binding"
    /// The Approved Verdict Copy catalogue.
    case copyCatalog = "copy-catalog"
    /// The active Evidence Fusion Rule.
    case fusionRule = "fusion-rule"
}

/// Why approved copy could not be bound or resolved.
public enum PresentationCopyError: Error, Hashable, Sendable {
    /// The catalogue is not the single Version 1 user-facing language
    /// (Requirement 8.18).
    case unsupportedLanguage(expected: String, found: String)

    /// The catalogue carries a rejected content approval. Presence of an approval
    /// record is not approval, so a rejected decision fails closed rather than
    /// shipping unapproved wording.
    case unapprovedCatalog(catalog: ArtifactID, decision: ApprovalDecision)

    /// The session was bound to a different Release Capability Manifest than the
    /// one supplied, so the two disagree about the enabled capability set.
    case capabilityManifestMismatch(session: ArtifactID, supplied: ArtifactID)

    /// One record names a different Approved Verdict Copy compatibility identifier
    /// than the session-bound Model Bundle (Requirement 8.1).
    case compatibilityMismatch(
        source: CopyCompatibilitySource,
        expected: ArtifactID,
        found: ArtifactID
    )

    /// The manifest and the session disagree about whether provenance is enabled,
    /// so which provenance surfaces are reachable is undecidable.
    case provenanceBindingMismatch(manifestEnablesProvenance: Bool, sessionBindsPolicy: Bool)

    /// The manifest and the session disagree about whether fusion is enabled.
    case fusionBindingMismatch(manifestEnablesFusion: Bool, sessionBindsRule: Bool)

    /// Fusion is enabled but no Evidence Fusion Rule was supplied, so the
    /// reachable Combined Summary keys are unknown.
    case missingFusionRule(expected: ArtifactID)

    /// An Evidence Fusion Rule was supplied for a release that does not enable
    /// fusion. An unavailable provenance lane can never support a Combined Summary
    /// (Requirement 7.10).
    case unexpectedFusionRule(supplied: ArtifactID)

    /// The supplied rule is not the rule this release and session are bound to.
    case fusionRuleMismatch(expected: ArtifactID, found: ArtifactID)

    /// Reachable surfaces the catalogue has no approved entry for, in stable order.
    case missingSurfaces([VerdictCopySurface])

    /// The surface is not reachable in this release's capability composition, so
    /// resolving it would render a state this build cannot produce. A pixel-only
    /// build cannot address an enabled provenance state at all, which is what makes
    /// "describe the lane as unavailable rather than absent, invalid, or authentic"
    /// structural rather than a rendering convention (Requirement 8.8).
    case unreachableSurface(VerdictCopySurface)

    /// The surface is reachable but the bound catalogue has no entry for it.
    case unresolvableSurface(VerdictCopySurface)

    /// A component declared a copy key that is not the approved key for its
    /// surface, so an unapproved sentence would be shown under an approved label.
    case unapprovedCopyKey(
        surface: VerdictCopySurface,
        declared: ApprovedCopyKey,
        approved: ApprovedCopyKey
    )

    /// A rendered pixel label is not the exact required string (Requirement 8.2).
    case pixelLabelTextMismatch(label: PixelLabelKey, expected: String, found: String)
}

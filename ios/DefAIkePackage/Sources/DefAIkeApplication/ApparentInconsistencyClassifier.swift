import DefAIkeDomain

// The release-controlled apparent-inconsistency classifier.
//
// Requirement 7.8 has two halves and they are enforced in different places. "Retain both
// source-lane results without suppressing, overriding, or ranking either" is structural:
// `ResolvedEvidenceLanes` carries both lanes verbatim and `EvidenceReport` has separate
// immutable fields for them, so there is nothing here that could suppress a lane. What is
// left is naming the apparent inconsistency, and that is this type: a lookup that may
// attach one approved explanatory key *beside* the two unchanged lanes.
//
// The classifier is additive only. It cannot change, reorder, hide, or outrank a lane,
// because it returns an ``ApprovedCopyKey`` and nothing else. That is the whole reason
// the design calls it a classifier rather than a resolver: an apparent contradiction is
// reported, never resolved.
//
// **Which lane combinations count as apparently inconsistent is an unresolved external
// decision.** It belongs with the fusion mappings and approved verdict copy the README
// lists as deliberately unresolved, and there is no default for it here — not a set, not
// a heuristic, and not a "positive pixel beside a validated credential" rule invented in
// source. A release that has not declared the set has no classifier, which the coordinator
// takes as `nil` and reports as no notice. Failing closed in that direction is safe and is
// not an understated limitation: both cards stay fully visible either way, which is the
// mandatory half of the requirement, and no notice is a missing sentence rather than a
// wrong one.
//
// The wording is equally not this type's to choose. The notice key comes from the
// Approved Verdict Copy catalogue's `apparent-inconsistency` surface, which is already in
// the closed unconditional surface vocabulary, so every release has to approve it
// (Requirement 8.1).

/// Names an apparent inconsistency between the two source lanes with approved copy.
///
/// Bound to one Approved Verdict Copy catalogue version, so the notice a report carries
/// cannot come from copy the session's Model Bundle and capability set were never
/// compatible with.
public struct ApparentInconsistencyClassifier: Hashable, Sendable {
    /// The approved copy key for the apparent-inconsistency notice.
    public let noticeKey: ApprovedCopyKey

    /// The catalogue the notice key came from.
    public let copyCatalogID: ArtifactID

    /// That catalogue's compatibility identifier, which the session's Model Bundle and
    /// capability set must match (Requirement 8.1).
    public let copyCompatibilityID: ArtifactID

    /// The enabled lane combinations an approved release decision declared apparently
    /// inconsistent.
    ///
    /// Keyed by ``FusionLaneCombination``, so the declared space is exactly the 3 × 5
    /// enabled combinations. The unavailable lane has no key in that space and therefore
    /// cannot be declared inconsistent with anything (Requirement 7.10's structure,
    /// reused: with no provenance evidence there is nothing to be inconsistent with).
    ///
    /// Nothing in this module supplies this set. It arrives from the composition root as
    /// an approved release input.
    public let contradictoryCombinations: Set<FusionLaneCombination>

    /// Builds a classifier from an approved catalogue and a declared combination set.
    ///
    /// Returns `nil` when:
    ///
    /// * the catalogue's own approval record is not an approval, because presence in a
    ///   build is not approval;
    /// * the catalogue omits the `apparent-inconsistency` surface, since the notice has
    ///   no wording without it and no fallback string may be substituted; or
    /// * `contradictoryCombinations` is empty. An empty set classifies nothing, and
    ///   permitting it would give one behavior two encodings — a release that declares no
    ///   contradictions has no classifier, and that is expressed by having none.
    public init?(
        catalog: ApprovedVerdictCopyCatalog,
        contradictoryCombinations: Set<FusionLaneCombination>
    ) {
        guard catalog.approval.isApproved else { return nil }
        guard let noticeKey = catalog.localizationKey(for: .apparentInconsistency) else {
            return nil
        }
        guard !contradictoryCombinations.isEmpty else { return nil }
        self.noticeKey = noticeKey
        self.copyCatalogID = catalog.id
        self.copyCompatibilityID = catalog.compatibilityID
        self.contradictoryCombinations = contradictoryCombinations
    }

    /// The approved notice for one resolved lane pair, or `nil` when none applies.
    ///
    /// A pure lookup with no default branch, deliberately shaped like fusion: an
    /// undeclared combination produces no notice, exactly as an unentered fusion
    /// combination could not exist. `nil` for an unavailable provenance lane without
    /// consulting the declared set at all, since an unavailable lane is not a finding
    /// about the image and cannot contradict one.
    public func notice(
        pixel: PixelEvidence,
        provenance: ProvenanceLane
    ) -> ApprovedCopyKey? {
        guard let evidence = provenance.evidence else { return nil }
        let combination = FusionLaneCombination.lookupKey(pixel: pixel, provenance: evidence)
        return contradictoryCombinations.contains(combination) ? noticeKey : nil
    }

    /// The approved notice for a joined pair of lanes.
    public func notice(for lanes: ResolvedEvidenceLanes) -> ApprovedCopyKey? {
        notice(pixel: lanes.pixel, provenance: lanes.provenance)
    }
}

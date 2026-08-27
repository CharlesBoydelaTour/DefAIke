import DefAIkeDomain

// Which copy surfaces one release composition can actually reach.
//
// Requirement 8.1 requires an approved entry for every reachable label, provenance
// state, unavailable state, Combined Summary, warning, and Analysis Error. "Every
// reachable" is not "every conceivable": a pixel-only build never produces an
// enabled provenance state, and a release with no approved Evidence Fusion Rule
// never produces a Combined Summary (Requirements 6.20, 7.10, and 7.16).
//
// So the required set is computed from the signed Release Capability Manifest and
// the active fusion rule, never from a hard-coded list. Two consequences follow, and
// both are intentional:
//
//   * a pixel-only catalogue is not failed for omitting provenance-state entries;
//   * a provenance-enabled catalogue *is* failed for omitting even one of them,
//     before any session runs, rather than at render time.

/// The copy surfaces one capability composition can reach, and therefore the
/// surfaces its catalogue must cover.
public struct ReachableCopySurfaces: Hashable, Sendable {
    /// Every surface this composition can reach.
    public let surfaces: Set<VerdictCopySurface>

    /// Whether an enabled provenance state is reachable at all.
    public let isProvenanceEnabled: Bool

    /// Whether a Combined Summary is reachable at all.
    public let isFusionEnabled: Bool

    /// The Combined Summary copy keys the active fusion rule can produce.
    ///
    /// Empty when fusion is disabled, and empty when every disposition in an active
    /// rule is an explicit omission. A rule of only omissions is valid: omission has
    /// to be written down (Requirement 7.12), and writing it down for all fifteen
    /// combinations reaches no summary surface.
    public let combinedSummaryKeys: Set<ApprovedCopyKey>

    /// Computes the reachable surfaces for one release composition.
    ///
    /// `fusionRule` is the rule the release actually binds, or `nil` when the
    /// composition enables no fusion. Whether supplying it is coherent with
    /// `capabilities` is checked by ``ApprovedCopyBinding``; this type answers only
    /// the reachability question.
    public init(
        capabilities: ReleaseCapabilityManifest,
        fusionRule: EvidenceFusionRule?
    ) {
        let provenanceEnabled = capabilities.enablesProvenance
        let summaryKeys: Set<ApprovedCopyKey> = fusionRule.map { rule in
            Set(
                rule.entries.compactMap { entry in
                    guard case let .show(key) = entry.disposition else { return nil }
                    return key
                }
            )
        } ?? []

        // Unconditional surfaces come from the domain catalogue schema rather than
        // from a second list here, so adding a surface to the closed vocabulary
        // cannot silently leave presentation behind.
        var reachable = VerdictCopySurface.unconditionalSurfaces
        if provenanceEnabled {
            for state in ProvenanceStateKey.allCases {
                reachable.insert(.provenanceState(state))
            }
        }
        for key in summaryKeys {
            reachable.insert(.combinedSummary(key))
        }

        self.surfaces = reachable
        self.isProvenanceEnabled = provenanceEnabled
        self.isFusionEnabled = fusionRule != nil
        self.combinedSummaryKeys = summaryKeys
    }

    /// Whether this composition can reach `surface`.
    public func contains(_ surface: VerdictCopySurface) -> Bool {
        surfaces.contains(surface)
    }

    /// Reachable surfaces `catalog` has no approved entry for, in stable order.
    ///
    /// Ordered by the surface's stable key so a failure report is deterministic and
    /// diffable rather than set-iteration ordered.
    public func missingSurfaces(
        in catalog: ApprovedVerdictCopyCatalog
    ) -> [VerdictCopySurface] {
        let covered = Set(catalog.entries.map(\.surface))
        return surfaces.subtracting(covered).sorted { $0.description < $1.description }
    }
}

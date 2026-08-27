import DefAIkeDomain

// The approved copy a provenance evidence value cannot be built without.
//
// Four of the five enabled states carry an ``ApprovedCopyKey``: `invalid`,
// `unsupported`, and `indeterminate` each need an explanation key, and every displayed
// detail needs a label key. Requirement 8.1 requires that copy to be version-controlled
// and compatible with the session's Model Bundle and capability set, so none of those
// keys may be minted in source. This type is where they arrive from approved artifacts,
// and it fails closed when any required key is missing.
//
// The state explanations come from the Approved Verdict Copy catalogue's
// `provenance-state/*` surfaces, which already exist in the closed surface vocabulary.
// The detail labels do not have a surface case yet, so they are supplied explicitly and
// must cover exactly the policy's displayable fields. Either way, nothing here has a
// default: a build that has not been given approved copy cannot project a validator
// result at all.

/// The approved copy keys required to project one validator outcome for display.
///
/// Bound to one Provenance Policy and one Approved Verdict Copy catalogue version, so a
/// mapper cannot be assembled from a policy and copy that were never approved together.
public struct ProvenanceCopyBinding: Hashable, Sendable {
    /// The Provenance Policy this binding was validated against.
    public let policyID: ArtifactID

    /// The Approved Verdict Copy catalogue the state explanations came from.
    public let copyCatalogID: ArtifactID

    /// That catalogue's compatibility identifier, which the session's Model Bundle and
    /// capability set must match (Requirement 8.1).
    public let copyCompatibilityID: ArtifactID

    /// One approved explanation key for each of the five enabled states.
    public let stateExplanations: [ProvenanceStateKey: ApprovedCopyKey]

    /// One approved label key for each field the policy permits displaying.
    public let detailLabels: [ProvenanceDisplayField: ApprovedCopyKey]

    /// Builds a binding from an approved policy, catalogue, and detail-label mapping.
    ///
    /// Returns `nil` when:
    ///
    /// * the catalogue's own approval record is not an approval, because presence is
    ///   not approval;
    /// * the catalogue omits the approved copy for any of the five enabled states,
    ///   since every reachable state needs an approved explanation; or
    /// * `detailLabels` does not cover exactly the policy's `displayableFields`, or
    ///   reuses one key for two fields. A missing label would silently drop a detail
    ///   Requirement 6.10 requires reporting; an extra one would name a field the
    ///   policy does not permit displaying.
    public init?(
        policy: ProvenancePolicy,
        catalog: ApprovedVerdictCopyCatalog,
        detailLabels: [ProvenanceDisplayField: ApprovedCopyKey]
    ) {
        guard catalog.approval.isApproved else { return nil }

        var explanations: [ProvenanceStateKey: ApprovedCopyKey] = [:]
        for state in ProvenanceStateKey.allCases {
            guard let key = catalog.localizationKey(for: .provenanceState(state)) else {
                return nil
            }
            explanations[state] = key
        }

        guard Set(detailLabels.keys) == policy.displayableFields else { return nil }
        guard Set(detailLabels.values).count == detailLabels.count else { return nil }

        self.policyID = policy.id
        self.copyCatalogID = catalog.id
        self.copyCompatibilityID = catalog.compatibilityID
        self.stateExplanations = explanations
        self.detailLabels = detailLabels
    }
}

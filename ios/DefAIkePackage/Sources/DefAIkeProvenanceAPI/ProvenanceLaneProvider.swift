import DefAIkeDomain

// The provenance source lane of one capability composition.
//
// Requirements 6.3, 6.4, 6.19, 6.20, and 7.10 together describe a release whose Content
// Credential validation is not usable: the provenance lane is unavailable, the analyzer
// stays inactive, the report uses only the unavailable state, and no Combined Summary is
// shown. This type is where all four hold at once, structurally:
//
//   * the unavailable case holds no analyzer, so there is nothing to invoke — "never
//     invoked" is not a check that can be forgotten but the absence of a callee;
//   * ``lane(for:)`` returns `.unavailable` on that path without awaiting anything; and
//   * ``fusionInput`` is `nil` for an unavailable lane, and `EvidenceFusing` takes
//     `ProvenanceEvidence` rather than `ProvenanceLane`, so fusion of an unavailable
//     lane is unrepresentable rather than merely avoided. `EvidenceReport` separately
//     refuses to hold a Combined Summary beside an unavailable lane.
//
// Linking a validator is not approval to use one, and this is where that stops being a
// slogan. The application composition links the reviewed adapter unconditionally, so
// non-linkage no longer does the work of keeping the validator inactive;
// ``resolve(linksValidator:analyzer:policy:manifest:)`` does, by requiring the signed
// Release Capability Manifest to enable the capability, to bind this exact policy, to
// record this exact implementation version, to carry an approved Provenance Feasibility
// decision, *and* an analyzer to exist. Anything less is the unavailable lane, and which
// of the three ``UnavailableReason`` values it reports says which requirement was the one
// left unmet.

/// Supplies the provenance source lane for one build.
///
/// Two states, and only one of them can reach a validator. `Hashable` is deliberately
/// absent: the enabled case holds an analyzer, and lane identity is a property of the
/// resolved lane value, not of the provider.
public struct ProvenanceLaneProvider: Sendable {
    private enum Composition: Sendable {
        case unavailable(UnavailableReason)
        case enabled(analyzer: any ProvenanceAnalyzing, policy: ProvenancePolicy)
    }

    private let composition: Composition

    private init(composition: Composition) {
        self.composition = composition
    }

    /// A build that links no Content Credential validator.
    ///
    /// A compile-time fact about the module graph, re-checked by the release archive
    /// audit and by `check-module-boundaries.py`, not a runtime setting. The shipped
    /// application composition links the adapter, so this is not the lane it reports;
    /// it stays because non-linkage is still representable and must still be answerable
    /// honestly when it happens.
    public static let validatorNotLinked = ProvenanceLaneProvider(
        composition: .unavailable(.validatorNotCompiledIntoRelease)
    )

    /// A build that compiled a validator the signed manifest does not enable for it.
    ///
    /// Also the outcome when the manifest enables the capability but does not name this
    /// policy, this implementation version, or an approved feasibility decision: such a
    /// manifest has not enabled provenance for *this* configuration.
    public static let capabilityNotEnabled = ProvenanceLaneProvider(
        composition: .unavailable(.capabilityNotEnabledByReleaseCapabilityManifest)
    )

    /// A build whose linked validator is enabled but has no analyzer to run.
    ///
    /// The state of a composition that links the reviewed adapter and carries a manifest
    /// that enables the capability, while the adapter still cannot conform to
    /// ``ProvenanceAnalyzing``. Fail-closed: the lane is unavailable, and it says so for
    /// the reason that is actually true rather than borrowing one of the other two.
    public static let enablementUnapproved = ProvenanceLaneProvider(
        composition: .unavailable(.validatorEnablementUnapproved)
    )

    /// Resolves the lane for a build, from what it compiled and what its manifest says.
    ///
    /// Total, and fail-closed at every step: every path short of full satisfaction is an
    /// unavailable lane, and none of them can reach the analyzer.
    ///
    /// The order of the three groups of checks is the load-bearing part, because each
    /// group can only honestly report its own reason:
    ///
    ///   1. **`linksValidator` first, and it outranks the manifest.** A signed manifest
    ///      cannot enable a capability whose implementation is absent from the binary,
    ///      so a build without the adapter reports
    ///      ``UnavailableReason/validatorNotCompiledIntoRelease`` whatever the manifest
    ///      says. It is passed in rather than inferred from `analyzer != nil`, which is
    ///      the whole point: an analyzer can be absent from a build that *does* link the
    ///      adapter, and conflating the two is what made a linked build claim its own
    ///      validator was never compiled.
    ///   2. **Then the manifest**, in full — enabled, policy bound, adapter version
    ///      matched, feasibility approved. Anything less has not enabled provenance for
    ///      this configuration.
    ///   3. **Then the analyzer.** Linked and enabled but absent is
    ///      ``UnavailableReason/validatorEnablementUnapproved``, which misstates neither
    ///      the module graph nor the manifest.
    public static func resolve(
        linksValidator: Bool,
        analyzer: (any ProvenanceAnalyzing)?,
        policy: ProvenancePolicy?,
        manifest: ReleaseCapabilityManifest
    ) -> ProvenanceLaneProvider {
        guard linksValidator else { return .validatorNotLinked }
        guard manifest.enablesProvenance, let policy else { return .capabilityNotEnabled }
        guard manifest.policyCompatibility.provenancePolicy.boundReference == policy.id else {
            return .capabilityNotEnabled
        }
        guard manifest.implementationVersion(for: .contentCredentialValidation)
            == policy.validatorImplementationVersion
        else {
            return .capabilityNotEnabled
        }
        guard policy.feasibilityApproval.isApproved else { return .capabilityNotEnabled }
        guard let analyzer else { return .enablementUnapproved }
        return ProvenanceLaneProvider(composition: .enabled(analyzer: analyzer, policy: policy))
    }

    /// Whether this composition can produce provenance evidence.
    public var isEnabled: Bool {
        switch composition {
        case .unavailable: false
        case .enabled: true
        }
    }

    /// Why the lane is unavailable, or `nil` when the capability is enabled.
    public var unavailableReason: UnavailableReason? {
        switch composition {
        case let .unavailable(reason): reason
        case .enabled: nil
        }
    }

    /// The Provenance Policy version in force, or `nil` when the lane is unavailable.
    ///
    /// A session records this in its immutable binding, which is why an unavailable
    /// composition records no provenance policy identifier at all.
    public var boundPolicyID: ArtifactID? {
        switch composition {
        case .unavailable: nil
        case let .enabled(_, policy): policy.id
        }
    }

    /// Whether a Combined Summary is reachable in this composition.
    ///
    /// Always false while the lane is unavailable (Requirement 7.10). Fusion
    /// additionally requires an approved Evidence Fusion Rule, which this type does not
    /// speak for.
    public var canProduceCombinedSummary: Bool { isEnabled }

    /// Produces the provenance source lane for one accepted ingest.
    ///
    /// On the unavailable path nothing is called and nothing is awaited: the lane is the
    /// composition's fixed reason. On the enabled path the analyzer receives the exact
    /// retained bytes immutably and has no access to the pixel lane, so it cannot change
    /// the raw logit, the execution status, or Pixel Evidence (Requirements 6.6 and 7.4).
    public func lane(for asset: ImportedEncodedAsset) async -> ProvenanceLane {
        switch composition {
        case let .unavailable(reason):
            return .unavailable(reason)
        case let .enabled(analyzer, policy):
            return .available(await analyzer.analyze(asset, policy: policy))
        }
    }

    /// The normalized inspection request for one accepted ingest, or `nil` when the
    /// lane is unavailable.
    ///
    /// An unavailable composition never describes an inspection, because no inspection
    /// happens.
    public func inspectionRequest(
        for asset: ImportedEncodedAsset
    ) -> ProvenanceInspectionRequest? {
        switch composition {
        case .unavailable:
            return nil
        case let .enabled(_, policy):
            return ProvenanceInspectionRequest(asset: asset, policy: policy)
        }
    }
}

extension ProvenanceLane {
    /// The value fusion consumes, or `nil` when this lane bypasses fusion entirely.
    ///
    /// The same answer as ``ProvenanceLane/evidence``, named for the decision it makes:
    /// `nil` means omit the Combined Summary (Requirement 7.10). Kept as a lane-level
    /// member so the fusion decision reads the same whether it is taken from a resolved
    /// lane or from a provider.
    public var fusionInput: ProvenanceEvidence? { evidence }
}
